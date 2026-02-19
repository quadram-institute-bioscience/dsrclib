import std/[os, strformat]
import dsrclib
import dsrclib/pure/[container, bitstream, chunk_decoder, tag_decoder, quality_decoder, types]
import support/oracle_harness

type
  EncodeMode = object
    label: string
    records: seq[FQRecord]
    lossy: bool
    dnaOrder: uint32
    qualityOrder: uint32
    expectQualityScheme: int
    expectDnaScheme: int

proc fq(name, seq, qua: string; comment = ""): FQRecord =
  FQRecord(name: name, comment: comment, sequence: seq, quality: qua)

proc writeFastq(path: string; records: openArray[FQRecord]) =
  var f = open(path, fmWrite)
  defer: f.close()
  for r in records:
    f.write("@")
    f.write(r.name)
    if r.comment.len > 0:
      f.write(" ")
      f.write(r.comment)
    f.write("\n")
    f.write(r.sequence)
    f.write("\n+\n")
    f.write(r.quality)
    f.write("\n")

proc readAllDsrc(path: string): seq[FQRecord] =
  for rec in readDSRC(path):
    result.add(rec)

proc readAllDsrcPure(path: string): seq[FQRecord] =
  for rec in readDSRCPure(path):
    result.add(rec)

proc assertSame(a, b: seq[FQRecord]; label: string) =
  if a.len != b.len:
    raise newException(AssertionDefect, fmt"{label}: count mismatch {a.len} vs {b.len}")
  for i in 0 ..< a.len:
    if a[i].name != b[i].name or
       a[i].comment != b[i].comment or
       a[i].sequence != b[i].sequence or
       a[i].quality != b[i].quality:
      raise newException(AssertionDefect, fmt"{label}: record mismatch at index {i}")

proc inspectSchemes(path: string): tuple[tagRaw: bool, qualityScheme: int, dnaScheme: int, chunkCount: int] =
  var c = openDsrcContainerReader(path)
  defer: c.close()

  result.chunkCount = c.footer.blockSizes.len

  var chunk: seq[uint8]
  doAssert c.readChunkAt(0, chunk)
  var r = initBitMemoryReader(chunk)
  let h = parseChunkHeaderMeta(r, c.footer.datasetType, c.footer.compSettings)

  var state = ChunkDecodeState(
    header: h,
    datasetType: c.footer.datasetType,
    compSettings: c.footer.compSettings,
    records: newSeq[PureFastqRecord](int(h.recordsCount))
  )
  decodeTagAndLengthsHook(r, state)
  result.tagRaw = (h.flags and FlagMixedFieldFormatting) != 0'u32

  result.qualityScheme = -1
  if c.footer.compSettings.qualityOrder == 0'u32:
    result.qualityScheme = int(r.data[r.pos])
  decodeQualityHook(r, state)

  result.dnaScheme = int(r.data[r.pos])

proc assertCliParity(path: string) =
  if not hasDsrcCli():
    return

  let cliOut = getTempDir() / (extractFilename(path) & ".cli.fastq")
  defer:
    if fileExists(cliOut):
      removeFile(cliOut)

  let (code, cliLog) = runDsrcCli(["d", "-t1", path, cliOut])
  if code != 0:
    raise newException(AssertionDefect, "dsrc CLI failed:\n" & cliLog)

  let nim = readAllDsrc(path)
  let cli = loadFastqRecords(cliOut)
  let diffs = diffRecordSeqs(nim, cli)
  if diffs.len > 0:
    raise newException(AssertionDefect, "CLI parity mismatch: " & diffs[0])

proc main() =
  let plainRecords = @[
    fq("P1", "ACGTACGTACGT", "ABCDEFGHIJKL", "plain"),
    fq("P2", "TGCATGCATGCA", "LKJIHGFEDCBA"),
    fq("P3", "AACCGGTTAACC", "BCDEFGHIJKLM")
  ]

  let truncRecords = @[
    fq("T1", "ACGTACGTACGT", "ABCDEFGH####", "trunc"),
    fq("T2", "TGCATGCATGCA", "BCDEFGHI####"),
    fq("T3", "AACCGGTTAACC", "CDEFGHIJ####")
  ]

  let rleRecords = @[
    fq("R1", "ACGTACGTACGT", "IIIIIIIIIIII", "rle"),
    fq("R2", "TGCATGCATGCA", "JJJJJJJJJJJJ"),
    fq("R3", "AACCGGTTAACC", "KKKKKKKKKKKK")
  ]

  let mixedDnaRecords = @[
    fq("D1", "ACGTNACGTNAA", "ABCDEFGHIJKL", "dna8"),
    fq("D2", "NNNNACGTNNNN", "LKJIHGFEDCBA"),
    fq("D3", "ACGTNNNNACGT", "BCDEFGHIJKLM")
  ]

  let lossyRecords = @[
    fq("L1", "ACGTACGTACGT", "!!!!!+++++++"),
    fq("L2", "TGCATGCATGCA", "######******"),
    fq("L3", "AACCGGTTAACC", "$$$$$$$$$$$$")
  ]

  let modes = @[
    EncodeMode(label: "lossless_plain", records: plainRecords, lossy: false, dnaOrder: 0'u32, qualityOrder: 0'u32, expectQualityScheme: 0, expectDnaScheme: 0),
    EncodeMode(label: "lossless_truncated", records: truncRecords, lossy: false, dnaOrder: 0'u32, qualityOrder: 0'u32, expectQualityScheme: 1, expectDnaScheme: 0),
    EncodeMode(label: "lossless_rle", records: rleRecords, lossy: false, dnaOrder: 0'u32, qualityOrder: 0'u32, expectQualityScheme: 2, expectDnaScheme: 0),
    EncodeMode(label: "lossless_dna_order4", records: plainRecords, lossy: false, dnaOrder: 2'u32, qualityOrder: 0'u32, expectQualityScheme: 0, expectDnaScheme: 0),
    EncodeMode(label: "lossless_dna8_quality_order", records: mixedDnaRecords, lossy: false, dnaOrder: 2'u32, qualityOrder: 1'u32, expectQualityScheme: -1, expectDnaScheme: 1),
    EncodeMode(label: "lossy_quality_order", records: lossyRecords, lossy: true, dnaOrder: 1'u32, qualityOrder: 1'u32, expectQualityScheme: -1, expectDnaScheme: 0)
  ]

  for mode in modes:
    let outPath = getTempDir() / ("dsrclib_pure_mode_" & mode.label & ".dsrc")
    if fileExists(outPath):
      removeFile(outPath)

    writeDSRCPure(
      outPath,
      mode.records,
      qualityOffset = 33'u32,
      calculateCrc32 = true,
      lossy = mode.lossy,
      dnaOrder = mode.dnaOrder,
      qualityOrder = mode.qualityOrder
    )

    let legacy = readAllDsrc(outPath)
    let pure = readAllDsrcPure(outPath)
    assertSame(legacy, pure, mode.label & ": pure vs legacy decode")

    if not mode.lossy:
      assertSame(mode.records, legacy, mode.label & ": lossless roundtrip")

    let sig = inspectSchemes(outPath)
    doAssert sig.tagRaw == false, mode.label & ": expected tokenizer tag path (non-raw)"
    if mode.expectQualityScheme >= 0:
      doAssert sig.qualityScheme == mode.expectQualityScheme, mode.label & ": unexpected quality scheme"
    doAssert sig.dnaScheme == mode.expectDnaScheme, mode.label & ": unexpected DNA scheme"

    assertCliParity(outPath)
    removeFile(outPath)

  echo "OK: pure encode mode matrix passed (quality schemes + DNA schemes + decode parity)"

  # Streaming compressor should emit multiple chunks with small chunk target.
  let streamInput = getTempDir() / "dsrclib_pure_stream_input.fastq"
  let streamOut = getTempDir() / "dsrclib_pure_stream_out.dsrc"
  if fileExists(streamInput):
    removeFile(streamInput)
  if fileExists(streamOut):
    removeFile(streamOut)

  var expanded: seq[FQRecord] = @[]
  for _ in 0 ..< 80:
    for r in mixedDnaRecords:
      expanded.add(r)
  writeFastq(streamInput, expanded)

  compressDSRCPure(
    streamInput,
    streamOut,
    qualityOffset = 33'u32,
    calculateCrc32 = true,
    lossy = false,
    dnaOrder = 2'u32,
    qualityOrder = 1'u32,
    targetChunkBytes = 512
  )

  var c = openDsrcContainerReader(streamOut)
  defer: c.close()
  doAssert c.footer.blockSizes.len > 1, "expected chunked streaming output to produce >1 chunk"

  let streamLegacy = readAllDsrc(streamOut)
  let streamPure = readAllDsrcPure(streamOut)
  assertSame(streamLegacy, streamPure, "streaming pure vs legacy decode")
  assertSame(expanded, streamLegacy, "streaming lossless roundtrip")

  assertCliParity(streamOut)

  removeFile(streamInput)
  removeFile(streamOut)
  echo "OK: compressDSRCPure chunked streaming path passed"

main()
