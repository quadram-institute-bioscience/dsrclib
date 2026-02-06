## Low-level Nim bindings to the DSRC2 C++ library.
## This module provides {.importcpp.} and {.compile.} pragmas
## for the DSRC decompression API.

import std/os

const csrcDir = currentSourcePath().parentDir / "csrc"
const srcDir = csrcDir / "src"
const inclDir = csrcDir / "include"

# Include paths
{.passC: "-I" & inclDir.}
{.passC: "-I" & srcDir.}

# Compile all 21 DSRC C++ source files
const cflags = "-std=c++11 -O2 -DNDEBUG -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE"
{.compile(srcDir / "BlockCompressor.cpp", cflags).}
{.compile(srcDir / "BlockCompressorExt.cpp", cflags).}
{.compile(srcDir / "Configurable.cpp", cflags).}
{.compile(srcDir / "DnaModelerHuffman.cpp", cflags).}
{.compile(srcDir / "DsrcArchive.cpp", cflags).}
{.compile(srcDir / "DsrcFile.cpp", cflags).}
{.compile(srcDir / "DsrcIo.cpp", cflags).}
{.compile(srcDir / "DsrcModule.cpp", cflags).}
{.compile(srcDir / "DsrcOperator.cpp", cflags).}
{.compile(srcDir / "DsrcWorker.cpp", cflags).}
{.compile(srcDir / "FastqFile.cpp", cflags).}
{.compile(srcDir / "FastqIo.cpp", cflags).}
{.compile(srcDir / "FastqParser.cpp", cflags).}
{.compile(srcDir / "FastqStream.cpp", cflags).}
{.compile(srcDir / "FileStream.cpp", cflags).}
{.compile(srcDir / "huffman.cpp", cflags).}
{.compile(srcDir / "QualityPositionModeler.cpp", cflags).}
{.compile(srcDir / "QualityRLEModeler.cpp", cflags).}
{.compile(srcDir / "RecordsProcessor.cpp", cflags).}
{.compile(srcDir / "StdStream.cpp", cflags).}
{.compile(srcDir / "TagModeler.cpp", cflags).}

# Ensure std::string is available
{.emit: """#include <string>""".}

# Type bindings
type
  DsrcArchive* {.importcpp: "dsrc::lib::DsrcArchive",
                 header: "dsrc/Dsrc.h".} = object
    ## DSRC2 archive for reading/writing compressed FASTQ files.

  CppFastqRecord* {.importcpp: "dsrc::lib::FastqRecord",
                    header: "dsrc/Dsrc.h".} = object
    ## The C++ FastqRecord from DSRC (not readfx's FQRecord).
    ## Fields: tag, sequence, plus, quality (all std::string).

  DsrcModule* {.importcpp: "dsrc::lib::DsrcModule",
                header: "dsrc/Dsrc.h".} = object
    ## DSRC2 module for file-to-file compress/decompress operations.

# Constructors
proc newDsrcArchive*(): DsrcArchive
  {.importcpp: "dsrc::lib::DsrcArchive()", constructor.}

proc newCppFastqRecord*(): CppFastqRecord
  {.importcpp: "dsrc::lib::FastqRecord()", constructor.}

proc newDsrcModule*(): DsrcModule
  {.importcpp: "dsrc::lib::DsrcModule()", constructor.}

# DsrcArchive decompression methods
proc startDecompress*(a: var DsrcArchive, filename: cstring)
  {.importcpp: "#.StartDecompress(std::string(#))", header: "dsrc/Dsrc.h".}
  ## Opens a .dsrc2 file for decompression.

proc readNextRecord*(a: var DsrcArchive, rec: var CppFastqRecord): bool
  {.importcpp: "#.ReadNextRecord(#)", header: "dsrc/Dsrc.h".}
  ## Reads next FASTQ record. Returns false at EOF.

proc finishDecompress*(a: var DsrcArchive)
  {.importcpp: "#.FinishDecompress()", header: "dsrc/Dsrc.h".}
  ## Finalizes decompression and releases resources.

# DsrcModule file-to-file operations
proc decompress*(m: var DsrcModule, inputFilename, outputFilename: cstring)
  {.importcpp: "#.Decompress(std::string(#), std::string(#))", header: "dsrc/Dsrc.h".}
  ## Decompress a .dsrc2 file to a FASTQ file (multi-threaded).

# CppFastqRecord field accessors (std::string -> cstring via c_str())
# Cast from const char* to char* to satisfy Nim's cstring type
proc getTag*(rec: CppFastqRecord): cstring
  {.importcpp: "(char*)(#.tag.c_str())", header: "dsrc/Dsrc.h".}

proc getSequence*(rec: CppFastqRecord): cstring
  {.importcpp: "(char*)(#.sequence.c_str())", header: "dsrc/Dsrc.h".}

proc getQuality*(rec: CppFastqRecord): cstring
  {.importcpp: "(char*)(#.quality.c_str())", header: "dsrc/Dsrc.h".}

proc getPlus*(rec: CppFastqRecord): cstring
  {.importcpp: "(char*)(#.plus.c_str())", header: "dsrc/Dsrc.h".}
