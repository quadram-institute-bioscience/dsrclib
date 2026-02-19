import os
import dsrclib/pure

proc main() =
  let testFile = currentSourcePath().parentDir / "data" / "test.fastq.dsrc"

  var reader = openDsrcContainerReader(testFile)
  defer: reader.close()

  var chunk: seq[uint8]
  doAssert reader.readNextChunk(chunk)

  let meta = parseChunkHeaderMeta(chunk, reader.footer.datasetType, reader.footer.compSettings)
  assert meta.recordsCount == 4'u32
  assert meta.maxQuaLength == 28'u32
  assert meta.minQuaLength == 12'u32
  assert (meta.flags and FlagVariableLength) != 0'u32
  assert qualityLengthBitWidth(meta) > 0'u32
  assert meta.chunkSize > 0'u32
  echo "OK: parsed DSRC chunk metadata"

  var hooks: ChunkDecodeHooks
  hooks.tag = decodeTagAndLengthsHook
  let decoded = decodeChunkWithHooks(chunk, reader.footer.datasetType, reader.footer.compSettings, hooks)
  assert decoded.records.len == 4
  assert decoded.tagDecoded
  assert not decoded.qualityDecoded
  assert not decoded.dnaDecoded

  assert decoded.records[0].title == "@SEQ1 first test sequence"
  assert decoded.records[1].title == "@SEQ2 second test sequence with longer comment"
  assert decoded.records[2].title == "@SEQ3"
  assert decoded.records[3].title == "@SEQ4 quality varies"
  assert decoded.records[0].quality.len == 28
  assert decoded.records[1].quality.len == 24
  assert decoded.records[2].quality.len == 16
  assert decoded.records[3].quality.len == 12
  assert decoded.records[0].sequence.len == decoded.records[0].quality.len
  echo "OK: tag decode hook populated titles and quality lengths"

main()
