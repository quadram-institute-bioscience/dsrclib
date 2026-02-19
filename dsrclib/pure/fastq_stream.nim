## FASTQ chunk reader mirroring DSRC FastqStream chunking strategy.

import std/[streams, strformat]

const
  SwapBufferSize* = 1 shl 13
  DefaultFastqChunkBufferSize* = 1 shl 20

type
  FastqChunkReader* = object
    stream: FileStream
    swapBuffer: seq[uint8]
    pendingBytes: int
    eofReached: bool
    usesCrlf*: bool
    chunkBufferSize*: int

proc ensure(cond: bool; msg: string) =
  if not cond:
    raise newException(IOError, msg)

proc openFastqChunkReader*(path: string; chunkBufferSize = DefaultFastqChunkBufferSize): FastqChunkReader =
  ensure(chunkBufferSize > SwapBufferSize + 64, "chunkBufferSize too small for DSRC chunk splitting")
  result.stream = newFileStream(path, fmRead)
  ensure(not result.stream.isNil, fmt"Cannot open FASTQ file for reading: {path}")
  result.swapBuffer = newSeq[uint8](SwapBufferSize)
  result.pendingBytes = 0
  result.eofReached = false
  result.usesCrlf = false
  result.chunkBufferSize = chunkBufferSize

proc close*(r: var FastqChunkReader) =
  if not r.stream.isNil:
    r.stream.close()
    r.stream = nil

proc skipToEol(data: openArray[uint8]; pos: var int; usesCrlf: var bool) =
  let n = data.len
  if pos >= n:
    return
  while pos < n and data[pos] != uint8('\n') and data[pos] != uint8('\r'):
    inc pos
  if pos < n and data[pos] == uint8('\r'):
    if pos + 1 < n and data[pos + 1] == uint8('\n'):
      usesCrlf = true
      inc pos

proc getNextRecordPos(data: openArray[uint8]; startPos: int; usesCrlf: var bool): int =
  var pos = startPos
  let n = data.len
  if pos >= n:
    return n

  skipToEol(data, pos, usesCrlf)
  inc pos
  while pos < n and data[pos] != uint8('@'):
    skipToEol(data, pos, usesCrlf)
    inc pos
  let pos0 = pos
  if pos >= n:
    return n

  skipToEol(data, pos, usesCrlf)
  inc pos
  if pos < n and data[pos] == uint8('@'):
    return pos

  if pos < n:
    skipToEol(data, pos, usesCrlf)
    inc pos

  # If buffer is malformed, return conservative split point.
  if pos >= n:
    return n
  if data[pos] != uint8('+'):
    return pos0
  pos0

proc readNextChunk*(r: var FastqChunkReader; outChunk: var seq[uint8]): bool =
  if r.eofReached:
    outChunk = @[]
    return false

  var data = newSeq[uint8](r.chunkBufferSize)
  var size = 0
  if r.pendingBytes > 0:
    for i in 0 ..< r.pendingBytes:
      data[i] = r.swapBuffer[i]
    size = r.pendingBytes
    r.pendingBytes = 0

  let toRead = r.chunkBufferSize - size
  let got = if toRead > 0: r.stream.readData(addr data[size], toRead) else: 0

  if got <= 0:
    r.eofReached = true
    outChunk = @[]
    return size > 0

  size += got
  if got == toRead:
    var splitPos = r.chunkBufferSize - SwapBufferSize
    splitPos = getNextRecordPos(data, splitPos, r.usesCrlf)
    if splitPos > size:
      splitPos = size

    var chunkSize = splitPos - 1
    if r.usesCrlf:
      dec chunkSize
    if chunkSize < 0:
      chunkSize = 0

    if splitPos < size:
      r.pendingBytes = size - splitPos
      if r.pendingBytes > r.swapBuffer.len:
        r.swapBuffer.setLen(r.pendingBytes)
      for i in 0 ..< r.pendingBytes:
        r.swapBuffer[i] = data[splitPos + i]
    else:
      r.pendingBytes = 0

    outChunk = data[0 ..< chunkSize]
    return outChunk.len > 0

  var chunkSize = size - 1
  if r.usesCrlf:
    dec chunkSize
  if chunkSize < 0:
    chunkSize = 0
  r.eofReached = true
  outChunk = data[0 ..< chunkSize]
  outChunk.len > 0

