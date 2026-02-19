import std/[os, strutils]
import dsrclib
import dsrclib/pure

proc expectFail(opName, expectedSubstr: string; body: proc()) =
  var raised = false
  try:
    body()
  except IOError as e:
    raised = true
    doAssert e.msg.toLowerAscii().contains(expectedSubstr.toLowerAscii()),
      opName & ": unexpected error message: " & e.msg
  except DsrcFormatError as e:
    raised = true
    doAssert e.msg.toLowerAscii().contains(expectedSubstr.toLowerAscii()),
      opName & ": unexpected error message: " & e.msg
  doAssert raised, opName & ": expected failure, but operation succeeded"

proc writeFastq(path: string; lines: openArray[string]) =
  var f = open(path, fmWrite)
  defer: f.close()
  for ln in lines:
    f.write(ln)
    f.write("\n")

proc main() =
  let tmpColorFastq = getTempDir() / "dsrclib_pure_unsupported_colorspace.fastq"
  if fileExists(tmpColorFastq):
    removeFile(tmpColorFastq)

  # second base as numeric color code => color-space signature
  writeFastq(tmpColorFastq, [
    "@CS1",
    "A0..3",
    "+",
    "IIIII",
    "@CS2",
    "T1..2",
    "+",
    "IIIII"
  ])

  expectFail("compressDSRCPure color-space", "color-space") do:
    compressDSRCPure(tmpColorFastq, getTempDir() / "dsrclib_pure_unsupported_colorspace.dsrc")

  removeFile(tmpColorFastq)
  echo "OK: color-space inputs are explicitly rejected by pure encoder"

  let recs = @[
    PureFastqRecord(title: "@R1 test", sequence: "ACGTACGT", plus: "+", quality: "IIIIIIII", truncatedLen: 0'u16)
  ]
  var ds = defaultFastqDatasetType()
  ds.qualityOffset = 33'u32
  ds.plusRepetition = false
  ds.colorSpace = false

  var settings = defaultCompressionSettings()
  settings.lossy = false
  settings.dnaOrder = 0'u32
  settings.qualityOrder = 0'u32
  settings.calculateCrc32 = false
  settings.tagPreserveFlags = 1'u64

  expectFail("encodeChunkRecords non-default tag preserve", "tag preserve") do:
    discard encodeChunkRecords(recs, ds, settings)

  echo "OK: non-default tag-preserve mode is explicitly rejected by pure encoder"

main()
