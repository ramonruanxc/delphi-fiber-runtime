# Vendored Boost.Context assembly

Upstream: https://github.com/boostorg/context

Tag: `boost-1.85.0`

Exact commit: `1bde50e400547e29336afe7ea0cd693d8c884fb6`

All six assembly files were copied byte-for-byte from `src/asm/` at this commit.
Only `make_fcontext` and `jump_fcontext` are used. Original notices are retained.
No Boost C++ source, headers, libraries or `ontop_fcontext` are needed.
The C transfer record matches upstream
[`detail/fcontext.hpp`](https://github.com/boostorg/context/blob/1bde50e400547e29336afe7ea0cd693d8c884fb6/include/boost/context/detail/fcontext.hpp).

Assembly source URL pattern:
`https://raw.githubusercontent.com/boostorg/context/1bde50e400547e29336afe7ea0cd693d8c884fb6/src/asm/<filename>`.

The unmodified Boost Software License 1.0 is from the Boost superproject's
`boost-1.85.0` tag, exact commit `ab7968a0bbcf574a7859240d1d8443f58ed6f6cf`:
https://raw.githubusercontent.com/boostorg/boost/ab7968a0bbcf574a7859240d1d8443f58ed6f6cf/LICENSE_1_0.txt

SHA-256 hashes of vendored bytes:

| File | SHA-256 |
|---|---|
| `make_x86_64_sysv_elf_gas.S` | `214cc3e7fc2924f47fbf4ad2d24d061e7534b2003d429151153cc2dd50d58282` |
| `jump_x86_64_sysv_elf_gas.S` | `e036f57a2ba6b0d98f57c169076f5258344fd813a0814c7cc43066db969b7149` |
| `make_x86_64_sysv_macho_gas.S` | `5e615865fdc9d899bef02955cc98c7e606777e307ca3fcbd241397bf7d94d0e4` |
| `jump_x86_64_sysv_macho_gas.S` | `b8420515bfdc497a647f8b6676f8c62a2ca4e367b7824a68c054d35536bc3e42` |
| `make_arm64_aapcs_macho_gas.S` | `18afb54c805451b5b07898660522ab991b5bdacbe1bf4cdbf86d5a81a0168fd6` |
| `jump_arm64_aapcs_macho_gas.S` | `d6a3dcf28a083e163e8176a1299fa90e2ae1310153fae5313febd7170f1e1521` |
| `LICENSE_1_0.txt` | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` |
