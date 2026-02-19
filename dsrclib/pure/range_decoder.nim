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
    stepSize: uint16
    maxAccumulatedValue: uint32

proc initAdaptiveSymbolCoder*(
  symbolCount: int;
  stepSize: uint16
): AdaptiveSymbolCoder =
  doAssert symbolCount > 0
  result.stats = newSeq[uint16](symbolCount)
  for i in 0 ..< symbolCount:
    result.stats[i] = 1'u16
  result.stepSize = stepSize
  result.maxAccumulatedValue = (1'u32 shl 16) - uint32(symbolCount) * uint32(stepSize)

proc clear*(coder: var AdaptiveSymbolCoder) =
  for i in 0 ..< coder.stats.len:
    coder.stats[i] = 1'u16

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
    coder.stats[i] = coder.stats[i] - (coder.stats[i] shr 1)

proc accumulate(coder: var AdaptiveSymbolCoder): uint32 =
  result = 0'u32
  for i in 0 ..< coder.stats.len:
    result += uint32(coder.stats[i])

  if result >= coder.maxAccumulatedValue:
    coder.rescale()
    result = 0'u32
    for i in 0 ..< coder.stats.len:
      result += uint32(coder.stats[i])

proc decodeSymbol*(
  coder: var AdaptiveSymbolCoder;
  decoder: var RangeDecoder;
  reader: var BitMemoryReader
): uint32 =
  let acc = coder.accumulate()
  let cul = decoder.getCumulativeFreq(acc)

  var idx = 0
  var hiEnd = 0'u32
  while idx < coder.stats.len:
    hiEnd += uint32(coder.stats[idx])
    if hiEnd > cul:
      break
    inc idx

  doAssert idx < coder.stats.len
  let lowEnd = hiEnd - uint32(coder.stats[idx])
  decoder.updateFrequency(reader, uint32(coder.stats[idx]), lowEnd)
  coder.stats[idx] = coder.stats[idx] + coder.stepSize
  uint32(idx)

proc encodeSymbol*(
  coder: var AdaptiveSymbolCoder;
  encoder: var RangeEncoder;
  writer: var BitMemoryWriter;
  sym: uint32
) =
  doAssert sym < uint32(coder.stats.len)
  let acc = coder.accumulate()

  var lowEnd = 0'u32
  for i in 0 ..< int(sym):
    lowEnd += uint32(coder.stats[i])

  encoder.encodeFrequency(writer, uint32(coder.stats[sym]), lowEnd, acc)
  coder.stats[sym.int] = coder.stats[sym.int] + coder.stepSize
