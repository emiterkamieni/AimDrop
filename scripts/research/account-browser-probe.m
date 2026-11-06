// Read-only application-service discovery through the system broker. Does not
// register or replace an AirDrop listener, connect to peers, or read identity keys.
// Reports presence and protocol flags only, never names, addresses, or account IDs.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <dlfcn.h>
#import <xpc/xpc.h>

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        void *network = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
        typedef nw_txt_record_t (*CopyTXT)(nw_endpoint_t) NS_RETURNS_RETAINED;
        typedef const char *(*GetText)(nw_endpoint_t);
        CopyTXT copyTXT = (CopyTXT)dlsym(network, "nw_endpoint_copy_txt_record");
        GetText getDevice = (GetText)dlsym(network, "nw_endpoint_get_device_id");
        GetText getContact = (GetText)dlsym(network, "nw_endpoint_get_contact_id");
        if (!copyTXT || !getDevice || !getContact) return 2;
        nw_browse_descriptor_t descriptor = nw_browse_descriptor_create_application_service("com.apple.sharingd.AirDrop");
        // Match Sharing's airDropNetworkBrowserParameters(domain:type:), which
        // selects RapportBrowseAgent rather than a generic application browse.
        typedef void (*RequiredAgents)(nw_parameters_t, xpc_object_t, xpc_object_t);
        typedef void (*SetBool)(nw_parameters_t, bool);
        RequiredAgents require = (RequiredAgents)dlsym(network, "nw_parameters_set_required_netagent_classes");
        SetBool ble = (SetBool)dlsym(network, "nw_parameters_set_include_ble");
        if (!require || !ble) return 2;
        nw_parameters_t parameters = nw_parameters_create();
        xpc_object_t domains = xpc_array_create(NULL, 0), types = xpc_array_create(NULL, 0);
        xpc_array_set_string(domains, XPC_ARRAY_APPEND, "com.apple.rapport.browse");
        xpc_array_set_string(types, XPC_ARRAY_APPEND, "RapportBrowseAgent");
        require(parameters, domains, types);
        ble(parameters, true);
        nw_browser_t browser = nw_browser_create(descriptor, parameters);
        dispatch_queue_t queue = dispatch_queue_create("pl.airfolder.account-browser", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block unsigned results = 0;
        nw_browser_set_queue(browser, queue);
        nw_browser_set_state_changed_handler(browser, ^(nw_browser_state_t state, nw_error_t error) {
            printf("browser_state=%d error=%d\n", state, error ? nw_error_get_error_code(error) : 0);
            if (state == nw_browser_state_failed) dispatch_semaphore_signal(done);
        });
        nw_browser_set_browse_results_changed_handler(browser, ^(nw_browse_result_t old, nw_browse_result_t result, bool complete) {
            (void)old; (void)complete;
            if (!result) return;
            results++;
            nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(result);
            nw_txt_record_t txt = copyTXT(endpoint);
            printf("broker_endpoint type=%d has_device_id=%d has_contact_id=%d txt_keys=%zu",
                   nw_endpoint_get_type(endpoint), getDevice(endpoint) != NULL, getContact(endpoint) != NULL,
                   nw_txt_record_get_key_count(txt));
            if (txt) {
                nw_txt_record_access_key(txt, "StatusFlags", ^bool(const char *key, nw_txt_record_find_key_t found, const uint8_t *value, size_t length) {
                    (void)key; (void)found;
                    if (value && length && length < 24) {
                        NSString *number = [[NSString alloc] initWithBytes:value length:length encoding:NSUTF8StringEncoding];
                        NSCharacterSet *invalid = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                        if (number && [number rangeOfCharacterFromSet:invalid].location == NSNotFound) printf(" status_flags=%s", number.UTF8String);
                    }
                    return true;
                });
            }
            puts("");
        });
        nw_browser_start(browser);
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        nw_browser_cancel(browser);
        dispatch_sync(queue, ^{ printf("broker_discovery_updates=%u\n", results); });
        return 0;
    }
}
