## DSRC-compatible binary reader/writer primitives.
## Notes:
## - Word/DWord helpers are big-endian to match DSRC BitMemory PutWord/GetWord.
## - Some DSRC footer fields are little-endian raw uint32 arrays; helpers are provided.

import std/strformat

type
  ByteReader* = object
    data*: seq[uint8]
    pos*: int

  ByteWriter* = object
    data*: seq[uint8]

  BitMemoryReader* = object
    data*: seq[uint8]
    pos*: int
    wordBuffer*: uint32
    wordBufferPos*: uint32

  BitMemoryWriter* = object
    data*: seq[uint8]
    wordBuffer*: uint32
    wordBufferPos*: uint32

proc failBounds(what: string; need, have: int) {.noinline.} =
  raise newException(IOError, fmt"{what}: need {need} bytes, have {have}")

proc bitMask(n: uint32): uint32 =
  doAssert n < 32'u32
  (1'u32 shl n) - 1'u32

proc initByteReader*(src: openArray[uint8]): ByteReader =
  result.data = @src
  result.pos = 0

proc remaining*(r: ByteReader): int =
  r.data.len - r.pos

proc readByte*(r: var ByteReader): uint8 =
  if r.remaining < 1:
    failBounds("readByte", 1, r.remaining)
  result = r.data[r.pos]
  inc r.pos

proc readBytes*(r: var ByteReader; n: int): seq[uint8] =
  if r.remaining < n:
    failBounds("readBytes", n, r.remaining)
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

proc skipBytes*(r: var ByteReader; n: int) =
  if r.remaining < n:
    failBounds("skipBytes", n, r.remaining)
  r.pos += n

proc readWordBE*(r: var ByteReader): uint32 =
  var c = uint32(r.readByte())
  c = (c shl 8) or uint32(r.readByte())
  c = (c shl 8) or uint32(r.readByte())
  result = (c shl 8) or uint32(r.readByte())

proc readDWordBE*(r: var ByteReader): uint64 =
  var c = uint64(r.readByte())
  for _ in 0 ..< 7:
    c = (c shl 8) or uint64(r.readByte())
  result = c

proc readWordLE*(r: var ByteReader): uint32 =
  let b0 = uint32(r.readByte())
  let b1 = uint32(r.readByte())
  let b2 = uint32(r.readByte())
  let b3 = uint32(r.readByte())
  result = b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc initByteWriter*(initialCapacity = 0): ByteWriter =
  if initialCapacity > 0:
    result.data = newSeqOfCap[uint8](initialCapacity)
  else:
    result.data = @[]

proc writeByte*(w: var ByteWriter; b: uint8) =
  w.data.add(b)

proc writeBytes*(w: var ByteWriter; src: openArray[uint8]) =
  w.data.add(src)

proc writeWordBE*(w: var ByteWriter; v: uint32) =
  w.writeByte(uint8(v shr 24))
  w.writeByte(uint8((v shr 16) and 0xFF'u32))
  w.writeByte(uint8((v shr 8) and 0xFF'u32))
  w.writeByte(uint8(v and 0xFF'u32))

proc writeDWordBE*(w: var ByteWriter; v: uint64) =
  w.writeByte(uint8(v shr 56))
  w.writeByte(uint8((v shr 48) and 0xFF'u64))
  w.writeByte(uint8((v shr 40) and 0xFF'u64))
  w.writeByte(uint8((v shr 32) and 0xFF'u64))
  w.writeByte(uint8((v shr 24) and 0xFF'u64))
  w.writeByte(uint8((v shr 16) and 0xFF'u64))
  w.writeByte(uint8((v shr 8) and 0xFF'u64))
  w.writeByte(uint8(v and 0xFF'u64))

proc writeWordLE*(w: var ByteWriter; v: uint32) =
  w.writeByte(uint8(v and 0xFF'u32))
  w.writeByte(uint8((v shr 8) and 0xFF'u32))
  w.writeByte(uint8((v shr 16) and 0xFF'u32))
  w.writeByte(uint8((v shr 24) and 0xFF'u32))

proc initBitMemoryReader*(src: openArray[uint8]): BitMemoryReader =
  result.data = @src
  result.pos = 0
  result.wordBuffer = 0
  result.wordBufferPos = 0

proc getByte*(r: var BitMemoryReader): uint8 =
  if r.pos >= r.data.len:
    failBounds("BitMemoryReader.getByte", 1, r.data.len - r.pos)
  result = r.data[r.pos]
  inc r.pos

proc getBytes*(r: var BitMemoryReader; n: int): seq[uint8] =
  if (r.data.len - r.pos) < n:
    failBounds("BitMemoryReader.getBytes", n, r.data.len - r.pos)
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

proc getWord*(r: var BitMemoryReader): uint32 =
  var c = uint32(r.getByte())
  c = (c shl 8) or uint32(r.getByte())
  c = (c shl 8) or uint32(r.getByte())
  result = (c shl 8) or uint32(r.getByte())

proc getDWord*(r: var BitMemoryReader): uint64 =
  var c = uint64(r.getByte())
  for _ in 0 ..< 7:
    c = (c shl 8) or uint64(r.getByte())
  result = c

proc getBit*(r: var BitMemoryReader): uint32 =
  if r.wordBufferPos == 0:
    r.wordBuffer = uint32(r.getByte())
    r.wordBufferPos = 7
    return (r.wordBuffer shr 7) and 1'u32

  dec r.wordBufferPos
  (r.wordBuffer shr r.wordBufferPos) and 1'u32

proc get2Bits*(r: var BitMemoryReader): uint32 =
  if r.wordBufferPos >= 2:
    r.wordBufferPos -= 2
    return (r.wordBuffer shr r.wordBufferPos) and 3'u32

  if r.wordBufferPos == 0:
    r.wordBuffer = uint32(r.getByte())
    r.wordBufferPos = 6
    return (r.wordBuffer shr r.wordBufferPos) and 3'u32

  var word = (r.wordBuffer and 1'u32) shl 1
  r.wordBuffer = uint32(r.getByte())
  r.wordBufferPos = 7
  word += r.wordBuffer shr r.wordBufferPos
  word and 3'u32

proc getBits*(r: var BitMemoryReader; n: uint32): uint32 =
  doAssert n > 0'u32 and n < 32'u32
  var left = n
  var word = 0'u32
  while left > 0'u32:
    if r.wordBufferPos == 0:
      r.wordBuffer = uint32(r.getByte())
      r.wordBufferPos = 8

    if left > r.wordBufferPos:
      word = word shl r.wordBufferPos
      word += r.wordBuffer and bitMask(r.wordBufferPos)
      left -= r.wordBufferPos
      r.wordBufferPos = 0
    else:
      word = word shl left
      r.wordBufferPos -= left
      word += (r.wordBuffer shr r.wordBufferPos) and bitMask(left)
      break
  result = word

proc flushInputWordBuffer*(r: var BitMemoryReader) =
  r.wordBufferPos = 0

proc reset*(r: var BitMemoryReader) =
  r.pos = 0
  r.wordBuffer = 0
  r.wordBufferPos = 0

proc initBitMemoryWriter*(initialCapacity = 0): BitMemoryWriter =
  if initialCapacity > 0:
    result.data = newSeqOfCap[uint8](initialCapacity)
  else:
    result.data = @[]
  result.wordBuffer = 0
  result.wordBufferPos = 0

proc putByte*(w: var BitMemoryWriter; b: uint8) =
  w.data.add(b)

proc putBytes*(w: var BitMemoryWriter; src: openArray[uint8]) =
  w.data.add(src)

proc putWord*(w: var BitMemoryWriter; data: uint32) =
  w.putByte(uint8(data shr 24))
  w.putByte(uint8((data shr 16) and 0xFF'u32))
  w.putByte(uint8((data shr 8) and 0xFF'u32))
  w.putByte(uint8(data and 0xFF'u32))

proc putDWord*(w: var BitMemoryWriter; data: uint64) =
  w.putByte(uint8(data shr 56))
  w.putByte(uint8((data shr 48) and 0xFF'u64))
  w.putByte(uint8((data shr 40) and 0xFF'u64))
  w.putByte(uint8((data shr 32) and 0xFF'u64))
  w.putByte(uint8((data shr 24) and 0xFF'u64))
  w.putByte(uint8((data shr 16) and 0xFF'u64))
  w.putByte(uint8((data shr 8) and 0xFF'u64))
  w.putByte(uint8(data and 0xFF'u64))

proc putBit*(w: var BitMemoryWriter; b: uint32) =
  if w.wordBufferPos < 32'u32:
    w.wordBuffer = w.wordBuffer shl 1
    w.wordBuffer += (b and 1'u32)
    inc w.wordBufferPos
  else:
    w.putWord(w.wordBuffer)
    w.wordBufferPos = 1
    w.wordBuffer = b and 1'u32

proc put2Bits*(w: var BitMemoryWriter; word: uint32) =
  var bits = word and 3'u32
  if w.wordBufferPos + 2'u32 <= 32'u32:
    w.wordBuffer = w.wordBuffer shl 2
    w.wordBuffer += bits
    w.wordBufferPos += 2
  elif w.wordBufferPos == 32'u32:
    w.putWord(w.wordBuffer)
    w.wordBufferPos = 2
    w.wordBuffer = bits
  else:
    w.wordBuffer = w.wordBuffer shl 1
    w.wordBuffer += bits shr 1
    w.putWord(w.wordBuffer)
    w.wordBuffer = bits and 1'u32
    w.wordBufferPos = 1

proc putBits*(w: var BitMemoryWriter; word, n: uint32) =
  doAssert n > 0'u32 and n < 32'u32
  var nbits = n
  var value = word and bitMask(nbits)
  let rest = 32'u32 - w.wordBufferPos
  if nbits >= rest:
    nbits -= rest
    w.wordBuffer = w.wordBuffer shl rest
    w.wordBuffer += value shr nbits
    w.wordBufferPos = 0
    w.putWord(w.wordBuffer)
    w.wordBuffer = 0

  w.wordBuffer = w.wordBuffer shl nbits
  w.wordBuffer += value and bitMask(nbits)
  w.wordBufferPos += nbits

proc flushFullWordBuffer*(w: var BitMemoryWriter) =
  w.putWord(w.wordBuffer)
  w.wordBuffer = 0
  w.wordBufferPos = 0

proc flushPartialWordBuffer*(w: var BitMemoryWriter) =
  let shiftAmt = int((32'u32 - w.wordBufferPos) and 7'u32)
  w.wordBuffer = w.wordBuffer shl shiftAmt

  if w.wordBufferPos > 24'u32:
    w.putByte(uint8(w.wordBuffer shr 24))
  if w.wordBufferPos > 16'u32:
    w.putByte(uint8((w.wordBuffer shr 16) and 0xFF'u32))
  if w.wordBufferPos > 8'u32:
    w.putByte(uint8((w.wordBuffer shr 8) and 0xFF'u32))
  if w.wordBufferPos > 0'u32:
    w.putByte(uint8(w.wordBuffer and 0xFF'u32))

  w.wordBuffer = 0
  w.wordBufferPos = 0

proc flush*(w: var BitMemoryWriter) =
  w.flushPartialWordBuffer()

