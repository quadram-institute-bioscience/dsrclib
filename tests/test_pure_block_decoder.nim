import std/[os, strutils]
import dsrclib

const
  FnvOffset = 1469598103934665603'u64
  FnvPrime = 1099511628211'u64

proc fnvMix(h: var uint64; b: uint8) =
  h = (h xor uint64(b)) * FnvPrime

proc fnvMixStr(h: var uint64; s: string) =
  for ch in s:
    h.fnvMix(uint8(ord(ch)))

proc fnvMixU32(h: var uint64; x: uint32) =
  h.fnvMix(uint8(x and 0xFF'u32))
  h.fnvMix(uint8((x shr 8) and 0xFF'u32))
  h.fnvMix(uint8((x shr 16) and 0xFF'u32))
  h.fnvMix(uint8((x shr 24) and 0xFF'u32))

proc fingerprintPure(path: string): tuple[count: int, fp: string] =
  var h = FnvOffset
  var n = 0
  for rec in readDSRCPure(path):
    h.fnvMixU32(uint32(rec.name.len))
    h.fnvMixStr(rec.name)
    h.fnvMixU32(uint32(rec.comment.len))
    h.fnvMixStr(rec.comment)
    h.fnvMixU32(uint32(rec.sequence.len))
    h.fnvMixStr(rec.sequence)
    h.fnvMixU32(uint32(rec.quality.len))
    h.fnvMixStr(rec.quality)
    inc n
  (n, toHex(h, 16).toLowerAscii())

proc main() =
  let base = currentSourcePath().parentDir
  let tinyDsrc = base / "data" / "test.fastq.dsrc"
  let medDsrc = base / "data" / "16S_R1.fq.dsrc"

  let tiny = fingerprintPure(tinyDsrc)
  assert tiny.count == 4
  assert tiny.fp == "7143f668f6431066"

  let medium = fingerprintPure(medDsrc)
  assert medium.count == 6137
  assert medium.fp == "5ff1400310305e2c"
  echo "OK: pure block decoder matched fixture fingerprints"

  var cppTiny: seq[FQRecord]
  for rec in readDSRC(tinyDsrc):
    cppTiny.add(rec)

  var pureTiny: seq[FQRecord]
  for rec in readDSRCPure(tinyDsrc):
    pureTiny.add(rec)

  assert pureTiny.len == cppTiny.len
  for i in 0 ..< pureTiny.len:
    assert pureTiny[i].name == cppTiny[i].name
    assert pureTiny[i].comment == cppTiny[i].comment
    assert pureTiny[i].sequence == cppTiny[i].sequence
    assert pureTiny[i].quality == cppTiny[i].quality
  echo "OK: readDSRCPure matches legacy readDSRC on tiny fixture"

  when defined(dsrclibLegacy):
    # Decode parity for order-model path (DNA order + lossy quality order).
    proc makeCppRec(tag, seq, qua: string): CppFastqRecord =
      var rec = newCppFastqRecord()
      rec.setTag(tag)
      rec.setSequence(seq)
      rec.setQuality(qua)
      rec.setPlus("+")
      rec

    let tmpOrder = getTempDir() / "dsrclib_pure_order_path_test.dsrc"
    if fileExists(tmpOrder):
      removeFile(tmpOrder)

    var archive = newDsrcArchive()
    archive.setQualityOffset(33'u32)
    archive.setLossyCompression(true)
    archive.setDnaCompressionLevel(1'u32)      # dnaOrder = 3
    archive.setQualityCompressionLevel(1'u32)  # qualityOrder = 3
    archive.startCompress(tmpOrder.cstring)
    archive.writeNextRecord(makeCppRec("@R1", "ACGTNACGTN", "II!!II!!II"))
    archive.writeNextRecord(makeCppRec("@R2 test", "NNNNACGT", "!!!!IIII"))
    archive.finishCompress()

    var cppOrder: seq[FQRecord]
    for rec in readDSRC(tmpOrder):
      cppOrder.add(rec)
    var pureOrder: seq[FQRecord]
    for rec in readDSRCPure(tmpOrder):
      pureOrder.add(rec)

    removeFile(tmpOrder)

    assert pureOrder.len == cppOrder.len
    for i in 0 ..< pureOrder.len:
      assert pureOrder[i].name == cppOrder[i].name
      assert pureOrder[i].comment == cppOrder[i].comment
      assert pureOrder[i].sequence == cppOrder[i].sequence
      assert pureOrder[i].quality == cppOrder[i].quality
    echo "OK: readDSRCPure matches legacy readDSRC on order-model lossy fixture"
  else:
    echo "SKIP: legacy order-model parity fixture requires -d:dsrclibLegacy"

main()
