## End-to-end block decode pipeline for pure-Nim DSRC decompression (PN-010 decode path).

import types, container, chunk_decoder, tag_decoder, quality_decoder, dna_decoder, records_processor, phase_profile

proc verifyChecksum(
  expected, actual: FastqChecksum;
  flags: uint32
) =
  if (flags and ChecksumCalcTag) != 0'u32 and expected.tag != actual.tag:
    raise newException(DsrcFormatError, "Tag checksum mismatch")
  if (flags and ChecksumCalcSequence) != 0'u32 and expected.sequence != actual.sequence:
    raise newException(DsrcFormatError, "Sequence checksum mismatch")
  if (flags and ChecksumCalcQuality) != 0'u32 and expected.quality != actual.quality:
    raise newException(DsrcFormatError, "Quality checksum mismatch")

proc postprocessRecords(state: var ChunkDecodeState; verifyChecksums: bool) =
  if state.compSettings.lossy:
    var p = initLossyRecordsProcessor(
      qualityOffset = state.datasetType.qualityOffset,
      colorSpace = state.datasetType.colorSpace
    )
    if state.datasetType.colorSpace:
      var cs = ColorSpaceStats()
      cs.constBeginSym = state.header.csConstBeginSym
      cs.seqBegin = state.header.csSeqBegin
      cs.quaBegin = state.header.csQuaBegin
      p.setColorSpaceStats(cs)

    let checksum = p.processBackward(state.records, state.header.checksumFlags)
    if verifyChecksums and state.compSettings.calculateCrc32:
      verifyChecksum(state.header.checksum, checksum, state.header.checksumFlags)
  else:
    var p = initLosslessRecordsProcessor(
      qualityOffset = state.datasetType.qualityOffset,
      colorSpace = state.datasetType.colorSpace
    )
    if state.datasetType.colorSpace:
      var cs = ColorSpaceStats()
      cs.constBeginSym = state.header.csConstBeginSym
      cs.seqBegin = state.header.csSeqBegin
      cs.quaBegin = state.header.csQuaBegin
      p.setColorSpaceStats(cs)

    let checksum = p.processBackward(state.records, state.header.checksumFlags)
    if verifyChecksums and state.compSettings.calculateCrc32:
      verifyChecksum(state.header.checksum, checksum, state.header.checksumFlags)

  if state.datasetType.plusRepetition:
    for rec in mitems(state.records):
      if rec.title.len == 0:
        rec.plus = "+"
        continue

      let hasAt = rec.title[0] == '@'
      let srcStart = if hasAt: 1 else: 0
      let payloadLen = rec.title.len - srcStart
      rec.plus = newString(payloadLen + 1)
      rec.plus[0] = '+'
      if payloadLen > 0:
        copyMem(addr rec.plus[1], unsafeAddr rec.title[srcStart], payloadLen)
  else:
    for rec in mitems(state.records):
      rec.plus = "+"

proc decodeChunkRecords*(
  chunk: openArray[uint8];
  datasetType: FastqDatasetType;
  compSettings: CompressionSettings;
  verifyChecksums = true
): seq[PureFastqRecord] {.gcsafe.} =
  let profile = phaseProfileEnabled()
  var tAll: PhaseStamp
  var tPost: PhaseStamp
  if profile:
    tAll = phaseNow()

  var hooks: ChunkDecodeHooks
  hooks.tag = decodeTagAndLengthsHook
  hooks.quality = decodeQualityHook
  hooks.dna = decodeDnaHook

  var state = decodeChunkWithHooks(chunk, datasetType, compSettings, hooks)
  if profile:
    tPost = phaseNow()
  state.postprocessRecords(verifyChecksums = verifyChecksums)
  if profile:
    let postMs = phaseElapsedMs(tPost)
    let totalMs = phaseElapsedMs(tAll)
    stderr.writeLine(
      "[phase][decode] rec=" & $state.records.len &
      " raw=" & $state.header.chunkSize &
      " meta_ms=" & fmtMs(state.phaseTimings.metaMs) &
      " tag_ms=" & fmtMs(state.phaseTimings.tagMs) &
      " qual_ms=" & fmtMs(state.phaseTimings.qualityMs) &
      " dna_ms=" & fmtMs(state.phaseTimings.dnaMs) &
      " post_ms=" & fmtMs(postMs) &
      " total_ms=" & fmtMs(totalMs)
    )
  state.records

iterator readDsrcPure*(
  path: string;
  verifyChecksums = true
): PureFastqRecord =
  var reader = openDsrcContainerReader(path)
  defer: reader.close()

  var chunk: seq[uint8]
  while reader.readNextChunk(chunk):
    let decoded = decodeChunkRecords(
      chunk,
      reader.footer.datasetType,
      reader.footer.compSettings,
      verifyChecksums = verifyChecksums
    )
    for rec in decoded:
      yield rec

proc decodeDsrcFile*(
  path: string;
  verifyChecksums = true
): seq[PureFastqRecord] =
  for rec in readDsrcPure(path, verifyChecksums = verifyChecksums):
    result.add(rec)
