## dsrclib — Read DSRC2 compressed FASTQ files
##
## Provides a readfx-compatible iterator for reading .dsrc2 files.
##
## Usage:
##   import dsrclib
##   for rec in readDSRC("reads.dsrc2"):
##     echo rec.name, " ", rec.sequence.len

import readfx
import dsrclib/dsrc_bindings

export readfx
export dsrc_bindings

proc toNimString(ks: KString): string =
  ## Convert a KString to a Nim string using the length field,
  ## not null termination. This avoids stale data from kseq's
  ## buffer reuse when a field (e.g. comment) is empty.
  if ks.s.isNil or ks.l == 0:
    return ""
  result = newString(ks.l.int)
  copyMem(addr result[0], ks.s, ks.l.int)

# zlib procs for readFastq (readfx links -lz but doesn't export these).
# Use header to avoid conflicting forward declarations with zlib.h.
# gzFile is gzFile_s* in zlib; C++ requires explicit casts from void*.
type GzFilePtr {.importc: "gzFile", header: "<zlib.h>".} = pointer
proc dsrc_gzopen(path: cstring, mode: cstring): GzFilePtr
  {.cdecl, importc: "gzopen", header: "<zlib.h>".}
proc dsrc_gzdopen(fd: int32, mode: cstring): GzFilePtr
  {.cdecl, importc: "gzdopen", header: "<zlib.h>".}
proc dsrc_gzclose(thefile: GzFilePtr): int32
  {.cdecl, importc: "gzclose", header: "<zlib.h>".}

iterator readFastq*(path: string): FQRecord =
  ## Read FASTQ/FASTA records from a plain or gzipped file.
  ## Uses kseq (from readfx) with proper length-aware string conversion,
  ## avoiding stale comment data on records without comments.
  var fp: GzFilePtr
  if path == "-":
    fp = dsrc_gzdopen(0, "r")
  else:
    fp = dsrc_gzopen(path.cstring, "r")
  doAssert fp != nil, "Failed to open: " & path
  let rec = dsrc_bindings.kseqInit(cast[pointer](fp))
  while dsrc_bindings.kseqRead(rec) >= 0:
    yield FQRecord(
      name: toNimString(rec.name),
      comment: toNimString(rec.comment),
      sequence: toNimString(rec.sequence),
      quality: toNimString(rec.qual)
    )
  dsrc_bindings.kseqDestroy(rec)
  discard dsrc_gzclose(fp)

proc dsrc_gzread(f: GzFilePtr, buf: pointer, len: cuint): cint
  {.cdecl, importc: "gzread", header: "<zlib.h>".}

proc gzDecompressFile*(gzPath, outPath: string) =
  ## Decompress a gzipped file to a plain file.
  ## Useful for preparing gzipped FASTQ for compressDSRC.
  let fp = dsrc_gzopen(gzPath.cstring, "r")
  doAssert fp != nil, "Failed to open: " & gzPath
  let outFile = open(outPath, fmWrite)
  var buf: array[65536, char]
  while true:
    let n = dsrc_gzread(fp, addr buf[0], buf.len.cuint)
    if n <= 0: break
    discard outFile.writeBuffer(addr buf[0], n)
  outFile.close()
  discard dsrc_gzclose(fp)

proc splitTag(tag: string): tuple[name: string, comment: string] =
  # DSRC's tag field includes the '@' prefix from the FASTQ header line.
  # ReadFX strips it, so we do the same.
  var t = tag
  if t.len > 0 and t[0] == '@':
    t = t[1 .. ^1]
  let spacePos = t.find(' ')
  if spacePos == -1:
    result = (t, "")
  else:
    result = (t[0 ..< spacePos], t[spacePos + 1 .. ^1])

iterator readDSRC*(path: string): FQRecord =
  ## Read FASTQ records from a DSRC2 compressed file.
  ## Yields readfx-compatible FQRecord objects.
  var archive = newDsrcArchive()
  var cppRec = newCppFastqRecord()
  try:
    archive.startDecompress(path.cstring)
    while archive.readNextRecord(cppRec):
      let tag = $cppRec.getTag()
      let (name, comment) = splitTag(tag)
      yield FQRecord(
        name: name,
        comment: comment,
        sequence: $cppRec.getSequence(),
        quality: $cppRec.getQuality()
      )
    archive.finishDecompress()
  except:
    try: archive.finishDecompress()
    except: discard
    let msg = getCurrentExceptionMsg()
    raise newException(IOError, "DSRC read error: " & msg)

proc decompressDSRC*(inputPath, outputPath: string,
                     threads: uint32 = 0, useStdIo: bool = false) =
  ## Decompress a .dsrc2 file to a .fastq file.
  ## Uses DsrcModule for maximum performance (multi-threaded).
  ## threads: 0 = use all available cores (default).
  ## useStdIo: if true, write decompressed FASTQ to stdout instead of outputPath.
  var module = newDsrcModule()
  if threads > 0:
    module.setThreadsNumber(threads)
  if useStdIo:
    module.setStdIoUsing(true)
  module.decompress(inputPath.cstring, outputPath.cstring)

proc makeTag(rec: FQRecord): string =
  ## Reconstruct the DSRC tag field from an FQRecord.
  ## DSRC's tag = "@name comment" (with @ prefix).
  if rec.comment.len > 0:
    "@" & rec.name & " " & rec.comment
  else:
    "@" & rec.name

proc writeDSRC*(path: string, records: openArray[FQRecord],
                qualityOffset: uint32 = 33) =
  ## Write a sequence of FQRecord to a DSRC2 compressed file.
  ## qualityOffset: 33 for Phred+33 (Illumina 1.8+), 64 for Phred+64.
  var archive = newDsrcArchive()
  var cppRec = newCppFastqRecord()
  archive.setQualityOffset(qualityOffset)
  archive.startCompress(path.cstring)
  for rec in records:
    cppRec.setTag(makeTag(rec).cstring)
    cppRec.setSequence(rec.sequence.cstring)
    cppRec.setQuality(rec.quality.cstring)
    cppRec.setPlus("+".cstring)
    archive.writeNextRecord(cppRec)
  archive.finishCompress()

proc compressDSRC*(inputPath, outputPath: string,
                   threads: uint32 = 0, useStdIo: bool = false) =
  ## Compress a .fastq file to a .dsrc2 file.
  ## Uses DsrcModule for maximum performance (multi-threaded).
  ## threads: 0 = use all available cores (default).
  ## useStdIo: if true, read FASTQ from stdin instead of inputPath.
  var module = newDsrcModule()
  if threads > 0:
    module.setThreadsNumber(threads)
  if useStdIo:
    module.setStdIoUsing(true)
  module.compress(inputPath.cstring, outputPath.cstring)
