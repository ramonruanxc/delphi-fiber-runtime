# Experimental Unix context helper

`fr_context.h` defines experimental C ABI v1. Linux x64 and macOS x64/ARM64
select the matching assembly pair below. Windows uses the Pascal native-fiber
adapter and does not link this helper. There is no C++ runtime dependency.

Creation is dormant and binds the context to the current native thread. Entry
receives the supplied opaque data pointer and must return normally. Every resume
captures its actual caller, including when the caller differs from the previous
resume on the same native thread. Nested contexts are supported by a thread-local
active-context check. Arbitrary concurrent use, stale handles, signal-handler
transfers and thread migration are outside this ABI.

Operations return zero or a positive errno value: `EINVAL` for null handles or
yielding a context other than the active one; `EPERM` for a foreign native thread;
`EBUSY` for resuming a running context or destroying a running/suspended context;
`EALREADY` for resuming a completed context. Create and stack getters use NULL/0
plus errno on failure. Errno numeric values are platform-specific.

Stacks use anonymous `mmap`, with a non-readable/non-writable guard page on each
side. Requests of 64 KiB through 64 MiB are rounded up to a page boundary.
`fr_context_stack_bottom` and `fr_context_stack_size` expose only the usable
region, for compiler-specific stack metadata adapters. Destroy releases the
mapping and handle only before first entry or after normal entry completion.
Cooperative completion is necessary to clean up a suspended stack.

The C helper saves/restores `fenv_t` on transfers, in addition to the upstream
assembly's ABI-preserved registers. This preserves rounding mode consistently
on x64 and ARM64. OS TLS, `errno`, signal state and language runtime TLS are not
task-local. This helper cannot certify Pascal exceptions, managed values,
threadvars or RTL stack/exception metadata. The Pascal adapter and compiler-
specific execution tests must establish their own restricted support contract.
No exception or Pascal managed value may cross the C entry boundary.

## Build from the repository root

Linux x64 (GCC):

```sh
mkdir -p build/context-native
gcc -std=c11 -Wall -Wextra -Werror -O2 -pthread -c native/context/fr_context.c -o build/context-native/fr_context.o
gcc -c native/context/boost/make_x86_64_sysv_elf_gas.S -o build/context-native/make.o
gcc -c native/context/boost/jump_x86_64_sysv_elf_gas.S -o build/context-native/jump.o
ar rcs build/context-native/libfr_context.a build/context-native/fr_context.o build/context-native/make.o build/context-native/jump.o
gcc -std=c11 -Wall -Wextra -Werror -O2 -pthread native/context/context_tests.c build/context-native/libfr_context.a -lm -o build/context-native/context-tests
build/context-native/context-tests
```

macOS (Clang), using `arch=x86_64_sysv_macho_gas` on Intel or
`arch=arm64_aapcs_macho_gas` on Apple Silicon:

```sh
mkdir -p build/context-native
arch=arm64_aapcs_macho_gas
clang -std=c11 -Wall -Wextra -Werror -O2 -pthread -c native/context/fr_context.c -o build/context-native/fr_context.o
clang -c native/context/boost/make_${arch}.S -o build/context-native/make.o
clang -c native/context/boost/jump_${arch}.S -o build/context-native/jump.o
ar rcs build/context-native/libfr_context.a build/context-native/fr_context.o build/context-native/make.o build/context-native/jump.o
clang -std=c11 -Wall -Wextra -Werror -O2 -pthread native/context/context_tests.c build/context-native/libfr_context.a -lm -o build/context-native/context-tests
build/context-native/context-tests
```

The native suite exercises nested stack locals, alternating contexts, changed
callers, entry completion, refused destruction of live stacks, invalid inputs,
native-thread ownership, usable-stack metadata, floating-point rounding and
2,000 create/resume/destroy cycles. A timeout, crash or missing PASS output is a
failure, never a passing negative case.

The Linux x64 suite was executed on Ubuntu 24.04 under WSL. macOS execution is
tracked separately by the repository's hosted validation; the presence of its
assembly files is not execution evidence.
