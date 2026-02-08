/*
 * C++ compatible kseq declarations.
 *
 * This header is force-included (-include) before all generated C++ code.
 * It provides:
 *   1. kseq type definitions compatible with readfx's Nim declarations
 *   2. extern "C" function declarations for kseq_init/kseq_read/kseq_destroy
 *   3. Guards that prevent readfx's kseq.h from expanding KSEQ_INIT in C++
 *
 * The actual implementations live in kseq_cpp.c (compiled as C).
 *
 * When included from C (kseq_cpp.c), this header is a no-op — the C file
 * includes klib/kseq.h directly and compiles the actual implementations.
 */
#ifndef KSEQ_CPP_H
#define KSEQ_CPP_H

#ifdef __cplusplus
/* === C++ mode only === */

/* Prevent klib/kseq.h from being included (it generates C-only code).
   The actual guard macro is AC_KSEQ_H (not KSEQ_H). */
#ifndef AC_KSEQ_H
#define AC_KSEQ_H
#endif

/* When readfx/kseq.h is included by Nim's generated C++, it will try to
   call KSEQ_INIT(gzFile, gzread). Make it a no-op since we provide
   the implementations separately via kseq_cpp.c. */
#ifndef KSEQ_INIT
#define KSEQ_INIT(type_t, __read)
#endif

#include <zlib.h>
#include <stdlib.h>

extern "C" {

/* kstring_t — matches klib/kseq.h definition */
#ifndef KSTRING_T
#define KSTRING_T kstring_t
typedef struct __kstring_t {
    size_t l, m;
    char *s;
} kstring_t;
#endif

typedef struct {
    unsigned char *buf;
    int begin, end, is_eof;
    gzFile f;
} kstream_t;

typedef struct {
    kstring_t name, comment, seq, qual;
    int last_char;
    kstream_t *f;
} kseq_t;

/* Functions implemented in kseq_cpp.c (compiled as C).
   kseq_init takes void* because readfx declares gzFile as Nim `pointer`. */
kseq_t *kseq_init(void *fp);
int kseq_read(kseq_t *seq);
void kseq_destroy(kseq_t *ks);

#define kseq_rewind(ks) ((ks)->last_char = (ks)->f->is_eof = (ks)->f->begin = (ks)->f->end = 0)

} /* extern "C" */

#endif /* __cplusplus */

#endif /* KSEQ_CPP_H */
