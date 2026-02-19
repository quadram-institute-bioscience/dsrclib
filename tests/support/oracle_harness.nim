import std/[json, os, osproc, strformat, strutils]
import dsrclib
import dsrclib/pure/[container, bitstream]

type
  OracleFixture* = object
    id*: string
    description*: string
    fastqPath*: string
    dsrcPath*: string
    expectedRecords*: int
    expectedFingerprint*: string
    crossCompat*: bool

  FingerprintResult* = object
    records*: int
    fingerprint*: string

const
  FnvOffset = 1469598103934665603'u64
  FnvPrime = 1099511628211'u64

proc fnvMix(h: var uint64; b: uint8) =
  h = (h xor uint64(b)) * FnvPrime

proc fnvMixStr(h: var uint64; s: string) =
  for ch in s:
    h.fnvMix(uint8(ord(ch)))

proc fnvMixU32(h: var uint64; x: uint32) =
  h.fnvMix(uint8(x and 0xFF'u32))
  h.fnvMix(uint8((x shr 8) and 0xFF'u32))
  h.fnvMix(uint8((x shr 16) and 0xFF'u32))
  h.fnvMix(uint8((x shr 24) and 0xFF'u32))

proc fingerprintHex(h: uint64): string =
  result = toHex(h, 16).toLowerAscii()

proc updateRecord(h: var uint64; rec: FQRecord) =
  h.fnvMixU32(uint32(rec.name.len))
  h.fnvMixStr(rec.name)
  h.fnvMixU32(uint32(rec.comment.len))
  h.fnvMixStr(rec.comment)
  h.fnvMixU32(uint32(rec.sequence.len))
  h.fnvMixStr(rec.sequence)
  h.fnvMixU32(uint32(rec.quality.len))
  h.fnvMixStr(rec.quality)

proc loadFastqRecords*(path: string): seq[FQRecord] =
  result = @[]
  for rec in readFastq(path):
    result.add(rec)

proc loadDsrcRecords*(path: string): seq[FQRecord] =
  result = @[]
  for rec in readDSRC(path):
    result.add(rec)

proc fingerprintFastqPath*(path: string): FingerprintResult =
  var h = FnvOffset
  var n = 0
  for rec in readFastq(path):
    h.updateRecord(rec)
    inc n
  result.records = n
  result.fingerprint = fingerprintHex(h)

proc fingerprintDsrcPath*(path: string): FingerprintResult =
  var h = FnvOffset
  var n = 0
  for rec in readDSRC(path):
    h.updateRecord(rec)
    inc n
  result.records = n
  result.fingerprint = fingerprintHex(h)

proc diffRecordSeqs*(
  expected, actual: seq[FQRecord];
  maxDiffs = 8
): seq[string] =
  result = @[]
  let minLen = min(expected.len, actual.len)

  for i in 0 ..< minLen:
    if expected[i].name != actual[i].name:
      result.add(fmt"record {i}: name differs: '{expected[i].name}' vs '{actual[i].name}'")
      if result.len >= maxDiffs: return
    if expected[i].comment != actual[i].comment:
      result.add(fmt"record {i}: comment differs: '{expected[i].comment}' vs '{actual[i].comment}'")
      if result.len >= maxDiffs: return
    if expected[i].sequence != actual[i].sequence:
      result.add(fmt"record {i}: sequence differs (len {expected[i].sequence.len} vs {actual[i].sequence.len})")
      if result.len >= maxDiffs: return
    if expected[i].quality != actual[i].quality:
      result.add(fmt"record {i}: quality differs (len {expected[i].quality.len} vs {actual[i].quality.len})")
      if result.len >= maxDiffs: return

  if expected.len != actual.len and result.len < maxDiffs:
    result.add(fmt"record count differs: expected {expected.len}, actual {actual.len}")

proc diffFastqLogical*(
  expectedPath, actualPath: string;
  maxDiffs = 8
): seq[string] =
  let a = loadFastqRecords(expectedPath)
  let b = loadFastqRecords(actualPath)
  result = diffRecordSeqs(a, b, maxDiffs)

proc loadOracleFixtures*(manifestPath: string): seq[OracleFixture] =
  let node = parseFile(manifestPath)
  let items = node["fixtures"]
  for it in items:
    var fx: OracleFixture
    fx.id = it["id"].getStr()
    fx.description = it["description"].getStr()
    fx.fastqPath = it["fastqPath"].getStr()
    fx.dsrcPath = it["dsrcPath"].getStr()
    fx.expectedRecords = it["expectedRecords"].getInt()
    fx.expectedFingerprint = it["expectedFingerprint"].getStr()
    fx.crossCompat = it["crossCompat"].getBool()
    result.add(fx)

proc runDsrcCli*(
  args: openArray[string];
  cwd: string = ""
): tuple[code: int, output: string]

proc hasDsrcCli*(): bool =
  let (code, output) = runDsrcCli(["--help"])
  code == 0 or output.contains("DSRC - DNA Sequence Reads Compressor")

proc runDsrcCli*(
  args: openArray[string];
  cwd: string = ""
): tuple[code: int, output: string] =
  var cmd = getEnv("DSRCLIB_DSRC_CMD", "dsrc").strip()
  if cmd.len == 0:
    cmd = "dsrc"
  for a in args:
    cmd.add(" ")
    cmd.add(quoteShell(a))
  let res = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut}, workingDir = cwd)
  (res.exitCode, res.output)

proc dsrcCliUsesDebugControlChecks*(
  tmpDir: string
): bool =
  ## Detect whether the DSRC CLI emits debug control-check markers.
  ## This probes a tiny archive and inspects chunk-leading words.
  createDir(tmpDir)
  let probeFastq = tmpDir / "cli_control_probe.fastq"
  let probeDsrc = tmpDir / "cli_control_probe.dsrc"
  if fileExists(probeFastq):
    removeFile(probeFastq)
  if fileExists(probeDsrc):
    removeFile(probeDsrc)
  defer:
    if fileExists(probeFastq):
      removeFile(probeFastq)
    if fileExists(probeDsrc):
      removeFile(probeDsrc)

  var f = open(probeFastq, fmWrite)
  f.write("@probe1\nACGTACGT\n+\nIIIIIIII\n")
  f.write("@probe2\nTGCATGCA\n+\nJJJJJJJJ\n")
  f.write("@probe3\nAACCGGTT\n+\nHHHHHHHH\n")
  f.close()

  let (cCode, cOut) = runDsrcCli(["c", "-t1", probeFastq, probeDsrc])
  if cCode != 0:
    raise newException(
      IOError,
      "dsrc debug-control-check probe: CLI encode failed\n" & cOut
    )

  var c = openDsrcContainerReader(probeDsrc)
  defer: c.close()

  var chunk: seq[uint8]
  if not c.readChunkAt(0, chunk):
    raise newException(IOError, "dsrc debug-control-check probe: missing chunk 0")
  if chunk.len < 8:
    return false

  var r = initBitMemoryReader(chunk)
  let marker = r.getWord()
  let nextWord = r.getWord()
  marker == 0'u32 and nextWord > 0'u32
