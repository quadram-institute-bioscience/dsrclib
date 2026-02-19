# Compile all DSRC C++ source files for legacy backend bindings.
const cflags = "-std=c++11 -O3 -march=native -flto -DNDEBUG -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE"
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

# Ensure std::string is available for importcpp signatures.
{.emit: """#include <string>""".}

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

proc newDsrcArchive*(): DsrcArchive
  {.importcpp: "dsrc::lib::DsrcArchive()", constructor.}

proc newCppFastqRecord*(): CppFastqRecord
  {.importcpp: "dsrc::lib::FastqRecord()", constructor.}

proc newDsrcModule*(): DsrcModule
  {.importcpp: "dsrc::lib::DsrcModule()", constructor.}

proc startDecompress*(a: var DsrcArchive, filename: cstring)
  {.importcpp: "#.StartDecompress(std::string(#))", header: "dsrc/Dsrc.h".}
  ## Opens a .dsrc2 file for decompression.

proc readNextRecord*(a: var DsrcArchive, rec: var CppFastqRecord): bool
  {.importcpp: "#.ReadNextRecord(#)", header: "dsrc/Dsrc.h".}
  ## Reads next FASTQ record. Returns false at EOF.

proc finishDecompress*(a: var DsrcArchive)
  {.importcpp: "#.FinishDecompress()", header: "dsrc/Dsrc.h".}
  ## Finalizes decompression and releases resources.

proc decompress*(m: var DsrcModule, inputFilename, outputFilename: cstring)
  {.importcpp: "#.Decompress(std::string(#), std::string(#))", header: "dsrc/Dsrc.h".}
  ## Decompress a .dsrc2 file to a FASTQ file (multi-threaded).

# CppFastqRecord field accessors (std::string -> cstring via c_str()).
proc getTag*(rec: CppFastqRecord): cstring
  {.importcpp: "(char*)(#.tag.c_str())", header: "dsrc/Dsrc.h".}

proc getSequence*(rec: CppFastqRecord): cstring
  {.importcpp: "(char*)(#.sequence.c_str())", header: "dsrc/Dsrc.h".}

proc getQuality*(rec: CppFastqRecord): cstring
  {.importcpp: "(char*)(#.quality.c_str())", header: "dsrc/Dsrc.h".}

proc getPlus*(rec: CppFastqRecord): cstring
  {.importcpp: "(char*)(#.plus.c_str())", header: "dsrc/Dsrc.h".}

proc startCompress*(a: var DsrcArchive, filename: cstring)
  {.importcpp: "#.StartCompress(std::string(#))", header: "dsrc/Dsrc.h".}
  ## Opens a .dsrc2 file for compression.

proc writeNextRecord*(a: var DsrcArchive, rec: CppFastqRecord)
  {.importcpp: "#.WriteNextRecord(#)", header: "dsrc/Dsrc.h".}
  ## Writes a FASTQ record to the compressed archive.

proc finishCompress*(a: var DsrcArchive)
  {.importcpp: "#.FinishCompress()", header: "dsrc/Dsrc.h".}
  ## Finalizes compression and releases resources.

proc setTag*(rec: var CppFastqRecord, val: cstring)
  {.importcpp: "#.tag = std::string(#)".}

proc setSequence*(rec: var CppFastqRecord, val: cstring)
  {.importcpp: "#.sequence = std::string(#)".}

proc setQuality*(rec: var CppFastqRecord, val: cstring)
  {.importcpp: "#.quality = std::string(#)".}

proc setPlus*(rec: var CppFastqRecord, val: cstring)
  {.importcpp: "#.plus = std::string(#)".}

proc compress*(m: var DsrcModule, inputFilename, outputFilename: cstring)
  {.importcpp: "#.Compress(std::string(#), std::string(#))", header: "dsrc/Dsrc.h".}
  ## Compress a FASTQ file to a .dsrc2 file (multi-threaded).

proc setQualityOffset*(c: var DsrcArchive, offset: uint32)
  {.importcpp: "#.SetQualityOffset(#)", header: "dsrc/Dsrc.h".}

proc setDnaCompressionLevel*(c: var DsrcArchive, level: uint32)
  {.importcpp: "#.SetDnaCompressionLevel(#)", header: "dsrc/Dsrc.h".}

proc setQualityCompressionLevel*(c: var DsrcArchive, level: uint32)
  {.importcpp: "#.SetQualityCompressionLevel(#)", header: "dsrc/Dsrc.h".}

proc setLossyCompression*(c: var DsrcArchive, lossy: bool)
  {.importcpp: "#.SetLossyCompression(#)", header: "dsrc/Dsrc.h".}

proc setFastqBufferSizeMB*(c: var DsrcArchive, size: uint64)
  {.importcpp: "#.SetFastqBufferSizeMB(#)", header: "dsrc/Dsrc.h".}

proc setQualityOffset*(c: var DsrcModule, offset: uint32)
  {.importcpp: "#.SetQualityOffset(#)", header: "dsrc/Dsrc.h".}

proc setDnaCompressionLevel*(c: var DsrcModule, level: uint32)
  {.importcpp: "#.SetDnaCompressionLevel(#)", header: "dsrc/Dsrc.h".}

proc setQualityCompressionLevel*(c: var DsrcModule, level: uint32)
  {.importcpp: "#.SetQualityCompressionLevel(#)", header: "dsrc/Dsrc.h".}

proc setLossyCompression*(c: var DsrcModule, lossy: bool)
  {.importcpp: "#.SetLossyCompression(#)", header: "dsrc/Dsrc.h".}

proc setFastqBufferSizeMB*(c: var DsrcModule, size: uint64)
  {.importcpp: "#.SetFastqBufferSizeMB(#)", header: "dsrc/Dsrc.h".}

proc setThreadsNumber*(c: var DsrcModule, threadNum: uint32)
  {.importcpp: "#.SetThreadsNumber(#)", header: "dsrc/Dsrc.h".}

proc setStdIoUsing*(c: var DsrcModule, use: bool)
  {.importcpp: "#.SetStdIoUsing(#)", header: "dsrc/Dsrc.h".}
