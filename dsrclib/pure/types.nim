## Shared structures/constants for the pure-Nim DSRC backend.

type
  DsrcFormatError* = object of IOError
    ## Raised when DSRC archive structure is invalid.

  FastqDatasetType* = object
    qualityOffset*: uint32
    plusRepetition*: bool
    colorSpace*: bool

  CompressionSettings* = object
    dnaOrder*: uint32
    qualityOrder*: uint32
    tagPreserveFlags*: uint64
    lossy*: bool
    calculateCrc32*: bool
    debugControlChecks*: bool

  DsrcFileHeader* = object
    dummyByte*: uint8
    versionMajor*: uint8
    versionMinor*: uint8
    versionRev*: uint8
    footerSize*: uint32
    footerOffset*: uint64
    recordsCount*: uint64
    blockCount*: uint64
    reserved*: array[8, uint8]

  DsrcFileFooter* = object
    dummyByte*: uint8
    datasetType*: FastqDatasetType
    compSettings*: CompressionSettings
    blockSizes*: seq[uint32]

  StreamName* = enum
    MetaStream = 0
    TagStream = 1
    DnaStream = 2
    QualityStream = 3

  StreamsInfo* = object
    sizes*: array[4, uint64]

  PureFastqRecord* = object
    title*: string
    sequence*: string
    plus*: string
    quality*: string
    truncatedLen*: uint16

  FastqChecksum* = object
    tag*: uint32
    sequence*: uint32
    quality*: uint32

  ColorSpaceStats* = object
    constBeginSym*: bool
    seqBegin*: uint8
    quaBegin*: uint8

  DnaStats* = object
    symbolCount*: uint32
    symbolFreqs*: array[20, uint32]
    symbols*: array[20, uint8]

  QualityStats* = object
    symbolCount*: uint32
    symbolFreqs*: array[256, uint32]
    symbols*: array[256, uint8]
    minLength*: uint32
    maxLength*: uint32
    rawLength*: uint32
    thLength*: uint32
    rleLength*: uint32
    symbolThreshold*: uint32

const
  DsrcHeaderDummyByte* = 0xAA'u8
  DsrcFooterDummyByte* = 0xCC'u8
  DsrcReservedBytes* = 8'u32
  DsrcHeaderSize* = 40'u64

  DsrcVersionMajor* = 2'u8
  DsrcVersionMinor* = 0'u8
  DsrcVersionRev* = 2'u8

  FlagPlusRepetition* = 1'u8 shl 0
  FlagColorSpace* = 1'u8 shl 1

  FlagLossyQuality* = 1'u8 shl 0
  FlagCalculateCrc32* = 1'u8 shl 1

  DefaultTagPreserveFlags* = 0'u64
  DefaultQualityOffset* = 0'u32

  ChecksumCalcTag* = 1'u32 shl 0
  ChecksumCalcSequence* = 1'u32 shl 1
  ChecksumCalcQuality* = 1'u32 shl 2
  ChecksumCalcNone* = 0'u32
  ChecksumCalcAll* = ChecksumCalcTag or ChecksumCalcSequence or ChecksumCalcQuality

  HashSymbolNormal* = 2'u8
  HashSymbolQuantized* = 1'u8

  EmptyStatSymbol* = 255'u8

proc defaultFastqDatasetType*(): FastqDatasetType =
  FastqDatasetType(
    qualityOffset: DefaultQualityOffset,
    plusRepetition: false,
    colorSpace: false
  )

proc defaultCompressionSettings*(): CompressionSettings =
  CompressionSettings(
    dnaOrder: 0'u32,
    qualityOrder: 0'u32,
    tagPreserveFlags: DefaultTagPreserveFlags,
    lossy: false,
    calculateCrc32: false,
    debugControlChecks: false
  )

proc clear*(s: var StreamsInfo) =
  for i in 0 ..< 4:
    s.sizes[i] = 0'u64

proc clear*(s: var FastqChecksum) =
  s.tag = 0'u32
  s.sequence = 0'u32
  s.quality = 0'u32

proc clear*(s: var ColorSpaceStats) =
  s.constBeginSym = true
  s.seqBegin = EmptyStatSymbol
  s.quaBegin = EmptyStatSymbol

proc clear*(s: var DnaStats) =
  s.symbolCount = 0'u32
  for i in 0 ..< s.symbols.len:
    s.symbols[i] = EmptyStatSymbol
    s.symbolFreqs[i] = 0'u32

proc clear*(s: var QualityStats) =
  s.symbolCount = 0'u32
  for i in 0 ..< s.symbols.len:
    s.symbols[i] = EmptyStatSymbol
    s.symbolFreqs[i] = 0'u32
  s.minLength = uint32.high
  s.maxLength = 0'u32
  s.rawLength = 0'u32
  s.thLength = 0'u32
  s.rleLength = 0'u32
  s.symbolThreshold = 0'u32
