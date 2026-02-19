## DSRC block/chunk metadata decoding and pipeline hook shell (PN-010 bootstrap).
## This mirrors BlockCompressor::ReadMetaData and provides extension points for
## Tag/DNA/Quality decoders.

import types, bitstream

const
  FlagDeltaConstant* = 1'u32 shl 0
  FlagVariableLength* = 1'u32 shl 1
  FlagMixedFieldFormatting* = 1'u32 shl 2

type
  ChunkHeaderMeta* = object
    recordsCount*: uint32
    chunkSize*: uint32
    flags*: uint32
    minQuaLength*: uint32
    maxQuaLength*: uint32
    csConstBeginSym*: bool
    csSeqBegin*: uint8
    csQuaBegin*: uint8
    checksum*: FastqChecksum
    checksumFlags*: uint32
    controlChecks*: bool

  ChunkDecodeState* = object
    header*: ChunkHeaderMeta
    datasetType*: FastqDatasetType
    compSettings*: CompressionSettings
    records*: seq[PureFastqRecord]
    tagDecoded*: bool
    qualityDecoded*: bool
    dnaDecoded*: bool

  TagDecodeHook* = proc(reader: var BitMemoryReader; state: var ChunkDecodeState) {.gcsafe.}
  QualityDecodeHook* = proc(reader: var BitMemoryReader; state: var ChunkDecodeState) {.gcsafe.}
  DnaDecodeHook* = proc(reader: var BitMemoryReader; state: var ChunkDecodeState) {.gcsafe.}

  ChunkDecodeHooks* = object
    tag*: TagDecodeHook
    quality*: QualityDecodeHook
    dna*: DnaDecodeHook

proc bitLength(x: uint32): uint32 =
  if x == 0'u32:
    return 0'u32
  var i = 0'u32
  var tmp = x
  while tmp > 0'u32:
    inc i
    tmp = tmp shr 1
  i

proc qualityLengthBitWidth*(header: ChunkHeaderMeta): uint32 =
  bitLength(header.maxQuaLength - header.minQuaLength)

proc parseChunkHeaderMeta*(
  reader: var BitMemoryReader;
  datasetType: FastqDatasetType;
  compSettings: CompressionSettings
): ChunkHeaderMeta =
  let startPos = reader.pos
  if (reader.data.len - reader.pos) >= 20:
    let marker = reader.getWord()
    if marker == uint32(startPos):
      let probeRecords = reader.getWord()
      discard reader.getWord() # max quality length
      let probeFlags = reader.getWord()
      let probeChunkSize = reader.getWord()
      let validProbe =
        probeRecords > 0'u32 and
        probeFlags < (1'u32 shl 8) and
        probeChunkSize > 0'u32
      if validProbe:
        result.controlChecks = true
        reader.pos = startPos + 4
      else:
        reader.pos = startPos
      reader.flushInputWordBuffer()
    else:
      reader.pos = startPos
      reader.flushInputWordBuffer()

  result.recordsCount = reader.getWord()
  result.maxQuaLength = reader.getWord()
  result.flags = reader.getWord()
  doAssert result.flags < (1'u32 shl 8)
  result.chunkSize = reader.getWord()

  if (result.flags and FlagVariableLength) != 0'u32:
    result.minQuaLength = reader.getWord()
    doAssert result.maxQuaLength >= result.minQuaLength
  else:
    result.minQuaLength = result.maxQuaLength

  if datasetType.colorSpace:
    result.csConstBeginSym = (result.flags and FlagDeltaConstant) != 0'u32
    if result.csConstBeginSym:
      result.csSeqBegin = reader.getByte()
      result.csQuaBegin = reader.getByte()

  if compSettings.calculateCrc32:
    if compSettings.tagPreserveFlags == DefaultTagPreserveFlags:
      result.checksum.tag = reader.getWord()
      doAssert result.checksum.tag != 0'u32
      result.checksumFlags = result.checksumFlags or ChecksumCalcTag

    result.checksum.sequence = reader.getWord()
    doAssert result.checksum.sequence != 0'u32
    result.checksumFlags = result.checksumFlags or ChecksumCalcSequence

    if not compSettings.lossy:
      result.checksum.quality = reader.getWord()
      doAssert result.checksum.quality != 0'u32
      result.checksumFlags = result.checksumFlags or ChecksumCalcQuality

  reader.flushInputWordBuffer()

proc readControlCheck(reader: var BitMemoryReader) =
  let markerPos = reader.pos
  let marker = reader.getWord()
  if marker != uint32(markerPos):
    raise newException(DsrcFormatError, "Invalid debug control-check marker in chunk stream")

proc parseChunkHeaderMeta*(
  chunk: openArray[uint8];
  datasetType: FastqDatasetType;
  compSettings: CompressionSettings
): ChunkHeaderMeta =
  var reader = initBitMemoryReader(chunk)
  parseChunkHeaderMeta(reader, datasetType, compSettings)

proc decodeChunkWithHooks*(
  chunk: openArray[uint8];
  datasetType: FastqDatasetType;
  compSettings: CompressionSettings;
  hooks: ChunkDecodeHooks
): ChunkDecodeState {.gcsafe.} =
  var reader = initBitMemoryReader(chunk)
  result.header = parseChunkHeaderMeta(reader, datasetType, compSettings)
  result.datasetType = datasetType
  result.compSettings = compSettings
  result.records = newSeq[PureFastqRecord](int(result.header.recordsCount))

  if result.header.controlChecks:
    readControlCheck(reader)
  if hooks.tag != nil:
    hooks.tag(reader, result)
    result.tagDecoded = true

  if result.header.controlChecks:
    readControlCheck(reader)
  if hooks.quality != nil:
    hooks.quality(reader, result)
    result.qualityDecoded = true

  if result.header.controlChecks:
    readControlCheck(reader)
  if hooks.dna != nil:
    hooks.dna(reader, result)
    result.dnaDecoded = true

  if result.header.controlChecks:
    readControlCheck(reader)
