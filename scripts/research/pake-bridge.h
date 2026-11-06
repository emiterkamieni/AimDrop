// Private API declarations for the standalone research executable.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Network/Network.h>
#import "pair-verify-bridge.h"

NS_ASSUME_NONNULL_BEGIN
sec_identity_t _Nullable AFCreateSPAKEIdentity(NSString *context, NSString *client,
                                              NSString *server, NSString *password,
                                              BOOL serverMode) NS_RETURNS_RETAINED;
sec_identity_t _Nullable AFCreatePrePairIdentity(void) NS_RETURNS_RETAINED;
BOOL AFSetPeerAuthenticationOptional(sec_protocol_options_t options);
nw_protocol_options_t _Nullable AFCreateTLSRecordOptions(void) NS_RETURNS_RETAINED;
BOOL AFConfigurePAKEChallenge(sec_protocol_options_t options,
                             sec_identity_t _Nullable (^lookup)(NSString *client, NSString *server));
NSData * _Nullable AFProbeAuthTag(NSData *irk, NSString *serverIdentity, NSDate *dateAdded);
nw_parameters_t _Nullable AFCreateApplicationServiceHTTP3Parameters(void) NS_RETURNS_RETAINED;
BOOL AFSetListenerPairingService(nw_listener_t listener, NSString *name, NSString *pin);
void AFReceiveHTTP(nw_connection_t connection, void (^completion)(NSString * _Nullable path, NSDictionary<NSString *, NSString *> *headers, NSData *data, BOOL complete, int error));
BOOL AFSendHTTP(nw_connection_t connection, unsigned status, NSData *data, NSDictionary<NSString *, NSString *> *headers, BOOL final, void (^completion)(int error));
nw_parameters_t _Nullable AFCreateHTTP3ClientParameters(void) NS_RETURNS_RETAINED;
NSData * _Nullable AFQUICPublicKey(nw_parameters_t parameters);
void AFHTTP3Check(nw_parameters_t parameters, NSString *serviceID, NSData *publicKey,
                  NSString *path, NSData *body, NSDictionary<NSString *, NSString *> *headers,
                  void (^completion)(unsigned status, NSData *body, NSDictionary<NSString *, NSString *> *headers, int error));
NS_ASSUME_NONNULL_END
