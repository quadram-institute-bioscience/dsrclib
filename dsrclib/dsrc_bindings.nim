## Low-level Nim bindings to the DSRC2 C++ library.
## This module provides {.importcpp.} and {.compile.} pragmas
## for the DSRC decompression API.

import std/[os, strutils]

const csrcDir = currentSourcePath().parentDir / "csrc"
const srcDir = csrcDir / "src"
const inclDir = csrcDir / "include"
const bindingsDir = currentSourcePath().parentDir

# Include paths
{.passC: "-I" & inclDir.}
{.passC: "-I" & srcDir.}

# kseq C++ compatibility layer for readfx.
# readfx's kseq.h uses KSEQ_INIT which generates C-only code.
# We compile kseq as C separately and force-include a C++ compatible header.
const readfxKlibParent = staticExec("nimble path readfx 2>/dev/null").splitLines()[0] / "readfx"
{.compile(bindingsDir / "kseq_cpp.c", "-std=c11 -I" & readfxKlibParent).}
{.passC: "-include " & bindingsDir / "kseq_cpp.h".}

const kseqCppH = bindingsDir / "kseq_cpp.h"

# kseq types (C++ compatible, matching readfx's kseq layout)
type
  KString* {.importc: "kstring_t", header: kseqCppH.} = object
    l*: csize_t  ## Length of the string
    m*: csize_t  ## Allocated capacity
    s*: ptr char ## String data

  KStream* {.importc: "kstream_t", header: kseqCppH.} = object

  KSeq* {.importc: "kseq_t", header: kseqCppH.} = object
    name*: KString
    comment*: KString
    sequence* {.importc: "seq".}: KString
    qual*: KString
    last_char*: cint
    f*: ptr KStream

proc kseqInit*(fp: pointer): ptr KSeq
  {.importc: "kseq_init", header: kseqCppH.}

proc kseqRead*(seq: ptr KSeq): cint
  {.importc: "kseq_read", header: kseqCppH.}

proc kseqDestroy*(seq: ptr KSeq)
  {.importc: "kseq_destroy", header: kseqCppH.}

when defined(dsrclibLegacy):
  include dsrc_legacy_bindings_impl
