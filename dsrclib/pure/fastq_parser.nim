## FASTQ parser and analyzer mirroring DSRC FastqParser/FastqParserExt behavior.

import types

const
  FieldSeparators* = {' ', '.', '_', ',', '=', ':', '/', '-', '#'}

type
  FastqParseResult* = object
    records*: seq[PureFastqRecord]
    streamsInfo*: StreamsInfo
    skippedBytes*: uint64
    totalBytesCut*: uint64
    consumedBytes*: uint64

proc parseLine(data: openArray[uint8]; pos: var int): string =
  var start = pos
  let n = data.len
  while pos < n and data[pos] != uint8('\n') and data[pos] != uint8('\r'):
    inc pos
  let stop = pos

  if pos < n and data[pos] == uint8('\r'):
    inc pos
    if pos < n and data[pos] == uint8('\n'):
      inc pos
  elif pos < n and data[pos] == uint8('\n'):
    inc pos

  if stop <= start:
    return ""
  result = newString(stop - start)
  for i in 0 ..< result.len:
    result[i] = char(data[start + i])

proc applyTagFieldFilter(title: string; tagPreserveFlags: uint64): tuple[value: string, bytesCut: uint64] =
  if tagPreserveFlags == 0'u64 or title.len == 0:
    return (title, 0'u64)

  var filtered = newStringOfCap(title.len)
  var fieldNo = 0
  var fieldStart = 0
  for i in 0 .. title.len:
    let isEnd = i == title.len
    let isSep = (not isEnd) and (title[i] in FieldSeparators)
    if not isSep and not isEnd:
      continue

    inc fieldNo
    let keep = ((tagPreserveFlags and (1'u64 shl fieldNo)) != 0'u64)
    if keep:
      if isEnd:
        filtered.add(title[fieldStart ..< i])
      else:
        filtered.add(title[fieldStart .. i]) # include separator
    fieldStart = i + 1

  result = (filtered, uint64(title.len - filtered.len))

proc parseFastqChunk*(
  chunk: openArray[uint8];
  tagPreserveFlags = 0'u64
): FastqParseResult =
  result.streamsInfo.clear()
  result.records = @[]
  result.skippedBytes = 0'u64
  result.totalBytesCut = 0'u64
  result.consumedBytes = 0'u64

  var pos = 0
  let n = chunk.len
  while pos < n:
    let title = parseLine(chunk, pos)
    if title.len == 0 or title[0] != '@':
      break

    let sequence = parseLine(chunk, pos)
    if sequence.len == 0:
      break

    let plus = parseLine(chunk, pos)
    if plus.len == 0 or plus[0] != '+':
      break

    let quality = parseLine(chunk, pos)
    if quality.len == 0 or sequence.len != quality.len:
      break

    let (filteredTitle, cut) = applyTagFieldFilter(title, tagPreserveFlags)
    result.totalBytesCut += cut

    result.records.add(
      PureFastqRecord(
        title: filteredTitle,
        sequence: sequence,
        plus: plus,
        quality: quality,
        truncatedLen: 0'u16
      )
    )
    result.streamsInfo.sizes[TagStream.ord] += uint64(filteredTitle.len)
    result.streamsInfo.sizes[DnaStream.ord] += uint64(sequence.len)
    result.streamsInfo.sizes[QualityStream.ord] += uint64(quality.len)
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
  while pos < n:
    let title = parseLine(chunk, pos)
    if title.len == 0 or title[0] != '@':
      break

    let sequence = parseLine(chunk, pos)
    if sequence.len == 0:
      break

    let plus = parseLine(chunk, pos)
    if plus.len == 0 or plus[0] != '+':
      break

    let quality = parseLine(chunk, pos)
    if quality.len == 0:
      break

    if estimateQualityOffset:
      for ch in quality:
        let b = uint8(ord(ch))
        if b < minQuality: minQuality = b
        if b > maxQuality: maxQuality = b

    let plusRep = plus.len > 1
    let colorEnc = (sequence.len > 1) and (
      (sequence[1] >= '0' and sequence[1] <= '3') or sequence[1] == '.'
    )

    if recCount != 0:
      if result.datasetType.colorSpace != colorEnc:
        return (false, result.datasetType)
      if result.datasetType.colorSpace and sequence[0] >= '0' and sequence[0] <= '3':
        return (false, result.datasetType)
      if result.datasetType.plusRepetition != plusRep:
        return (false, result.datasetType)
    else:
      result.datasetType.colorSpace = colorEnc
      result.datasetType.plusRepetition = plusRep

    if sequence.len != quality.len:
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
