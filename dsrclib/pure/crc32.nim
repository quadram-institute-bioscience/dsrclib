## DSRC-compatible CRC32 (LSB) hasher.
## Mirrors DSRC C++ defaults:
## - polynomial: 0xEDB88320
## - seed:       0xFFFFFFFF
## - xor-out:    0xFFFFFFFF

type
  Crc32Hasher* = object
    polynomial*: uint32
    crc*: uint32
    lookupTable*: array[256, uint32]

proc fillLookupTable(h: var Crc32Hasher) =
  h.lookupTable[0] = 0'u32
  for i in 1'u32 .. 255'u32:
    var v = i
    for _ in 0 ..< 8:
      if (v and 1'u32) != 0'u32:
        v = h.polynomial xor (v shr 1)
      else:
        v = v shr 1
    h.lookupTable[i] = v

proc initCrc32Hasher*(polynomial = 0xEDB88320'u32; seed = 0xFFFFFFFF'u32): Crc32Hasher =
  result.polynomial = polynomial
  result.crc = seed
  result.fillLookupTable()

proc reset*(h: var Crc32Hasher; polynomial = 0xEDB88320'u32; seed = 0xFFFFFFFF'u32) =
  if h.polynomial != polynomial:
    h.polynomial = polynomial
    h.fillLookupTable()
  h.crc = seed

proc update*(h: var Crc32Hasher; b: uint8) =
  h.crc = (h.crc shr 8) xor h.lookupTable[(uint32(b) xor h.crc) and 0xFF'u32]

proc update*(h: var Crc32Hasher; data: openArray[uint8]) =
  for b in data:
    h.update(b)

proc update*(h: var Crc32Hasher; s: string) =
  for ch in s:
    h.update(uint8(ord(ch)))

proc digest*(h: Crc32Hasher): uint32 =
  h.crc xor 0xFFFFFFFF'u32

proc computeCrc32*(data: openArray[uint8]): uint32 =
  var h = initCrc32Hasher()
  h.update(data)
  h.digest()

