## Reusable Huffman tree decoder compatible with DSRC's serialized tree format.

import bitstream

type
  HuffNode* = object
    leftChild*: int32
    rightChild*: int32

  HuffmanDecoder* = object
    nSymbols*: uint32
    minLen*: uint32
    bitsPerId*: uint32
    rootId*: int32
    curId*: int32
    tmpId*: int32
    tree*: seq[HuffNode]
    speedupTree*: seq[int32]

proc intLog*(x, base: uint32): uint32 =
  var r = 0'u32
  if base == 0'u32:
    return 1'u32
  var b = base
  if b == 1'u32:
    inc b
  var tmp = b
  while tmp <= x:
    inc r
    tmp *= b
  r

proc decodeBit*(h: var HuffmanDecoder; bit: uint32): int32 =
  if h.curId <= 0:
    h.curId = h.rootId
  if bit != 0'u32:
    h.curId = h.tree[h.curId].rightChild
  else:
    h.curId = h.tree[h.curId].leftChild
  if h.curId <= 0:
    return -h.curId
  -1

proc decodeFast*(h: var HuffmanDecoder; bits: uint32): int32 =
  if h.speedupTree.len == 0:
    h.curId = h.rootId
    if h.minLen > 0'u32:
      for j in countdown(int(h.minLen) - 1, 0):
        discard h.decodeBit((bits shr uint32(j)) and 1'u32)
    if h.curId <= 0:
      return -h.curId
    return -1

  h.curId = h.speedupTree[bits]
  if h.curId <= 0:
    return -h.curId
  -1

proc decodeProcess(h: var HuffmanDecoder; reader: var BitMemoryReader; nodeId: int32): int32 =
  doAssert nodeId >= 0
  if reader.getBit() == 0'u32:
    dec h.tmpId
    h.tree[nodeId].leftChild = h.decodeProcess(reader, h.tmpId)
    h.tree[nodeId].rightChild = h.decodeProcess(reader, h.tmpId)
    return nodeId
  -(int32(reader.getBits(h.bitsPerId)))

proc computeSpeedupTree(h: var HuffmanDecoder) =
  if h.minLen == 0'u32:
    return
  h.speedupTree = newSeq[int32](1 shl int(h.minLen))
  for i in 0 ..< h.speedupTree.len:
    h.curId = h.rootId
    for j in countdown(int(h.minLen) - 1, 0):
      discard h.decodeBit((uint32(i) shr uint32(j)) and 1'u32)
    h.speedupTree[i] = h.curId
  h.curId = h.rootId
  h.tmpId = h.rootId

proc loadTree*(h: var HuffmanDecoder; reader: var BitMemoryReader) =
  reader.flushInputWordBuffer()

  let memBegin = reader.pos
  let memSize = reader.getWord()
  doAssert memSize > 0'u32 and memSize < (1'u32 shl 20)

  let encodedRootId = int32(reader.getWord())
  h.nSymbols = reader.getWord()
  doAssert h.nSymbols > 1'u32
  doAssert h.nSymbols < (1'u32 shl 10)

  h.tmpId = encodedRootId
  h.curId = encodedRootId
  h.minLen = uint32(reader.getByte())

  h.bitsPerId = intLog(h.nSymbols, 2'u32)
  if (h.nSymbols and (h.nSymbols - 1'u32)) != 0'u32:
    inc h.bitsPerId
  doAssert h.bitsPerId > 0'u32

  let nodeId = encodedRootId - int32(h.nSymbols) + 1
  h.rootId = nodeId
  h.tmpId = nodeId
  h.curId = nodeId
  h.tree = newSeq[HuffNode](nodeId + 1)
  discard h.decodeProcess(reader, nodeId)

  reader.flushInputWordBuffer()
  if h.minLen == 0'u32:
    h.minLen = 1'u32
  h.computeSpeedupTree()
  doAssert memBegin + int(memSize) == reader.pos

proc decodeSymbol*(h: var HuffmanDecoder; reader: var BitMemoryReader): int32 =
  var bit = reader.getBits(h.minLen)
  var sym = h.decodeFast(bit)
  while sym < 0:
    bit = reader.getBit()
    sym = h.decodeBit(bit)
  sym
