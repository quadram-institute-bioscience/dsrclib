## undsrc - Decompress DSRC files to FASTQ
##
## Usage: undsrc INPUT_FILE.dsrc > OUTPUT_FASTQ

import dsrclib
import os

proc main() =
  if paramCount() < 1:
    stderr.writeLine "Usage: undsrc INPUT_FILE.dsrc > OUTPUT_FASTQ"
    stderr.writeLine ""
    stderr.writeLine "Decompresses a DSRC file and prints FASTQ to stdout."
    stderr.writeLine "Stats are printed to stderr."
    quit(1)

  let inputFile = paramStr(1)

  if not fileExists(inputFile):
    stderr.writeLine "Error: file not found: " & inputFile
    quit(1)

  var totalRecords = 0
  var totalBases = 0

  for rec in readDSRC(inputFile):
    # Print FASTQ format to stdout
    if rec.comment.len > 0:
      stdout.writeLine "@", rec.name, " ", rec.comment
    else:
      stdout.writeLine "@", rec.name
    stdout.writeLine rec.sequence
    stdout.writeLine "+"
    stdout.writeLine rec.quality

    inc totalRecords
    totalBases += rec.sequence.len

  # Print stats to stderr
  stderr.writeLine "Total records: ", totalRecords
  stderr.writeLine "Total bases: ", totalBases

when isMainModule:
  main()
