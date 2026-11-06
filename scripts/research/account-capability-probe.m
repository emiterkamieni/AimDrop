// Check the Rapport identity API's authorization gate without requesting any
// identity category. On macOS 26.5.2, flags=0 returns an empty list if authorized
// (RPIdentityDaemon getIdentitiesWithFlags: at 0x100065ed0).
// Never requests, inspects, exports, or logs account identity/key material.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

@protocol AFCapabilityClient
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)getIdentitiesWithFlags:(unsigned)flags completion:(void (^)(NSArray *, NSError *))completion;
- (void)invalidate;
@end

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        if (!dlopen("/System/Library/PrivateFrameworks/Rapport.framework/Rapport", RTLD_LAZY | RTLD_LOCAL)) return 2;
        Class cls = NSClassFromString(@"RPClient");
        if (!cls || ![cls instancesRespondToSelector:@selector(getIdentitiesWithFlags:completion:)]) return 2;
        id<AFCapabilityClient> client = (id<AFCapabilityClient>)[cls new];
        dispatch_queue_t queue = dispatch_queue_create("pl.airfolder.account-capability", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [client setDispatchQueue:queue];
        [client getIdentitiesWithFlags:0 completion:^(NSArray *identities, NSError *error) {
            if (error) {
                BOOL entitlement = [error.localizedDescription containsString:@"com.apple.rapport.Client"];
                printf("identity_api=denied domain=%s code=%ld rapport_client_entitlement_required=%s\n",
                       error.domain.UTF8String, (long)error.code, entitlement ? "yes" : "unknown");
            } else {
                printf("identity_api=authorized empty_selection=%s\n", identities.count == 0 ? "yes" : "unexpected-nonempty");
            }
            dispatch_semaphore_signal(done);
        }];
        BOOL timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0;
        [client invalidate];
        if (timedOut) puts("identity_api=timeout");
        return timedOut ? 3 : 0;
    }
}
