## Reusable Huffman tree encoder compatible with DSRC serialized tree format.

import bitstream, huffman_decoder

type
  HuffCode* = object
    code*: uint32
    len*: uint32

  HuffBuild* = object
    nSymbols*: uint32
    rootId*: int32
    minLen*: uint32
    bitsPerId*: uint32
    nodes*: seq[HuffNode]
    codes*: seq[HuffCode]

proc ceilLog2(x: int): uint32 =
  doAssert x > 0
  var p = 1
  while p < x:
    p = p shl 1
    inc result
  if result == 0'u32:
    result = 1'u32

proc pickMin(active: seq[int32]; weights: seq[uint64]): int =
  doAssert active.len > 0
  result = 0
  for i in 1 ..< active.len:
    let a = active[i]
    let b = active[result]
    if weights[a] < weights[b] or (weights[a] == weights[b] and a < b):
      result = i

proc assignCodes(
  build: var HuffBuild;
  nodeId: int32;
  code: uint32;
  clen: uint32
) =
  if nodeId < int32(build.nSymbols):
    build.codes[nodeId.int].code = code
    build.codes[nodeId.int].len = clen
    return

  let n = build.nodes[nodeId.int]
  assignCodes(build, n.leftChild, code shl 1, clen + 1'u32)
  assignCodes(build, n.rightChild, (code shl 1) or 1'u32, clen + 1'u32)

proc buildHuffman*(freqs: openArray[uint32]): HuffBuild =
  doAssert freqs.len > 0

  let n = max(freqs.len, 2)
  result.nSymbols = uint32(n)
  result.bitsPerId = ceilLog2(n)
  result.nodes = newSeq[HuffNode](2 * n)
  result.codes = newSeq[HuffCode](n)

  var weights = newSeq[uint64](2 * n)
  var hasNonZero = false
  for i in 0 ..< n:
    let w = if i < freqs.len: uint64(freqs[i]) else: 0'u64
    if w > 0'u64:
      hasNonZero = true
    weights[i] = w
    result.nodes[i].leftChild = -1
    result.nodes[i].rightChild = -1

  if not hasNonZero:
    weights[0] = 1'u64
    if n > 1:
      weights[1] = 1'u64

  var active = newSeq[int32](n)
  for i in 0 ..< n:
    active[i] = int32(i)

  var nextNode = n
  while active.len > 1:
    let i1 = pickMin(active, weights)
    let left = active[i1]
    active.delete(i1)
    let i2 = pickMin(active, weights)
    let right = active[i2]
    active.delete(i2)

    result.nodes[nextNode].leftChild = left
    result.nodes[nextNode].rightChild = right
    weights[nextNode] = weights[left.int] + weights[right.int]
    active.add(int32(nextNode))
    inc nextNode

  result.rootId = active[0]
  result.assignCodes(result.rootId, 0'u32, 0'u32)

  result.minLen = uint32.high
  for c in result.codes:
    if c.len > 0'u32 and c.len < result.minLen:
      result.minLen = c.len
  if result.minLen == uint32.high:
    result.minLen = 1'u32

proc encodeTreeProcess(
  writer: var BitMemoryWriter;
  build: HuffBuild;
  nodeId: int32
) =
  if nodeId < int32(build.nSymbols):
    writer.putBit(1'u32)
    writer.putBits(uint32(nodeId), build.bitsPerId)
    return

  writer.putBit(0'u32)
  let n = build.nodes[nodeId.int]
  encodeTreeProcess(writer, build, n.leftChild)
  encodeTreeProcess(writer, build, n.rightChild)

proc storeTree*(writer: var BitMemoryWriter; build: HuffBuild) =
  # Tree payload must start on a byte boundary.
  writer.flushPartialWordBuffer()

  var tmp = initBitMemoryWriter()
  tmp.putWord(0'u32) # placeholder for mem size
  tmp.putWord(uint32(build.rootId))
  tmp.putWord(build.nSymbols)
  tmp.putByte(uint8(build.minLen))
  encodeTreeProcess(tmp, build, build.rootId)
  tmp.flushPartialWordBuffer()

  let memSize = uint32(tmp.data.len)
  tmp.data[0] = uint8(memSize shr 24)
  tmp.data[1] = uint8((memSize shr 16) and 0xFF'u32)
  tmp.data[2] = uint8((memSize shr 8) and 0xFF'u32)
  tmp.data[3] = uint8(memSize and 0xFF'u32)
  writer.putBytes(tmp.data)
