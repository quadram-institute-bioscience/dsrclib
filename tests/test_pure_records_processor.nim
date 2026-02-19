import dsrclib/pure

proc toBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  for i, ch in s:
    result[i] = uint8(ord(ch))

proc makeFastq(records: openArray[(string, string, string)]): string =
  ## tuple: (title, sequence, quality)
  var buf = newStringOfCap(records.len * 64)
  for r in records:
    buf.add(r[0]); buf.add('\n')
    buf.add(r[1]); buf.add('\n')
    buf.add('+'); buf.add('\n')
    buf.add(r[2]); buf.add('\n')
  buf

proc assertRecordsEqual(a, b: seq[PureFastqRecord]) =
  assert a.len == b.len
  for i in 0 ..< a.len:
    assert a[i].title == b[i].title
    assert a[i].sequence == b[i].sequence
    assert a[i].quality == b[i].quality

proc main() =
  let fq = makeFastq([
    ("@R1 full", "ACGTN", "IIIII"),
    ("@R2 transfer", "ANNT", "!!!!"),
    ("@R3 iupac", "AGRY", "####")
  ])
  var parsed = parseFastqChunk(toBytes(fq))
  let original = parsed.records

  var p = initLosslessRecordsProcessor(qualityOffset = 33'u32, colorSpace = false)
  p.initializeStats()
  let chkF = p.processForward(parsed.records, ChecksumCalcAll)
  p.finalizeStats()

  assert parsed.records[1].sequence.len < original[1].sequence.len, "ambiguous symbols should be transferred for low-quality bins"
  assert p.dnaStats.symbolCount > 0
  assert p.qualityStats.symbolCount > 0
  assert p.qualityStats.maxLength == 5'u32
  assert p.qualityStats.minLength == 4'u32

  let chkB = p.processBackward(parsed.records, ChecksumCalcAll)
  assert chkF.tag == chkB.tag
  assert chkF.sequence == chkB.sequence
  assert chkF.quality == chkB.quality
  assertRecordsEqual(parsed.records, original)
  echo "OK: lossless processor forward/backward roundtrip + checksum parity"

  var parsed2 = parseFastqChunk(toBytes(fq))
  var p2 = initLosslessRecordsProcessor(qualityOffset = 33'u32, colorSpace = false)
  p2.initializeStats()
  let seqOnlyF = p2.processForward(parsed2.records, ChecksumCalcSequence)
  discard p2.processBackward(parsed2.records, ChecksumCalcSequence)
  assert seqOnlyF.tag == 0'u32 and seqOnlyF.quality == 0'u32
  assert seqOnlyF.sequence != 0'u32
  echo "OK: selective checksum flags are respected"

  let fqLossy = makeFastq([
    ("@L1 qbins", "ACGT", "!#5I"),
    ("@L2 amb", "ANNT", "I!I!")
  ])
  var lossyParsed = parseFastqChunk(toBytes(fqLossy))
  var lp = initLossyRecordsProcessor(qualityOffset = 33'u32, colorSpace = false)
  lp.initializeStats()
  let lossyChkFSeq = lp.processForward(lossyParsed.records, ChecksumCalcTag or ChecksumCalcSequence)
  lp.finalizeStats()

  assert lp.base.dnaStats.symbolCount <= 4'u32
  assert lp.base.qualityStats.symbolCount <= 8'u32

  let lossyChkBSeq = lp.processBackward(lossyParsed.records, ChecksumCalcTag or ChecksumCalcSequence)
  assert lossyChkFSeq.tag == lossyChkBSeq.tag
  assert lossyChkFSeq.sequence == lossyChkBSeq.sequence

  # Quality values are quantized according to Illumina binning in lossy mode.
  assert lossyParsed.records[0].sequence == "ACGT"
  assert lossyParsed.records[0].quality == "''7I"
  assert lossyParsed.records[1].sequence == "ANNT"
  assert lossyParsed.records[1].quality == "I!!'"

  var lossyParsed2 = parseFastqChunk(toBytes(fqLossy))
  var lp2 = initLossyRecordsProcessor(qualityOffset = 33'u32, colorSpace = false)
  let lossyChkFAll = lp2.processForward(lossyParsed2.records, ChecksumCalcAll)
  let lossyChkBAll = lp2.processBackward(lossyParsed2.records, ChecksumCalcAll)
  assert lossyChkFAll.tag == lossyChkBAll.tag
  assert lossyChkFAll.sequence == lossyChkBAll.sequence
  assert lossyChkFAll.quality != lossyChkBAll.quality
  echo "OK: lossy processor quantization + checksum behavior"

main()
