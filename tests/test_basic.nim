import dsrclib
import os

let testFile = currentSourcePath().parentDir / "data" / "test.fastq.dsrc"

# Test 1: Read records from .dsrc file - count check
var count = 0
for rec in readDSRC(testFile):
  assert rec.name.len > 0, "name should not be empty"
  assert rec.sequence.len > 0, "sequence should not be empty"
  assert rec.quality.len == rec.sequence.len,
    "quality length (" & $rec.quality.len & ") != sequence length (" & $rec.sequence.len & ")"
  inc count
assert count == 4, "expected 4 records, got " & $count
echo "OK: read ", count, " records from test.fastq.dsrc"

# Test 2: Verify specific record contents
var records: seq[FQRecord]
for rec in readDSRC(testFile):
  records.add(rec)

# SEQ1: has name and comment
assert records[0].name == "SEQ1", "SEQ1 name mismatch: got '" & records[0].name & "'"
assert records[0].comment == "first test sequence"
assert records[0].sequence == "ACGTACGTACGTACGTACGTACGTACGT"
assert records[0].quality == "IIIIIIIIIIIIIIIIIIIIIIIIIIII"
assert records[0].sequence.len == 28
assert records[0].quality.len == 28

# SEQ2: has longer comment
assert records[1].name == "SEQ2"
assert records[1].comment == "second test sequence with longer comment"
assert records[1].sequence == "GGCCTTAAGGCCTTAAGGCCTTAA"
assert records[1].quality == "HHHHHHHHHHHHHHHHHHHHHHHH"
assert records[1].sequence.len == 24

# SEQ3: no comment (name only)
assert records[2].name == "SEQ3"
assert records[2].comment == ""
assert records[2].sequence == "ATATATATATATATAT"
assert records[2].quality == "DDDDDDDDDDDDDDDD"
assert records[2].sequence.len == 16

# SEQ4: varying quality scores
assert records[3].name == "SEQ4"
assert records[3].comment == "quality varies"
assert records[3].sequence == "ACACACACACAC"
assert records[3].quality == "ABCDEFGHIJKL"
assert records[3].sequence.len == 12

echo "OK: all record contents verified"

# Test 3: decompressDSRC file-to-file
let tmpOut = getTempDir() / "dsrclib_test_output.fastq"
decompressDSRC(testFile, tmpOut)
var lineCount = 0
for line in lines(tmpOut):
  inc lineCount
assert lineCount == 16, "expected 16 lines in decompressed FASTQ, got " & $lineCount
removeFile(tmpOut)
echo "OK: file-to-file decompression works"

# Test 4: Record-by-record roundtrip via writeDSRC
var original: seq[FQRecord]
for rec in readDSRC(testFile):
  original.add(rec)

let tmpDsrc = getTempDir() / "dsrclib_roundtrip.dsrc"
writeDSRC(tmpDsrc, original)

var roundtripped: seq[FQRecord]
for rec in readDSRC(tmpDsrc):
  roundtripped.add(rec)

assert roundtripped.len == original.len,
  "roundtrip count: expected " & $original.len & ", got " & $roundtripped.len
for i in 0 ..< original.len:
  assert roundtripped[i].name == original[i].name,
    "name mismatch at " & $i & ": '" & roundtripped[i].name & "' vs '" & original[i].name & "'"
  assert roundtripped[i].comment == original[i].comment,
    "comment mismatch at " & $i
  assert roundtripped[i].sequence == original[i].sequence,
    "sequence mismatch at " & $i
  assert roundtripped[i].quality == original[i].quality,
    "quality mismatch at " & $i
removeFile(tmpDsrc)
echo "OK: record-by-record roundtrip passed"

# Test 5: File-to-file compression roundtrip via compressDSRC
let tmpFq = getTempDir() / "dsrclib_compress_test.fastq"
let tmpDsrc2 = getTempDir() / "dsrclib_compress_test.dsrc"
decompressDSRC(testFile, tmpFq)
compressDSRC(tmpFq, tmpDsrc2)
var count2 = 0
for rec in readDSRC(tmpDsrc2):
  inc count2
assert count2 == 4, "compress roundtrip: expected 4 records, got " & $count2
removeFile(tmpFq)
removeFile(tmpDsrc2)
echo "OK: file-to-file compression roundtrip passed"

echo "All tests passed!"
