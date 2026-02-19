import os
import dsrclib/pure

proc main() =
  let testFile = currentSourcePath().parentDir / "data" / "test.fastq.dsrc"

  var r = openDsrcContainerReader(testFile)
  defer: r.close()

  assert r.header.dummyByte == DsrcHeaderDummyByte
  assert r.header.versionMajor == DsrcVersionMajor
  assert r.header.versionMinor == DsrcVersionMinor
  assert r.footer.dummyByte == DsrcFooterDummyByte
  assert r.footer.blockSizes.len > 0
  assert r.footer.blockSizes.len == int(r.header.blockCount)

  let fileSize = uint64(getFileSize(testFile))
  assert r.header.footerOffset + uint64(r.header.footerSize) == fileSize

  var chunks: seq[seq[uint8]]
  var totalChunkBytes = 0'u64
  var chunk: seq[uint8]
  while r.readNextChunk(chunk):
    chunks.add(chunk)
    totalChunkBytes += uint64(chunk.len)

  assert chunks.len == r.footer.blockSizes.len
  assert totalChunkBytes == r.header.footerOffset - DsrcHeaderSize
  echo "OK: parsed DSRC container metadata and read ", chunks.len, " chunks"

  # Raw container rewrite smoke-test (no recompression, just chunk framing).
  let tmpOut = getTempDir() / "dsrclib_pure_container_copy.dsrc"
  var w = openDsrcContainerWriter(tmpOut, r.footer.datasetType, r.footer.compSettings)
  for c in chunks:
    w.writeChunk(c)
  w.close()

  var r2 = openDsrcContainerReader(tmpOut)
  defer:
    r2.close()
    removeFile(tmpOut)

  assert r2.footer.blockSizes == r.footer.blockSizes
  assert r2.footer.datasetType.qualityOffset == r.footer.datasetType.qualityOffset
  assert r2.footer.datasetType.plusRepetition == r.footer.datasetType.plusRepetition
  assert r2.footer.datasetType.colorSpace == r.footer.datasetType.colorSpace
  assert r2.footer.compSettings.dnaOrder == r.footer.compSettings.dnaOrder
  assert r2.footer.compSettings.qualityOrder == r.footer.compSettings.qualityOrder
  assert r2.footer.compSettings.lossy == r.footer.compSettings.lossy
  assert r2.footer.compSettings.calculateCrc32 == r.footer.compSettings.calculateCrc32
  assert r2.footer.compSettings.tagPreserveFlags == r.footer.compSettings.tagPreserveFlags
  echo "OK: raw DSRC container rewrite preserved footer/chunk metadata"

main()
