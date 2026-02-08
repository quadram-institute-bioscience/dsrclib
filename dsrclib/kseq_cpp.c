/*
 * kseq C compilation unit for C++ compatibility.
 *
 * Compiles kseq.h as C and provides non-static kseq_init, kseq_read,
 * kseq_destroy with external linkage, callable from C++ via extern "C".
 *
 * This file must be compiled with -I pointing to the directory
 * containing klib/kseq.h (i.e. the readfx/readfx/ directory).
 */
#include <zlib.h>
#include "klib/kseq.h"

/* KSEQ_INIT2 with empty SCOPE generates non-static (externally visible)
   kseq_init, kseq_read, kseq_destroy. The internal ks_* helpers from
   KSTREAM_INIT remain static inline (only needed within this unit). */
KSEQ_INIT2(, gzFile, gzread)
