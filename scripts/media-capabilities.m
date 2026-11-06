// Build-time query of this Mac's media support, using the same representation
// as AirDrop. Optional private API: receiver/main.py has a legacy fallback.
// Only codec/container data is exported, not Photos asset/edit capabilities.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

@interface NSObject (AirFrajerMediaCapabilities)
+ (instancetype)capabilitiesForCurrentDevice;
- (NSData *)opaqueRepresentation;
@end

int main(void) {
    @autoreleasepool {
        @try {
            if (!dlopen("/System/Library/PrivateFrameworks/PhotosFormats.framework/PhotosFormats", RTLD_LAZY)) return 1;
            Class cls = NSClassFromString(@"PFMediaCapabilities");
            if (![cls respondsToSelector:@selector(capabilitiesForCurrentDevice)]) return 1;
            id capabilities = [cls capabilitiesForCurrentDevice];
            if (![capabilities respondsToSelector:@selector(opaqueRepresentation)]) return 1;
            NSData *data = [capabilities opaqueRepresentation];
            if (![data isKindOfClass:[NSData class]]) return 1;
            id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![value isKindOfClass:[NSDictionary class]] || ![value[@"Version"] isKindOfClass:[NSNumber class]]) return 1;
            NSMutableDictionary *media = [NSMutableDictionary dictionaryWithObject:value[@"Version"] forKey:@"Version"];
            for (NSString *key in @[@"Codecs", @"ContainerFormats"]) {
                if ([value[key] isKindOfClass:[NSDictionary class]]) media[key] = value[key];
            }
            if (media.count < 2) return 1;
            NSData *result = [NSJSONSerialization dataWithJSONObject:media options:NSJSONWritingSortedKeys error:nil];
            if (!result) return 1;
            [[NSFileHandle fileHandleWithStandardOutput] writeData:result];
            return 0;
        } @catch (NSException *exception) {
            return 1;
        }
    }
}
