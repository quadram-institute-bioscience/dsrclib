import os
import std/strutils
import dsrclib/pure

proc writeTempFastq(content: string): string =
  result = getTempDir() / "dsrclib_pure_fastq_test.fastq"
  writeFile(result, content)

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

proc toBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  for i, ch in s:
    result[i] = uint8(ord(ch))

proc main() =
  # Includes CRLF records and mixed title fields to exercise chunk parsing + filtering.
  var fastqContent = newStringOfCap(30000)
  for i in 0 ..< 256:
    fastqContent.add("@SEQ" & $i & " first test sequence\r\n")
    fastqContent.add("ACGTACGT\r\n")
    fastqContent.add("+SEQ" & $i & " first test sequence\r\n")
    fastqContent.add("IIIIIIII\r\n")

  let path = writeTempFastq(fastqContent)
  defer: removeIfExists(path)

  var reader = openFastqChunkReader(path, chunkBufferSize = 9000)
  defer: reader.close()

  var total = 0
  var chunkCount = 0
  var chunk: seq[uint8]
  while reader.readNextChunk(chunk):
    inc chunkCount
    let parsed = parseFastqChunk(chunk)
    total += parsed.records.len

  assert chunkCount > 1, "expected multiple chunks with small chunk buffer"
  assert total == 256, "expected 256 records from chunk parser, got " & $total
  echo "OK: chunk reader + parser decoded ", total, " records over ", chunkCount, " chunks"

  let allBytes = toBytes(readFile(path))
  let analyzed = analyzeFastqChunk(allBytes, estimateQualityOffset = true)
  assert analyzed.ok, "dataset analysis should succeed"
  assert analyzed.datasetType.qualityOffset == 33'u32
  assert analyzed.datasetType.plusRepetition
  assert not analyzed.datasetType.colorSpace
  echo "OK: analyzer detected plus repetition and quality offset"

  # Keep only field 1 and 3 from tags split by separators.
  let filtered = parseFastqChunk(allBytes, tagPreserveFlags = (1'u64 shl 1) or (1'u64 shl 3))
  assert filtered.records.len == 256
  assert filtered.records[0].title.contains("SEQ0")
  assert filtered.records[0].title.contains("test")
  assert not filtered.records[0].title.contains("first")
  echo "OK: tag field filtering applied to parsed titles"

main()
