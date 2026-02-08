## undsrc - Decompress DSRC files to FASTQ
##
## Usage: undsrc INPUT_FILE.dsrc > OUTPUT_FASTQ
##        undsrc INPUT_FILE.dsrc OUTPUT_FASTQ
##
## Uses DsrcModule (multi-threaded) for fast decompression.

import dsrclib
import os, strutils

proc usage() =
  stderr.writeLine "Usage: undsrc [-t THREADS] INPUT_FILE.dsrc [OUTPUT_FASTQ]"
  stderr.writeLine ""
  stderr.writeLine "Decompresses a DSRC file to FASTQ."
  stderr.writeLine "If OUTPUT_FASTQ is omitted, writes to stdout."
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

  if args.len < 1:
    usage()

  let inputFile = args[0]

  if not fileExists(inputFile):
    stderr.writeLine "Error: file not found: " & inputFile
    quit(1)

  if args.len >= 2:
    let outputFile = args[1]
    if fileExists(outputFile):
      stderr.writeLine "Error: output file already exists: " & outputFile
      quit(1)
    decompressDSRC(inputFile, outputFile, threads = threads)
  else:
    decompressDSRC(inputFile, "", threads = threads, useStdIo = true)

when isMainModule:
  main()
