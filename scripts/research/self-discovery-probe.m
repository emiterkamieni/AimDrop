// Bounded, isolated experiment: can publication scope hide a receiver locally?
// Uses synthetic identities and a non-AirDrop service name. Never pairs or
// touches the running receiver. Plain TCP is enough to test Bonjour publication.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <dns_sd.h>
#import <net/if.h>

static const char *types[] = {"_appSvcPrePair._tcp", "_applicationServicePairing._tcp"};
static NSString *serviceName = @"pl.aimdrop.self-discovery-probe";

@interface Probe : NSObject
@property NSString *label;
@property NSString *name;
@property NSString *serverID;
@property NSString *type;
@property nw_listener_t listener;
@property DNSServiceRef registration;
@property BOOL ready;
@property BOOL advertised;
@property BOOL seen;
@property BOOL failed;
@end
@implementation Probe
@end

static void registered(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType error,
                       const char *name, const char *type, const char *domain, void *context) {
    (void)ref; (void)flags; (void)name; (void)type; (void)domain;
    Probe *probe = (__bridge Probe *)context;
    probe.advertised = error == kDNSServiceErr_NoError;
    probe.failed = error != kDNSServiceErr_NoError;
    printf("registered mode=%s type=%s error=%d\n", probe.label.UTF8String, probe.type.UTF8String, error);
}

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        uint32_t awdl = if_nametoindex("awdl0");
        if (!awdl) { fputs("AWDL interface unavailable\n", stderr); return 2; }
        dispatch_queue_t queue = dispatch_queue_create("pl.aimdrop.self-discovery-probe", DISPATCH_QUEUE_SERIAL);
        NSMutableArray<Probe *> *probes = [NSMutableArray array];
        NSMutableArray *browsers = [NSMutableArray array];
        NSString *nonce = NSUUID.UUID.UUIDString;
        NSArray<NSString *> *modes = @[@"network-default", @"network-no-loopback", @"dns-any", @"dns-awdl-only"];
        for (NSUInteger index = 0; index < modes.count; index++) {
            for (NSUInteger t = 0; t < 2; t++) {
                Probe *probe = [Probe new];
                probe.label = modes[index];
                probe.name = [NSString stringWithFormat:@"ADProbe-%lu-%lu-%@", index, t, nonce];
                probe.serverID = NSUUID.UUID.UUIDString;
                probe.type = @(types[t]);
                [probes addObject:probe];
                nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
                nw_parameters_set_include_peer_to_peer(parameters, true);
                if (index == 1) nw_parameters_prohibit_interface_type(parameters, nw_interface_type_loopback);
                nw_listener_t listener = nw_listener_create(parameters);
                if (!listener) { fputs("Could not create listener\n", stderr); return 2; }
                probe.listener = listener;
                if (index < 2) {
                    nw_advertise_descriptor_t descriptor = nw_advertise_descriptor_create_bonjour_service(probe.name.UTF8String, types[t], "local.");
                    nw_txt_record_t record = nw_txt_record_create_dictionary();
                    nw_txt_record_set_key(record, "sn", (const uint8_t *)serviceName.UTF8String, strlen(serviceName.UTF8String));
                    nw_txt_record_set_key(record, "sid", (const uint8_t *)probe.serverID.UTF8String, strlen(probe.serverID.UTF8String));
                    nw_advertise_descriptor_set_txt_record_object(descriptor, record);
                    nw_listener_set_advertise_descriptor(listener, descriptor);
                    nw_listener_set_advertised_endpoint_changed_handler(listener, ^(nw_endpoint_t endpoint, bool added) {
                        (void)endpoint;
                        if (added) probe.advertised = YES;
                    });
                }
                nw_listener_set_queue(listener, queue);
                nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) { nw_connection_cancel(connection); });
                nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
                    if (state == nw_listener_state_failed) {
                        probe.failed = YES;
                        printf("listener_failed mode=%s error=%d\n", probe.label.UTF8String, error ? nw_error_get_error_code(error) : 0);
                    }
                    if (state != nw_listener_state_ready) return;
                    probe.ready = YES;
                    if (index < 2) return;
                    TXTRecordRef record;
                    TXTRecordCreate(&record, 0, NULL);
                    TXTRecordSetValue(&record, "sn", (uint8_t)strlen(serviceName.UTF8String), serviceName.UTF8String);
                    TXTRecordSetValue(&record, "sid", (uint8_t)strlen(probe.serverID.UTF8String), probe.serverID.UTF8String);
                    DNSServiceRef registration = NULL;
                    DNSServiceErrorType result = DNSServiceRegister(&registration,
                        kDNSServiceFlagsIncludeP2P | kDNSServiceFlagsIncludeAWDL,
                        index == 3 ? awdl : kDNSServiceInterfaceIndexAny,
                        probe.name.UTF8String, probe.type.UTF8String, "local.", NULL,
                        htons(nw_listener_get_port(listener)), TXTRecordGetLength(&record), TXTRecordGetBytesPtr(&record),
                        registered, (__bridge void *)probe);
                    TXTRecordDeallocate(&record);
                    if (!result) {
                        probe.registration = registration;
                        result = DNSServiceSetDispatchQueue(registration, queue);
                    }
                    if (result) {
                        probe.failed = YES;
                        printf("register_failed mode=%s error=%d\n", probe.label.UTF8String, result);
                    }
                });
            }
        }
        for (NSUInteger t = 0; t < 2; t++) {
            nw_parameters_t parameters = nw_parameters_create();
            nw_parameters_set_include_peer_to_peer(parameters, true);
            nw_browse_descriptor_t descriptor = nw_browse_descriptor_create_bonjour_service(types[t], "local.");
            nw_browse_descriptor_set_include_txt_record(descriptor, true);
            nw_browser_t browser = nw_browser_create(descriptor, parameters);
            [browsers addObject:browser];
            nw_browser_set_queue(browser, queue);
            nw_browser_set_browse_results_changed_handler(browser, ^(nw_browse_result_t old, nw_browse_result_t result, bool complete) {
                (void)old; (void)complete;
                if (!result) return;
                nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(result);
                const char *name = nw_endpoint_get_bonjour_service_name(endpoint);
                if (!name) return;
                for (Probe *probe in probes) {
                    if (![probe.name isEqualToString:@(name)]) continue;
                    probe.seen = YES;
                    nw_browse_result_enumerate_interfaces(result, ^bool(nw_interface_t interface) {
                        printf("local_result mode=%s type=%s interface=%s\n", probe.label.UTF8String,
                               probe.type.UTF8String, nw_interface_get_name(interface));
                        return true;
                    });
                }
            });
            nw_browser_start(browser);
        }
        for (Probe *probe in probes) nw_listener_start(probe.listener);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), queue, ^{
            for (Probe *probe in probes) {
                printf("summary mode=%s type=%s ready=%d advertised=%d visible_locally=%d failed=%d\n",
                       probe.label.UTF8String, probe.type.UTF8String, probe.ready, probe.advertised, probe.seen, probe.failed);
                if (probe.registration) DNSServiceRefDeallocate(probe.registration);
                nw_listener_cancel(probe.listener);
            }
            for (nw_browser_t browser in browsers) nw_browser_cancel(browser);
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC))) return 2;
        __block BOOL failed = NO;
        dispatch_sync(queue, ^{
            for (Probe *probe in probes) {
                if (probe.failed || !probe.ready || !probe.advertised) failed = YES;
                // Release callback cycles only after cancellation on this queue.
                nw_listener_set_state_changed_handler(probe.listener, nil);
                nw_listener_set_new_connection_handler(probe.listener, nil);
                nw_listener_set_advertised_endpoint_changed_handler(probe.listener, nil);
                probe.listener = nil;
            }
            for (nw_browser_t browser in browsers) nw_browser_set_browse_results_changed_handler(browser, nil);
        });
        return failed ? 1 : 0;
    }
}
