## Quality stream decode side for pure-Nim DSRC block decoding (PN-009 decode path).

import bitstream, chunk_decoder, huffman_decoder, range_decoder, types, adaptive_model_map

const
  QualitySchemeNone = 255'u8
  QualityPlain = 0'u8
  QualityTruncated = 1'u8
  QualityRle = 2'u8

  QualityMaxSymbolCount = 256
  QualityMaxLengthSymbols = 256
  QualityHashThreshold = 128'u8

type
  QualityHashState = object
    hash: uint64
    symBuffer: uint64
    alphabetBits: int
    bitsLo: int
    bitsHi: int
    symbolMask: uint64
    symbolSwapMask: uint64
    symbolHashMask: uint64

  PositionModelContext = object
    maxLength: uint32
    symbols: seq[uint8]                # index -> decoded symbol value
    positionContexts: seq[HuffmanDecoder]

  RleContext = object
    runLength: uint32
    qSymbols: seq[uint8]               # index -> quality symbol
    lSymbols: seq[uint8]               # index -> run-length-minus-1
    qContexts: seq[HuffmanDecoder]
    lContexts: seq[HuffmanDecoder]
    qRun: seq[uint8]
    lRun: seq[uint8]

  OrderLosslessCfg = object
    symbolCount: int
    symbolOrder: int
    symbolRescale: int

proc bitLength32(x: uint32): uint32 =
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

proc readPositionContext(reader: var BitMemoryReader): PositionModelContext =
  reader.flushInputWordBuffer()

  result.maxLength = reader.getWord()
  doAssert result.maxLength > 0'u32

  result.symbols = @[]
  for i in 0 ..< QualityMaxSymbolCount:
    if reader.getBit() != 0'u32:
      result.symbols.add(uint8(i))
  doAssert result.symbols.len > 0

  result.positionContexts = newSeq[HuffmanDecoder](int(result.maxLength))
  for i in 0 ..< int(result.maxLength):
    result.positionContexts[i].loadTree(reader)

proc decodePositionalPlain(
  reader: var BitMemoryReader;
  state: var ChunkDecodeState;
  quantizedValues: bool
) =
  var ctx = readPositionContext(reader)

  for i in 0 ..< state.records.len:
    let qLen = state.records[i].quality.len
    doAssert qLen <= int(ctx.maxLength)

    var nCount = 0
    for j in 0 ..< qLen:
      let idx = ctx.positionContexts[j].decodeSymbol(reader)
      doAssert idx >= 0 and idx < int32(ctx.symbols.len)
      let q = ctx.symbols[idx.int]
      state.records[i].quality[j] = char(q)

      if quantizedValues:
        nCount += int(q == 0'u8)
      else:
        nCount += int(q >= QualityHashThreshold)

    state.records[i].sequence.setLen(qLen - nCount)

  reader.flushInputWordBuffer()

proc decodePositionalTruncated(
  reader: var BitMemoryReader;
  state: var ChunkDecodeState;
  quantizedValues: bool
) =
  var ctx = readPositionContext(reader)
  let maxBitLength = bitLength32(ctx.maxLength)
  let variableLength = reader.getBit() != 0'u32
  let hashSymbol = if quantizedValues: char(HashSymbolQuantized) else: char(HashSymbolNormal)

  for i in 0 ..< state.records.len:
    let qLen = uint32(state.records[i].quality.len)
    var thLen = qLen

    if reader.getBit() != 0'u32:
      let bitLen = if variableLength: bitLength32(qLen) else: maxBitLength
      if bitLen > 0'u32:
        thLen = reader.getBits(bitLen)
      else:
        thLen = 0'u32
    doAssert thLen <= qLen

    var nCount = 0
    for j in 0 ..< int(thLen):
      let idx = ctx.positionContexts[j].decodeSymbol(reader)
      doAssert idx >= 0 and idx < int32(ctx.symbols.len)
      let q = ctx.symbols[idx.int]
      state.records[i].quality[j] = char(q)
      if quantizedValues:
        nCount += int(q == 0'u8)
      else:
        nCount += int(q >= QualityHashThreshold)

    for j in int(thLen) ..< int(qLen):
      state.records[i].quality[j] = hashSymbol

    state.records[i].sequence.setLen(int(qLen) - nCount)

  reader.flushInputWordBuffer()

proc readRleSymbols(reader: var BitMemoryReader; ctx: var RleContext) =
  ctx.qSymbols = @[]
  ctx.lSymbols = @[]

  for i in 0 ..< QualityMaxSymbolCount:
    if reader.getBit() != 0'u32:
      ctx.qSymbols.add(uint8(i))
  for i in 0 ..< QualityMaxLengthSymbols:
    if reader.getBit() != 0'u32:
      ctx.lSymbols.add(uint8(i))

  reader.flushInputWordBuffer()
  doAssert ctx.qSymbols.len > 0
  doAssert ctx.lSymbols.len > 0

proc readRleContexts(reader: var BitMemoryReader; ctx: var RleContext) =
  if ctx.qSymbols.len <= 1:
    return

  ctx.qContexts = newSeq[HuffmanDecoder](ctx.qSymbols.len)
  ctx.lContexts = newSeq[HuffmanDecoder](ctx.qSymbols.len)
  for i in 0 ..< ctx.qSymbols.len:
    ctx.qContexts[i].loadTree(reader)
    ctx.lContexts[i].loadTree(reader)

proc decodeRleRuns(reader: var BitMemoryReader; ctx: var RleContext) =
  ctx.qRun = newSeq[uint8](int(ctx.runLength))
  ctx.lRun = newSeq[uint8](int(ctx.runLength))

  if ctx.qSymbols.len > 1:
    var prev = 0
    for i in 0 ..< int(ctx.runLength):
      let qIdx = ctx.qContexts[prev].decodeSymbol(reader)
      if qIdx < 0 or qIdx >= int32(ctx.qSymbols.len):
        raise newException(
          DsrcFormatError,
          "RLE qIdx out of range: " & $qIdx & " (qSymbols=" & $ctx.qSymbols.len & ", prev=" & $prev & ")"
        )
      ctx.qRun[i] = ctx.qSymbols[qIdx.int]
      prev = qIdx.int

      let lIdxRaw = ctx.lContexts[prev].decodeSymbol(reader)
      if lIdxRaw < 0 or lIdxRaw >= int32(ctx.lSymbols.len):
        if ctx.lSymbols.len == 1:
          # CLI q0 archives can produce a degenerate 1-length alphabet context.
          # Keep bitstream consumption from the context decode, clamp the symbol id.
          ctx.lRun[i] = ctx.lSymbols[0]
        else:
          raise newException(
            DsrcFormatError,
            "RLE lIdx out of range: " & $lIdxRaw & " (lSymbols=" & $ctx.lSymbols.len & ", prev=" & $prev & ")"
          )
      else:
        ctx.lRun[i] = ctx.lSymbols[lIdxRaw.int]
    return

  var lBegin = ctx.lSymbols[0]
  var lEnd = lBegin
  if ctx.lSymbols.len > 1:
    reader.flushInputWordBuffer()
    let beginIdx = int(reader.getByte())
    doAssert beginIdx >= 0 and beginIdx < ctx.lSymbols.len
    lBegin = ctx.lSymbols[beginIdx]
    lEnd = ctx.lSymbols[0]
    if lEnd == lBegin:
      lEnd = ctx.lSymbols[1]
    doAssert lEnd != lBegin

  for i in 0 ..< int(ctx.runLength):
    ctx.qRun[i] = ctx.qSymbols[0]
    ctx.lRun[i] = lBegin
  if ctx.runLength > 0'u32:
    ctx.lRun[^1] = lEnd

proc decodeRleRecords(
  state: var ChunkDecodeState;
  quantizedValues: bool;
  ctx: RleContext
) =
  var curLen = 0'u32
  var curQua = 0'u8
  var curIdx = 0

  for i in 0 ..< state.records.len:
    let qLen = state.records[i].quality.len
    var nCount = 0

    for j in 0 ..< qLen:
      if curLen == 0'u32:
        doAssert curIdx < int(ctx.runLength)
        curQua = ctx.qRun[curIdx]
        curLen = uint32(ctx.lRun[curIdx]) + 1'u32
        inc curIdx

      state.records[i].quality[j] = char(curQua)
      dec curLen

      if quantizedValues:
        nCount += int(curQua == 0'u8)
      else:
        nCount += int(curQua >= QualityHashThreshold)

    state.records[i].sequence.setLen(qLen - nCount)

proc decodeRle(
  reader: var BitMemoryReader;
  state: var ChunkDecodeState;
  quantizedValues: bool
) =
  var ctx = RleContext()
  ctx.runLength = reader.getWord()
  readRleSymbols(reader, ctx)
  readRleContexts(reader, ctx)

  reader.flushInputWordBuffer()
  decodeRleRuns(reader, ctx)
  decodeRleRecords(state, quantizedValues, ctx)
  reader.flushInputWordBuffer()

proc decodeExtOrderSymbol(
  reader: var BitMemoryReader;
  decoder: var RangeDecoder;
  model: var AdaptiveSymbolCoderMap;
  hashState: var QualityHashState;
  ctx0: uint32;
  symbolCount: int
): uint32 =
  let key = (hashState.getHash() shl hashState.alphabetBits) or uint64(ctx0)
  result = model.getOrInit(key).decodeSymbol(decoder, reader)
  doAssert result < uint32(symbolCount)
  hashState.updateHash(result)

proc decodeLossyOrder(reader: var BitMemoryReader; state: var ChunkDecodeState) =
  let order = int(state.compSettings.qualityOrder)
  doAssert order > 0

  var hashState = initQualityHashState(order, 8)
  let keyBits = order * hashState.alphabetBits + hashState.alphabetBits
  let capHint = 1 shl min(max(keyBits div 2, 10), 16)
  var model = initAdaptiveSymbolCoderMap(capHint, 8, 2'u16)
  var decoder = RangeDecoder()
  decoder.start(reader)

  for i in 0 ..< state.records.len:
    let qLen = state.records[i].quality.len
    if qLen == 0:
      state.records[i].sequence.setLen(0)
      continue

    var nCount = 0
    for j in 0 ..< qLen:
      let pctx = uint32((j * 8) div qLen)
      let q = decodeExtOrderSymbol(reader, decoder, model, hashState, pctx, 8)
      state.records[i].quality[j] = char(uint8(q))
      nCount += int(q == 0'u32)
    state.records[i].sequence.setLen(qLen - nCount)

  decoder.finish()

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

proc readTranslationalSymbols(reader: var BitMemoryReader): seq[uint8] =
  reader.flushInputWordBuffer()
  result = @[]
  for i in 0 ..< QualityMaxSymbolCount:
    if reader.getBit() != 0'u32:
      result.add(uint8(i))
  reader.flushInputWordBuffer()

proc decodeLosslessOrder(reader: var BitMemoryReader; state: var ChunkDecodeState) =
  let order = int(state.compSettings.qualityOrder)
  let scheme = reader.getByte()
  if scheme == QualitySchemeNone:
    return

  let cfg = getLosslessOrderCfg(order, scheme)
  let symbols = readTranslationalSymbols(reader)
  doAssert symbols.len > 0 and symbols.len <= cfg.symbolCount

  var hashState = initQualityHashState(cfg.symbolOrder, cfg.symbolCount)
  let keyBits = cfg.symbolOrder * hashState.alphabetBits + hashState.alphabetBits
  let capHint = 1 shl min(max(keyBits div 2, 10), 16)
  var model = initAdaptiveSymbolCoderMap(capHint, cfg.symbolCount, 2'u16)
  var decoder = RangeDecoder()
  decoder.start(reader)

  for i in 0 ..< state.records.len:
    let qLen = state.records[i].quality.len
    if qLen == 0:
      state.records[i].sequence.setLen(0)
      continue

    var nCount = 0
    for j in 0 ..< qLen:
      let pctx = uint32((j * cfg.symbolRescale) div qLen)
      let c = decodeExtOrderSymbol(reader, decoder, model, hashState, pctx, cfg.symbolCount)
      doAssert c < uint32(symbols.len)
      let q = symbols[c.int]
      state.records[i].quality[j] = char(q)
      nCount += int(q >= QualityHashThreshold)
    state.records[i].sequence.setLen(qLen - nCount)

  decoder.finish()

proc decodeNormal(reader: var BitMemoryReader; state: var ChunkDecodeState) =
  let scheme = reader.getByte()
  if scheme == QualitySchemeNone:
    return

  let quantizedValues = state.compSettings.lossy
  case scheme
  of QualityPlain:
    decodePositionalPlain(reader, state, quantizedValues)
  of QualityTruncated:
    decodePositionalTruncated(reader, state, quantizedValues)
  of QualityRle:
    decodeRle(reader, state, quantizedValues)
  else:
    raise newException(DsrcFormatError, "Unsupported quality scheme: " & $scheme)

proc decodeQualityHook*(
  reader: var BitMemoryReader;
  state: var ChunkDecodeState
) {.gcsafe.} =
  if state.compSettings.qualityOrder == 0'u32:
    decodeNormal(reader, state)
    return

  if state.compSettings.lossy:
    decodeLossyOrder(reader, state)
  else:
    decodeLosslessOrder(reader, state)
