#include "fr_context.h"
#include <errno.h>
#include <fenv.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define CHECK(condition, name) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s (line %d)\n", name, __LINE__); \
        exit(1); \
    } \
} while (0)

struct task {
    fr_context *ctx;
    int steps;
    int seed;
};

/* A missing stack save, overwritten local, or premature entry fails here. */
static void nested(struct task *task, int depth)
{
    volatile uint64_t local[8];
    int i;
    uintptr_t bottom = (uintptr_t)fr_context_stack_bottom(task->ctx);
    size_t size = fr_context_stack_size(task->ctx);
    CHECK((uintptr_t)&local[0] >= bottom &&
          (uintptr_t)&local[7] < bottom + size, "locals lie inside usable stack");
    for (i = 0; i < 8; ++i)
        local[i] = (uint64_t)(task->seed + depth * 10 + i);
    if (depth != 0) {
        nested(task, depth - 1);
    } else {
        CHECK(fr_context_destroy(task->ctx) == EBUSY, "running destroy refused");
        CHECK(fr_context_resume(task->ctx) == EBUSY, "recursive resume refused");
        for (i = 0; i < 3; ++i) {
            ++task->steps;
            CHECK(fr_context_yield(task->ctx) == 0, "nested yield returns");
        }
    }
    for (i = 0; i < 8; ++i)
        CHECK(local[i] == (uint64_t)(task->seed + depth * 10 + i),
              "nested stack locals preserved");
}

static void entry(void *data)
{
    struct task *task = data;
    nested(task, 5);
    ++task->steps;
}

static void complete(void *data) { ++*(int *)data; }

static void floating_entry(void *data)
{
    struct task *task = data;
    CHECK(fesetround(FE_DOWNWARD) == 0, "child sets rounding");
    CHECK(fr_context_yield(task->ctx) == 0, "floating child yields");
    CHECK(fegetround() == FE_DOWNWARD, "child rounding survives caller changes");
}

struct pair { fr_context *parent; fr_context *child; int stage; };

static void inner_entry(void *data)
{
    struct pair *pair = data;
    CHECK(fr_context_yield(pair->parent) == EINVAL, "child cannot yield ancestor");
    ++pair->stage;
    CHECK(fr_context_yield(pair->child) == 0, "inner child yields to parent");
    ++pair->stage;
}

static void outer_entry(void *data)
{
    struct pair *pair = data;
    CHECK(fr_context_resume(pair->child) == 0, "parent resumes inner child");
    CHECK(pair->stage == 1, "inner child returned to correct caller");
    CHECK(fr_context_yield(pair->parent) == 0, "parent yields to root");
    CHECK(fr_context_resume(pair->child) == EALREADY,
          "parent sees inner child completed by root");
    CHECK(pair->stage == 2, "inner child completed on correct caller");
}

/* A removed owner check fails each operation on a real foreign thread. */
static void *foreign_thread(void *data)
{
    fr_context *ctx = data;
    CHECK(fr_context_resume(ctx) == EPERM, "foreign resume refused");
    CHECK(fr_context_yield(ctx) == EPERM, "foreign yield refused");
    CHECK(fr_context_destroy(ctx) == EPERM, "foreign destroy refused");
    CHECK(fr_context_stack_bottom(ctx) == NULL && errno == EPERM,
          "foreign stack bottom refused");
    CHECK(fr_context_stack_size(ctx) == 0 && errno == EPERM,
          "foreign stack size refused");
    return NULL;
}

int main(void)
{
    struct task a = {NULL, 0, 100}, b = {NULL, 0, 900};
    struct task fp = {NULL, 0, 0};
    struct pair pair = {NULL, NULL, 0};
    pthread_t thread;
    fr_context *ctx;
    int i, calls = 0;

    a.ctx = fr_context_create(entry, &a, 65536);
    CHECK(a.ctx != NULL, "create supported context");
    CHECK(fr_context_stack_bottom(a.ctx) != NULL, "usable stack bottom exposed");
    CHECK(fr_context_stack_size(a.ctx) >= 65536, "minimum stack size exposed");
    CHECK(a.steps == 0, "creation dormant");
    CHECK(fr_context_yield(a.ctx) == EINVAL, "caller cannot yield dormant child");
    CHECK(pthread_create(&thread, NULL, foreign_thread, a.ctx) == 0,
          "start foreign thread");
    CHECK(pthread_join(thread, NULL) == 0, "join foreign thread");
    b.ctx = fr_context_create(entry, &b, 65537);
    CHECK(b.ctx != NULL, "unaligned stack request rounded");
    CHECK(fr_context_stack_size(b.ctx) >= 65537 &&
          fr_context_stack_size(b.ctx) < 65537 + (size_t)sysconf(_SC_PAGESIZE),
          "rounded stack excludes guard pages");
    CHECK((uintptr_t)fr_context_stack_bottom(b.ctx) %
          (size_t)sysconf(_SC_PAGESIZE) == 0, "usable stack page aligned");
    for (i = 1; i <= 3; ++i) {
        CHECK(fr_context_resume(a.ctx) == 0, "resume first child");
        CHECK(a.steps == i && b.steps == i - 1, "first child independent");
        CHECK(fr_context_destroy(a.ctx) == EBUSY, "suspended destroy refused");
        CHECK(fr_context_yield(a.ctx) == EINVAL, "caller cannot yield child");
        CHECK(fr_context_resume(b.ctx) == 0, "resume second child");
        CHECK(b.steps == i, "second child independent");
    }
    CHECK(fr_context_resume(a.ctx) == 0, "first entry returns to caller");
    CHECK(fr_context_resume(b.ctx) == 0, "second entry returns to caller");
    CHECK(a.steps == 4 && b.steps == 4, "both callbacks finished");
    CHECK(fr_context_resume(a.ctx) == EALREADY, "completed resume refused");
    CHECK(fr_context_yield(a.ctx) == EINVAL, "completed yield refused");
    CHECK(fr_context_destroy(a.ctx) == 0, "destroy first completed child");
    CHECK(fr_context_destroy(b.ctx) == 0, "destroy second completed child");

    CHECK(fesetround(FE_UPWARD) == 0, "caller sets rounding");
    fp.ctx = fr_context_create(floating_entry, &fp, 65536);
    CHECK(fp.ctx != NULL, "create floating child");
    CHECK(fr_context_resume(fp.ctx) == 0, "resume floating child");
    CHECK(fegetround() == FE_UPWARD, "yield restores caller rounding");
    CHECK(fesetround(FE_TOWARDZERO) == 0, "caller changes rounding");
    CHECK(fr_context_resume(fp.ctx) == 0, "finish floating child");
    CHECK(fegetround() == FE_TOWARDZERO, "completion restores caller rounding");
    CHECK(fr_context_destroy(fp.ctx) == 0, "destroy floating child");
    CHECK(fesetround(FE_TONEAREST) == 0, "reset rounding");

    pair.parent = fr_context_create(outer_entry, &pair, 65536);
    pair.child = fr_context_create(inner_entry, &pair, 65536);
    CHECK(pair.parent != NULL && pair.child != NULL, "create nested contexts");
    CHECK(fr_context_resume(pair.parent) == 0 && pair.stage == 1,
          "nested contexts return to root");
    /* Move the suspended child to another caller on the same native thread. */
    CHECK(fr_context_resume(pair.child) == 0 && pair.stage == 2,
          "resume captures a different caller each time");
    CHECK(fr_context_resume(pair.parent) == 0, "complete nested parent");
    CHECK(fr_context_destroy(pair.child) == 0, "destroy nested child");
    CHECK(fr_context_destroy(pair.parent) == 0, "destroy nested parent");

    CHECK(fr_context_create(NULL, NULL, 65536) == NULL && errno == EINVAL,
          "null entry refused");
    CHECK(fr_context_create(complete, &calls, 65535) == NULL && errno == EINVAL,
          "undersized stack refused");
    CHECK(fr_context_create(complete, &calls, 67108865) == NULL && errno == EINVAL,
          "oversized stack refused");
    CHECK(fr_context_create(complete, &calls, SIZE_MAX) == NULL && errno == EINVAL,
          "overflow stack refused");
    CHECK(fr_context_resume(NULL) == EINVAL, "null resume refused");
    CHECK(fr_context_yield(NULL) == EINVAL, "null yield refused");
    CHECK(fr_context_destroy(NULL) == EINVAL, "null destroy refused");
    CHECK(fr_context_stack_bottom(NULL) == NULL && errno == EINVAL,
          "null stack bottom refused");
    CHECK(fr_context_stack_size(NULL) == 0 && errno == EINVAL,
          "null stack size refused");
    ctx = fr_context_create(complete, &calls, 67108864);
    CHECK(ctx != NULL, "maximum stack accepted");
    CHECK(fr_context_destroy(ctx) == 0 && calls == 0, "destroy dormant child");
    for (i = 0; i < 2000; ++i) {
        ctx = fr_context_create(complete, &calls, 65536);
        CHECK(ctx != NULL, "churn create");
        CHECK(fr_context_resume(ctx) == 0, "churn entry returns");
        CHECK(fr_context_destroy(ctx) == 0, "churn destroys completed child");
    }
    CHECK(calls == 2000, "churn callbacks exactly once");
    printf("PASS: native context lifecycle, nested yields, alternation, ownership, churn (%s)\n",
           fr_context_backend());
    return 0;
}
