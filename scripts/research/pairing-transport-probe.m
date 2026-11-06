// Bounded interoperability probe using a distinct application service.
// It never accepts files and never accesses or exports identity keys.
// --pairing supplies the configuration verified by pairing-configuration-codec.swift.
// Listener readiness alone does not prove pairing, discovery on iOS, or an icon change.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <dlfcn.h>

typedef nw_parameters_t (*CreateParameters)(void);
typedef void (*DescriptorBytes)(nw_advertise_descriptor_t, const void *, size_t);
typedef void (*DescriptorBool)(nw_advertise_descriptor_t, bool);
typedef void (*ParametersBool)(nw_parameters_t, bool);

int main(int argc, const char **argv) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        if (argc > 2 || (argc == 2 && strcmp(argv[1], "--pairing"))) {
            fprintf(stderr, "Usage: %s [--pairing]\n", argv[0]);
            return 2;
        }
        BOOL pairing = argc > 1 && !strcmp(argv[1], "--pairing");
        void *network = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
        CreateParameters create = (CreateParameters)dlsym(network, "nw_parameters_create_application_service_quic");
        DescriptorBytes custom = (DescriptorBytes)dlsym(network, "nw_advertise_descriptor_set_custom_service");
        DescriptorBool prefix = (DescriptorBool)dlsym(network, "nw_advertise_descriptor_set_enable_service_name_prefixing");
        if (!create || !custom || !prefix) return 2;
        nw_parameters_t parameters = create();
        if (!parameters) { puts("parameters=unavailable"); return 3; }
        nw_parameters_set_include_peer_to_peer(parameters, true);
        ParametersBool attach = (ParametersBool)dlsym(network, "nw_parameters_set_attach_protocol_listener");
        ParametersBool server = (ParametersBool)dlsym(network, "nw_parameters_set_server_mode");
        if (attach) attach(parameters, true);
        if (server) server(parameters, true);
        nw_listener_t listener = nw_listener_create(parameters);
        if (!listener) { puts("listener=unavailable"); return 4; }
        nw_advertise_descriptor_t descriptor = nw_advertise_descriptor_create_application_service("pl.airfolder.protocolprobe");
        prefix(descriptor, false);
        if (pairing) {
            NSDictionary *configuration = @{
                @"supportedPairingTypes": @[@{@"pin": @{}}],
                @"generatePairingValueImmediately": @NO,
                @"_advertiseSensitiveInfo": @NO,
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:configuration options:0 error:nil];
            custom(descriptor, data.bytes, data.length);
        }
        nw_listener_set_advertise_descriptor(listener, descriptor);
        dispatch_queue_t queue = dispatch_queue_create("pl.airfolder.protocolprobe", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        dispatch_semaphore_t cancelled = dispatch_semaphore_create(0);
        __block int result = 5;
        nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
            printf("state=%d", state);
            if (error) printf(" error_domain=%d error_code=%d", nw_error_get_error_domain(error), nw_error_get_error_code(error));
            puts("");
            if (state == nw_listener_state_ready) result = 0;
            if (state == nw_listener_state_failed) { result = 6; dispatch_semaphore_signal(finished); }
            if (state == nw_listener_state_cancelled) dispatch_semaphore_signal(cancelled);
        });
        nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
            puts("incoming=declined");
            nw_connection_cancel(connection);
        });
        nw_listener_set_queue(listener, queue);
        printf("mode=%s pid=%d bundle=%s\n", pairing ? "pin-configuration" : "baseline",
               getpid(), NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "none");
        nw_listener_start(listener);
        dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
        nw_listener_cancel(listener);
        dispatch_semaphore_wait(cancelled, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        dispatch_sync(queue, ^{});
        printf("result=%d\n", result);
        return result;
    }
}
