// CUPairingSession with application-owned keys only. Its raw callback ABI was
// verified in CoreUtils +0x84be0/+0x84d14 and rapportd's native block descriptors.
#import "pair-verify-bridge.h"
#import <dlfcn.h>

@protocol AFNativePairingStream
- (NSData *)encryptData:(NSData *)data aadData:(NSData *)aad error:(NSError **)error;
- (NSData *)decryptData:(NSData *)data aadData:(NSData *)aad error:(NSError **)error;
@end

@protocol AFNativePairingSession
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)setSessionType:(uint32_t)type;
- (void)setFlags:(uint32_t)flags;
- (void)setLabel:(NSString *)label;
- (void)setSignDataHandler:(NSData *(^)(uint32_t, NSData *, NSError **))handler;
- (void)setVerifySignatureHandler:(BOOL (^)(uint32_t, NSData *, NSData *, NSError **))handler;
- (void)setSendDataHandler:(void (^)(uint32_t, NSData *))handler;
- (void)setCompletionHandler:(void (^)(NSError *))handler;
- (void)activate;
- (void)receivedData:(NSData *)data;
- (id<AFNativePairingStream>)openStreamWithName:(NSString *)name error:(NSError **)error;
- (void)invalidate;
@end

@interface AFPairVerify ()
@property id<AFNativePairingSession> engine;
@property id<AFNativePairingStream> stream;
@property dispatch_queue_t queue;
@property NSMutableArray<NSData *> *outgoing;
@property(copy) void (^pending)(NSData *, BOOL, int);
@property BOOL verified;
@property BOOL invalidated;
@property int failure;
@property NSUInteger generation;
- (void)flush;
- (void)close;
@end

@implementation AFPairVerify
- (void)flush {
    if (!self.pending || (!self.outgoing.count && !self.verified && !self.failure)) return;
    void (^callback)(NSData *, BOOL, int) = self.pending;
    self.pending = nil;
    NSData *data = self.outgoing.firstObject;
    if (data) [self.outgoing removeObjectAtIndex:0];
    callback(data, self.verified, self.failure);
}
- (void)close {
    if (self.invalidated) return;
    self.invalidated = YES;
    if (!self.failure) self.failure = -6754;
    [self.engine setSignDataHandler:nil];
    [self.engine setVerifySignatureHandler:nil];
    [self.engine setSendDataHandler:nil];
    [self.engine setCompletionHandler:nil];
    [self.engine invalidate];
    self.engine = nil;
    self.stream = nil;
    [self flush];
}
@end

AFPairVerify *AFCreatePairVerify(BOOL server, NSData *(^sign)(NSData *), BOOL (^verify)(NSData *, NSData *)) {
    dlopen("/System/Library/PrivateFrameworks/CoreUtils.framework/CoreUtils", RTLD_LAZY | RTLD_LOCAL);
    Class cls = NSClassFromString(@"CUPairingSession");
    if (!cls) return nil;
    AFPairVerify *session = [AFPairVerify new];
    session.queue = dispatch_queue_create("pl.airfolder.pair-verify", DISPATCH_QUEUE_SERIAL);
    session.outgoing = [NSMutableArray array];
    session.engine = (id<AFNativePairingSession>)[cls new];
    __weak AFPairVerify *weak = session;
    [session.engine setDispatchQueue:session.queue];
    [session.engine setFlags:0x400000];
    [session.engine setSessionType:server ? 4 : 3];
    [session.engine setLabel:@"AimDropPairVerify"];
    [session.engine setSignDataHandler:^NSData *(uint32_t flags, NSData *data, NSError **error) {
        (void)flags;
        NSData *signature = sign(data);
        if (signature.length != 64) {
            if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-6754 userInfo:nil];
            return nil;
        }
        return signature;
    }];
    // NB: data precedes signature, unlike RPIdentity's verify selector.
    [session.engine setVerifySignatureHandler:^BOOL(uint32_t flags, NSData *data, NSData *signature, NSError **error) {
        (void)flags;
        BOOL valid = signature.length == 64 && verify(data, signature);
        if (!valid && error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-6754 userInfo:nil];
        return valid;
    }];
    [session.engine setSendDataHandler:^(uint32_t flags, NSData *data) {
        (void)flags;
        AFPairVerify *strong = weak;
        if (!strong || strong.invalidated) return;
        [strong.outgoing addObject:data];
        // The engine emits M4 before its success callback in the same queue
        // turn. Deliver both together; otherwise the caller can miss success.
        dispatch_async(strong.queue, ^{ [strong flush]; });
    }];
    [session.engine setCompletionHandler:^(NSError *error) {
        AFPairVerify *strong = weak;
        if (!strong || strong.invalidated) return;
        strong.failure = error ? (int)(error.code ?: -6754) : 0;
        strong.verified = error == nil;
        dispatch_async(strong.queue, ^{ [strong flush]; });
        if (error) [strong close];
    }];
    [session.engine activate];
    return session;
}

void AFPairVerifyExchange(AFPairVerify *session, NSData *data, void (^completion)(NSData *, BOOL, int)) {
    dispatch_async(session.queue, ^{
        if (session.pending || session.invalidated || session.verified) {
            completion(nil, session.verified, -6754); return;
        }
        session.pending = completion;
        NSUInteger generation = ++session.generation;
        if (data) [session.engine receivedData:data];
        [session flush];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), session.queue, ^{
            if (session.generation != generation || !session.pending) return;
            session.failure = -6722;
            [session close];
        });
    });
}

static NSData *AFPairVerifyCrypt(AFPairVerify *session, NSData *data, BOOL encrypt, NSError **error) {
    __block NSData *result = nil;
    __block NSError *failure = nil;
    dispatch_sync(session.queue, ^{
        if (!session.verified || session.invalidated) {
            failure = [NSError errorWithDomain:NSOSStatusErrorDomain code:-6754 userInfo:nil]; return;
        }
        if (!session.stream) session.stream = [session.engine openStreamWithName:@"RPPairingPairVerifyStream" error:&failure];
        if (!session.stream) return;
        NSData *aad = [@"rppairing-bonjour-resolve" dataUsingEncoding:NSUTF8StringEncoding];
        result = encrypt ? [session.stream encryptData:data aadData:aad error:&failure]
                         : [session.stream decryptData:data aadData:aad error:&failure];
        if (!result) [session close];
    });
    if (error) *error = failure;
    return result;
}
NSData *AFPairVerifyEncrypt(AFPairVerify *session, NSData *data, NSError **error) { return AFPairVerifyCrypt(session, data, YES, error); }
NSData *AFPairVerifyDecrypt(AFPairVerify *session, NSData *data, NSError **error) { return AFPairVerifyCrypt(session, data, NO, error); }
void AFPairVerifyInvalidate(AFPairVerify *session) { dispatch_async(session.queue, ^{ [session close]; }); }
