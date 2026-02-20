## dsrclib — Read DSRC2 compressed FASTQ files
##
## Provides a readfx-compatible iterator for reading .dsrc2 files.
##
## Usage:
##   import dsrclib
##   for rec in readDSRC("reads.dsrc2"):
##     echo rec.name, " ", rec.sequence.len

import readfx
import std/[os, osproc, strutils]
when compileOption("threads"):
  import std/[deques, threadpool]
import dsrclib/dsrc_bindings
import dsrclib/pure as pure

export readfx
export dsrc_bindings

const
  LegacyBackendEnabled* = defined(dsrclibLegacy)
  PureOnlyBackend* = not LegacyBackendEnabled

when defined(dsrclibPureOnly) and defined(dsrclibLegacy):
  {.error: "dsrclibPureOnly and dsrclibLegacy are mutually exclusive".}
when defined(dsrclibPureOnly):
  {.warning: "dsrclibPureOnly is deprecated; pure backend is now default. Use -d:dsrclibLegacy to enable legacy C++ backend.".}

type
  BackendMode = enum
    bmAuto, bmPure, bmLegacy

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

const FastqWriteBufferFlushBytes = 1 shl 20

proc appendSlice(buf: var string; s: string; first, last: int) =
  if first < 0 or last < first or first >= s.len:
    return
  let hi = min(last, s.high)
  let n = hi - first + 1
  let oldLen = buf.len
  buf.setLen(oldLen + n)
  copyMem(addr buf[oldLen], unsafeAddr s[first], n)

proc appendNormalizedTag(buf: var string; tag: string) =
  var start = 0
  if tag.len > 0 and tag[0] == '@':
    start = 1

  let spacePos = tag.find(' ', start)
  buf.add('@')

  if spacePos == -1:
    appendSlice(buf, tag, start, tag.high)
    return

  appendSlice(buf, tag, start, spacePos - 1)
  if spacePos < tag.high:
    buf.add(' ')
    appendSlice(buf, tag, spacePos + 1, tag.high)

proc appendPureFastqRecord(buf: var string; rec: pure.PureFastqRecord) =
  appendNormalizedTag(buf, rec.title)
  buf.add('\n')
  buf.add(rec.sequence)
  buf.add("\n+\n")
  buf.add(rec.quality)
  buf.add('\n')

proc envEnabled(name: string): bool =
  getEnv(name, "0") == "1"

proc backendMode(): BackendMode =
  let mode = getEnv("DSRCLIB_BACKEND", "auto").strip().toLowerAscii()
  case mode
  of "", "auto":
    bmAuto
  of "pure":
    bmPure
  of "legacy":
    bmLegacy
  else:
    raise newException(IOError, "Invalid DSRCLIB_BACKEND value: " & mode & " (expected auto|pure|legacy)")

proc backendForcesPure(): bool =
  backendMode() == bmPure

proc backendForcesLegacy(): bool =
  backendMode() == bmLegacy

proc ensureLegacyBackend(op: string) =
  when not defined(dsrclibLegacy):
    raise newException(IOError, op & ": legacy backend unavailable in this build (compile with -d:dsrclibLegacy)")
  else:
    discard

proc resolvedPureWorkers(threads: uint32): int =
  when compileOption("threads"):
    if threads == 0'u32:
      return max(countProcessors(), 1)
    if threads > 1'u32:
      return int(threads)
  1

proc usePureStOperator(threads: uint32): bool =
  ## threads=1 now defaults to pure-Nim ST path.
  ## Keep FORCE_PURE_ST for backwards compatibility and
  ## FORCE_LEGACY_ST as an explicit fallback switch.
  if backendForcesLegacy():
    return false
  if backendForcesPure():
    when compileOption("threads"):
      return threads == 1'u32
    else:
      return threads <= 1'u32
  when not defined(dsrclibLegacy):
    when compileOption("threads"):
      return threads == 1'u32
    else:
      return threads <= 1'u32
  else:
    return threads == 1'u32 and (
      envEnabled("DSRCLIB_FORCE_PURE_ST_OPERATOR") or
      not envEnabled("DSRCLIB_FORCE_LEGACY_ST_OPERATOR")
    )

proc usePureMtOperator(threads: uint32): bool =
  ## threads>1 now defaults to pure-Nim MT path when thread support is enabled.
  when compileOption("threads"):
    if backendForcesLegacy():
      return false
    if backendForcesPure():
      return threads == 0'u32 or threads > 1'u32
    when not defined(dsrclibLegacy):
      return threads == 0'u32 or threads > 1'u32
    else:
      return threads > 1'u32 and (
        envEnabled("DSRCLIB_FORCE_PURE_MT_OPERATOR") or
        not envEnabled("DSRCLIB_FORCE_LEGACY_MT_OPERATOR")
      )
  else:
    return false

when compileOption("threads"):
  proc configureThreadPool(workers: int) =
    ## Keep a fixed-size worker pool for deterministic bounded in-flight tasks.
    doAssert workers > 0
    setMinPoolSize(workers)
    setMaxPoolSize(workers)

  proc encodeChunkTask(
    records: seq[pure.PureFastqRecord];
    datasetType: pure.FastqDatasetType;
    compSettings: pure.CompressionSettings
  ): seq[uint8] {.gcsafe.} =
    var work = records
    pure.encodeChunkRecordsInPlace(work, datasetType, compSettings)

  proc decodeChunkTask(
    chunk: seq[uint8];
    datasetType: pure.FastqDatasetType;
    compSettings: pure.CompressionSettings;
    verifyChecksums: bool
  ): seq[pure.PureFastqRecord] {.gcsafe.} =
    pure.decodeChunkRecords(
      chunk,
      datasetType,
      compSettings,
      verifyChecksums = verifyChecksums
    )

iterator readDSRC*(path: string): FQRecord =
  ## Read FASTQ records from a DSRC2 compressed file.
  ## Yields readfx-compatible FQRecord objects.
  if backendForcesPure() or
     (not backendForcesLegacy() and getEnv("DSRCLIB_FORCE_PURE_DECODE", "0") == "1") or
     (PureOnlyBackend and not backendForcesLegacy()):
    for rec in pure.readDsrcPure(path):
      let (name, comment) = splitTag(rec.title)
      yield FQRecord(
        name: name,
        comment: comment,
        sequence: rec.sequence,
        quality: rec.quality
      )
  else:
    when defined(dsrclibLegacy):
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
    else:
      ensureLegacyBackend("readDSRC")

iterator readDSRCPure*(path: string): FQRecord =
  ## Read FASTQ records from a DSRC2 file using the pure-Nim decode path.
  for rec in pure.readDsrcPure(path):
    let (name, comment) = splitTag(rec.title)
    yield FQRecord(
      name: name,
      comment: comment,
      sequence: rec.sequence,
      quality: rec.quality
    )

proc writeFastqFromPure(inputPath: string; outFile: File) =
  ## Materialize a DSRC archive to FASTQ via the pure-Nim decoder.
  var outBuf = newStringOfCap(FastqWriteBufferFlushBytes)
  for rec in pure.readDsrcPure(inputPath):
    appendPureFastqRecord(outBuf, rec)
    if outBuf.len >= FastqWriteBufferFlushBytes:
      outFile.write(outBuf)
      outBuf.setLen(0)
  if outBuf.len > 0:
    outFile.write(outBuf)

when compileOption("threads"):
  proc writeFastqFromPureMt(
    inputPath: string;
    outFile: File;
    workers: int;
    verifyChecksums = true
  ) =
    if workers <= 1:
      writeFastqFromPure(inputPath, outFile)
      return

    configureThreadPool(workers)
    let maxPending = max(workers * 2, workers)

    var reader = pure.openDsrcContainerReader(inputPath)
    defer: reader.close()

    var pending = initDeque[FlowVar[seq[pure.PureFastqRecord]]]()
    proc drainOneDecode() =
      let decoded = ^pending.popFirst()
      var outBuf = newStringOfCap(FastqWriteBufferFlushBytes)
      for rec in decoded:
        appendPureFastqRecord(outBuf, rec)
      if outBuf.len > 0:
        outFile.write(outBuf)

    var chunk: seq[uint8]
    while reader.readNextChunk(chunk):
      pending.addLast(
        spawn decodeChunkTask(
          chunk,
          reader.footer.datasetType,
          reader.footer.compSettings,
          verifyChecksums
        )
      )
      if pending.len >= maxPending:
        drainOneDecode()

    while pending.len > 0:
      drainOneDecode()

proc writeFastqFileFromPure(inputPath, outputPath: string) =
  var f = open(outputPath, fmWrite)
  defer: f.close()
  writeFastqFromPure(inputPath, f)

when compileOption("threads"):
  proc writeFastqFileFromPureMt(inputPath, outputPath: string; workers: int) =
    var f = open(outputPath, fmWrite)
    defer: f.close()
    writeFastqFromPureMt(inputPath, f, workers)

proc decompressDSRC*(inputPath, outputPath: string,
                     threads: uint32 = 0, useStdIo: bool = false) =
  ## Decompress a .dsrc2 file to a .fastq file.
  ## Uses DsrcModule for maximum performance (multi-threaded).
  ## threads: 0 = use all available cores (default).
  ## useStdIo: if true, write decompressed FASTQ to stdout instead of outputPath.
  let pureWorkers = resolvedPureWorkers(threads)
  if usePureStOperator(threads):
    if useStdIo:
      writeFastqFromPure(inputPath, stdout)
    else:
      writeFastqFileFromPure(inputPath, outputPath)
    return

  when compileOption("threads"):
    if usePureMtOperator(threads):
      if useStdIo:
        writeFastqFromPureMt(inputPath, stdout, pureWorkers)
      else:
        writeFastqFileFromPureMt(inputPath, outputPath, pureWorkers)
      return

  when defined(dsrclibLegacy):
    var module = newDsrcModule()
    if threads > 0:
      module.setThreadsNumber(threads)
    if useStdIo:
      module.setStdIoUsing(true)
    module.decompress(inputPath.cstring, outputPath.cstring)
  else:
    ensureLegacyBackend("decompressDSRC")

proc makeTag(rec: FQRecord): string =
  ## Reconstruct the DSRC tag field from an FQRecord.
  ## DSRC's tag = "@name comment" (with @ prefix).
  if rec.comment.len > 0:
    result = newStringOfCap(rec.name.len + rec.comment.len + 2)
    result.add('@')
    result.add(rec.name)
    result.add(' ')
    result.add(rec.comment)
  else:
    result = newStringOfCap(rec.name.len + 1)
    result.add('@')
    result.add(rec.name)

proc toPureRecord(rec: FQRecord): pure.PureFastqRecord =
  pure.PureFastqRecord(
    title: makeTag(rec),
    sequence: rec.sequence,
    plus: "+",
    quality: rec.quality,
    truncatedLen: 0'u16
  )

proc writeDSRCPure*(
  path: string;
  records: openArray[FQRecord];
  qualityOffset: uint32 = 33;
  calculateCrc32 = false;
  plusRepetition = false;
  lossy = false;
  dnaOrder: uint32 = 0;
  qualityOrder: uint32 = 0;
  debugControlChecks = false
) =
  ## Write records to a DSRC2 file using the pure-Nim encoder.
  ## Color-space and non-default tag-preserve modes are intentionally unsupported.
  if records.len == 0:
    raise newException(IOError, "writeDSRCPure: no records provided")

  var dsType = pure.defaultFastqDatasetType()
  dsType.qualityOffset = qualityOffset
  dsType.plusRepetition = plusRepetition
  dsType.colorSpace = false

  var settings = pure.defaultCompressionSettings()
  settings.lossy = lossy
  settings.dnaOrder = dnaOrder
  settings.qualityOrder = qualityOrder
  settings.tagPreserveFlags = pure.DefaultTagPreserveFlags
  settings.calculateCrc32 = calculateCrc32
  settings.debugControlChecks = debugControlChecks

  var pureRecords = newSeq[pure.PureFastqRecord](records.len)
  for i in 0 ..< records.len:
    if records[i].sequence.len != records[i].quality.len:
      raise newException(IOError, "writeDSRCPure: sequence/quality length mismatch at record " & $i)
    pureRecords[i] = toPureRecord(records[i])

  let chunk = pure.encodeChunkRecords(pureRecords, dsType, settings)
  var writer = pure.openDsrcContainerWriter(path, dsType, settings)
  writer.writeChunk(chunk)
  writer.close()

proc compressDSRCPure*(
  inputPath, outputPath: string;
  qualityOffset: uint32 = 33;
  calculateCrc32 = false;
  plusRepetition = false;
  lossy = false;
  dnaOrder: uint32 = 0;
  qualityOrder: uint32 = 0;
  targetChunkBytes = 1 shl 22;
  workers = 1;
  debugControlChecks = false
) =
  ## Compress a FASTQ file to DSRC2 using chunked pure-Nim encoding.
  ## Color-space and non-default tag-preserve modes are intentionally unsupported.
  if targetChunkBytes <= 0:
    raise newException(IOError, "compressDSRCPure: targetChunkBytes must be > 0")
  if workers <= 0:
    raise newException(IOError, "compressDSRCPure: workers must be > 0")

  var dsType = pure.defaultFastqDatasetType()
  dsType.qualityOffset = qualityOffset
  dsType.plusRepetition = plusRepetition
  dsType.colorSpace = false

  var settings = pure.defaultCompressionSettings()
  settings.lossy = lossy
  settings.dnaOrder = dnaOrder
  settings.qualityOrder = qualityOrder
  settings.tagPreserveFlags = pure.DefaultTagPreserveFlags
  settings.calculateCrc32 = calculateCrc32
  settings.debugControlChecks = debugControlChecks

  var chunkRecords: seq[pure.PureFastqRecord] = @[]
  var chunkBytes = 0
  var totalRecords = 0

  var writer: pure.DsrcContainerWriter
  var writerOpen = false

  proc flushChunkSync() =
    if chunkRecords.len == 0:
      return

    if not writerOpen:
      writer = pure.openDsrcContainerWriter(outputPath, dsType, settings)
      writerOpen = true

    let chunk = pure.encodeChunkRecordsInPlace(chunkRecords, dsType, settings)
    writer.writeChunk(chunk)
    chunkRecords.setLen(0)
    chunkBytes = 0

  when compileOption("threads"):
    var pending = initDeque[FlowVar[seq[uint8]]]()
    let maxPending = max(workers * 2, workers)

    proc drainOneEncode() =
      writer.writeChunk(^pending.popFirst())

    proc flushChunkMt() =
      if chunkRecords.len == 0:
        return

      if not writerOpen:
        writer = pure.openDsrcContainerWriter(outputPath, dsType, settings)
        writerOpen = true

      var batch = move(chunkRecords)
      chunkRecords = newSeqOfCap[pure.PureFastqRecord](batch.len)
      chunkBytes = 0
      pending.addLast(spawn encodeChunkTask(batch, dsType, settings))
      if pending.len >= maxPending:
        drainOneEncode()

  try:
    when compileOption("threads"):
      if workers > 1:
        configureThreadPool(workers)
    for rec in readFastq(inputPath):
      if rec.sequence.len != rec.quality.len:
        raise newException(IOError, "compressDSRCPure: sequence/quality length mismatch for read '" & rec.name & "'")

      if rec.sequence.len > 1 and (
        (rec.sequence[1] >= '0' and rec.sequence[1] <= '3') or rec.sequence[1] == '.'
      ):
        raise newException(IOError, "compressDSRCPure: color-space datasets are not supported by pure-Nim encoder")

      let title = makeTag(rec)
      chunkRecords.add(
        pure.PureFastqRecord(
          title: title,
          sequence: rec.sequence,
          plus: "+",
          quality: rec.quality,
          truncatedLen: 0'u16
        )
      )
      chunkBytes += title.len + rec.sequence.len + rec.quality.len + 5
      inc totalRecords

      if chunkBytes >= targetChunkBytes:
        when compileOption("threads"):
          if workers > 1:
            flushChunkMt()
          else:
            flushChunkSync()
        else:
          flushChunkSync()

    if totalRecords == 0:
      raise newException(IOError, "compressDSRCPure: no FASTQ records read from input")

    when compileOption("threads"):
      if workers > 1:
        flushChunkMt()
        while pending.len > 0:
          drainOneEncode()
      else:
        flushChunkSync()
    else:
      flushChunkSync()

    if writerOpen:
      writer.close()
      writerOpen = false
  finally:
    if writerOpen:
      try:
        writer.close()
      except:
        discard

proc writeDSRC*(path: string, records: openArray[FQRecord],
                qualityOffset: uint32 = 33) =
  ## Write a sequence of FQRecord to a DSRC2 compressed file.
  ## qualityOffset: 33 for Phred+33 (Illumina 1.8+), 64 for Phred+64.
  if backendForcesPure() or (PureOnlyBackend and not backendForcesLegacy()):
    writeDSRCPure(path, records, qualityOffset = qualityOffset)
    return

  when defined(dsrclibLegacy):
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
  else:
    ensureLegacyBackend("writeDSRC")

proc compressDSRC*(inputPath, outputPath: string,
                   threads: uint32 = 0, useStdIo: bool = false) =
  ## Compress a .fastq file to a .dsrc2 file.
  ## Uses DsrcModule for maximum performance (multi-threaded).
  ## threads: 0 = use all available cores (default).
  ## useStdIo: if true, read FASTQ from stdin instead of inputPath.
  let debugControlChecks = envEnabled("DSRCLIB_PURE_DEBUG_CONTROL_CHECKS")
  let pureWorkers = resolvedPureWorkers(threads)

  if usePureStOperator(threads):
    let pureInput = if useStdIo: "-" else: inputPath
    compressDSRCPure(
      pureInput,
      outputPath,
      workers = pureWorkers,
      debugControlChecks = debugControlChecks
    )
    return

  when compileOption("threads"):
    if usePureMtOperator(threads):
      let pureInput = if useStdIo: "-" else: inputPath
      compressDSRCPure(
        pureInput,
        outputPath,
        workers = pureWorkers,
        debugControlChecks = debugControlChecks
      )
      return

  if not backendForcesLegacy() and envEnabled("DSRCLIB_FORCE_PURE_ENCODE"):
    let pureInput = if useStdIo: "-" else: inputPath
    compressDSRCPure(
      pureInput,
      outputPath,
      workers = pureWorkers,
      debugControlChecks = debugControlChecks
    )
    return

  when defined(dsrclibLegacy):
    var module = newDsrcModule()
    if threads > 0:
      module.setThreadsNumber(threads)
    if useStdIo:
      module.setStdIoUsing(true)
    module.compress(inputPath.cstring, outputPath.cstring)
  else:
    ensureLegacyBackend("compressDSRC")
