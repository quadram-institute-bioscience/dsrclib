## fastq2dsrc - Compress FASTQ files to DSRC
##
## Usage: fastq2dsrc INPUT_FASTQ OUTPUT_DSRC
##        cat reads.fq | fastq2dsrc - OUTPUT_DSRC
##
## Uses pure-Nim encoder by default.
## Legacy backend is opt-in at compile-time with -d:dsrclibLegacy and can be
## selected at runtime with --backend legacy.

when not declared(compressDSRC):
  import dsrclib
import os, osproc, strutils

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

proc parsePositiveInt(s: string; optName: string): int =
  try:
    result = parseInt(s)
  except ValueError:
    stderr.writeLine "Error: invalid integer for " & optName & ": " & s
    quit(1)
  if result <= 0:
    stderr.writeLine "Error: " & optName & " must be > 0"
    quit(1)

proc parseUInt32(s: string; optName: string): uint32 =
  try:
    result = parseUInt(s).uint32
  except ValueError:
    stderr.writeLine "Error: invalid integer for " & optName & ": " & s
    quit(1)

proc usage() =
  stderr.writeLine "Usage: fastq2dsrc [options] INPUT_FASTQ OUTPUT_DSRC"
  stderr.writeLine "       cat reads.fq | fastq2dsrc [options] - OUTPUT_DSRC"
  stderr.writeLine ""
  stderr.writeLine "Compresses a FASTQ file to DSRC format."
  stderr.writeLine "Supports plain FASTQ, gzipped (.gz), and stdin (-)."
  stderr.writeLine ""
  stderr.writeLine "Options:"
  stderr.writeLine "  -t THREADS            Worker/threads count (default: all available cores)"
  stderr.writeLine "  --backend MODE        pure|auto|legacy (default: pure)"
  stderr.writeLine "  --pure                Shortcut for --backend pure"
  stderr.writeLine "  --legacy              Shortcut for --backend legacy"
  stderr.writeLine "  --lossy               Pure mode: enable lossy quality compression"
  stderr.writeLine "  --dna-order N         Pure mode: DNA model order (default: 0)"
  stderr.writeLine "  --quality-order N     Pure mode: quality model order (default: 0)"
  stderr.writeLine "  --chunk-bytes N       Pure mode: target chunk bytes (default: 1048576)"
  stderr.writeLine "  --crc32               Pure mode: include per-chunk CRC32"
  stderr.writeLine "  --debug-control-checks  Pure mode: emit debug control markers"
  stderr.writeLine "  -h, --help            Show this help"
  quit(1)

proc main() =
  var threads: uint32 = 0
  var backend = "pure"
  var lossy = false
  var dnaOrder: uint32 = 0
  var qualityOrder: uint32 = 0
  var targetChunkBytes = 1 shl 20
  var calculateCrc32 = false
  var debugControlChecks = false
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
      threads = parseUInt32(paramStr(i), "-t")
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
    elif p == "--lossy":
      lossy = true
    elif p == "--dna-order":
      if i + 1 > paramCount():
        stderr.writeLine "Error: --dna-order requires an argument"
        quit(1)
      inc i
      dnaOrder = parseUInt32(paramStr(i), "--dna-order")
    elif p == "--quality-order":
      if i + 1 > paramCount():
        stderr.writeLine "Error: --quality-order requires an argument"
        quit(1)
      inc i
      qualityOrder = parseUInt32(paramStr(i), "--quality-order")
    elif p == "--chunk-bytes":
      if i + 1 > paramCount():
        stderr.writeLine "Error: --chunk-bytes requires an argument"
        quit(1)
      inc i
      targetChunkBytes = parsePositiveInt(paramStr(i), "--chunk-bytes")
    elif p == "--crc32":
      calculateCrc32 = true
    elif p == "--debug-control-checks":
      debugControlChecks = true
    else:
      args.add(p)
    inc i

  if backend notin ["pure", "auto", "legacy"]:
    stderr.writeLine "Error: invalid backend mode '" & backend & "' (expected pure|auto|legacy)"
    quit(1)

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

  let hasPureSpecificTuning =
    lossy or dnaOrder > 0'u32 or qualityOrder > 0'u32 or
    targetChunkBytes != (1 shl 20) or calculateCrc32 or debugControlChecks

  try:
    if backend == "pure":
      let workers =
        if threads == 0'u32: max(countProcessors(), 1)
        else: int(threads)
      let pureInput = if useStdin: "-" else: inputFile
      compressDSRCPure(
        pureInput,
        outputFile,
        calculateCrc32 = calculateCrc32,
        lossy = lossy,
        dnaOrder = dnaOrder,
        qualityOrder = qualityOrder,
        targetChunkBytes = targetChunkBytes,
        workers = workers,
        debugControlChecks = debugControlChecks
      )
    else:
      if hasPureSpecificTuning:
        stderr.writeLine "Error: pure-specific options require --backend pure"
        quit(1)
      let stdIoInput = if useStdin: "" else: inputFile
      if not useStdin and inputFile.endsWith(".gz"):
        let tmpFq = outputFile & ".tmp.fastq"
        try:
          gzDecompressFile(inputFile, tmpFq)
          withBackend(backend):
            compressDSRC(tmpFq, outputFile, threads = threads)
        finally:
          if fileExists(tmpFq):
            removeFile(tmpFq)
      else:
        withBackend(backend):
          compressDSRC(stdIoInput, outputFile, threads = threads, useStdIo = useStdin)
  except CatchableError as e:
    stderr.writeLine "Error: " & e.msg
    quit(1)

when isMainModule:
  main()
