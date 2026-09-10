#define _GNU_SOURCE
#include "fr_context.h"
#include <errno.h>
#include <fenv.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#if !((defined(__linux__) && defined(__x86_64__)) || \
      (defined(__APPLE__) && (defined(__x86_64__) || defined(__aarch64__))))
#error Unsupported native context platform
#endif

/* Matches pinned Boost.Context detail/fcontext.hpp, without C++ dependencies. */
typedef struct { void *fctx; void *data; } fr_transfer;
extern void *make_fcontext(void *sp, size_t size, void (*entry)(fr_transfer));
extern fr_transfer jump_fcontext(void *to, void *data);

enum fr_state { FR_CREATED, FR_RUNNING, FR_SUSPENDED, FR_FINISHED };

struct fr_context {
    pthread_t owner;
    void *mapping;
    size_t mapping_bytes;
    void *stack_bottom;
    size_t stack_bytes;
    void *child;
    void *caller;
    fr_context_entry entry;
    void *data;
    enum fr_state state;
    fr_context *parent;
    fenv_t environment;
};

/* Logical active context; OS TLS itself remains shared between contexts. */
static _Thread_local fr_context *active_context;

static int check_owner(fr_context *ctx)
{
    if (ctx == NULL)
        return EINVAL;
    /* Check immutable ownership before reading any changing context state. */
    if (!pthread_equal(ctx->owner, pthread_self()))
        return EPERM;
    return 0;
}

static void context_entry(fr_transfer transfer)
{
    fr_context *ctx = transfer.data;
    ctx->caller = transfer.fctx;
    ctx->entry(ctx->data);
    ctx->state = FR_FINISHED;
    active_context = ctx->parent;
    (void)jump_fcontext(ctx->caller, ctx);
    /* A completed context can never legally be resumed. */
    abort();
}

fr_context *fr_context_create(fr_context_entry entry, void *data, size_t bytes)
{
    fr_context *ctx;
    long page_result;
    size_t page, usable;
    int saved_error;
    if (entry == NULL || bytes < 65536 || bytes > 67108864) {
        errno = EINVAL;
        return NULL;
    }
    page_result = sysconf(_SC_PAGESIZE);
    if (page_result <= 0) {
        errno = EINVAL;
        return NULL;
    }
    page = (size_t)page_result;
    usable = ((bytes + page - 1) / page) * page;
    ctx = calloc(1, sizeof(*ctx));
    if (ctx == NULL)
        return NULL;
    ctx->owner = pthread_self();
    ctx->mapping_bytes = usable + 2 * page;
    ctx->mapping = mmap(NULL, ctx->mapping_bytes, PROT_NONE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ctx->mapping == MAP_FAILED) {
        saved_error = errno;
        free(ctx);
        errno = saved_error;
        return NULL;
    }
    if (mprotect((char *)ctx->mapping + page, usable,
                 PROT_READ | PROT_WRITE) != 0) {
        saved_error = errno;
        goto fail_mapping;
    }
    if (fegetenv(&ctx->environment) != 0) {
        saved_error = EIO;
        goto fail_mapping;
    }
    ctx->entry = entry;
    ctx->data = data;
    ctx->stack_bottom = (char *)ctx->mapping + page;
    ctx->stack_bytes = usable;
    ctx->state = FR_CREATED;
    ctx->child = make_fcontext((char *)ctx->mapping + page + usable,
                              usable, context_entry);
    return ctx;

fail_mapping:
    (void)munmap(ctx->mapping, ctx->mapping_bytes);
    free(ctx);
    errno = saved_error;
    return NULL;
}

int fr_context_resume(fr_context *ctx)
{
    fr_transfer transfer;
    fenv_t caller_environment;
    fr_context *previous;
    int result = check_owner(ctx);
    if (result != 0)
        return result;
    if (ctx->state == FR_FINISHED)
        return EALREADY;
    if (ctx->state == FR_RUNNING)
        return EBUSY;
    if (fegetenv(&caller_environment) != 0 ||
        fesetenv(&ctx->environment) != 0)
        return EIO;
    previous = active_context;
    ctx->parent = previous;
    ctx->state = FR_RUNNING;
    active_context = ctx;
    transfer = jump_fcontext(ctx->child, ctx);
    ctx->child = transfer.fctx;
    active_context = previous;
    if (fesetenv(&caller_environment) != 0)
        return EIO;
    return 0;
}

int fr_context_yield(fr_context *ctx)
{
    fr_transfer transfer;
    int result = check_owner(ctx);
    if (result != 0)
        return result;
    if (ctx->state != FR_RUNNING || active_context != ctx)
        return EINVAL;
    if (fegetenv(&ctx->environment) != 0)
        return EIO;
    ctx->state = FR_SUSPENDED;
    active_context = ctx->parent;
    transfer = jump_fcontext(ctx->caller, ctx);
    ctx->caller = transfer.fctx;
    return 0;
}

int fr_context_destroy(fr_context *ctx)
{
    int result = check_owner(ctx);
    if (result != 0)
        return result;
    if (ctx->state != FR_CREATED && ctx->state != FR_FINISHED)
        return EBUSY;
    if (munmap(ctx->mapping, ctx->mapping_bytes) != 0)
        return errno;
    free(ctx);
    return 0;
}

const char *fr_context_backend(void)
{
    return "boost.context-1.85.0-cabi-v1";
}

void *fr_context_stack_bottom(fr_context *ctx)
{
    int result = check_owner(ctx);
    if (result != 0) {
        errno = result;
        return NULL;
    }
    return ctx->stack_bottom;
}

size_t fr_context_stack_size(fr_context *ctx)
{
    int result = check_owner(ctx);
    if (result != 0) {
        errno = result;
        return 0;
    }
    return ctx->stack_bytes;
}
