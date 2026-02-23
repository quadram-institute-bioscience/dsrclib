## Tag decode side for DSRC chunk pipeline (PN-007 decode bootstrap).
## Implements TagRawDecoder and TagTokenizerDecoder logic from DSRC.

import types, bitstream, chunk_decoder

const
  MaxSymbolCount = 128
  MaxFieldStatLen = 128

  SchemeNone = 0'u8
  SchemeValueVar = 1'u8
  SchemeValueRle = 2'u8
  SchemeDeltaVar = 3'u8
  SchemeDeltaRle = 4'u8
  SchemeDeltaConst = 5'u8

type
  HuffNode = object
    leftChild: int32
    rightChild: int32

  HuffmanDecoder = object
    nSymbols: uint32
    minLen: uint32
    bitsPerId: uint32
    rootId: int32
    curId: int32
    tmpId: int32
    tree: seq[HuffNode]
    speedupTree: seq[int32]

  RleState = object
    curSym: int32
    curLen: uint32

  TagField = object
    sep: char
    isConstant: bool
    isNumeric: bool
    isLenConstant: bool
    len: uint32
    minLen: uint32
    maxLen: uint32
    minValue: int32
    maxValue: int32
    minDelta: int32
    maxDelta: int32
    bitsPerNum: uint32
    bitsPerValue: uint32
    bitsPerLen: uint32
    isDeltaCoding: bool
    isDeltaConst: bool
    varStatEncode: bool
    numericScheme: uint8
    data: string
    hamMask: seq[bool]
    globalTreePresent: bool
    globalTree: HuffmanDecoder
    localTreePresent: seq[bool]
    localTrees: seq[HuffmanDecoder]
    rleDelta: RleState

  TagRawDecoder = object
    symbolCount: uint32
    symbols: array[MaxSymbolCount, char]
    titleLenBits: uint32
    minTitleLen: uint32
    maxTitleLen: uint32
    huf: HuffmanDecoder

  TagTokenizerDecoder = object
    fields: seq[TagField]
    prevFieldValues: seq[int32]
    recordCounter: uint32

proc intLog(x, base: uint32): uint32 =
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

proc bitLength32(x: uint32): uint32 =
  if x == 0'u32:
    return 0'u32
  var t = x
  while t > 0'u32:
    inc result
    t = t shr 1

proc decodeBit(h: var HuffmanDecoder; bit: uint32): int32 =
  if h.curId <= 0:
    h.curId = h.rootId
  if bit != 0'u32:
    h.curId = h.tree[h.curId].rightChild
  else:
    h.curId = h.tree[h.curId].leftChild
  if h.curId <= 0:
    return -h.curId
  -1

proc decodeFast(h: var HuffmanDecoder; bits: uint32): int32 =
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

proc loadTree(h: var HuffmanDecoder; reader: var BitMemoryReader) =
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

proc decodeSymbol(h: var HuffmanDecoder; reader: var BitMemoryReader): int32 =
  var bit = reader.getBits(h.minLen)
  var sym = h.decodeFast(bit)
  while sym < 0:
    bit = reader.getBit()
    sym = h.decodeBit(bit)
  sym

proc startDecoding(d: var TagRawDecoder; reader: var BitMemoryReader) =
  d.minTitleLen = reader.getWord()
  d.maxTitleLen = reader.getWord()
  d.titleLenBits = bitLength32(d.maxTitleLen - d.minTitleLen)

  d.symbolCount = 0'u32
  for i in 0 ..< MaxSymbolCount:
    if reader.getBit() != 0'u32:
      d.symbols[int(d.symbolCount)] = char(i)
      inc d.symbolCount
  doAssert d.symbolCount > 0'u32

  d.huf.loadTree(reader)

proc decodeNextTitle(d: var TagRawDecoder; reader: var BitMemoryReader): string =
  let titleLen = if d.titleLenBits > 0'u32:
      reader.getBits(d.titleLenBits) + d.minTitleLen
    else:
      d.maxTitleLen
  result = newString(int(titleLen))
  for i in 0 ..< int(titleLen):
    let sidx = d.huf.decodeSymbol(reader)
    doAssert sidx >= 0 and sidx < int32(d.symbolCount)
    result[i] = d.symbols[sidx.int]

proc finishDecoding(d: var TagRawDecoder; reader: var BitMemoryReader) =
  discard d
  reader.flushInputWordBuffer()

proc readFields(d: var TagTokenizerDecoder; reader: var BitMemoryReader) =
  let nField = int(reader.getByte())
  doAssert nField > 0
  d.fields = newSeq[TagField](nField)

  for i in 0 ..< nField:
    var field = TagField()
    field.sep = char(reader.getByte())
    field.isConstant = reader.getByte() != 0'u8

    if field.isConstant:
      field.len = reader.getWord()
      doAssert field.len < (1'u32 shl 10)
      let raw = reader.getBytes(int(field.len))
      field.data = newString(int(field.len))
      for k in 0 ..< raw.len:
        field.data[k] = char(raw[k])
      d.fields[i] = field
      continue

    field.isNumeric = reader.getByte() != 0'u8
    if field.isNumeric:
      field.numericScheme = reader.getByte()
      doAssert field.numericScheme >= SchemeValueVar and field.numericScheme <= SchemeDeltaConst

      field.minValue = int32(reader.getWord())
      field.maxValue = int32(reader.getWord())
      doAssert field.minValue <= field.maxValue
      field.bitsPerValue = bitLength32(uint32(field.maxValue - field.minValue))
      field.bitsPerNum = 0'u32

      case field.numericScheme
      of SchemeDeltaConst, SchemeDeltaRle, SchemeDeltaVar:
        field.minDelta = int32(reader.getWord())
        field.maxDelta = int32(reader.getWord())
        doAssert field.minDelta <= field.maxDelta
        field.bitsPerNum = bitLength32(uint32(field.maxDelta - field.minDelta))
        field.isDeltaCoding = true
        field.isDeltaConst = field.numericScheme == SchemeDeltaConst
        if field.numericScheme == SchemeDeltaVar:
          field.varStatEncode = reader.getByte() != 0'u8
          if field.varStatEncode:
            field.globalTreePresent = true
            field.globalTree.loadTree(reader)
      of SchemeValueRle:
        field.bitsPerNum = field.bitsPerValue
        field.isDeltaCoding = false
      of SchemeValueVar:
        field.bitsPerNum = field.bitsPerValue
        field.varStatEncode = reader.getByte() != 0'u8
        if field.varStatEncode:
          field.globalTreePresent = true
          field.globalTree.loadTree(reader)
        field.isDeltaCoding = false
      else:
        doAssert false

      d.fields[i] = field
      continue

    field.isLenConstant = reader.getByte() != 0'u8
    field.len = reader.getWord()
    doAssert field.len < (1'u32 shl 10)
    field.maxLen = reader.getWord()
    doAssert field.maxLen < (1'u32 shl 10)
    field.minLen = reader.getWord()
    doAssert field.minLen < (1'u32 shl 10)
    field.bitsPerLen = bitLength32(field.maxLen - field.minLen)

    let raw = reader.getBytes(int(field.len))
    field.data = newString(int(field.len))
    for k in 0 ..< raw.len:
      field.data[k] = char(raw[k])

    field.hamMask = newSeq[bool](int(field.len))
    for j in 0 ..< int(field.len):
      field.hamMask[j] = reader.getBit() != 0'u32
    reader.flushInputWordBuffer()

    # Keep a fixed [0..128] local tree slot layout matching DSRC's MIN(k, 128)
    # decode lookup pattern.
    field.localTrees = newSeq[HuffmanDecoder](MaxFieldStatLen + 1)
    field.localTreePresent = newSeq[bool](MaxFieldStatLen + 1)

    let maxJ = int(min(field.maxLen, uint32(MaxFieldStatLen)))
    for j in 0 ..< maxJ:
      if uint32(j) >= field.len or not field.hamMask[j]:
        field.localTreePresent[j] = true
        field.localTrees[j].loadTree(reader)

    if field.maxLen >= uint32(MaxFieldStatLen):
      let overflowSlot = int(min(field.maxLen, uint32(MaxFieldStatLen)))
      field.localTreePresent[overflowSlot] = true
      field.localTrees[overflowSlot].loadTree(reader)

    d.fields[i] = field

proc startDecoding(d: var TagTokenizerDecoder; reader: var BitMemoryReader) =
  d.readFields(reader)
  d.recordCounter = 0'u32
  d.prevFieldValues = newSeq[int32](d.fields.len)

proc readNumericField(
  d: var TagTokenizerDecoder;
  reader: var BitMemoryReader;
  fieldIdx: int
): uint32 =
  var numVal = 0'u32
  let field = addr d.fields[fieldIdx]
  let prevValue = d.prevFieldValues[fieldIdx]

  if d.recordCounter == 0'u32:
    numVal = if field[].bitsPerValue > 0'u32: reader.getBits(field[].bitsPerValue) else: 0'u32
    if field[].numericScheme == SchemeValueRle:
      field[].rleDelta.curLen = reader.getBits(8'u32)
      field[].rleDelta.curSym = int32(numVal)
    numVal += uint32(field[].minValue)
    return numVal

  case field[].numericScheme
  of SchemeDeltaConst:
    numVal = uint32(prevValue + field[].minDelta)
  of SchemeDeltaRle:
    if d.recordCounter == 1'u32:
      numVal = if field[].bitsPerNum > 0'u32: reader.getBits(field[].bitsPerNum) else: 0'u32
      field[].rleDelta.curSym = int32(numVal)
      field[].rleDelta.curLen = reader.getBits(8'u32)
    else:
      if field[].rleDelta.curLen == 0'u32:
        numVal = if field[].bitsPerNum > 0'u32: reader.getBits(field[].bitsPerNum) else: 0'u32
        field[].rleDelta.curSym = int32(numVal)
        field[].rleDelta.curLen = reader.getBits(8'u32)
      else:
        dec field[].rleDelta.curLen
        numVal = uint32(field[].rleDelta.curSym)
    numVal += uint32(prevValue + field[].minDelta)
  of SchemeValueVar, SchemeDeltaVar:
    if field[].globalTreePresent:
      numVal = uint32(field[].globalTree.decodeSymbol(reader))
    else:
      numVal = if field[].bitsPerNum > 0'u32: reader.getBits(field[].bitsPerNum) else: 0'u32
    if field[].numericScheme == SchemeDeltaVar:
      numVal += uint32(prevValue + field[].minDelta)
    else:
      numVal += uint32(field[].minValue)
  of SchemeValueRle:
    if field[].rleDelta.curLen == 0'u32:
      numVal = if field[].bitsPerNum > 0'u32: reader.getBits(field[].bitsPerNum) else: 0'u32
      field[].rleDelta.curSym = int32(numVal)
      field[].rleDelta.curLen = reader.getBits(8'u32)
    else:
      dec field[].rleDelta.curLen
      numVal = uint32(field[].rleDelta.curSym)
    numVal += uint32(field[].minValue)
  else:
    doAssert false

  numVal

proc decodeNextTitle(d: var TagTokenizerDecoder; reader: var BitMemoryReader): string =
  var titleBuf = newStringOfCap(128)
  for j in 0 ..< d.fields.len:
    let field = addr d.fields[j]
    if field[].isConstant:
      titleBuf.add(field[].data)
      titleBuf.add(field[].sep)
      continue

    if field[].isNumeric:
      let numVal = d.readNumericField(reader, j)
      titleBuf.add($numVal)
      d.prevFieldValues[j] = int32(numVal)
      titleBuf.add(field[].sep)
      continue

    var fieldLen = 0'u32
    if not field[].isLenConstant:
      fieldLen = if field[].bitsPerLen > 0'u32: reader.getBits(field[].bitsPerLen) + field[].minLen else: field[].minLen
    else:
      fieldLen = field[].len
    doAssert fieldLen <= field[].maxLen

    for k in 0 ..< int(fieldLen):
      if uint32(k) < field[].len and field[].hamMask[k]:
        titleBuf.add(field[].data[k])
      else:
        let idx = min(k, MaxFieldStatLen)
        doAssert idx < field[].localTreePresent.len
        doAssert field[].localTreePresent[idx]
        let sym = field[].localTrees[idx].decodeSymbol(reader)
        titleBuf.add(char(sym))
    titleBuf.add(field[].sep)

  if titleBuf.len > 0:
    titleBuf.setLen(titleBuf.len - 1) # do not count last separator
  inc d.recordCounter
  result = titleBuf

proc canUseSingleVarTextFastPath(d: TagTokenizerDecoder): bool =
  if d.fields.len != 1:
    return false
  let field = d.fields[0]
  if field.isConstant or field.isNumeric:
    return false
  if field.len != 0'u32:
    return false
  if field.hamMask.len != 0:
    return false
  let maxJ = int(min(field.maxLen, uint32(MaxFieldStatLen)))
  for j in 0 ..< maxJ:
    if not field.localTreePresent[j]:
      return false
  if field.maxLen >= uint32(MaxFieldStatLen) and not field.localTreePresent[MaxFieldStatLen]:
    return false
  true

proc decodeNextTitleSingleVarText(d: var TagTokenizerDecoder; reader: var BitMemoryReader): string =
  let field = addr d.fields[0]
  var fieldLen = 0'u32
  if not field[].isLenConstant:
    fieldLen = if field[].bitsPerLen > 0'u32:
        reader.getBits(field[].bitsPerLen) + field[].minLen
      else:
        field[].minLen
  else:
    fieldLen = field[].len
  doAssert fieldLen <= field[].maxLen

  let n = int(fieldLen)
  result = newString(n)
  for k in 0 ..< n:
    let idx = min(k, MaxFieldStatLen)
    result[k] = char(field[].localTrees[idx].decodeSymbol(reader))
  inc d.recordCounter

proc finishDecoding(d: var TagTokenizerDecoder; reader: var BitMemoryReader) =
  discard d
  reader.flushInputWordBuffer()

proc decodeTagAndLengthsHook*(
  reader: var BitMemoryReader;
  state: var ChunkDecodeState
) {.gcsafe.} =
  let useRaw = (state.header.flags and FlagMixedFieldFormatting) != 0'u32
  let lenBits = qualityLengthBitWidth(state.header)
  let isVariableLen = lenBits > 0'u32

  if useRaw:
    var dec = TagRawDecoder()
    dec.startDecoding(reader)
    for rec in mitems(state.records):
      rec.title = dec.decodeNextTitle(reader)

      let qLen = if isVariableLen:
          reader.getBits(lenBits) + state.header.minQuaLength
        else:
          state.header.maxQuaLength
      let qLenInt = int(qLen)
      rec.quality = newString(qLenInt)
      rec.sequence = newString(qLenInt)
    dec.finishDecoding(reader)
    return

  var dec = TagTokenizerDecoder()
  dec.startDecoding(reader)
  let fastOneField = dec.canUseSingleVarTextFastPath()
  for rec in mitems(state.records):
    if fastOneField:
      rec.title = dec.decodeNextTitleSingleVarText(reader)
    else:
      rec.title = dec.decodeNextTitle(reader)

    let qLen = if isVariableLen:
        reader.getBits(lenBits) + state.header.minQuaLength
      else:
        state.header.maxQuaLength
    let qLenInt = int(qLen)
    rec.quality = newString(qLenInt)
    rec.sequence = newString(qLenInt)
  dec.finishDecoding(reader)
