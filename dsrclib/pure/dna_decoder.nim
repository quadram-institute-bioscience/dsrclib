## DNA stream decode side for pure-Nim DSRC block decoding (PN-008 decode path).

import types, bitstream, chunk_decoder, huffman_decoder, range_decoder, adaptive_model_map

const
  DnaSchemeNone = 255'u8
  DnaOrder0SchemeB2 = 0'u8
  DnaOrder0SchemeHuffman = 1'u8
  DnaOrderNScheme4Sym = 0'u8
  DnaOrderNScheme8Sym = 1'u8
  DnaMaxSymbolCount = 20

proc decodeOrder0B2(reader: var BitMemoryReader; state: var ChunkDecodeState) =
  for rec in mitems(state.records):
    for j in 0 ..< rec.sequence.len:
      rec.sequence[j] = char(uint8(reader.get2Bits()))
  reader.flushInputWordBuffer()

proc decodeOrder0Huffman(reader: var BitMemoryReader; state: var ChunkDecodeState) =
  var symbolCount = 0'u32
  var symbols: array[DnaMaxSymbolCount, uint8]
  for i in 0 ..< DnaMaxSymbolCount:
    symbols[i] = 255'u8

  for i in 0 ..< DnaMaxSymbolCount:
    if reader.getBit() != 0'u32:
      symbols[int(symbolCount)] = uint8(i)
      inc symbolCount
  doAssert symbolCount > 0'u32

  var dec = HuffmanDecoder()
  dec.loadTree(reader)

  for rec in mitems(state.records):
    for j in 0 ..< rec.sequence.len:
      let sidx = dec.decodeSymbol(reader)
      doAssert sidx >= 0 and sidx < int32(symbolCount)
      rec.sequence[j] = char(symbols[sidx.int])

  reader.flushInputWordBuffer()

proc decodeOrderN(
  reader: var BitMemoryReader;
  state: var ChunkDecodeState;
  scheme: uint8
) =
  let requestedOrder = int(state.compSettings.dnaOrder)
  doAssert requestedOrder > 0

  var symbolCount = 0
  var alphabetBits = 0
  var order = requestedOrder

  case scheme
  of DnaOrderNScheme4Sym:
    symbolCount = 4
    alphabetBits = 2
  of DnaOrderNScheme8Sym:
    symbolCount = 8
    alphabetBits = 3
    if order > 7:
      order = 7
  else:
    raise newException(DsrcFormatError, "Unsupported DNA order-N scheme: " & $scheme)

  doAssert order > 0
  let hashBits = order * alphabetBits
  doAssert hashBits < 63
  let hashMask = (1'u64 shl hashBits) - 1'u64

  let capHint = 1 shl min(max(hashBits div 2, 10), 16)
  var model = initAdaptiveSymbolCoderMap(capHint, symbolCount, 2'u16)
  var decoder = RangeDecoder()
  decoder.start(reader)

  var hash = 0'u64
  for rec in mitems(state.records):
    for j in 0 ..< rec.sequence.len:
      let sym = model.getOrInit(hash).decodeSymbol(decoder, reader)
      doAssert sym < uint32(symbolCount)
      rec.sequence[j] = char(uint8(sym))

      hash = hash shl alphabetBits
      hash = hash or uint64(sym)
      hash = hash and hashMask

  decoder.finish()

proc decodeDnaHook*(
  reader: var BitMemoryReader;
  state: var ChunkDecodeState
) {.gcsafe.} =
  if state.compSettings.dnaOrder == 0'u32:
    let scheme = reader.getByte()
    case scheme
    of DnaSchemeNone:
      return
    of DnaOrder0SchemeB2:
      decodeOrder0B2(reader, state)
    of DnaOrder0SchemeHuffman:
      decodeOrder0Huffman(reader, state)
    else:
      raise newException(DsrcFormatError, "Unsupported DNA order-0 scheme: " & $scheme)
    return

  let scheme = reader.getByte()
  if scheme == DnaSchemeNone:
    return
  decodeOrderN(reader, state, scheme)
