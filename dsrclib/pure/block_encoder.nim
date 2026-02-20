## End-to-end block encode pipeline for pure-Nim DSRC compression (PN-011).
## Scope:
## - color-space is intentionally unsupported
## - non-default tag preserve flags are intentionally unsupported
## - supports lossless/lossy, order-0/order-N DNA, quality normal/order modelers

import types, bitstream, chunk_decoder, records_processor, huffman_encoder, range_decoder, adaptive_model_map

const
  TagRawMaxSymbolCount = 128
  TagTokenizerMaxSymbolCount = 256
  TagTokenizerMaxFieldStatLen = 128

  QualitySchemeNone = 255'u8
  QualityPlain = 0'u8
  QualityTruncated = 1'u8
  QualityRle = 2'u8

  DnaSchemeNone = 255'u8
  DnaOrder0SchemeB2 = 0'u8
  DnaOrder0SchemeHuffman = 1'u8
  DnaOrderNScheme4Sym = 0'u8
  DnaOrderNScheme8Sym = 1'u8
  DnaMaxSymbolCount = 20

type
  TagRawStats = object
    minTitleLen: uint32
    maxTitleLen: uint32
    symbolFreqs: array[TagRawMaxSymbolCount, uint32]

  QualityHashState = object
    hash: uint64
    symBuffer: uint64
    alphabetBits: int
    bitsLo: int
    bitsHi: int
    symbolMask: uint64
    symbolSwapMask: uint64
    symbolHashMask: uint64

  OrderLosslessCfg = object
    symbolCount: int
    symbolOrder: int
    symbolRescale: int

proc bitLength(x: uint32): uint32 =
  if x == 0'u32:
    return 0'u32
  var t = x
  while t > 0'u32:
    inc result
    t = t shr 1

proc bitMask64(bits: int): uint64 =
  if bits <= 0:
    return 0'u64
  if bits >= 64:
    return uint64.high
  (1'u64 shl bits) - 1'u64

proc intLog2Pow2(x: int): int =
  doAssert x > 0
  var v = x
  while (v and 1) == 0:
    inc result
    v = v shr 1
  doAssert v == 1

proc initQualityHashState(symbolOrder: int; symbolCount: int): QualityHashState =
  doAssert symbolOrder > 0
  doAssert symbolCount > 0

  result.hash = 0'u64
  result.symBuffer = 0'u64
  result.alphabetBits = intLog2Pow2(symbolCount)
  result.bitsLo = (symbolOrder div 2) * result.alphabetBits
  result.bitsHi = (symbolOrder div 2 + 1) * result.alphabetBits
  result.symbolMask = bitMask64(result.alphabetBits)
  result.symbolSwapMask = bitMask64(result.bitsLo) or (not bitMask64(result.bitsHi))
  result.symbolHashMask = bitMask64(symbolOrder * result.alphabetBits)

proc getHash(state: QualityHashState): uint64 =
  state.hash and state.symbolHashMask

proc updateHash(state: var QualityHashState; sym: uint32) =
  state.hash = state.hash shl state.alphabetBits

  let nextBuf = (state.hash shr state.bitsLo) and state.symbolMask
  let swp = (nextBuf + state.symBuffer) div 2'u64

  state.hash = state.hash and state.symbolSwapMask
  state.hash = state.hash or (swp shl state.bitsLo)
  state.hash = state.hash or uint64(sym)

  state.symBuffer = nextBuf

proc checksumFlags(settings: CompressionSettings): uint32 =
  if not settings.calculateCrc32:
    return ChecksumCalcNone

  result = result or ChecksumCalcSequence
  if settings.tagPreserveFlags == DefaultTagPreserveFlags:
    result = result or ChecksumCalcTag
  if not settings.lossy:
    result = result or ChecksumCalcQuality

proc computeChunkSize(records: openArray[PureFastqRecord]; plusRepetition: bool): uint32 =
  var total = 0'u64
  for rec in records:
    let plusLen = if plusRepetition: rec.title.len else: 1
    total += uint64(rec.title.len + rec.sequence.len + rec.quality.len + plusLen + 4)

  if total > 0'u64:
    dec total
  doAssert total <= uint64(uint32.high)
  uint32(total)

proc writeMetaData(
  writer: var BitMemoryWriter;
  header: ChunkHeaderMeta;
  datasetType: FastqDatasetType;
  compSettings: CompressionSettings
) =
  writer.putWord(header.recordsCount)
  writer.putWord(header.maxQuaLength)
  writer.putWord(header.flags)
  writer.putWord(header.chunkSize)

  if (header.flags and FlagVariableLength) != 0'u32:
    writer.putWord(header.minQuaLength)

  if datasetType.colorSpace and (header.flags and FlagDeltaConstant) != 0'u32:
    writer.putByte(header.csSeqBegin)
    writer.putByte(header.csQuaBegin)

  if compSettings.calculateCrc32:
    if compSettings.tagPreserveFlags == DefaultTagPreserveFlags:
      writer.putWord(header.checksum.tag)
    writer.putWord(header.checksum.sequence)
    if not compSettings.lossy:
      writer.putWord(header.checksum.quality)

  writer.flushPartialWordBuffer()

proc writeControlCheck(writer: var BitMemoryWriter; enabled: bool) =
  if not enabled:
    return
  if writer.wordBufferPos != 0'u32:
    writer.flushPartialWordBuffer()
  writer.putWord(uint32(writer.data.len))

proc analyzeTagRaw(records: openArray[PureFastqRecord]): TagRawStats =
  result.minTitleLen = uint32.high
  result.maxTitleLen = 0'u32
  for rec in records:
    let tlen = uint32(rec.title.len)
    if tlen < result.minTitleLen:
      result.minTitleLen = tlen
    if tlen > result.maxTitleLen:
      result.maxTitleLen = tlen

    for ch in rec.title:
      let c = ord(ch)
      if c < 0 or c >= TagRawMaxSymbolCount:
        raise newException(DsrcFormatError, "Tag contains non-ASCII symbol not supported by TagRaw encoder")
      result.symbolFreqs[c] += 1'u32

  if records.len == 0:
    result.minTitleLen = 0'u32

proc encodeTagRawAndLengths(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  minQuaLen, maxQuaLen: uint32
) =
  let stats = analyzeTagRaw(records)
  writer.putWord(stats.minTitleLen)
  writer.putWord(stats.maxTitleLen)

  var symToIdx: array[TagRawMaxSymbolCount, int32]
  for i in 0 ..< symToIdx.len:
    symToIdx[i] = -1

  var freqs: seq[uint32] = @[]
  for i in 0 ..< TagRawMaxSymbolCount:
    if stats.symbolFreqs[i] > 0'u32:
      symToIdx[i] = int32(freqs.len)
      freqs.add(stats.symbolFreqs[i])
    writer.putBit(if stats.symbolFreqs[i] > 0'u32: 1'u32 else: 0'u32)

  if freqs.len == 0:
    raise newException(DsrcFormatError, "No tag symbols available for raw tag encoding")

  writer.flushPartialWordBuffer()
  let build = buildHuffman(freqs)
  storeTree(writer, build)

  let titleLenBits = bitLength(stats.maxTitleLen - stats.minTitleLen)
  let quaLenBits = bitLength(maxQuaLen - minQuaLen)

  for rec in records:
    if titleLenBits > 0'u32:
      writer.putBits(uint32(rec.title.len) - stats.minTitleLen, titleLenBits)

    for ch in rec.title:
      let idx = symToIdx[ord(ch)].int
      doAssert idx >= 0 and idx < build.codes.len
      let c = build.codes[idx]
      writer.putBits(c.code, c.len)

    if quaLenBits > 0'u32:
      writer.putBits(uint32(rec.quality.len) - minQuaLen, quaLenBits)

  writer.flushPartialWordBuffer()

proc encodeTagTokenizerAndLengths(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  minQuaLen, maxQuaLen: uint32
) =
  var minTitleLen = uint32.high
  var maxTitleLen = 0'u32
  for rec in records:
    let tlen = uint32(rec.title.len)
    if tlen < minTitleLen:
      minTitleLen = tlen
    if tlen > maxTitleLen:
      maxTitleLen = tlen
  if records.len == 0:
    minTitleLen = 0'u32

  # 1-field tokenizer form: full title as variable-length non-numeric field.
  writer.putByte(1'u8)       # nField
  writer.putByte(uint8(ord(' ')))
  writer.putByte(0'u8)       # isConstant
  writer.putByte(0'u8)       # isNumeric
  writer.putByte(0'u8)       # isLenConstant
  writer.putWord(0'u32)      # len
  writer.putWord(maxTitleLen)
  writer.putWord(minTitleLen)

  let maxJ = int(min(maxTitleLen, uint32(TagTokenizerMaxFieldStatLen)))
  for _ in 0 ..< 0:
    discard

  var localTrees: seq[HuffBuild] = @[]
  for j in 0 ..< maxJ:
    var freqs = newSeq[uint32](TagTokenizerMaxSymbolCount)
    for rec in records:
      if j < rec.title.len:
        freqs[ord(rec.title[j])] += 1'u32
    let tree = buildHuffman(freqs)
    localTrees.add(tree)
    storeTree(writer, tree)

  if maxTitleLen >= uint32(TagTokenizerMaxFieldStatLen):
    var freqs = newSeq[uint32](TagTokenizerMaxSymbolCount)
    for rec in records:
      for k in TagTokenizerMaxFieldStatLen ..< rec.title.len:
        freqs[ord(rec.title[k])] += 1'u32
    let tree = buildHuffman(freqs)
    localTrees.add(tree)
    storeTree(writer, tree)

  let titleLenBits = bitLength(maxTitleLen - minTitleLen)
  let quaLenBits = bitLength(maxQuaLen - minQuaLen)

  for rec in records:
    if titleLenBits > 0'u32:
      writer.putBits(uint32(rec.title.len) - minTitleLen, titleLenBits)

    for k in 0 ..< rec.title.len:
      let idx = min(k, TagTokenizerMaxFieldStatLen)
      let treeIdx = if idx < maxJ: idx else: localTrees.len - 1
      doAssert treeIdx >= 0 and treeIdx < localTrees.len
      let c = localTrees[treeIdx].codes[ord(rec.title[k])]
      writer.putBits(c.code, c.len)

    if quaLenBits > 0'u32:
      writer.putBits(uint32(rec.quality.len) - minQuaLen, quaLenBits)

  writer.flushPartialWordBuffer()

proc chooseRawTagCoding(records: openArray[PureFastqRecord]): bool =
  for rec in records:
    for ch in rec.title:
      if ord(ch) < 32:
        return true
      if ord(ch) >= TagRawMaxSymbolCount:
        return false
  false

proc encodeQualityContexts(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  maxQuaLen: uint32;
  symToIdx: array[256, int32];
  symbolCount: int;
  truncatedMode: bool
): seq[HuffBuild] =
  result = newSeq[HuffBuild](int(maxQuaLen))
  var positionFreqs = newSeq[seq[uint32]](int(maxQuaLen))
  for j in 0 ..< int(maxQuaLen):
    positionFreqs[j] = newSeq[uint32](symbolCount)

  for rec in records:
    let limit = if truncatedMode: int(rec.truncatedLen) else: rec.quality.len
    for j in 0 ..< limit:
      let idx = symToIdx[ord(rec.quality[j])].int
      doAssert idx >= 0 and idx < symbolCount
      positionFreqs[j][idx] += 1'u32

  for j in 0 ..< int(maxQuaLen):
    result[j] = buildHuffman(positionFreqs[j])
    storeTree(writer, result[j])

proc selectQualityNormalScheme(stats: QualityStats): uint8 =
  let useRle = stats.rleLength > 0'u32 and
               stats.thLength > 0'u32 and
               (float(stats.thLength) / float(stats.rleLength)) > 1.25
  if useRle:
    return QualityRle

  let useTrunc = stats.thLength > 0'u32 and
                 (float(stats.rawLength) / float(stats.thLength)) > 1.10
  if useTrunc:
    return QualityTruncated

  QualityPlain

proc encodeQualityPlain(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  maxQuaLen: uint32
) =
  writer.putByte(QualityPlain)
  writer.flushPartialWordBuffer()
  writer.putWord(maxQuaLen)

  var present: array[256, bool]
  var symToIdx: array[256, int32]
  for i in 0 ..< symToIdx.len:
    symToIdx[i] = -1

  for rec in records:
    for ch in rec.quality:
      present[ord(ch)] = true

  var symbolCount = 0
  for i in 0 ..< 256:
    if present[i]:
      symToIdx[i] = int32(symbolCount)
      inc symbolCount
      writer.putBit(1'u32)
    else:
      writer.putBit(0'u32)

  doAssert symbolCount > 0
  let contexts = encodeQualityContexts(writer, records, maxQuaLen, symToIdx, symbolCount, truncatedMode = false)

  for rec in records:
    for j in 0 ..< rec.quality.len:
      let idx = symToIdx[ord(rec.quality[j])].int
      let c = contexts[j].codes[idx]
      writer.putBits(c.code, c.len)

  writer.flushPartialWordBuffer()

proc encodeQualityTruncated(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  minQuaLen, maxQuaLen: uint32
) =
  writer.putByte(QualityTruncated)
  writer.flushPartialWordBuffer()
  writer.putWord(maxQuaLen)

  var present: array[256, bool]
  var symToIdx: array[256, int32]
  for i in 0 ..< symToIdx.len:
    symToIdx[i] = -1

  for rec in records:
    for ch in rec.quality:
      present[ord(ch)] = true

  var symbolCount = 0
  for i in 0 ..< 256:
    if present[i]:
      symToIdx[i] = int32(symbolCount)
      inc symbolCount
      writer.putBit(1'u32)
    else:
      writer.putBit(0'u32)

  doAssert symbolCount > 0
  let contexts = encodeQualityContexts(writer, records, maxQuaLen, symToIdx, symbolCount, truncatedMode = true)

  let variableLength = minQuaLen != maxQuaLen
  let maxBitLength = bitLength(maxQuaLen)
  writer.putBit(if variableLength: 1'u32 else: 0'u32)

  for rec in records:
    let qLen = uint32(rec.quality.len)
    let thLen = uint32(rec.truncatedLen)
    doAssert thLen <= qLen

    writer.putBit(if qLen != thLen: 1'u32 else: 0'u32)
    if qLen != thLen:
      let bitLen = if variableLength: bitLength(qLen) else: maxBitLength
      if bitLen > 0'u32:
        writer.putBits(thLen, bitLen)

    for j in 0 ..< int(thLen):
      let idx = symToIdx[ord(rec.quality[j])].int
      let c = contexts[j].codes[idx]
      writer.putBits(c.code, c.len)

  writer.flushPartialWordBuffer()

proc encodeQualityRle(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord]
) =
  writer.putByte(QualityRle)
  writer.flushPartialWordBuffer()

  type Run = tuple[q: uint8, l: uint8]
  var runs: seq[Run] = @[]

  var prevSym = -1
  var curLen = 0'u32
  for rec in records:
    for ch in rec.quality:
      let q = uint8(ord(ch))
      if prevSym >= 0 and q == uint8(prevSym) and curLen < 255'u32:
        inc curLen
      else:
        if prevSym >= 0:
          runs.add((uint8(prevSym), uint8(curLen)))
        prevSym = int(q)
        curLen = 0'u32

  doAssert prevSym >= 0
  runs.add((uint8(prevSym), uint8(curLen)))

  writer.putWord(uint32(runs.len))

  var qFreqs: array[256, uint32]
  var lFreqs: array[256, uint32]
  for r in runs:
    qFreqs[r.q.int] += 1'u32
    lFreqs[r.l.int] += 1'u32

  var qValToIdx: array[256, int32]
  var lValToIdx: array[256, int32]
  for i in 0 ..< 256:
    qValToIdx[i] = -1
    lValToIdx[i] = -1

  var qCount = 0
  var lCount = 0
  for i in 0 ..< 256:
    if qFreqs[i] > 0'u32:
      qValToIdx[i] = int32(qCount)
      inc qCount
      writer.putBit(1'u32)
    else:
      writer.putBit(0'u32)

  for i in 0 ..< 256:
    if lFreqs[i] > 0'u32:
      lValToIdx[i] = int32(lCount)
      inc lCount
      writer.putBit(1'u32)
    else:
      writer.putBit(0'u32)

  doAssert qCount > 0
  doAssert lCount > 0

  if qCount > 1:
    var qCtxFreqs = newSeq[seq[uint32]](qCount)
    var lCtxFreqs = newSeq[seq[uint32]](qCount)
    for i in 0 ..< qCount:
      qCtxFreqs[i] = newSeq[uint32](qCount)
      lCtxFreqs[i] = newSeq[uint32](lCount)

    var prev = 0
    for r in runs:
      let q = qValToIdx[r.q.int].int
      let l = lValToIdx[r.l.int].int
      qCtxFreqs[prev][q] += 1'u32
      lCtxFreqs[q][l] += 1'u32
      prev = q

    var qTrees = newSeq[HuffBuild](qCount)
    var lTrees = newSeq[HuffBuild](qCount)
    for i in 0 ..< qCount:
      qTrees[i] = buildHuffman(qCtxFreqs[i])
      lTrees[i] = buildHuffman(lCtxFreqs[i])
      storeTree(writer, qTrees[i])
      storeTree(writer, lTrees[i])

    prev = 0
    for r in runs:
      let q = qValToIdx[r.q.int].int
      let l = lValToIdx[r.l.int].int

      let qCode = qTrees[prev].codes[q]
      let lCode = lTrees[q].codes[l]
      writer.putBits(qCode.code, qCode.len)
      writer.putBits(lCode.code, lCode.len)

      prev = q
  else:
    doAssert lCount <= 2
    if lCount > 1:
      writer.flushPartialWordBuffer()
      let beginIdx = uint8(lValToIdx[runs[0].l.int])
      writer.putByte(beginIdx)

  writer.flushPartialWordBuffer()

proc getLosslessOrderCfg(order: int; scheme: uint8): OrderLosslessCfg =
  doAssert order == 1 or order == 2
  case order
  of 1:
    case scheme
    of 0'u8: result = OrderLosslessCfg(symbolCount: 16, symbolOrder: 3, symbolRescale: 8)
    of 1'u8: result = OrderLosslessCfg(symbolCount: 32, symbolOrder: 2, symbolRescale: 8)
    of 2'u8: result = OrderLosslessCfg(symbolCount: 64, symbolOrder: 1, symbolRescale: 8)
    of 3'u8: result = OrderLosslessCfg(symbolCount: 128, symbolOrder: 1, symbolRescale: 8)
    of 4'u8: result = OrderLosslessCfg(symbolCount: 16, symbolOrder: 3, symbolRescale: 16)
    of 5'u8: result = OrderLosslessCfg(symbolCount: 32, symbolOrder: 2, symbolRescale: 32)
    of 6'u8: result = OrderLosslessCfg(symbolCount: 64, symbolOrder: 1, symbolRescale: 64)
    of 7'u8: result = OrderLosslessCfg(symbolCount: 128, symbolOrder: 1, symbolRescale: 128)
    else:
      raise newException(DsrcFormatError, "Unsupported lossless quality order scheme: " & $scheme)
  of 2:
    case scheme
    of 0'u8: result = OrderLosslessCfg(symbolCount: 16, symbolOrder: 4, symbolRescale: 8)
    of 1'u8: result = OrderLosslessCfg(symbolCount: 32, symbolOrder: 3, symbolRescale: 8)
    of 2'u8: result = OrderLosslessCfg(symbolCount: 64, symbolOrder: 2, symbolRescale: 8)
    of 3'u8: result = OrderLosslessCfg(symbolCount: 128, symbolOrder: 1, symbolRescale: 8)
    of 4'u8: result = OrderLosslessCfg(symbolCount: 16, symbolOrder: 4, symbolRescale: 16)
    of 5'u8: result = OrderLosslessCfg(symbolCount: 32, symbolOrder: 3, symbolRescale: 32)
    of 6'u8: result = OrderLosslessCfg(symbolCount: 64, symbolOrder: 2, symbolRescale: 64)
    of 7'u8: result = OrderLosslessCfg(symbolCount: 128, symbolOrder: 1, symbolRescale: 128)
    else:
      raise newException(DsrcFormatError, "Unsupported lossless quality order scheme: " & $scheme)
  else:
    raise newException(DsrcFormatError, "Unsupported lossless quality order: " & $order)

proc selectLosslessOrderScheme(stats: QualityStats; order: int): uint8 =
  if stats.symbolCount > 128'u32:
    raise newException(DsrcFormatError, "Pure encoder does not support lossless quality-order symbol count > 128")

  result = QualitySchemeNone
  for i in 0'u8 .. 7'u8:
    if (16'u32 shl i) >= stats.symbolCount:
      result = i
      break

  if result == QualitySchemeNone:
    raise newException(DsrcFormatError, "Unsupported lossless quality-order scheme selection")

  if order == 2:
    let rleRatio = if stats.rleLength > 0'u32:
        float(stats.rawLength) / float(stats.rleLength)
      else:
        0.0
    if stats.maxLength == stats.minLength and rleRatio > 1.175:
      result = result + 4'u8

proc encodeLossyOrder(writer: var BitMemoryWriter; records: openArray[PureFastqRecord]; order: int) =
  var hashState = initQualityHashState(order, 8)
  let keyBits = order * hashState.alphabetBits + hashState.alphabetBits
  let capHint = 1 shl min(max(keyBits div 2, 10), 16)
  var model = initAdaptiveSymbolCoderMap(capHint, 8, 2'u16)
  var encoder = RangeEncoder()
  encoder.start()

  for rec in records:
    let qLen = rec.quality.len
    if qLen == 0:
      continue

    for j in 0 ..< qLen:
      let pctx = uint32((j * 8) div qLen)
      let q = uint32(ord(rec.quality[j]))
      doAssert q <= 7'u32

      let key = (hashState.getHash() shl hashState.alphabetBits) or uint64(pctx)
      model.getOrInit(key).encodeSymbol(encoder, writer, q)
      hashState.updateHash(q)

  encoder.finish(writer)

proc encodeLosslessOrder(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  stats: QualityStats;
  order: int
) =
  let scheme = selectLosslessOrderScheme(stats, order)
  writer.putByte(scheme)

  let cfg = getLosslessOrderCfg(order, scheme)

  var present: array[256, bool]
  var symToIdx: array[256, int32]
  for i in 0 ..< symToIdx.len:
    symToIdx[i] = -1

  var symCount = 0
  for rec in records:
    for ch in rec.quality:
      present[ord(ch)] = true

  for i in 0 ..< 256:
    if present[i]:
      symToIdx[i] = int32(symCount)
      inc symCount
      writer.putBit(1'u32)
    else:
      writer.putBit(0'u32)

  doAssert symCount > 0
  doAssert symCount <= cfg.symbolCount
  writer.flushPartialWordBuffer()

  var hashState = initQualityHashState(cfg.symbolOrder, cfg.symbolCount)
  let keyBits = cfg.symbolOrder * hashState.alphabetBits + hashState.alphabetBits
  let capHint = 1 shl min(max(keyBits div 2, 10), 16)
  var model = initAdaptiveSymbolCoderMap(capHint, cfg.symbolCount, 2'u16)
  var encoder = RangeEncoder()
  encoder.start()

  for rec in records:
    let qLen = rec.quality.len
    if qLen == 0:
      continue

    for j in 0 ..< qLen:
      let pctx = uint32((j * cfg.symbolRescale) div qLen)
      let idx = uint32(symToIdx[ord(rec.quality[j])])

      let key = (hashState.getHash() shl hashState.alphabetBits) or uint64(pctx)
      model.getOrInit(key).encodeSymbol(encoder, writer, idx)
      hashState.updateHash(idx)

  encoder.finish(writer)

proc encodeQuality(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  stats: QualityStats;
  minQuaLen, maxQuaLen: uint32;
  compSettings: CompressionSettings
) =
  if compSettings.qualityOrder == 0'u32:
    if maxQuaLen == 0'u32:
      writer.putByte(QualitySchemeNone)
      return

    case selectQualityNormalScheme(stats)
    of QualityPlain:
      encodeQualityPlain(writer, records, maxQuaLen)
    of QualityTruncated:
      encodeQualityTruncated(writer, records, minQuaLen, maxQuaLen)
    of QualityRle:
      encodeQualityRle(writer, records)
    else:
      raise newException(DsrcFormatError, "Invalid quality normal scheme")
    return

  if compSettings.lossy:
    encodeLossyOrder(writer, records, int(compSettings.qualityOrder))
  else:
    encodeLosslessOrder(writer, records, stats, int(compSettings.qualityOrder))

proc encodeDnaB2(writer: var BitMemoryWriter; records: openArray[PureFastqRecord]) =
  writer.putByte(DnaOrder0SchemeB2)
  for rec in records:
    for ch in rec.sequence:
      let s = uint32(ord(ch))
      doAssert s < 4'u32
      writer.put2Bits(s)
  writer.flushPartialWordBuffer()

proc encodeDnaHuffman(writer: var BitMemoryWriter; records: openArray[PureFastqRecord]) =
  writer.putByte(DnaOrder0SchemeHuffman)

  var freqsByValue: array[DnaMaxSymbolCount, uint32]
  for rec in records:
    for ch in rec.sequence:
      let v = ord(ch)
      if v < 0 or v >= DnaMaxSymbolCount:
        raise newException(DsrcFormatError, "DNA symbol out of order-0 range")
      freqsByValue[v] += 1'u32

  var valToIdx: array[DnaMaxSymbolCount, int32]
  for i in 0 ..< valToIdx.len:
    valToIdx[i] = -1

  var freqs: seq[uint32] = @[]
  for v in 0 ..< DnaMaxSymbolCount:
    if freqsByValue[v] > 0'u32:
      valToIdx[v] = int32(freqs.len)
      freqs.add(freqsByValue[v])
      writer.putBit(1'u32)
    else:
      writer.putBit(0'u32)

  doAssert freqs.len > 0
  writer.flushPartialWordBuffer()

  let build = buildHuffman(freqs)
  storeTree(writer, build)

  for rec in records:
    for ch in rec.sequence:
      let idx = valToIdx[ord(ch)].int
      doAssert idx >= 0 and idx < build.codes.len
      let c = build.codes[idx]
      writer.putBits(c.code, c.len)

  writer.flushPartialWordBuffer()

proc encodeDnaOrderN(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  order: int;
  scheme: uint8
) =
  writer.putByte(scheme)

  var symbolCount = 0
  var alphabetBits = 0
  var modelOrder = order

  case scheme
  of DnaOrderNScheme4Sym:
    symbolCount = 4
    alphabetBits = 2
  of DnaOrderNScheme8Sym:
    symbolCount = 8
    alphabetBits = 3
    if modelOrder > 7:
      modelOrder = 7
  else:
    raise newException(DsrcFormatError, "Unsupported DNA order-N scheme")

  doAssert modelOrder > 0
  let hashBits = modelOrder * alphabetBits
  doAssert hashBits < 63
  let hashMask = (1'u64 shl hashBits) - 1'u64

  let capHint = 1 shl min(max(hashBits div 2, 10), 16)
  var model = initAdaptiveSymbolCoderMap(capHint, symbolCount, 2'u16)
  var encoder = RangeEncoder()
  encoder.start()

  var hash = 0'u64
  for rec in records:
    for ch in rec.sequence:
      let sym = uint32(ord(ch))
      doAssert sym < uint32(symbolCount)
      model.getOrInit(hash).encodeSymbol(encoder, writer, sym)

      hash = hash shl alphabetBits
      hash = hash or uint64(sym)
      hash = hash and hashMask

  encoder.finish(writer)

proc encodeDna(
  writer: var BitMemoryWriter;
  records: openArray[PureFastqRecord];
  stats: DnaStats;
  compSettings: CompressionSettings
) =
  var hasSymbols = false
  for rec in records:
    if rec.sequence.len > 0:
      hasSymbols = true
      break

  if not hasSymbols:
    writer.putByte(DnaSchemeNone)
    return

  if compSettings.dnaOrder == 0'u32:
    if stats.symbolCount <= 4'u32:
      encodeDnaB2(writer, records)
    else:
      encodeDnaHuffman(writer, records)
    return

  if stats.symbolCount <= 4'u32:
    encodeDnaOrderN(writer, records, int(compSettings.dnaOrder), DnaOrderNScheme4Sym)
  elif stats.symbolCount <= 8'u32:
    encodeDnaOrderN(writer, records, int(compSettings.dnaOrder), DnaOrderNScheme8Sym)
  else:
    raise newException(DsrcFormatError, "DNA order-N supports at most 8 symbols")

proc encodeChunkRecordsInPlace*(
  records: var seq[PureFastqRecord];
  datasetType: FastqDatasetType;
  compSettings: CompressionSettings
): seq[uint8] =
  if records.len == 0:
    raise newException(DsrcFormatError, "Cannot encode empty record set into DSRC chunk")
  if datasetType.colorSpace:
    raise newException(DsrcFormatError, "Pure-Nim encoder does not support color-space datasets")
  if compSettings.tagPreserveFlags != DefaultTagPreserveFlags:
    raise newException(DsrcFormatError, "Pure-Nim encoder does not support non-default tag preserve flags")
  if compSettings.dnaOrder > 9'u32:
    raise newException(DsrcFormatError, "DNA order must be in range 0..9")
  if compSettings.qualityOrder > 9'u32:
    raise newException(DsrcFormatError, "Quality order must be in range 0..9")
  if compSettings.qualityOrder > 2'u32 and not compSettings.lossy:
    raise newException(DsrcFormatError, "Lossless quality order supports only 1 or 2")

  # Chunk size must reflect original FASTQ payload, before forward transforms.
  let originalChunkSize = computeChunkSize(records, datasetType.plusRepetition)

  var checksum = FastqChecksum()
  var dnaStats = DnaStats()
  var qualityStats = QualityStats()

  let cFlags = checksumFlags(compSettings)
  if compSettings.lossy:
    var rp = initLossyRecordsProcessor(
      qualityOffset = datasetType.qualityOffset,
      colorSpace = datasetType.colorSpace
    )
    rp.initializeStats()
    checksum = rp.processForward(records, cFlags)
    rp.finalizeStats()
    dnaStats = rp.base.dnaStats
    qualityStats = rp.base.qualityStats
  else:
    var rp = initLosslessRecordsProcessor(
      qualityOffset = datasetType.qualityOffset,
      colorSpace = datasetType.colorSpace
    )
    rp.initializeStats()
    checksum = rp.processForward(records, cFlags)
    rp.finalizeStats()
    dnaStats = rp.dnaStats
    qualityStats = rp.qualityStats

  var header = ChunkHeaderMeta()
  header.recordsCount = uint32(records.len)
  header.chunkSize = originalChunkSize
  header.flags = 0'u32
  header.minQuaLength = qualityStats.minLength
  header.maxQuaLength = qualityStats.maxLength
  if header.maxQuaLength != header.minQuaLength:
    header.flags = header.flags or FlagVariableLength
  header.checksum = checksum
  header.checksumFlags = cFlags

  let useRawTags = compSettings.debugControlChecks or chooseRawTagCoding(records)
  if useRawTags:
    header.flags = header.flags or FlagMixedFieldFormatting

  var writer = initBitMemoryWriter()
  let controlChecks = compSettings.debugControlChecks
  writeControlCheck(writer, controlChecks)
  writeMetaData(writer, header, datasetType, compSettings)
  writeControlCheck(writer, controlChecks)
  if useRawTags:
    encodeTagRawAndLengths(writer, records, header.minQuaLength, header.maxQuaLength)
  else:
    encodeTagTokenizerAndLengths(writer, records, header.minQuaLength, header.maxQuaLength)
  writeControlCheck(writer, controlChecks)
  encodeQuality(writer, records, qualityStats, header.minQuaLength, header.maxQuaLength, compSettings)
  writeControlCheck(writer, controlChecks)
  encodeDna(writer, records, dnaStats, compSettings)
  writeControlCheck(writer, controlChecks)
  writer.data

proc encodeChunkRecords*(
  records: openArray[PureFastqRecord];
  datasetType: FastqDatasetType;
  compSettings: CompressionSettings
): seq[uint8] =
  var work = @records
  encodeChunkRecordsInPlace(work, datasetType, compSettings)
