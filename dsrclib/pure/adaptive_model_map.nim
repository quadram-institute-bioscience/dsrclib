## Flat open-address model map for hot order-N range coder contexts.
## Replaces std/tables hash map lookups in symbol-by-symbol loops.

import range_decoder

type
  AdaptiveSymbolCoderMap* = object
    keys: seq[uint64]
    occupied: seq[uint8]
    coders: seq[AdaptiveSymbolCoder]
    count: int
    symbolCount: int
    stepSize: uint16

proc nextPow2(x: int): int =
  var v = if x <= 1: 1 else: x - 1
  v = v or (v shr 1)
  v = v or (v shr 2)
  v = v or (v shr 4)
  v = v or (v shr 8)
  v = v or (v shr 16)
  when sizeof(int) >= 8:
    v = v or (v shr 32)
  v + 1

proc mix64(x: uint64): uint64 =
  var z = x + 0x9e3779b97f4a7c15'u64
  z = (z xor (z shr 30)) * 0xbf58476d1ce4e5b9'u64
  z = (z xor (z shr 27)) * 0x94d049bb133111eb'u64
  z xor (z shr 31)

proc initAdaptiveSymbolCoderMap*(
  initialCapacity: int;
  symbolCount: int;
  stepSize: uint16 = 2'u16
): AdaptiveSymbolCoderMap =
  doAssert symbolCount > 0
  let cap = max(64, nextPow2(initialCapacity))
  result.keys = newSeq[uint64](cap)
  result.occupied = newSeq[uint8](cap)
  result.coders = newSeq[AdaptiveSymbolCoder](cap)
  result.count = 0
  result.symbolCount = symbolCount
  result.stepSize = stepSize

proc rehash(m: var AdaptiveSymbolCoderMap; newCap: int) =
  let oldKeys = m.keys
  let oldOccupied = m.occupied
  let oldCoders = m.coders

  m.keys = newSeq[uint64](newCap)
  m.occupied = newSeq[uint8](newCap)
  m.coders = newSeq[AdaptiveSymbolCoder](newCap)
  m.count = 0

  let mask = uint64(newCap - 1)
  for i in 0 ..< oldKeys.len:
    if oldOccupied[i] == 0'u8:
      continue
    let key = oldKeys[i]
    var idx = int(mix64(key) and mask)
    while m.occupied[idx] != 0'u8:
      idx = (idx + 1) and (newCap - 1)
    m.occupied[idx] = 1'u8
    m.keys[idx] = key
    m.coders[idx] = oldCoders[i]
    inc m.count

proc ensureCapacity(m: var AdaptiveSymbolCoderMap) =
  # Resize at ~70% load factor.
  if m.count * 10 < m.keys.len * 7:
    return
  m.rehash(m.keys.len shl 1)

proc getOrInit*(
  m: var AdaptiveSymbolCoderMap;
  key: uint64
): var AdaptiveSymbolCoder =
  doAssert m.keys.len > 0
  m.ensureCapacity()

  let cap = m.keys.len
  let mask = uint64(cap - 1)
  var idx = int(mix64(key) and mask)

  while true:
    if m.occupied[idx] == 0'u8:
      m.occupied[idx] = 1'u8
      m.keys[idx] = key
      m.coders[idx] = initAdaptiveSymbolCoder(m.symbolCount, m.stepSize)
      inc m.count
      return m.coders[idx]
    if m.keys[idx] == key:
      return m.coders[idx]
    idx = (idx + 1) and (cap - 1)

  doAssert false, "unreachable"
  return m.coders[0]
