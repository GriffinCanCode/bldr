module engine.distributed.protocol.grpc.bindings;

/**
 * C bindings for grpc-core
 * 
 * Provides low-level access to gRPC functionality via FFI.
 * Link with: -lgrpc -lgpr
 * 
 * For full gRPC support, install: brew install grpc (macOS) or apt install libgrpc-dev (Linux)
 */

extern (C):
nothrow:
@nogc:

// =============================================================================
// Basic Types
// =============================================================================

alias gpr_timespec = grpc_timespec;

struct grpc_timespec {
    long tv_sec;
    int tv_nsec;
    grpc_clock_type clock_type;
}

enum grpc_clock_type {
    GPR_CLOCK_MONOTONIC = 0,
    GPR_CLOCK_REALTIME = 1,
    GPR_CLOCK_PRECISE = 2,
    GPR_TIMESPAN = 3
}

struct grpc_slice {
    grpc_slice_refcount* refcount;
    union Data {
        struct Refcounted {
            size_t length;
            ubyte* bytes;
        }
        Refcounted refcounted;
        struct Inlined {
            ubyte length;
            ubyte[23] bytes;  // GRPC_SLICE_INLINED_SIZE
        }
        Inlined inlined;
    }
    Data data;
}

struct grpc_slice_refcount;

struct grpc_byte_buffer;

// grpc_byte_buffer_reader is an opaque struct in the C API
// We define a minimal size for allocation purposes (actual size varies by platform)
struct grpc_byte_buffer_reader {
    void*[8] _opaque;  // Reserve space for internal pointers
}

// =============================================================================
// Completion Queue Types
// =============================================================================

struct grpc_completion_queue;

enum grpc_cq_completion_type {
    GRPC_CQ_NEXT = 0,
    GRPC_CQ_PLUCK = 1,
    GRPC_CQ_CALLBACK = 2
}

enum grpc_cq_polling_type {
    GRPC_CQ_DEFAULT_POLLING,
    GRPC_CQ_NON_LISTENING,
    GRPC_CQ_NON_POLLING
}

struct grpc_completion_queue_attributes {
    int version_;
    grpc_cq_completion_type cq_completion_type;
    grpc_cq_polling_type cq_polling_type;
    void* cq_shutdown_cb;
}

struct grpc_event {
    grpc_completion_type type;
    int success;
    void* tag;
}

enum grpc_completion_type {
    GRPC_QUEUE_SHUTDOWN,
    GRPC_QUEUE_TIMEOUT,
    GRPC_OP_COMPLETE
}

// =============================================================================
// Channel Types
// =============================================================================

struct grpc_channel;
struct grpc_server;
struct grpc_call;

struct grpc_channel_args {
    size_t num_args;
    grpc_arg* args;
}

struct grpc_arg {
    grpc_arg_type type;
    char* key;
    union Value {
        char* string_;
        int integer;
        grpc_arg_pointer pointer;
    }
    Value value;
}

enum grpc_arg_type {
    GRPC_ARG_STRING,
    GRPC_ARG_INTEGER,
    GRPC_ARG_POINTER
}

struct grpc_arg_pointer {
    void* p;
    void* function(void*) copy;
    void function(void*) destroy;
    int function(void*, void*) cmp;
}

// =============================================================================
// Call/Op Types
// =============================================================================

struct grpc_metadata {
    grpc_slice key;
    grpc_slice value;
    uint flags;
    void*[4] internal_data;
}

struct grpc_metadata_array {
    size_t count;
    size_t capacity;
    grpc_metadata* metadata;
}

struct grpc_call_details {
    grpc_slice method;
    grpc_slice host;
    gpr_timespec deadline;
    uint flags;
    void* reserved;
}

enum grpc_op_type {
    GRPC_OP_SEND_INITIAL_METADATA = 0,
    GRPC_OP_SEND_MESSAGE = 1,
    GRPC_OP_SEND_CLOSE_FROM_CLIENT = 2,
    GRPC_OP_SEND_STATUS_FROM_SERVER = 3,
    GRPC_OP_RECV_INITIAL_METADATA = 4,
    GRPC_OP_RECV_MESSAGE = 5,
    GRPC_OP_RECV_STATUS_ON_CLIENT = 6,
    GRPC_OP_RECV_CLOSE_ON_SERVER = 7
}

struct grpc_op {
    grpc_op_type op;
    uint flags;
    void* reserved;
    union Data {
        // GRPC_OP_SEND_INITIAL_METADATA
        struct SendInitialMetadata {
            size_t count;
            grpc_metadata* metadata;
            grpc_compression_level maybe_compression_level;
        }
        SendInitialMetadata send_initial_metadata;
        
        // GRPC_OP_SEND_MESSAGE
        struct SendMessage {
            grpc_byte_buffer* send_message;
        }
        SendMessage send_message;
        
        // GRPC_OP_SEND_STATUS_FROM_SERVER
        struct SendStatusFromServer {
            size_t trailing_metadata_count;
            grpc_metadata* trailing_metadata;
            grpc_status_code status;
            grpc_slice* status_details;
        }
        SendStatusFromServer send_status_from_server;
        
        // GRPC_OP_RECV_INITIAL_METADATA
        struct RecvInitialMetadata {
            grpc_metadata_array* recv_initial_metadata;
        }
        RecvInitialMetadata recv_initial_metadata;
        
        // GRPC_OP_RECV_MESSAGE
        struct RecvMessage {
            grpc_byte_buffer** recv_message;
        }
        RecvMessage recv_message;
        
        // GRPC_OP_RECV_STATUS_ON_CLIENT
        struct RecvStatusOnClient {
            grpc_metadata_array* trailing_metadata;
            grpc_status_code* status;
            grpc_slice* status_details;
            const(char)** error_string;
        }
        RecvStatusOnClient recv_status_on_client;
        
        // GRPC_OP_RECV_CLOSE_ON_SERVER
        struct RecvCloseOnServer {
            int* cancelled;
        }
        RecvCloseOnServer recv_close_on_server;
    }
    Data data;
}

enum grpc_compression_level {
    GRPC_COMPRESS_LEVEL_NONE = 0,
    GRPC_COMPRESS_LEVEL_LOW = 1,
    GRPC_COMPRESS_LEVEL_MED = 2,
    GRPC_COMPRESS_LEVEL_HIGH = 3,
    GRPC_COMPRESS_LEVEL_COUNT = 4
}

enum grpc_status_code {
    GRPC_STATUS_OK = 0,
    GRPC_STATUS_CANCELLED = 1,
    GRPC_STATUS_UNKNOWN = 2,
    GRPC_STATUS_INVALID_ARGUMENT = 3,
    GRPC_STATUS_DEADLINE_EXCEEDED = 4,
    GRPC_STATUS_NOT_FOUND = 5,
    GRPC_STATUS_ALREADY_EXISTS = 6,
    GRPC_STATUS_PERMISSION_DENIED = 7,
    GRPC_STATUS_RESOURCE_EXHAUSTED = 8,
    GRPC_STATUS_FAILED_PRECONDITION = 9,
    GRPC_STATUS_ABORTED = 10,
    GRPC_STATUS_OUT_OF_RANGE = 11,
    GRPC_STATUS_UNIMPLEMENTED = 12,
    GRPC_STATUS_INTERNAL = 13,
    GRPC_STATUS_UNAVAILABLE = 14,
    GRPC_STATUS_DATA_LOSS = 15,
    GRPC_STATUS_UNAUTHENTICATED = 16,
    GRPC_STATUS__DO_NOT_USE = -1
}

enum grpc_call_error {
    GRPC_CALL_OK = 0,
    GRPC_CALL_ERROR = 1,
    GRPC_CALL_ERROR_NOT_ON_SERVER = 2,
    GRPC_CALL_ERROR_NOT_ON_CLIENT = 3,
    GRPC_CALL_ERROR_ALREADY_ACCEPTED = 4,
    GRPC_CALL_ERROR_ALREADY_INVOKED = 5,
    GRPC_CALL_ERROR_NOT_INVOKED = 6,
    GRPC_CALL_ERROR_ALREADY_FINISHED = 7,
    GRPC_CALL_ERROR_TOO_MANY_OPERATIONS = 8,
    GRPC_CALL_ERROR_INVALID_FLAGS = 9,
    GRPC_CALL_ERROR_INVALID_METADATA = 10,
    GRPC_CALL_ERROR_INVALID_MESSAGE = 11,
    GRPC_CALL_ERROR_NOT_SERVER_COMPLETION_QUEUE = 12,
    GRPC_CALL_ERROR_BATCH_TOO_BIG = 13,
    GRPC_CALL_ERROR_PAYLOAD_TYPE_MISMATCH = 14,
    GRPC_CALL_ERROR_COMPLETION_QUEUE_SHUTDOWN = 15
}

// =============================================================================
// Credentials Types
// =============================================================================

struct grpc_channel_credentials;
struct grpc_server_credentials;
struct grpc_call_credentials;

// =============================================================================
// Core Functions
// =============================================================================

// Initialization
void grpc_init();
void grpc_shutdown();
void grpc_shutdown_blocking();
int grpc_is_initialized();
const(char)* grpc_version_string();

// Time
gpr_timespec gpr_now(grpc_clock_type clock);
gpr_timespec gpr_time_add(gpr_timespec a, gpr_timespec b);
gpr_timespec gpr_time_from_millis(long ms, grpc_clock_type clock);
gpr_timespec gpr_time_from_seconds(long s, grpc_clock_type clock);
gpr_timespec gpr_inf_future(grpc_clock_type clock);
gpr_timespec gpr_inf_past(grpc_clock_type clock);

// Completion queue
grpc_completion_queue* grpc_completion_queue_create_for_next(void* reserved);
grpc_completion_queue* grpc_completion_queue_create_for_pluck(void* reserved);
grpc_event grpc_completion_queue_next(grpc_completion_queue* cq, gpr_timespec deadline, void* reserved);
grpc_event grpc_completion_queue_pluck(grpc_completion_queue* cq, void* tag, gpr_timespec deadline, void* reserved);
void grpc_completion_queue_shutdown(grpc_completion_queue* cq);
void grpc_completion_queue_destroy(grpc_completion_queue* cq);

// Channel
grpc_channel* grpc_insecure_channel_create(const(char)* target, const(grpc_channel_args)* args, void* reserved);
grpc_channel* grpc_secure_channel_create(grpc_channel_credentials* creds, const(char)* target, const(grpc_channel_args)* args, void* reserved);
void grpc_channel_destroy(grpc_channel* channel);
grpc_connectivity_state grpc_channel_check_connectivity_state(grpc_channel* channel, int try_to_connect);

enum grpc_connectivity_state {
    GRPC_CHANNEL_IDLE = 0,
    GRPC_CHANNEL_CONNECTING = 1,
    GRPC_CHANNEL_READY = 2,
    GRPC_CHANNEL_TRANSIENT_FAILURE = 3,
    GRPC_CHANNEL_SHUTDOWN = 4
}

// Server
grpc_server* grpc_server_create(const(grpc_channel_args)* args, void* reserved);
void grpc_server_register_completion_queue(grpc_server* server, grpc_completion_queue* cq, void* reserved);
int grpc_server_add_insecure_http2_port(grpc_server* server, const(char)* addr);
int grpc_server_add_secure_http2_port(grpc_server* server, const(char)* addr, grpc_server_credentials* creds);
void grpc_server_start(grpc_server* server);
void grpc_server_shutdown_and_notify(grpc_server* server, grpc_completion_queue* cq, void* tag);
void grpc_server_cancel_all_calls(grpc_server* server);
void grpc_server_destroy(grpc_server* server);
grpc_call_error grpc_server_request_call(grpc_server* server, grpc_call** call, grpc_call_details* details,
    grpc_metadata_array* request_metadata, grpc_completion_queue* cq_bound_to_call,
    grpc_completion_queue* cq_for_notification, void* tag_new);

// Call
grpc_call* grpc_channel_create_call(grpc_channel* channel, grpc_call* parent_call, uint propagation_mask,
    grpc_completion_queue* cq, grpc_slice method, const(grpc_slice)* host, gpr_timespec deadline, void* reserved);
grpc_call_error grpc_call_start_batch(grpc_call* call, const(grpc_op)* ops, size_t nops, void* tag, void* reserved);
grpc_call_error grpc_call_cancel(grpc_call* call, void* reserved);
grpc_call_error grpc_call_cancel_with_status(grpc_call* call, grpc_status_code status, const(char)* description, void* reserved);
void grpc_call_unref(grpc_call* call);
char* grpc_call_get_peer(grpc_call* call);

// Metadata
void grpc_metadata_array_init(grpc_metadata_array* array);
void grpc_metadata_array_destroy(grpc_metadata_array* array);
void grpc_call_details_init(grpc_call_details* details);
void grpc_call_details_destroy(grpc_call_details* details);

// Slice
grpc_slice grpc_slice_from_copied_string(const(char)* source);
grpc_slice grpc_slice_from_copied_buffer(const(char)* source, size_t len);
grpc_slice grpc_slice_malloc(size_t length);
void grpc_slice_unref(grpc_slice s);
size_t GRPC_SLICE_LENGTH(grpc_slice s);
ubyte* GRPC_SLICE_START_PTR(grpc_slice s);

// Byte buffer
grpc_byte_buffer* grpc_raw_byte_buffer_create(grpc_slice* slices, size_t nslices);
void grpc_byte_buffer_destroy(grpc_byte_buffer* bb);
size_t grpc_byte_buffer_length(grpc_byte_buffer* bb);
int grpc_byte_buffer_reader_init(grpc_byte_buffer_reader* reader, grpc_byte_buffer* buffer);
void grpc_byte_buffer_reader_destroy(grpc_byte_buffer_reader* reader);
int grpc_byte_buffer_reader_next(grpc_byte_buffer_reader* reader, grpc_slice* slice);

// Credentials
grpc_channel_credentials* grpc_insecure_credentials_create();
void grpc_channel_credentials_release(grpc_channel_credentials* creds);
grpc_server_credentials* grpc_insecure_server_credentials_create();
void grpc_server_credentials_release(grpc_server_credentials* creds);

// SSL credentials (simplified)
grpc_channel_credentials* grpc_ssl_credentials_create(
    const(char)* pem_root_certs,
    grpc_ssl_pem_key_cert_pair* pem_key_cert_pair,
    grpc_ssl_verify_peer_options* verify_options,
    void* reserved);

struct grpc_ssl_pem_key_cert_pair {
    const(char)* private_key;
    const(char)* cert_chain;
}

struct grpc_ssl_verify_peer_options {
    void* function(void*) verify_peer_callback_userdata;
    int function(const(char)*, const(char)*, void*) verify_peer_callback;
    void function(void*) verify_peer_destruct;
}

