## fastq2dsrc - Compress FASTQ files to DSRC
##
## Usage: fastq2dsrc INPUT_FASTQ OUTPUT_DSRC
##        cat reads.fq | fastq2dsrc - OUTPUT_DSRC
##
## Uses DsrcModule (multi-threaded) for fast compression.
## Supports plain FASTQ, gzipped FASTQ (.gz), and stdin (-).

import dsrclib
import os, strutils

proc isGzipped(path: string): bool =
  ## Check if a file starts with the gzip magic bytes (0x1f 0x8b).
  let f = open(path, fmRead)
  defer: f.close()
  var magic: array[2, uint8]
  if f.readBytes(magic, 0, 2) == 2:
    result = magic[0] == 0x1f'u8 and magic[1] == 0x8b'u8

proc usage() =
  stderr.writeLine "Usage: fastq2dsrc [-t THREADS] INPUT_FASTQ OUTPUT_DSRC"
  stderr.writeLine "       cat reads.fq | fastq2dsrc [-t THREADS] - OUTPUT_DSRC"
  stderr.writeLine ""
  stderr.writeLine "Compresses a FASTQ file to DSRC format."
  stderr.writeLine "Supports plain FASTQ, gzipped (.gz), and stdin (-)."
  stderr.writeLine ""
  stderr.writeLine "Options:"
  stderr.writeLine "  -t THREADS  Number of threads (default: all available cores)"
  quit(1)

proc main() =
  var threads: uint32 = 0
  var args: seq[string]

  var i = 1
  while i <= paramCount():
    let p = paramStr(i)
    if p == "-t":
      if i + 1 > paramCount():
        stderr.writeLine "Error: -t requires an argument"
        quit(1)
      inc i
      try:
        threads = parseUInt(paramStr(i)).uint32
      except ValueError:
        stderr.writeLine "Error: invalid thread count: " & paramStr(i)
        quit(1)
    else:
      args.add(p)
    inc i

  if args.len < 2:
    usage()

  let inputFile = args[0]
  let outputFile = args[1]
  let useStdin = inputFile == "-"

  if not useStdin and not fileExists(inputFile):
    stderr.writeLine "Error: file not found: " & inputFile
    quit(1)

  if fileExists(outputFile):
    stderr.writeLine "Error: output file already exists: " & outputFile
    quit(1)

  if useStdin:
    compressDSRC("", outputFile, threads = threads, useStdIo = true)
  elif isGzipped(inputFile):
    let tmpFq = outputFile & ".tmp.fastq"
    try:
      gzDecompressFile(inputFile, tmpFq)
      compressDSRC(tmpFq, outputFile, threads = threads)
    finally:
      if fileExists(tmpFq):
        removeFile(tmpFq)
  else:
    compressDSRC(inputFile, outputFile, threads = threads)

when isMainModule:
  main()
