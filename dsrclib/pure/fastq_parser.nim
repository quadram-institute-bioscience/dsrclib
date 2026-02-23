## FASTQ parser and analyzer mirroring DSRC FastqParser/FastqParserExt behavior.

import types

const
  FieldSeparators* = {' ', '.', '_', ',', '=', ':', '/', '-', '#'}

type
  LineSpan = object
    start: int
    len: int

  FastqParseResult* = object
    records*: seq[PureFastqRecord]
    streamsInfo*: StreamsInfo
    skippedBytes*: uint64
    totalBytesCut*: uint64
    consumedBytes*: uint64

proc parseLineSpan(data: openArray[uint8]; pos: var int; outSpan: var LineSpan): bool {.inline.} =
  let n = data.len
  if pos >= n:
    outSpan.start = n
    outSpan.len = 0
    return false

  let start = pos
  while pos < n and data[pos] != uint8('\n') and data[pos] != uint8('\r'):
    inc pos
  outSpan.start = start
  outSpan.len = pos - start

  if pos < n and data[pos] == uint8('\r'):
    inc pos
    if pos < n and data[pos] == uint8('\n'):
      inc pos
  elif pos < n and data[pos] == uint8('\n'):
    inc pos

  true

proc spanToString(data: openArray[uint8]; span: LineSpan): string {.inline.} =
  if span.len <= 0:
    return ""
  result = newString(span.len)
  copyMem(addr result[0], unsafeAddr data[span.start], span.len)

proc applyTagFieldFilter(
  data: openArray[uint8];
  title: LineSpan;
  tagPreserveFlags: uint64
): tuple[value: string, bytesCut: uint64] =
  if title.len == 0:
    return ("", 0'u64)
  if tagPreserveFlags == 0'u64:
    return (spanToString(data, title), 0'u64)

  var filtered = newStringOfCap(title.len)
  var fieldNo = 0
  var fieldStart = title.start
  let titleEnd = title.start + title.len
  var i = title.start
  while i <= titleEnd:
    let isEnd = i == titleEnd
    let isSep = (not isEnd) and (char(data[i]) in FieldSeparators)
    if not isSep and not isEnd:
      inc i
      continue

    inc fieldNo
    let keep = ((tagPreserveFlags and (1'u64 shl fieldNo)) != 0'u64)
    if keep:
      let oldLen = filtered.len
      let keepLen = if isEnd: i - fieldStart else: i - fieldStart + 1
      if keepLen > 0:
        filtered.setLen(oldLen + keepLen)
        copyMem(addr filtered[oldLen], unsafeAddr data[fieldStart], keepLen)
    fieldStart = i + 1
    inc i

  result = (filtered, uint64(title.len - filtered.len))

proc parseFastqChunk*(
  chunk: openArray[uint8];
  tagPreserveFlags = 0'u64
): FastqParseResult =
  result.streamsInfo.clear()
  result.records = newSeqOfCap[PureFastqRecord](max(1, chunk.len shr 8))
  result.skippedBytes = 0'u64
  result.totalBytesCut = 0'u64
  result.consumedBytes = 0'u64

  var pos = 0
  let n = chunk.len
  var titleSpan, seqSpan, plusSpan, qualSpan: LineSpan
  while pos < n:
    if not parseLineSpan(chunk, pos, titleSpan):
      break
    if titleSpan.len == 0 or chunk[titleSpan.start] != uint8('@'):
      break

    if not parseLineSpan(chunk, pos, seqSpan):
      break
    if seqSpan.len == 0:
      break

    if not parseLineSpan(chunk, pos, plusSpan):
      break
    if plusSpan.len == 0 or chunk[plusSpan.start] != uint8('+'):
      break

    if not parseLineSpan(chunk, pos, qualSpan):
      break
    if qualSpan.len == 0 or seqSpan.len != qualSpan.len:
      break

    let (filteredTitle, cut) = applyTagFieldFilter(chunk, titleSpan, tagPreserveFlags)
    result.totalBytesCut += cut

    result.records.add(
      PureFastqRecord(
        title: filteredTitle,
        sequence: spanToString(chunk, seqSpan),
        plus: spanToString(chunk, plusSpan),
        quality: spanToString(chunk, qualSpan),
        truncatedLen: 0'u16
      )
    )
    result.streamsInfo.sizes[TagStream.ord] += uint64(filteredTitle.len)
    result.streamsInfo.sizes[DnaStream.ord] += uint64(seqSpan.len)
    result.streamsInfo.sizes[QualityStream.ord] += uint64(qualSpan.len)
  result.consumedBytes = uint64(n) - result.totalBytesCut - result.skippedBytes

proc analyzeFastqChunk*(
  chunk: openArray[uint8];
  estimateQualityOffset = false
): tuple[ok: bool, datasetType: FastqDatasetType] =
  result.datasetType = defaultFastqDatasetType()
  var minQuality = uint8(255)
  var maxQuality = uint8(0)

  var pos = 0
  let n = chunk.len
  var recCount = 0
  var titleSpan, seqSpan, plusSpan, qualSpan: LineSpan
  while pos < n:
    if not parseLineSpan(chunk, pos, titleSpan):
      break
    if titleSpan.len == 0 or chunk[titleSpan.start] != uint8('@'):
      break

    if not parseLineSpan(chunk, pos, seqSpan):
      break
    if seqSpan.len == 0:
      break

    if not parseLineSpan(chunk, pos, plusSpan):
      break
    if plusSpan.len == 0 or chunk[plusSpan.start] != uint8('+'):
      break

    if not parseLineSpan(chunk, pos, qualSpan):
      break
    if qualSpan.len == 0:
      break

    if estimateQualityOffset:
      for i in qualSpan.start ..< (qualSpan.start + qualSpan.len):
        let b = chunk[i]
        if b < minQuality: minQuality = b
        if b > maxQuality: maxQuality = b

    let plusRep = plusSpan.len > 1
    let colorEnc = (seqSpan.len > 1) and (
      (chunk[seqSpan.start + 1] >= uint8('0') and chunk[seqSpan.start + 1] <= uint8('3')) or
      chunk[seqSpan.start + 1] == uint8('.')
    )

    if recCount != 0:
      if result.datasetType.colorSpace != colorEnc:
        return (false, result.datasetType)
      if result.datasetType.colorSpace and chunk[seqSpan.start] >= uint8('0') and chunk[seqSpan.start] <= uint8('3'):
        return (false, result.datasetType)
      if result.datasetType.plusRepetition != plusRep:
        return (false, result.datasetType)
    else:
      result.datasetType.colorSpace = colorEnc
      result.datasetType.plusRepetition = plusRep

    if seqSpan.len != qualSpan.len:
      break
    inc recCount

  if estimateQualityOffset:
    if maxQuality <= 74'u8:
      if minQuality >= 33'u8:
        result.datasetType.qualityOffset = 33'u32
    elif maxQuality <= 105'u8:
      if minQuality >= 64'u8:
        result.datasetType.qualityOffset = 64'u32
      elif minQuality >= 59'u8:
        result.datasetType.qualityOffset = 59'u32

    if result.datasetType.qualityOffset == 0'u32:
      if minQuality >= 33'u8:
        result.datasetType.qualityOffset = 33'u32
      else:
        return (false, result.datasetType)

  result.ok = recCount > 1
