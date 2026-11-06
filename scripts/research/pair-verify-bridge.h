#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface AFPairVerify : NSObject
@end
AFPairVerify * _Nullable AFCreatePairVerify(BOOL server,
    NSData * _Nullable (^sign)(NSData *data), BOOL (^verify)(NSData *data, NSData *signature));
void AFPairVerifyExchange(AFPairVerify *session, NSData * _Nullable data,
    void (^completion)(NSData * _Nullable output, BOOL verified, int error));
NSData * _Nullable AFPairVerifyEncrypt(AFPairVerify *session, NSData *data, NSError **error);
NSData * _Nullable AFPairVerifyDecrypt(AFPairVerify *session, NSData *data, NSError **error);
void AFPairVerifyInvalidate(AFPairVerify *session);
NS_ASSUME_NONNULL_END
