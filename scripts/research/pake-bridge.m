// Research bridge using freshly derived probe identities only. Verified against Apple's
// protocol/SecProtocolTypesPriv.h and the running system's exported symbols.
#import "pake-bridge.h"
#import <dlfcn.h>

typedef sec_identity_t (*CreateClient)(dispatch_data_t, dispatch_data_t, dispatch_data_t,
                                      dispatch_data_t, uint16_t) NS_RETURNS_RETAINED;
typedef sec_identity_t (*CreateServer)(dispatch_data_t, dispatch_data_t, dispatch_data_t,
                                      dispatch_data_t, dispatch_data_t) NS_RETURNS_RETAINED;
typedef dispatch_data_t (*CopyData)(sec_identity_t) NS_RETURNS_RETAINED;

static dispatch_data_t bytes(NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    return dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
}

sec_identity_t AFCreateSPAKEIdentity(NSString *context, NSString *client,
                                    NSString *server, NSString *password, BOOL serverMode) {
    void *library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    CreateClient createClient = (CreateClient)dlsym(library, "sec_identity_create_client_SPAKE2PLUSV1_identity");
    CreateServer createServer = (CreateServer)dlsym(library, "sec_identity_create_server_SPAKE2PLUSV1_identity");
    CopyData copyVerifier = (CopyData)dlsym(library, "sec_identity_copy_SPAKE2PLUSV1_server_password_verifier");
    CopyData copyRegistration = (CopyData)dlsym(library, "sec_identity_copy_SPAKE2PLUSV1_registration_record");
    if (!createClient || !createServer || !copyVerifier || !copyRegistration) return nil;
    dispatch_data_t contextData = bytes(context), clientData = bytes(client), serverData = bytes(server);
    sec_identity_t identity = createClient(contextData, clientData, serverData, bytes(password), 0);
    if (!identity || !serverMode) return identity;
    dispatch_data_t verifier = copyVerifier(identity), registration = copyRegistration(identity);
    if (!verifier || !registration) return nil;
    return createServer(contextData, clientData, serverData, verifier, registration);
}

sec_identity_t AFCreatePrePairIdentity(void) {
    void *library = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_LAZY | RTLD_LOCAL);
    typedef SecIdentityRef (*CreateIdentity)(CFStringRef);
    CreateIdentity create = (CreateIdentity)dlsym(library, "_CFHTTPServerCreateSelfSignedIdentity");
    if (!create) return nil;
    SecIdentityRef identity = create(CFSTR("AimDropPairingProbe"));
    if (!identity) return nil;
    sec_identity_t result = sec_identity_create(identity);
    CFRelease(identity);
    return result;
}

@interface NSObject (AFOfferedIdentity)
- (NSData *)client_identity;
- (NSData *)server_identity;
@end

BOOL AFSetPeerAuthenticationOptional(sec_protocol_options_t options) {
    void *library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    typedef void (*SetOptional)(sec_protocol_options_t, bool);
    SetOptional set = (SetOptional)dlsym(library, "sec_protocol_options_set_peer_authentication_optional");
    if (!set) return NO;
    set(options, true);
    return YES;
}

nw_protocol_options_t AFCreateTLSRecordOptions(void) {
    void *library = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
    typedef nw_protocol_options_t (*Create)(void) NS_RETURNS_RETAINED;
    Create create = (Create)dlsym(library, "nw_swift_tls_record_create_options");
    return create ? create() : nil;
}

BOOL AFConfigurePAKEChallenge(sec_protocol_options_t options,
                             sec_identity_t (^lookup)(NSString *, NSString *)) {
    void *library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    typedef void (^Challenge)(sec_protocol_metadata_t, id, void (^)(sec_identity_t));
    typedef void (*SetChallenge)(sec_protocol_options_t, Challenge, dispatch_queue_t);
    SetChallenge set = (SetChallenge)dlsym(library, "sec_protocol_options_set_pake_challenge_block");
    if (!set) return NO;
    set(options, ^(sec_protocol_metadata_t metadata, id offered, void (^complete)(sec_identity_t)) {
        (void)metadata;
        NSString *client = [[NSString alloc] initWithData:[offered client_identity] encoding:NSUTF8StringEncoding];
        NSString *server = [[NSString alloc] initWithData:[offered server_identity] encoding:NSUTF8StringEncoding];
        complete(client && server ? lookup(client, server) : nil);
    }, dispatch_queue_create("pl.airfolder.pake-probe", DISPATCH_QUEUE_SERIAL));
    return YES;
}

@protocol AFIdentity
- (instancetype)initWithType:(int)type;
- (void)setDeviceIRKData:(NSData *)data;
- (void)setIdentifier:(NSString *)identifier;
- (void)setDateAdded:(NSDate *)date;
- (NSData *)authTagForData:(NSData *)data type:(int)type error:(NSError **)error;
@end

NSData *AFProbeAuthTag(NSData *irk, NSString *serverIdentity, NSDate *dateAdded) {
    dlopen("/System/Library/PrivateFrameworks/Rapport.framework/Rapport", RTLD_LAZY | RTLD_LOCAL);
    Class cls = NSClassFromString(@"RPIdentity");
    id<AFIdentity> identity = [(id<AFIdentity>)[cls alloc] initWithType:15];
    [identity setDeviceIRKData:irk];
    [identity setIdentifier:serverIdentity];
    [identity setDateAdded:dateAdded];
    NSError *error = nil;
    NSData *tag = [identity authTagForData:[serverIdentity dataUsingEncoding:NSUTF8StringEncoding] type:6 error:&error];
    if (!tag) fprintf(stderr, "auth_tag_error=%s\n", error.localizedDescription.UTF8String ?: "unavailable");
    return tag;
}

nw_parameters_t AFCreateApplicationServiceHTTP3Parameters(void) {
    void *library = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
    typedef nw_parameters_t (*CreateParameters)(void) NS_RETURNS_RETAINED;
    typedef nw_protocol_options_t (*CreateOptions)(void) NS_RETURNS_RETAINED;
    typedef void (*SetBool)(nw_parameters_t, bool);
    CreateParameters create = (CreateParameters)dlsym(library, "nw_parameters_create_application_service_quic");
    CreateOptions http3 = (CreateOptions)dlsym(library, "nw_http3_create_options");
    SetBool attach = (SetBool)dlsym(library, "nw_parameters_set_attach_protocol_listener");
    SetBool server = (SetBool)dlsym(library, "nw_parameters_set_server_mode");
    if (!create || !http3 || !attach || !server) return nil;
    nw_parameters_t parameters = create();
    if (!parameters) return nil;
    nw_parameters_set_include_peer_to_peer(parameters, true);
    attach(parameters, true);
    server(parameters, true);
    nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(parameters);
    // sharingd's 0x100613b0c explicitly adds h3 to the application-service
    // QUIC TLS options. The generic constructor alone negotiates a different
    // ALPN: two copies of this probe worked, while iPhone failed with
    // INVALID_ALPN_PROTOCOL before any HTTP request could arrive.
    __block bool foundQUIC = false;
    nw_protocol_stack_iterate_application_protocols(stack, ^(nw_protocol_options_t options) {
        if (!nw_protocol_definition_is_equal(nw_protocol_options_copy_definition(options), nw_protocol_copy_quic_definition())) return;
        sec_protocol_options_t security = nw_quic_copy_sec_protocol_options(options);
        sec_protocol_options_add_tls_application_protocol(security, "h3");
        foundQUIC = true;
    });
    if (!foundQUIC) return nil;
    nw_protocol_stack_prepend_application_protocol(stack, http3());
    return parameters;
}

BOOL AFSetListenerPairingService(nw_listener_t listener, NSString *name, NSString *pin) {
    void *library = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
    typedef void (*SetData)(nw_advertise_descriptor_t, const void *, size_t);
    typedef void (*SetPrefix)(nw_advertise_descriptor_t, bool);
    SetData custom = (SetData)dlsym(library, "nw_advertise_descriptor_set_custom_service");
    SetPrefix prefix = (SetPrefix)dlsym(library, "nw_advertise_descriptor_set_enable_service_name_prefixing");
    if (!custom || !prefix) return NO;
    nw_advertise_descriptor_t descriptor = nw_advertise_descriptor_create_application_service(name.UTF8String);
    NSData *configuration = [NSJSONSerialization dataWithJSONObject:@{
        @"supportedPairingTypes": @[@{@"pin": @{}}],
        @"pairingValue": @{@"pin": @{@"_0": pin}},
        @"generatePairingValueImmediately": @NO,
        @"_advertiseSensitiveInfo": @NO
    } options:0 error:nil];
    custom(descriptor, configuration.bytes, configuration.length);
    prefix(descriptor, false);
    nw_listener_set_advertise_descriptor(listener, descriptor);
    return YES;
}

void AFReceiveHTTP(nw_connection_t connection, void (^completion)(NSString *, NSDictionary *, NSData *, BOOL, int)) {
    void *library = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
    typedef nw_protocol_definition_t (*Definition)(void) NS_RETURNS_RETAINED;
    typedef id (*CopyRequest)(nw_protocol_metadata_t) NS_RETURNS_RETAINED;
    typedef void (*AccessPath)(id, void (^)(const char *));
    // Network invokes this block with name/length/value/length and uses its
    // Boolean result to continue enumeration (including HTTP pseudo-headers).
    typedef void (*Headers)(nw_protocol_metadata_t, bool (^)(const char *, size_t, const char *, size_t));
    Definition definition = (Definition)dlsym(library, "nw_protocol_copy_http_definition");
    CopyRequest copyRequest = (CopyRequest)dlsym(library, "nw_http_metadata_copy_request");
    AccessPath accessPath = (AccessPath)dlsym(library, "nw_http_request_access_path");
    Headers enumerate = (Headers)dlsym(library, "nw_http_metadata_enumerate_headers");
    nw_connection_receive(connection, 0, 65536, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        __block NSString *path = nil;
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        if (definition && copyRequest && accessPath && context) {
            nw_protocol_metadata_t metadata = nw_content_context_copy_protocol_metadata(context, definition());
            id request = metadata ? copyRequest(metadata) : nil;
            if (metadata && enumerate) enumerate(metadata, ^bool(const char *name, size_t nameLength, const char *value, size_t valueLength) {
                if (name && value && nameLength > 0 && nameLength <= 256 && valueLength <= 65536 && name[0] != ':') {
                    NSString *key = [[NSString alloc] initWithBytes:name length:nameLength encoding:NSUTF8StringEncoding];
                    NSString *text = [[NSString alloc] initWithBytes:value length:valueLength encoding:NSUTF8StringEncoding];
                    if (key && text) headers[key.lowercaseString] = text;
                }
                return true;
            });
            if (request) accessPath(request, ^(const char *value) {
                if (value && strnlen(value, 4097) <= 4096) path = [NSString stringWithUTF8String:value];
            });
        }
        const void *buffer = NULL;
        size_t size = 0;
        dispatch_data_t mapped = content ? dispatch_data_create_map(content, &buffer, &size) : nil;
        NSData *data = mapped ? [NSData dataWithBytes:buffer length:size] : [NSData data];
        completion(path, headers, data, complete, error ? nw_error_get_error_code(error) : 0);
    });
}

BOOL AFSendHTTP(nw_connection_t connection, unsigned status, NSData *data, NSDictionary<NSString *, NSString *> *responseHeaders, BOOL final, void (^completion)(int)) {
    void *library = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
    typedef id (*CreateResponse)(unsigned) NS_RETURNS_RETAINED;
    typedef nw_protocol_metadata_t (*Metadata)(id) NS_RETURNS_RETAINED;
    typedef id (*CopyFields)(nw_protocol_metadata_t) NS_RETURNS_RETAINED;
    typedef void (*Append)(id, const char *, const char *);
    CreateResponse create = (CreateResponse)dlsym(library, "nw_http_response_create_well_known");
    Metadata metadataForResponse = (Metadata)dlsym(library, "nw_http_create_metadata_for_response");
    CopyFields fields = (CopyFields)dlsym(library, "nw_http_metadata_copy_header_fields");
    Append append = (Append)dlsym(library, "nw_http_fields_append");
    if (!create || !metadataForResponse || !fields || !append) return NO;
    nw_protocol_metadata_t metadata = metadataForResponse(create(status));
    id headers = fields(metadata);
    for (NSString *name in responseHeaders) append(headers, name.UTF8String, responseHeaders[name].UTF8String);
    if (status >= 200) append(headers, "content-length", [NSString stringWithFormat:@"%lu", (unsigned long)data.length].UTF8String);
    nw_content_context_t context = nw_content_context_create("airfolder-probe-response");
    nw_content_context_set_metadata_for_protocol(context, metadata);
    nw_content_context_set_is_final(context, final);
    dispatch_data_t content = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(connection, content, context, true, ^(nw_error_t error) {
        completion(error ? nw_error_get_error_code(error) : 0);
    });
    return YES;
}

nw_parameters_t AFCreateHTTP3ClientParameters(void) {
    nw_parameters_t parameters = AFCreateApplicationServiceHTTP3Parameters();
    if (!parameters) return nil;
    void *library = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
    typedef void (*SetBool)(nw_parameters_t, bool);
    ((SetBool)dlsym(library, "nw_parameters_set_server_mode"))(parameters, false);
    ((SetBool)dlsym(library, "nw_parameters_set_attach_protocol_listener"))(parameters, false);
    // Keep the test client strict: it must negotiate the iPhone's h3 protocol,
    // never silently fall back to the generic application-service ALPN.
    void *securityLibrary = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    typedef void (*ClearALPN)(sec_protocol_options_t);
    ClearALPN clear = (ClearALPN)dlsym(securityLibrary, "sec_protocol_options_clear_tls_application_protocols");
    if (!clear) return nil;
    nw_protocol_stack_iterate_application_protocols(nw_parameters_copy_default_protocol_stack(parameters), ^(nw_protocol_options_t options) {
        if (!nw_protocol_definition_is_equal(nw_protocol_options_copy_definition(options), nw_protocol_copy_quic_definition())) return;
        sec_protocol_options_t security = nw_quic_copy_sec_protocol_options(options);
        clear(security);
        sec_protocol_options_add_tls_application_protocol(security, "h3");
    });
    return parameters;
}

NSData *AFQUICPublicKey(nw_parameters_t parameters) {
    void *library = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
    typedef NSData *(*CopyKey)(nw_protocol_options_t) NS_RETURNS_RETAINED;
    CopyKey copy = (CopyKey)dlsym(library, "nw_quic_options_copy_local_public_key");
    if (!copy) return nil;
    __block NSData *key = nil;
    nw_protocol_stack_iterate_application_protocols(nw_parameters_copy_default_protocol_stack(parameters), ^(nw_protocol_options_t options) {
        if (nw_protocol_definition_is_equal(nw_protocol_options_copy_definition(options), nw_protocol_copy_quic_definition())) key = copy(options);
    });
    return key;
}

void AFHTTP3Check(nw_parameters_t parameters, NSString *serviceID, NSData *publicKey,
                  NSString *path, NSData *body, NSDictionary<NSString *, NSString *> *requestHeaders,
                  void (^completion)(unsigned, NSData *, NSDictionary *, int)) {
    void *library = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL);
    typedef void (*SetKeys)(nw_endpoint_t, NSArray *);
    typedef id (*CreateRequest)(const char *, const char *, const char *, const char *) NS_RETURNS_RETAINED;
    typedef nw_protocol_metadata_t (*CreateMetadata)(id) NS_RETURNS_RETAINED;
    typedef id (*CopyResponse)(nw_protocol_metadata_t) NS_RETURNS_RETAINED;
    typedef unsigned (*GetStatus)(id);
    typedef void (*Append)(id, const char *, const char *);
    typedef nw_protocol_definition_t (*Definition)(void) NS_RETURNS_RETAINED;
    typedef void (*Headers)(nw_protocol_metadata_t, bool (^)(const char *, size_t, const char *, size_t));
    SetKeys keys = (SetKeys)dlsym(library, "nw_endpoint_set_public_keys");
    CreateRequest request = (CreateRequest)dlsym(library, "nw_http_request_create");
    CreateMetadata metadata = (CreateMetadata)dlsym(library, "nw_http_create_metadata_for_request");
    CopyResponse response = (CopyResponse)dlsym(library, "nw_http_metadata_copy_response");
    GetStatus status = (GetStatus)dlsym(library, "nw_http_response_get_status_code");
    Append append = (Append)dlsym(library, "nw_http_fields_append");
    Definition definition = (Definition)dlsym(library, "nw_protocol_copy_http_definition");
    Headers enumerate = (Headers)dlsym(library, "nw_http_metadata_enumerate_headers");
    if (!keys || !request || !metadata || !response || !status || !append || !definition || !enumerate) { completion(0, [NSData data], @{}, -1); return; }
    nw_endpoint_t endpoint = nw_endpoint_create_bonjour_service(serviceID.UTF8String, "_asquic._udp", "local");
    keys(endpoint, @[publicKey]);
    nw_connection_t connection = nw_connection_create(endpoint, parameters);
    dispatch_queue_t queue = dispatch_queue_create("pl.airfolder.h3-check", DISPATCH_QUEUE_SERIAL);
    __block BOOL done = NO;
    __block void (^receive)(void) = nil;
    __block __weak void (^nextReceive)(void) = nil;
    NSMutableData *received = [NSMutableData data];
    NSMutableDictionary *receivedHeaders = [NSMutableDictionary dictionary];
    __block unsigned responseStatus = 0;
    void (^finish)(unsigned, int) = ^(unsigned code, int error) {
        if (done) return;
        done = YES;
        nw_connection_set_state_changed_handler(connection, NULL);
        nw_connection_cancel(connection);
        receive = nil;
        completion(code, received, receivedHeaders, error);
    };
    nw_connection_set_queue(connection, queue);
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_failed || state == nw_connection_state_waiting) { finish(0, error ? nw_error_get_error_code(error) : -2); return; }
        if (state != nw_connection_state_ready) return;
        nw_protocol_metadata_t quic = nw_connection_copy_protocol_metadata(connection, nw_protocol_copy_quic_definition());
        sec_protocol_metadata_t security = quic ? nw_quic_copy_sec_protocol_metadata(quic) : nil;
        const char *alpn = security ? sec_protocol_metadata_get_negotiated_protocol(security) : NULL;
        if (!alpn || strcmp(alpn, "h3") != 0) { finish(0, -5); return; }
        printf("native_http3_client_ready alpn=h3\n");
        const char *method = *(const char **)dlsym(library, "nw_http_request_method_post");
        id message = request(method, NULL, NULL, path.UTF8String);
        BOOL expect = [requestHeaders[@"expect"] isEqualToString:@"100-continue"];
        for (NSString *name in requestHeaders) append(message, name.UTF8String, requestHeaders[name].UTF8String);
        BOOL omitLength = [path isEqualToString:@"/Upload"] && [NSProcessInfo.processInfo.environment[@"AIRFOLDER_PROBE_CLIENT_NO_LENGTH"] isEqualToString:@"1"];
        if (!omitLength) append(message, "content-length", [NSString stringWithFormat:@"%lu", (unsigned long)body.length].UTF8String);
        nw_content_context_t context = nw_content_context_create("airfolder-http3-check");
        nw_content_context_set_metadata_for_protocol(context, metadata(message));
        nw_content_context_set_is_final(context, true);
        dispatch_data_t bytes = dispatch_data_create(body.bytes, body.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        __block BOOL bodySent = NO;
        void (^sendBody)(void) = ^{
            if (done || bodySent) return;
            bodySent = YES;
            nw_connection_send(connection, bytes, context, true, ^(nw_error_t error) { if (error) finish(0, nw_error_get_error_code(error)); });
        };
        if (expect) {
            nw_connection_send(connection, dispatch_data_empty, context, false, ^(nw_error_t error) { if (error) finish(0, nw_error_get_error_code(error)); });
            // Network's message-oriented H3 API may buffer headers until the
            // body is submitted. Apply the usual bounded Expect wait.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), queue, ^{
                if (!bodySent && !done) { printf("native_http3_expect_wait_expired\n"); sendBody(); }
            });
        } else { sendBody(); }
        receive = ^{
            nw_connection_receive(connection, 0, 65536, ^(dispatch_data_t data, nw_content_context_t context, bool complete, nw_error_t error) {
                if (done) return;
                if (error) { finish(0, nw_error_get_error_code(error)); return; }
                nw_protocol_metadata_t http = context ? nw_content_context_copy_protocol_metadata(context, definition()) : nil;
                id message = http ? response(http) : nil;
                unsigned code = message ? status(message) : 0;
                if (code == 100) {
                    printf("native_http3_continue_received\n");
                    sendBody();
                    void (^next)(void) = nextReceive;
                    if (next) next();
                    return;
                }
                if (code) responseStatus = code;
                if (http) enumerate(http, ^bool(const char *name, size_t nameLength, const char *value, size_t valueLength) {
                    if (name && value && nameLength && nameLength <= 256 && valueLength <= 65536 && name[0] != ':') {
                        NSString *key = [[NSString alloc] initWithBytes:name length:nameLength encoding:NSUTF8StringEncoding];
                        NSString *text = [[NSString alloc] initWithBytes:value length:valueLength encoding:NSUTF8StringEncoding];
                        if (key && text) receivedHeaders[key.lowercaseString] = text;
                    }
                    return true;
                });
                const void *buffer = NULL;
                size_t size = 0;
                dispatch_data_t mapped = data ? dispatch_data_create_map(data, &buffer, &size) : nil;
                if (mapped) [received appendBytes:buffer length:size];
                if (received.length > 8 * 1024 * 1024) { finish(0, -4); return; }
                if (complete) finish(responseStatus, 0);
                else {
                    void (^next)(void) = nextReceive;
                    if (next) next();
                }
            });
        };
        nextReceive = receive;
        receive();
    });
    nw_connection_start(connection);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), queue, ^{ finish(0, -3); });
}
