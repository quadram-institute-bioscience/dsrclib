import std/[os, strformat]
import ../support/oracle_harness

proc main() =
  if paramCount() != 2:
    quit("Usage: nim r tests/oracle/diff_fastq_logical.nim -- <expected.fastq(.gz)> <actual.fastq(.gz)>", QuitFailure)

  let expectedPath = paramStr(1)
  let actualPath = paramStr(2)
  let diffs = diffFastqLogical(expectedPath, actualPath, maxDiffs = 16)
  if diffs.len == 0:
    echo "No logical FASTQ differences found."
    quit(QuitSuccess)

  echo fmt"Found {diffs.len} logical differences:"
  for d in diffs:
    echo " - ", d
  quit(QuitFailure)

main()

