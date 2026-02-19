## undsrc - Decompress DSRC files to FASTQ
##
## Usage: undsrc INPUT_FILE.dsrc > OUTPUT_FASTQ
##        undsrc INPUT_FILE.dsrc OUTPUT_FASTQ
##
## Uses pure-Nim backend by default. Legacy backend is opt-in at compile-time
## with -d:dsrclibLegacy and can be selected at runtime with --backend legacy.

when not declared(readDSRC):
  import dsrclib
import os, strutils

template withBackend(mode: string; body: untyped) =
  let hadBackend = existsEnv("DSRCLIB_BACKEND")
  let prevBackend = getEnv("DSRCLIB_BACKEND", "")
  putEnv("DSRCLIB_BACKEND", mode)
  try:
    body
  finally:
    if hadBackend:
      putEnv("DSRCLIB_BACKEND", prevBackend)
    else:
      delEnv("DSRCLIB_BACKEND")

proc writeFastqRecord(outFile: File; rec: FQRecord) =
  outFile.write("@")
  outFile.write(rec.name)
  if rec.comment.len > 0:
    outFile.write(" ")
    outFile.write(rec.comment)
  outFile.write("\n")
  outFile.write(rec.sequence)
  outFile.write("\n+\n")
  outFile.write(rec.quality)
  outFile.write("\n")

proc usage() =
  stderr.writeLine "Usage: undsrc [options] INPUT_FILE.dsrc [OUTPUT_FASTQ]"
  stderr.writeLine ""
  stderr.writeLine "Decompresses a DSRC file to FASTQ."
  stderr.writeLine "If OUTPUT_FASTQ is omitted, writes to stdout."
  stderr.writeLine ""
  stderr.writeLine "Options:"
  stderr.writeLine "  -t THREADS         Number of threads (default: all available cores)"
  stderr.writeLine "  --backend MODE     pure|auto|legacy (default: pure)"
  stderr.writeLine "  --pure             Shortcut for --backend pure"
  stderr.writeLine "  --legacy           Shortcut for --backend legacy"
  stderr.writeLine "  --iterator         Use readDSRCPure iterator path (single-threaded)"
  stderr.writeLine "  -h, --help         Show this help"
  quit(1)

proc main() =
  var threads: uint32 = 0
  var backend = "pure"
  var useIterator = false
  var args: seq[string]

  var i = 1
  while i <= paramCount():
    let p = paramStr(i)
    if p == "-h" or p == "--help":
      usage()
    elif p == "-t":
      if i + 1 > paramCount():
        stderr.writeLine "Error: -t requires an argument"
        quit(1)
      inc i
      try:
        threads = parseUInt(paramStr(i)).uint32
      except ValueError:
        stderr.writeLine "Error: invalid thread count: " & paramStr(i)
        quit(1)
    elif p == "--backend":
      if i + 1 > paramCount():
        stderr.writeLine "Error: --backend requires an argument"
        quit(1)
      inc i
      backend = paramStr(i).toLowerAscii()
    elif p.startsWith("--backend="):
      backend = p.split("=", maxsplit = 1)[1].toLowerAscii()
    elif p == "--pure":
      backend = "pure"
    elif p == "--legacy":
      backend = "legacy"
    elif p == "--iterator":
      useIterator = true
    else:
      args.add(p)
    inc i

  if backend notin ["pure", "auto", "legacy"]:
    stderr.writeLine "Error: invalid backend mode '" & backend & "' (expected pure|auto|legacy)"
    quit(1)

  if useIterator and backend != "pure":
    stderr.writeLine "Error: --iterator requires --backend pure"
    quit(1)

  if args.len < 1:
    usage()

  let inputFile = args[0]

  if not fileExists(inputFile):
    stderr.writeLine "Error: file not found: " & inputFile
    quit(1)

  try:
    if args.len >= 2:
      let outputFile = args[1]
      if fileExists(outputFile):
        stderr.writeLine "Error: output file already exists: " & outputFile
        quit(1)
      if useIterator:
        var outFile = open(outputFile, fmWrite)
        defer: outFile.close()
        for rec in readDSRCPure(inputFile):
          writeFastqRecord(outFile, rec)
      else:
        withBackend(backend):
          decompressDSRC(inputFile, outputFile, threads = threads)
    else:
      if useIterator:
        for rec in readDSRCPure(inputFile):
          writeFastqRecord(stdout, rec)
      else:
        withBackend(backend):
          decompressDSRC(inputFile, "", threads = threads, useStdIo = true)
  except CatchableError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

when isMainModule:
  main()
