#ifndef FR_CONTEXT_H
#define FR_CONTEXT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Experimental ABI v1. Handles belong to their creating native thread.
 * Entry must return normally: no exceptions or managed values cross this ABI.
 * Request 64 KiB..64 MiB usable stack; guard pages are additional.
 * create returns NULL and sets errno on failure; other functions return 0
 * or a positive errno code. Only dormant/completed handles may be destroyed.
 * The caller owns data and keeps it alive until entry returns.
 * Concurrent destruction and operations on stale handles are invalid usage.
 */
typedef struct fr_context fr_context;
typedef void (*fr_context_entry)(void *data);

fr_context *fr_context_create(fr_context_entry entry, void *data,
                              size_t stack_bytes);
int fr_context_resume(fr_context *ctx);
int fr_context_yield(fr_context *ctx);
int fr_context_destroy(fr_context *ctx);
const char *fr_context_backend(void);
/* Usable stack bounds, excluding both guard pages. Errors return NULL/0 and
 * set errno; getters obey the same native-thread ownership as operations. */
void *fr_context_stack_bottom(fr_context *ctx);
size_t fr_context_stack_size(fr_context *ctx);

#ifdef __cplusplus
}
#endif
#endif
