## Lossless/lossy records processor and checksum flow (PN-006).
## Ported from DSRC RecordsProcessor.{h,cpp} for pure-Nim backend work.

import types, crc32

const
  InvalidValue = 255'u8
  Deltas: array[24, char] = [
    'N', 'N', 'A', 'C', 'G', 'T',
    'N', 'N', 'C', 'A', 'T', 'G',
    'N', 'N', 'G', 'T', 'A', 'C',
    'N', 'N', 'T', 'G', 'C', 'A'
  ]

type
  FastqChecksumHasher = object
    flags: uint32
    hashers: array[3, Crc32Hasher]

  LosslessRecordsProcessor* = object
    qualityOffset*: uint32
    colorSpace*: bool
    dnaStats*: DnaStats
    qualityStats*: QualityStats
    csStats*: ColorSpaceStats
    fastqHasher: FastqChecksumHasher
    dnaToIndexTable: array[128, uint8]
    dnaFromIndexTable: array[20, uint8]

  LossyRecordsProcessor* = object
    base*: LosslessRecordsProcessor
    qualityToIndexTable: array[64, uint8]
    qualityFromIndexTable: array[8, uint8]

proc cloneString(s: string): string {.inline.} =
  result = newString(s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc prependCharInPlace(s: var string; ch: char) {.inline.} =
  let oldLen = s.len
  s.setLen(oldLen + 1)
  if oldLen > 0:
    moveMem(addr s[1], addr s[0], oldLen)
  s[0] = ch

proc initFastqChecksumHasher(): FastqChecksumHasher =
  result.flags = ChecksumCalcNone
  for i in 0 ..< result.hashers.len:
    result.hashers[i] = initCrc32Hasher()

proc setFlags(h: var FastqChecksumHasher; flags: uint32) =
  h.flags = flags

proc reset(h: var FastqChecksumHasher) =
  for i in 0 ..< h.hashers.len:
    h.hashers[i].reset()

proc update(h: var FastqChecksumHasher; rec: PureFastqRecord) =
  if (h.flags and ChecksumCalcTag) != 0'u32:
    h.hashers[0].update(rec.title)
  if (h.flags and ChecksumCalcSequence) != 0'u32:
    h.hashers[1].update(rec.sequence)
  if (h.flags and ChecksumCalcQuality) != 0'u32:
    h.hashers[2].update(rec.quality)

proc checksum(h: FastqChecksumHasher): FastqChecksum =
  result.tag = h.hashers[0].digest()
  result.sequence = h.hashers[1].digest()
  result.quality = h.hashers[2].digest()

proc initLosslessRecordsProcessor*(
  qualityOffset = 33'u32;
  colorSpace = false
): LosslessRecordsProcessor =
  doAssert qualityOffset >= 33'u32 and qualityOffset <= 64'u32
  result.qualityOffset = qualityOffset
  result.colorSpace = colorSpace
  result.fastqHasher = initFastqChecksumHasher()

  result.dnaStats.clear()
  result.qualityStats.clear()
  result.csStats.clear()

  for i in 0 ..< result.dnaToIndexTable.len:
    result.dnaToIndexTable[i] = InvalidValue
  for i in 0 ..< result.dnaFromIndexTable.len:
    result.dnaFromIndexTable[i] = InvalidValue

  # Normal symbols
  result.dnaToIndexTable[ord('A')] = 0'u8; result.dnaFromIndexTable[0] = uint8(ord('A'))
  result.dnaToIndexTable[ord('G')] = 1'u8; result.dnaFromIndexTable[1] = uint8(ord('G'))
  result.dnaToIndexTable[ord('C')] = 2'u8; result.dnaFromIndexTable[2] = uint8(ord('C'))
  result.dnaToIndexTable[ord('T')] = 3'u8; result.dnaFromIndexTable[3] = uint8(ord('T'))
  # IUPAC ambiguous symbols
  result.dnaToIndexTable[ord('N')] = 4'u8; result.dnaFromIndexTable[4] = uint8(ord('N'))
  result.dnaToIndexTable[ord('R')] = 5'u8; result.dnaFromIndexTable[5] = uint8(ord('R'))
  result.dnaToIndexTable[ord('W')] = 6'u8; result.dnaFromIndexTable[6] = uint8(ord('W'))
  result.dnaToIndexTable[ord('S')] = 7'u8; result.dnaFromIndexTable[7] = uint8(ord('S'))
  result.dnaToIndexTable[ord('K')] = 8'u8; result.dnaFromIndexTable[8] = uint8(ord('K'))
  result.dnaToIndexTable[ord('M')] = 9'u8; result.dnaFromIndexTable[9] = uint8(ord('M'))
  result.dnaToIndexTable[ord('D')] = 10'u8; result.dnaFromIndexTable[10] = uint8(ord('D'))
  result.dnaToIndexTable[ord('V')] = 11'u8; result.dnaFromIndexTable[11] = uint8(ord('V'))
  result.dnaToIndexTable[ord('H')] = 12'u8; result.dnaFromIndexTable[12] = uint8(ord('H'))
  result.dnaToIndexTable[ord('B')] = 13'u8; result.dnaFromIndexTable[13] = uint8(ord('B'))
  result.dnaToIndexTable[ord('Y')] = 14'u8; result.dnaFromIndexTable[14] = uint8(ord('Y'))
  result.dnaToIndexTable[ord('X')] = 15'u8; result.dnaFromIndexTable[15] = uint8(ord('X'))
  result.dnaToIndexTable[ord('U')] = 16'u8; result.dnaFromIndexTable[16] = uint8(ord('U'))
  result.dnaToIndexTable[ord('.')] = 17'u8; result.dnaFromIndexTable[17] = uint8(ord('.'))
  result.dnaToIndexTable[ord('-')] = 18'u8; result.dnaFromIndexTable[18] = uint8(ord('-'))

proc initializeStats*(p: var LosslessRecordsProcessor) =
  p.dnaStats.clear()
  p.qualityStats.clear()
  p.csStats.clear()

proc finalizeStats*(p: var LosslessRecordsProcessor) =
  p.dnaStats.symbolCount = 0'u32
  for i in 0 ..< p.dnaStats.symbolFreqs.len:
    if p.dnaStats.symbolFreqs[i] > 0'u32:
      p.dnaStats.symbols[i] = uint8(p.dnaStats.symbolCount)
      inc p.dnaStats.symbolCount

  p.qualityStats.symbolCount = 0'u32
  for i in 0 ..< p.qualityStats.symbolFreqs.len:
    if p.qualityStats.symbolFreqs[i] > 0'u32:
      p.qualityStats.symbols[i] = uint8(p.qualityStats.symbolCount)
      inc p.qualityStats.symbolCount

proc setColorSpaceStats*(p: var LosslessRecordsProcessor; stats: ColorSpaceStats) =
  p.csStats = stats

proc findDeltaIndex(start: int; sym: uint8): int =
  for i in 0 ..< 6:
    if uint8(ord(Deltas[start + i])) == sym:
      return i
  # Keep DSRC's permissive behavior for malformed symbols.
  6

proc processRecordFromColorSpace(rec: var PureFastqRecord) =
  if rec.sequence.len == 0:
    return

  var symbol = uint8(ord(rec.sequence[0]))
  var lastMatrixStart = 0
  for k in 1 ..< rec.sequence.len:
    case char(symbol)
    of 'A': lastMatrixStart = 0
    of 'C': lastMatrixStart = 6
    of 'G': lastMatrixStart = 12
    of 'T': lastMatrixStart = 18
    else: discard

    let idx = ord(rec.sequence[k]) - ord('.')
    doAssert idx >= 0 and idx < 6
    symbol = uint8(ord(Deltas[lastMatrixStart + idx]))
    rec.sequence[k] = char(symbol)

proc processRecordToColorSpace(
  rec: var PureFastqRecord;
  useConstDelta: bool;
  seqStart: uint8;
  quaStart: uint8
) =
  if useConstDelta:
    rec.sequence.prependCharInPlace(char(seqStart))
    rec.quality.prependCharInPlace(char(quaStart))
  elif rec.sequence.len > 0 and rec.quality.len > 0:
    rec.sequence[0] = char(seqStart)
    rec.quality[0] = char(quaStart)

  var symbol = seqStart
  for k in 1 ..< rec.sequence.len:
    var dSelectStart = 0
    case char(symbol)
    of 'A': dSelectStart = 0
    of 'C': dSelectStart = 6
    of 'G': dSelectStart = 12
    of 'T': dSelectStart = 18
    else: discard

    symbol = uint8(ord(rec.sequence[k]))
    let deltaIdx = findDeltaIndex(dSelectStart, symbol)
    rec.sequence[k] = char(ord('.') + deltaIdx)

proc processFromColorSpace(p: var LosslessRecordsProcessor; rec: var PureFastqRecord) =
  processRecordFromColorSpace(rec)
  if rec.sequence.len == 0 or rec.quality.len == 0:
    return

  if p.csStats.seqBegin == EmptyStatSymbol:
    p.csStats.seqBegin = uint8(ord(rec.sequence[0]))
    p.csStats.quaBegin = uint8(ord(rec.quality[0]))

  p.csStats.constBeginSym = p.csStats.constBeginSym and (p.csStats.seqBegin == uint8(ord(rec.sequence[0])))
  doAssert (not p.csStats.constBeginSym) or (p.csStats.quaBegin == uint8(ord(rec.quality[0])))

proc processToColorSpace(
  p: var LosslessRecordsProcessor;
  rec: var PureFastqRecord;
  seq0: uint8;
  qua0: uint8
) =
  processRecordToColorSpace(rec, p.csStats.constBeginSym, seq0, qua0)

proc processForwardRecord(p: var LosslessRecordsProcessor; rec: var PureFastqRecord) =
  doAssert rec.sequence.len == rec.quality.len

  if p.colorSpace:
    p.processFromColorSpace(rec)

  let qLen = rec.quality.len
  var seqWrite = 0
  var prevQSymbol = 255
  var curQThLen = 0'u32

  for i in 0 ..< qLen:
    let seqOrd = ord(rec.sequence[i])
    doAssert seqOrd >= 0 and seqOrd < p.dnaToIndexTable.len
    let seqVal = p.dnaToIndexTable[seqOrd]
    doAssert seqVal != InvalidValue

    var qval = ord(rec.quality[i]) - int(p.qualityOffset)
    doAssert qval >= 0 and qval <= 255

    # Transfer ambiguous DNA symbol into quality stream when quality bin is small.
    if seqVal > 3'u8 and qval < 7:
      qval += int(128'u32 + (((uint32(seqVal) - 3'u32 + 1'u32) shl 3) - 16'u32))
    else:
      rec.sequence[seqWrite] = char(seqVal)
      inc seqWrite
      p.dnaStats.symbolFreqs[int(seqVal)] += 1'u32

    doAssert qval >= 0 and qval <= 255
    rec.quality[i] = char(uint8(qval))
    p.qualityStats.symbolFreqs[qval] += 1'u32

    if qval != prevQSymbol:
      p.qualityStats.rleLength += 1'u32
    if qval != int(HashSymbolNormal):
      curQThLen = uint32(i)
    prevQSymbol = qval

  rec.sequence.setLen(seqWrite)
  rec.truncatedLen = uint16(curQThLen + (if qLen > 0: 1'u32 else: 0'u32))

  if prevQSymbol == int(HashSymbolNormal) and p.qualityStats.rleLength > 0'u32:
    p.qualityStats.rleLength -= 1'u32

  p.qualityStats.rawLength += uint32(qLen)
  p.qualityStats.thLength += curQThLen
  if uint32(qLen) < p.qualityStats.minLength:
    p.qualityStats.minLength = uint32(qLen)
  if uint32(qLen) > p.qualityStats.maxLength:
    p.qualityStats.maxLength = uint32(qLen)

proc processBackwardRecord(p: var LosslessRecordsProcessor; rec: var PureFastqRecord) =
  let qLen = rec.quality.len
  var needsSeqCopy = false
  for i in 0 ..< qLen:
    if ord(rec.quality[i]) >= 128:
      needsSeqCopy = true
      break

  var packedSeq = if needsSeqCopy: cloneString(rec.sequence) else: rec.sequence
  var seqi = packedSeq.len - 1
  rec.sequence.setLen(qLen)

  if qLen > 0:
    for i in countdown(qLen - 1, 0):
      var qval = ord(rec.quality[i])
      var seqval = 0

      if qval >= 128:
        seqval = ((qval - 128 + 16) div 8) + 3 - 1
        doAssert seqval <= 18
        qval = qval and 7
      else:
        doAssert seqi >= 0
        seqval = ord(packedSeq[seqi])
        dec seqi

      doAssert seqval >= 0 and seqval < p.dnaFromIndexTable.len
      rec.sequence[i] = char(p.dnaFromIndexTable[seqval])
      rec.quality[i] = char(uint8(int(p.qualityOffset) + qval))

  if p.colorSpace and rec.sequence.len > 0 and rec.quality.len > 0:
    var seq0 = uint8(ord(rec.sequence[0]))
    var qua0 = uint8(ord(rec.quality[0]))

    if p.csStats.constBeginSym:
      seq0 = p.csStats.seqBegin
      qua0 = p.csStats.quaBegin

    # Handle both "stored as index" and "stored as symbol" cases safely.
    if int(seq0) < p.dnaFromIndexTable.len:
      seq0 = p.dnaFromIndexTable[int(seq0)]

    p.processToColorSpace(rec, seq0, qua0)

proc processForward*(
  p: var LosslessRecordsProcessor;
  records: var seq[PureFastqRecord];
  flags: uint32 = ChecksumCalcNone
): FastqChecksum =
  result.clear()
  if flags == ChecksumCalcNone:
    for rec in mitems(records):
      p.processForwardRecord(rec)
    return result

  p.fastqHasher.reset()
  p.fastqHasher.setFlags(flags)
  for rec in mitems(records):
    p.fastqHasher.update(rec)
    p.processForwardRecord(rec)
  result = p.fastqHasher.checksum()

proc processBackward*(
  p: var LosslessRecordsProcessor;
  records: var seq[PureFastqRecord];
  flags: uint32 = ChecksumCalcNone
): FastqChecksum =
  result.clear()
  if flags == ChecksumCalcNone:
    for rec in mitems(records):
      p.processBackwardRecord(rec)
    return result

  p.fastqHasher.reset()
  p.fastqHasher.setFlags(flags)
  for rec in mitems(records):
    p.processBackwardRecord(rec)
    p.fastqHasher.update(rec)
  result = p.fastqHasher.checksum()

proc initLossyRecordsProcessor*(
  qualityOffset = 33'u32;
  colorSpace = false
): LossyRecordsProcessor =
  result.base = initLosslessRecordsProcessor(qualityOffset = qualityOffset, colorSpace = colorSpace)

  for i in 0 ..< result.qualityToIndexTable.len:
    result.qualityToIndexTable[i] = InvalidValue
  for i in 0 ..< result.qualityFromIndexTable.len:
    result.qualityFromIndexTable[i] = InvalidValue

  let ranges = [0'u32, 2'u32, 10'u32, 20'u32, 25'u32, 30'u32, 35'u32, 40'u32, 64'u32]
  let qValues = [0'u8, 6'u8, 15'u8, 22'u8, 27'u8, 33'u8, 37'u8, 40'u8]
  let iValues = [0'u8, 1'u8, 2'u8, 3'u8, 4'u8, 5'u8, 6'u8, 7'u8]

  for i in 0 ..< 8:
    let r0 = int(ranges[i])
    let r1 = int(ranges[i + 1])
    for j in r0 ..< r1:
      result.qualityToIndexTable[j] = iValues[i]

  for i in 0 ..< 8:
    result.qualityFromIndexTable[i] = qValues[i]

proc initializeStats*(p: var LossyRecordsProcessor) =
  p.base.initializeStats()

proc finalizeStats*(p: var LossyRecordsProcessor) =
  p.base.finalizeStats()
  doAssert p.base.dnaStats.symbolCount <= 4'u32
  doAssert p.base.qualityStats.symbolCount <= 8'u32

proc setColorSpaceStats*(p: var LossyRecordsProcessor; stats: ColorSpaceStats) =
  p.base.setColorSpaceStats(stats)

proc processForwardRecord(p: var LossyRecordsProcessor; rec: var PureFastqRecord) =
  doAssert rec.sequence.len == rec.quality.len

  if p.base.colorSpace:
    p.base.processFromColorSpace(rec)

  let qLen = rec.quality.len
  var seqWrite = 0
  var prevQSymbol = 255
  var curQThLen = 0'u32

  for i in 0 ..< qLen:
    let seqOrd = ord(rec.sequence[i])
    doAssert seqOrd >= 0 and seqOrd < p.base.dnaToIndexTable.len
    let seqVal = p.base.dnaToIndexTable[seqOrd]
    doAssert seqVal != InvalidValue

    let qRaw = ord(rec.quality[i]) - int(p.base.qualityOffset)
    doAssert qRaw >= 0 and qRaw < 45 # DSRC invariant for lossy path
    var qval = int(p.qualityToIndexTable[qRaw])
    doAssert qval >= 0 and qval <= 7

    if seqVal >= 4'u8:
      if qval != 0:
        qval = 0
    else:
      if qval == 0:
        qval = 1
      rec.sequence[seqWrite] = char(seqVal)
      inc seqWrite
      p.base.dnaStats.symbolFreqs[int(seqVal)] += 1'u32

    rec.quality[i] = char(uint8(qval))
    p.base.qualityStats.symbolFreqs[qval] += 1'u32

    if qval != prevQSymbol:
      p.base.qualityStats.rleLength += 1'u32
    if qval != int(HashSymbolNormal):
      curQThLen = uint32(i)
    prevQSymbol = qval

  rec.sequence.setLen(seqWrite)
  rec.truncatedLen = uint16(curQThLen + (if qLen > 0: 1'u32 else: 0'u32))

  if prevQSymbol == int(HashSymbolNormal) and p.base.qualityStats.rleLength > 0'u32:
    p.base.qualityStats.rleLength -= 1'u32

  p.base.qualityStats.rawLength += uint32(qLen)
  p.base.qualityStats.thLength += curQThLen
  if uint32(qLen) < p.base.qualityStats.minLength:
    p.base.qualityStats.minLength = uint32(qLen)
  if uint32(qLen) > p.base.qualityStats.maxLength:
    p.base.qualityStats.maxLength = uint32(qLen)

proc processBackwardRecord(p: var LossyRecordsProcessor; rec: var PureFastqRecord) =
  let qLen = rec.quality.len
  var needsSeqCopy = false
  for i in 0 ..< qLen:
    if ord(rec.quality[i]) == 0:
      needsSeqCopy = true
      break

  var packedSeq = if needsSeqCopy: cloneString(rec.sequence) else: rec.sequence
  var seqi = packedSeq.len - 1
  rec.sequence.setLen(qLen)

  if qLen > 0:
    for i in countdown(qLen - 1, 0):
      let qval = ord(rec.quality[i])
      doAssert qval >= 0 and qval <= 7
      var seqval = 0

      if qval == 0:
        seqval = 4
      else:
        doAssert seqi >= 0
        seqval = ord(packedSeq[seqi])
        dec seqi

      doAssert seqval >= 0 and seqval < p.base.dnaFromIndexTable.len
      rec.sequence[i] = char(p.base.dnaFromIndexTable[seqval])
      rec.quality[i] = char(uint8(int(p.base.qualityOffset) + int(p.qualityFromIndexTable[qval])))

  if p.base.colorSpace and rec.sequence.len > 0 and rec.quality.len > 0:
    var seq0 = uint8(ord(rec.sequence[0]))
    var qua0 = uint8(ord(rec.quality[0]))

    if p.base.csStats.constBeginSym:
      seq0 = p.base.csStats.seqBegin
      qua0 = p.base.csStats.quaBegin

    if int(seq0) < p.base.dnaFromIndexTable.len:
      seq0 = p.base.dnaFromIndexTable[int(seq0)]

    p.base.processToColorSpace(rec, seq0, qua0)

proc processForward*(
  p: var LossyRecordsProcessor;
  records: var seq[PureFastqRecord];
  flags: uint32 = ChecksumCalcNone
): FastqChecksum =
  result.clear()
  if flags == ChecksumCalcNone:
    for rec in mitems(records):
      p.processForwardRecord(rec)
    return result

  p.base.fastqHasher.reset()
  p.base.fastqHasher.setFlags(flags)
  for rec in mitems(records):
    p.base.fastqHasher.update(rec)
    p.processForwardRecord(rec)
  result = p.base.fastqHasher.checksum()

proc processBackward*(
  p: var LossyRecordsProcessor;
  records: var seq[PureFastqRecord];
  flags: uint32 = ChecksumCalcNone
): FastqChecksum =
  result.clear()
  if flags == ChecksumCalcNone:
    for rec in mitems(records):
      p.processBackwardRecord(rec)
    return result

  p.base.fastqHasher.reset()
  p.base.fastqHasher.setFlags(flags)
  for rec in mitems(records):
    p.processBackwardRecord(rec)
    p.base.fastqHasher.update(rec)
  result = p.base.fastqHasher.checksum()
