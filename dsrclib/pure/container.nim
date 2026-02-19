## DSRC archive container metadata/chunk reader and writer.
## This layer handles only archive framing (header/footer/chunks), not block coding.

import std/[os, streams, strformat]
import types, bitstream

type
  DsrcContainerReader* = object
    path*: string
    fileSize*: uint64
    header*: DsrcFileHeader
    footer*: DsrcFileFooter
    chunkOffsets*: seq[uint64]
    nextChunkIdx*: int
    stream: FileStream

  DsrcContainerWriter* = object
    path*: string
    header*: DsrcFileHeader
    footer*: DsrcFileFooter
    stream: FileStream

proc ensure(cond: bool; msg: string) =
  if not cond:
    raise newException(DsrcFormatError, msg)

proc readExact(s: Stream; n: int): seq[uint8] =
  if n == 0:
    return @[]
  result = newSeq[uint8](n)
  let got = s.readData(addr result[0], n)
  if got != n:
    raise newException(IOError, fmt"Unexpected EOF: requested {n} bytes, got {got}")

proc writeAll(s: Stream; data: openArray[uint8]) =
  if data.len == 0:
    return
  s.writeData(unsafeAddr data[0], data.len)

proc parseHeader(raw: openArray[uint8]): DsrcFileHeader =
  ensure(raw.len == int(DsrcHeaderSize), "Corrupted DSRC header size")
  var br = initByteReader(raw)
  result.dummyByte = br.readByte()
  result.versionMajor = br.readByte()
  result.versionMinor = br.readByte()
  result.versionRev = br.readByte()
  result.footerSize = br.readWordBE()
  result.footerOffset = br.readDWordBE()
  result.recordsCount = br.readDWordBE()
  result.blockCount = br.readDWordBE()
  let resv = br.readBytes(int(DsrcReservedBytes))
  for i, b in resv:
    result.reserved[i] = b

proc parseFooter(raw: openArray[uint8]; blockCount: uint64): DsrcFileFooter =
  let minFooterBytes = int(1'u64 + blockCount * 4'u64 + 2'u64 + 3'u64 + 8'u64)
  ensure(raw.len >= minFooterBytes, "Corrupted DSRC footer size")
  var br = initByteReader(raw)

  result.dummyByte = br.readByte()
  result.blockSizes = newSeq[uint32](int(blockCount))
  for i in 0 ..< int(blockCount):
    # DSRC stores block sizes as native uint32 memory dump (little-endian on target platforms).
    result.blockSizes[i] = br.readWordLE()

  let dsFlags = br.readByte()
  result.datasetType.plusRepetition = (dsFlags and FlagPlusRepetition) != 0'u8
  result.datasetType.colorSpace = (dsFlags and FlagColorSpace) != 0'u8
  result.datasetType.qualityOffset = uint32(br.readByte())

  let compFlags = br.readByte()
  result.compSettings.lossy = (compFlags and FlagLossyQuality) != 0'u8
  result.compSettings.calculateCrc32 = (compFlags and FlagCalculateCrc32) != 0'u8
  result.compSettings.dnaOrder = uint32(br.readByte())
  result.compSettings.qualityOrder = uint32(br.readByte())
  result.compSettings.tagPreserveFlags = br.readDWordBE()

proc buildHeaderBytes(h: DsrcFileHeader): seq[uint8] =
  var bw = initByteWriter(int(DsrcHeaderSize))
  bw.writeByte(h.dummyByte)
  bw.writeByte(h.versionMajor)
  bw.writeByte(h.versionMinor)
  bw.writeByte(h.versionRev)
  bw.writeWordBE(h.footerSize)
  bw.writeDWordBE(h.footerOffset)
  bw.writeDWordBE(h.recordsCount)
  bw.writeDWordBE(h.blockCount)
  bw.writeBytes(h.reserved)
  result = bw.data

proc buildFooterBytes(f: DsrcFileFooter): seq[uint8] =
  let cap = 1 + f.blockSizes.len * 4 + 2 + 3 + 8
  var bw = initByteWriter(cap)
  bw.writeByte(f.dummyByte)
  for sz in f.blockSizes:
    bw.writeWordLE(sz)

  var dsFlags = 0'u8
  if f.datasetType.colorSpace:
    dsFlags = dsFlags or FlagColorSpace
  if f.datasetType.plusRepetition:
    dsFlags = dsFlags or FlagPlusRepetition
  bw.writeByte(dsFlags)
  bw.writeByte(uint8(f.datasetType.qualityOffset and 0xFF'u32))

  var compFlags = 0'u8
  if f.compSettings.lossy:
    compFlags = compFlags or FlagLossyQuality
  if f.compSettings.calculateCrc32:
    compFlags = compFlags or FlagCalculateCrc32
  bw.writeByte(compFlags)
  bw.writeByte(uint8(f.compSettings.dnaOrder and 0xFF'u32))
  bw.writeByte(uint8(f.compSettings.qualityOrder and 0xFF'u32))
  bw.writeDWordBE(f.compSettings.tagPreserveFlags)
  result = bw.data

proc close*(r: var DsrcContainerReader) =
  if not r.stream.isNil:
    r.stream.close()
    r.stream = nil

proc openDsrcContainerReader*(path: string): DsrcContainerReader =
  result.path = path
  result.fileSize = uint64(getFileSize(path))
  ensure(result.fileSize > 0'u64, "Empty DSRC file")

  result.stream = newFileStream(path, fmRead)
  ensure(not result.stream.isNil, "Failed to open DSRC file for reading")

  let rawHeader = readExact(result.stream, int(DsrcHeaderSize))
  result.header = parseHeader(rawHeader)

  ensure(
    result.header.versionMajor == DsrcVersionMajor and result.header.versionMinor == DsrcVersionMinor,
    fmt"Unsupported DSRC version {result.header.versionMajor}.{result.header.versionMinor}.{result.header.versionRev}"
  )
  ensure(result.header.blockCount > 0'u64, "Invalid DSRC archive: no blocks")
  ensure(
    result.header.footerOffset + uint64(result.header.footerSize) <= result.fileSize,
    "Corrupted DSRC archive: invalid footer location"
  )

  result.stream.setPosition(int(result.header.footerOffset))
  let rawFooter = readExact(result.stream, int(result.header.footerSize))
  result.footer = parseFooter(rawFooter, result.header.blockCount)
  ensure(result.footer.dummyByte == DsrcFooterDummyByte, "Corrupted DSRC footer marker")

  result.chunkOffsets = newSeq[uint64](result.footer.blockSizes.len)
  var pos = DsrcHeaderSize
  for i, sz in result.footer.blockSizes:
    result.chunkOffsets[i] = pos
    pos += uint64(sz)

  ensure(pos == result.header.footerOffset, "Corrupted DSRC archive: chunk span mismatch")
  result.nextChunkIdx = 0
  result.stream.setPosition(int(DsrcHeaderSize))

proc rewindChunks*(r: var DsrcContainerReader) =
  r.nextChunkIdx = 0
  if not r.stream.isNil:
    r.stream.setPosition(int(DsrcHeaderSize))

proc readChunkAt*(r: var DsrcContainerReader; idx: int; outChunk: var seq[uint8]): bool =
  if idx < 0 or idx >= r.footer.blockSizes.len:
    return false

  let size = int(r.footer.blockSizes[idx])
  r.stream.setPosition(int(r.chunkOffsets[idx]))
  outChunk = readExact(r.stream, size)
  true

proc readNextChunk*(r: var DsrcContainerReader; outChunk: var seq[uint8]): bool =
  if r.nextChunkIdx >= r.footer.blockSizes.len:
    return false
  result = r.readChunkAt(r.nextChunkIdx, outChunk)
  if result:
    inc r.nextChunkIdx

proc close*(w: var DsrcContainerWriter) =
  if w.stream.isNil:
    return

  ensure(w.footer.blockSizes.len > 0, "Cannot finalize DSRC container with zero chunks")

  let footerOffset = uint64(w.stream.getPosition())
  w.footer.dummyByte = DsrcFooterDummyByte
  let footerRaw = buildFooterBytes(w.footer)
  writeAll(w.stream, footerRaw)
  let endPos = uint64(w.stream.getPosition())

  w.header.dummyByte = DsrcHeaderDummyByte
  w.header.versionMajor = DsrcVersionMajor
  w.header.versionMinor = DsrcVersionMinor
  w.header.versionRev = DsrcVersionRev
  w.header.footerOffset = footerOffset
  w.header.footerSize = uint32(endPos - footerOffset)
  w.header.recordsCount = 0'u64
  w.header.blockCount = uint64(w.footer.blockSizes.len)
  for i in 0 ..< int(DsrcReservedBytes):
    w.header.reserved[i] = DsrcHeaderDummyByte

  w.stream.setPosition(0)
  let headerRaw = buildHeaderBytes(w.header)
  writeAll(w.stream, headerRaw)
  w.stream.close()
  w.stream = nil

proc openDsrcContainerWriter*(
  path: string;
  datasetType = defaultFastqDatasetType();
  compSettings = defaultCompressionSettings()
): DsrcContainerWriter =
  result.path = path
  result.footer.datasetType = datasetType
  result.footer.compSettings = compSettings
  result.footer.blockSizes = @[]

  result.stream = newFileStream(path, fmWrite)
  ensure(not result.stream.isNil, "Failed to open DSRC file for writing")

  # Reserve header space; patched during close().
  var placeholder = newSeq[uint8](int(DsrcHeaderSize))
  writeAll(result.stream, placeholder)

proc writeChunk*(w: var DsrcContainerWriter; chunk: openArray[uint8]) =
  ensure(not w.stream.isNil, "Writer is not open")
  ensure(chunk.len > 0, "Chunk size must be > 0")
  writeAll(w.stream, chunk)
  w.footer.blockSizes.add(uint32(chunk.len))
