## Range decoder and adaptive symbol coder primitives used by DSRC order modelers.

import bitstream

const
  RcTopValue* = 0x00ff_ffff'u32
  RcMask64* = 0xff00_0000_0000_0000'u64
  RcMask32* = 0xffff_ffff'u64

type
  RangeEncoder* = object
    low: uint64
    range: uint32

  RangeDecoder* = object
    low: uint64
    range: uint32
    buffer: uint64

  AdaptiveSymbolCoder* = object
    stats: seq[uint16]
    fenwick: seq[uint32] # 1-based Binary Indexed Tree over stats
    topBit: int
    stepSize: uint16
    total: uint32
    maxAccumulatedValue: uint32

proc highestPowerOfTwoLE(x: int): int {.inline.} =
  doAssert x > 0
  result = 1
  while (result shl 1) <= x:
    result = result shl 1

proc fenwickAdd(coder: var AdaptiveSymbolCoder; idx0: int; delta: uint32) {.inline.} =
  var i = idx0 + 1
  while i < coder.fenwick.len:
    coder.fenwick[i] += delta
    i += i and -i

proc fenwickPrefixExclusive(coder: AdaptiveSymbolCoder; idxExclusive: int): uint32 {.inline.} =
  var i = idxExclusive
  while i > 0:
    result += coder.fenwick[i]
    i -= i and -i

proc rebuildFenwick(coder: var AdaptiveSymbolCoder) =
  let n = coder.stats.len
  coder.fenwick = newSeq[uint32](n + 1)
  var total = 0'u32
  for i in 1 .. n:
    let v = uint32(coder.stats[i - 1])
    coder.fenwick[i] = v
    total += v
  for i in 1 .. n:
    let j = i + (i and -i)
    if j <= n:
      coder.fenwick[j] += coder.fenwick[i]
  coder.total = total
  coder.topBit = highestPowerOfTwoLE(n)

proc fenwickFindByCumulative(
  coder: AdaptiveSymbolCoder;
  cumulative: uint32;
  lowEnd: var uint32
): int {.inline.} =
  # Find smallest idx such that prefix(idx+1) > cumulative.
  var idx = 0
  var bit = coder.topBit
  var rem = cumulative + 1'u32
  lowEnd = 0'u32
  let n = coder.stats.len
  while bit != 0:
    let next = idx + bit
    if next <= n and coder.fenwick[next] < rem:
      idx = next
      lowEnd += coder.fenwick[next]
      rem -= coder.fenwick[next]
    bit = bit shr 1
  idx

proc initAdaptiveSymbolCoder*(
  symbolCount: int;
  stepSize: uint16
): AdaptiveSymbolCoder =
  doAssert symbolCount > 0
  result.stats = newSeq[uint16](symbolCount)
  for i in 0 ..< symbolCount:
    result.stats[i] = 1'u16
  result.rebuildFenwick()
  result.stepSize = stepSize
  result.total = uint32(symbolCount)
  result.maxAccumulatedValue = (1'u32 shl 16) - uint32(symbolCount) * uint32(stepSize)

proc clear*(coder: var AdaptiveSymbolCoder) =
  for i in 0 ..< coder.stats.len:
    coder.stats[i] = 1'u16
  coder.rebuildFenwick()

proc symbolCount*(coder: AdaptiveSymbolCoder): int =
  coder.stats.len

proc start*(decoder: var RangeDecoder; reader: var BitMemoryReader) =
  reader.flushInputWordBuffer()
  decoder.buffer = 0'u64
  for i in 1 .. 8:
    decoder.buffer = decoder.buffer or (uint64(reader.getByte()) shl (64 - i * 8))
  decoder.low = 0'u64
  decoder.range = uint32(RcMask32)

proc start*(encoder: var RangeEncoder) =
  encoder.low = 0'u64
  encoder.range = uint32(RcMask32)

proc encodeFrequency*(
  encoder: var RangeEncoder;
  writer: var BitMemoryWriter;
  symFreq: uint32;
  cumFreq: uint32;
  totalFreq: uint32
) =
  doAssert encoder.range > totalFreq
  encoder.range = encoder.range div totalFreq
  encoder.low = encoder.low + uint64(encoder.range) * uint64(cumFreq)
  encoder.range = encoder.range * symFreq

  while encoder.range <= RcTopValue:
    doAssert encoder.range != 0'u32
    if ((encoder.low xor (encoder.low + uint64(encoder.range))) and RcMask64) != 0'u64:
      let r = uint32(encoder.low and RcMask32)
      encoder.range = (r or RcTopValue) - r

    writer.putByte(uint8(encoder.low shr 56))
    encoder.low = encoder.low shl 8
    encoder.range = encoder.range shl 8

proc finish*(encoder: var RangeEncoder; writer: var BitMemoryWriter) =
  for _ in 0 ..< 8:
    writer.putByte(uint8(encoder.low shr 56))
    encoder.low = encoder.low shl 8

proc getCumulativeFreq*(decoder: var RangeDecoder; totalFreq: uint32): uint32 =
  doAssert totalFreq != 0'u32
  decoder.range = decoder.range div totalFreq
  uint32(decoder.buffer div uint64(decoder.range))

proc updateFrequency*(
  decoder: var RangeDecoder;
  reader: var BitMemoryReader;
  symFreq: uint32;
  lowEnd: uint32
) =
  let r = uint64(lowEnd) * uint64(decoder.range)
  decoder.buffer = decoder.buffer - r
  decoder.low = decoder.low + r
  decoder.range = decoder.range * symFreq

  while decoder.range <= RcTopValue:
    if ((decoder.low xor (decoder.low + uint64(decoder.range))) and RcMask64) != 0'u64:
      let low32 = uint32(decoder.low and RcMask32)
      decoder.range = (low32 or RcTopValue) - low32

    decoder.buffer = (decoder.buffer shl 8) + uint64(reader.getByte())
    decoder.low = decoder.low shl 8
    decoder.range = decoder.range shl 8

proc finish*(decoder: var RangeDecoder) =
  discard decoder

proc rescale(coder: var AdaptiveSymbolCoder) =
  for i in 0 ..< coder.stats.len:
    let v = coder.stats[i] - (coder.stats[i] shr 1)
    coder.stats[i] = v
  coder.rebuildFenwick()

proc accumulate(coder: var AdaptiveSymbolCoder): uint32 =
  if coder.total >= coder.maxAccumulatedValue:
    coder.rescale()
  coder.total

proc decodeSymbol*(
  coder: var AdaptiveSymbolCoder;
  decoder: var RangeDecoder;
  reader: var BitMemoryReader
): uint32 =
  let acc = coder.accumulate()
  let cul = decoder.getCumulativeFreq(acc)
  var lowEnd = 0'u32
  let idx = coder.fenwickFindByCumulative(cul, lowEnd)
  doAssert idx < coder.stats.len
  decoder.updateFrequency(reader, uint32(coder.stats[idx]), lowEnd)
  coder.stats[idx] = coder.stats[idx] + coder.stepSize
  let delta = uint32(coder.stepSize)
  coder.fenwickAdd(idx, delta)
  coder.total += delta
  uint32(idx)

proc encodeSymbol*(
  coder: var AdaptiveSymbolCoder;
  encoder: var RangeEncoder;
  writer: var BitMemoryWriter;
  sym: uint32
) =
  doAssert sym < uint32(coder.stats.len)
  let acc = coder.accumulate()
  let symIdx = sym.int
  let lowEnd = coder.fenwickPrefixExclusive(symIdx)
  encoder.encodeFrequency(writer, uint32(coder.stats[symIdx]), lowEnd, acc)
  coder.stats[symIdx] = coder.stats[symIdx] + coder.stepSize
  let delta = uint32(coder.stepSize)
  coder.fenwickAdd(symIdx, delta)
  coder.total += delta
