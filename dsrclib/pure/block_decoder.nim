## End-to-end block decode pipeline for pure-Nim DSRC decompression (PN-010 decode path).

import types, container, chunk_decoder, tag_decoder, quality_decoder, dna_decoder, records_processor

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

proc applyPlusLine(rec: var PureFastqRecord; plusRepetition: bool) =
  if plusRepetition:
    if rec.title.len > 0 and rec.title[0] == '@':
      if rec.title.len > 1:
        rec.plus = "+" & rec.title[1 .. ^1]
      else:
        rec.plus = "+"
    else:
      rec.plus = "+" & rec.title
  else:
    rec.plus = "+"

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

  for i in 0 ..< state.records.len:
    state.records[i].applyPlusLine(state.datasetType.plusRepetition)

proc decodeChunkRecords*(
  chunk: openArray[uint8];
  datasetType: FastqDatasetType;
  compSettings: CompressionSettings;
  verifyChecksums = true
): seq[PureFastqRecord] {.gcsafe.} =
  var hooks: ChunkDecodeHooks
  hooks.tag = decodeTagAndLengthsHook
  hooks.quality = decodeQualityHook
  hooks.dna = decodeDnaHook

  var state = decodeChunkWithHooks(chunk, datasetType, compSettings, hooks)
  state.postprocessRecords(verifyChecksums = verifyChecksums)
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
