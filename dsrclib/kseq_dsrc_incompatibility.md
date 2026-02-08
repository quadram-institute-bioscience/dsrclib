# kseq / DSRC C++ Incompatibility

## The Problem

dsrclib needs to compile with Nim's C++ backend (`nim cpp`) because the DSRC2 library is written in C++. However, readfx — the FASTQ parsing library — wraps [kseq.h](https://github.com/attractivechaos/klib), a C-only header that uses macros incompatible with C++.

Specifically, readfx's `kseq.h` contains:

```c
#include "klib/kseq.h"
KSEQ_INIT(gzFile, gzread)
```

`KSEQ_INIT` expands to function definitions that rely on implicit `void*` to typed-pointer conversions — valid in C but illegal in C++:

```c
// Inside __KS_GETUNTIL macro expansion:
unsigned char *sep = memchr(ks->buf + ks->begin, '\n', ...);
//                   ^^^^^^^ returns void* — C++ rejects implicit cast to unsigned char*
```

This means any Nim code that calls `readFQ()` or `readFQPtr()` triggers inclusion of `kseq.h` in the generated `.cpp` file, causing compilation errors.

### Secondary issue: stale comment data

readfx's `readFQ` iterator converts kseq fields to Nim strings via `$cast[cstring](rec.comment)`, which reads until a null terminator. But kseq reuses buffers between records — when a record has no comment, kseq sets `comment.l = 0` without null-terminating the buffer. The previous record's comment data remains, causing `readFQ` to return stale comments for comment-less records.

## The Fix

Three files implement a C++ compatibility layer:

### `kseq_cpp.c` — C compilation unit

Compiles kseq as C (not C++) in a separate translation unit. Uses `KSEQ_INIT2` with empty scope to generate `kseq_init`, `kseq_read`, and `kseq_destroy` with external linkage (non-static), so they can be linked from C++ code:

```c
#include <zlib.h>
#include "klib/kseq.h"
KSEQ_INIT2(, gzFile, gzread)  // empty scope = non-static
```

Compiled via `{.compile.}` with `-std=c11` to override any C++ flags, and `-I` pointing to readfx's directory so it can find `klib/kseq.h`.

### `kseq_cpp.h` — C++ compatible header

Force-included in all C++ compilation units via `-include` passC flag. Active only under `#ifdef __cplusplus`; a no-op when compiled as C (so it doesn't interfere with `kseq_cpp.c`).

It does three things:

1. **Suppresses klib/kseq.h** by defining the `AC_KSEQ_H` include guard
2. **Neutralizes `KSEQ_INIT`** by defining it as an empty macro, so when the C++ compiler processes readfx's `kseq.h` wrapper, the macro expansion is harmless
3. **Provides C++ declarations** for the kseq types and functions via `extern "C"`

`kseq_init` is declared with `void*` parameter (not `gzFile`) because readfx maps `gzFile` to Nim's `pointer` type, which becomes `void*` in C++.

### `dsrc_bindings.nim` — Nim-level type bindings

Declares `KString`, `KSeq`, and the kseq functions using `kseq_cpp.h` as the header. `KString` exposes the `l` (length) field that readfx's private `kstring_t` doesn't export.

### `dsrclib.nim` — `readFastq` iterator

Uses the bindings above to provide a length-aware FASTQ iterator:

```nim
iterator readFastq*(path: string): FQRecord =
  ...
  while dsrc_bindings.kseqRead(rec) >= 0:
    yield FQRecord(
      name: toNimString(rec.name),       # uses KString.l, not null terminator
      comment: toNimString(rec.comment),  # correctly returns "" when l == 0
      ...
    )
```

This replaces readfx's `readFQ` for dsrclib users, fixing the stale comment bug.

## How it all fits together

```
C++ compiler processes .nim.cpp file
  |
  +-- -include kseq_cpp.h (force-included first)
  |     |
  |     +-- #ifdef __cplusplus: defines AC_KSEQ_H guard, empty KSEQ_INIT
  |     +-- declares kseq types + extern "C" functions
  |
  +-- #include ".../readfx/kseq.h" (triggered by readfx's {.header.} pragma)
  |     |
  |     +-- #include "klib/kseq.h" --> skipped (AC_KSEQ_H already defined)
  |     +-- KSEQ_INIT(gzFile, gzread) --> expands to nothing
  |
  +-- calls kseq_init(), kseq_read() --> resolved by linker

C compiler processes kseq_cpp.c
  |
  +-- -include kseq_cpp.h --> no-op (not __cplusplus)
  +-- #include "klib/kseq.h" --> full kseq macro expansion (C mode, no issues)
  +-- KSEQ_INIT2(, gzFile, gzread) --> generates non-static functions
  +-- provides kseq_init, kseq_read, kseq_destroy symbols for linking
```
