// Start of context_prototypes.h
//
// Prototypes for the functions in context.h, or that will be called
// from those functions, that need to be available very early.

struct futhark_context_config;
struct futhark_context;

static void set_error(struct futhark_context* ctx, char *error);

// These are called in context/config new/free functions and contain shared setup.
static int init_constants(struct futhark_context*);
static int free_constants(struct futhark_context*);
static void context_setup(struct futhark_context_config* cfg, struct futhark_context *ctx);
static void context_teardown(struct futhark_context *ctx);

// Allocate host memory.  Must be freed with host_free().
static void host_alloc(struct futhark_context* ctx, size_t size, const char* tag, size_t* size_out, void** mem_out);
// Allocate memory allocated with host_alloc().
static void host_free(struct futhark_context* ctx, size_t size, const char* tag, void* mem);

// Functions that must be defined by the backend.
static void backend_context_config_setup(struct futhark_context_config* cfg);
static void backend_context_config_teardown(struct futhark_context_config* cfg);

// End of of context_prototypes.h
