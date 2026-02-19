import std/os
import dsrclib

proc readAllFastq(path: string): seq[FQRecord] =
  for rec in readFastq(path):
    result.add(rec)

proc readAllDsrc(path: string): seq[FQRecord] =
  for rec in readDSRC(path):
    result.add(rec)

proc readAllDsrcPure(path: string): seq[FQRecord] =
  for rec in readDSRCPure(path):
    result.add(rec)

proc assertSameRecords(a, b: seq[FQRecord]; label: string) =
  assert a.len == b.len, label & ": record count mismatch (" & $a.len & " vs " & $b.len & ")"
  for i in 0 ..< a.len:
    assert a[i].name == b[i].name, label & ": name mismatch at " & $i
    assert a[i].comment == b[i].comment, label & ": comment mismatch at " & $i
    assert a[i].sequence == b[i].sequence, label & ": sequence mismatch at " & $i
    assert a[i].quality == b[i].quality, label & ": quality mismatch at " & $i

proc main() =
  let base = currentSourcePath().parentDir
  let gzFastq = base / "data" / "test.fastq.gz"
  let source = readAllFastq(gzFastq)
  assert source.len == 4

  let tmpWritePure = getTempDir() / "dsrclib_test_write_pure.dsrc"
  if fileExists(tmpWritePure):
    removeFile(tmpWritePure)

  writeDSRCPure(tmpWritePure, source, qualityOffset = 33'u32, calculateCrc32 = true)
  let pureRoundtrip = readAllDsrcPure(tmpWritePure)
  assertSameRecords(source, pureRoundtrip, "writeDSRCPure -> readDSRCPure")

  let legacyRoundtrip = readAllDsrc(tmpWritePure)
  assertSameRecords(source, legacyRoundtrip, "writeDSRCPure -> readDSRC")
  removeFile(tmpWritePure)
  echo "OK: writeDSRCPure is compatible with pure and legacy decoders"

  let tmpCompressPure = getTempDir() / "dsrclib_test_compress_pure.dsrc"
  if fileExists(tmpCompressPure):
    removeFile(tmpCompressPure)

  compressDSRCPure(gzFastq, tmpCompressPure, qualityOffset = 33'u32, calculateCrc32 = true)
  let pureCompressed = readAllDsrc(tmpCompressPure)
  assertSameRecords(source, pureCompressed, "compressDSRCPure -> readDSRC")
  removeFile(tmpCompressPure)
  echo "OK: compressDSRCPure FASTQ path produces legacy-readable DSRC"

  let tmpPlainFastq = getTempDir() / "dsrclib_test_compress_pure.fastq"
  let tmpFlagDsrc = getTempDir() / "dsrclib_test_compress_flag.dsrc"
  let tmpStDsrc = getTempDir() / "dsrclib_test_st_operator_default.dsrc"
  let tmpStFastq = getTempDir() / "dsrclib_test_st_operator_default.fastq"
  let tmpLegacyStDsrc = getTempDir() / "dsrclib_test_st_operator_legacy.dsrc"
  let tmpLegacyStFastq = getTempDir() / "dsrclib_test_st_operator_legacy.fastq"
  let tmpMtDsrc = getTempDir() / "dsrclib_test_mt_operator_default.dsrc"
  let tmpMtFastq = getTempDir() / "dsrclib_test_mt_operator_default.fastq"
  let tmpLegacyMtDsrc = getTempDir() / "dsrclib_test_mt_operator_legacy.dsrc"
  let tmpLegacyMtFastq = getTempDir() / "dsrclib_test_mt_operator_legacy.fastq"
  if fileExists(tmpPlainFastq):
    removeFile(tmpPlainFastq)
  if fileExists(tmpFlagDsrc):
    removeFile(tmpFlagDsrc)
  if fileExists(tmpStDsrc):
    removeFile(tmpStDsrc)
  if fileExists(tmpStFastq):
    removeFile(tmpStFastq)
  if fileExists(tmpLegacyStDsrc):
    removeFile(tmpLegacyStDsrc)
  if fileExists(tmpLegacyStFastq):
    removeFile(tmpLegacyStFastq)
  if fileExists(tmpMtDsrc):
    removeFile(tmpMtDsrc)
  if fileExists(tmpMtFastq):
    removeFile(tmpMtFastq)
  if fileExists(tmpLegacyMtDsrc):
    removeFile(tmpLegacyMtDsrc)
  if fileExists(tmpLegacyMtFastq):
    removeFile(tmpLegacyMtFastq)

  gzDecompressFile(gzFastq, tmpPlainFastq)
  putEnv("DSRCLIB_FORCE_PURE_ENCODE", "1")
  try:
    compressDSRC(tmpPlainFastq, tmpFlagDsrc)
  finally:
    delEnv("DSRCLIB_FORCE_PURE_ENCODE")

  let forcedPure = readAllDsrc(tmpFlagDsrc)
  assertSameRecords(source, forcedPure, "compressDSRC(force pure) -> readDSRC")
  removeFile(tmpFlagDsrc)
  echo "OK: DSRCLIB_FORCE_PURE_ENCODE routes compressDSRC through pure backend"

  compressDSRC(tmpPlainFastq, tmpStDsrc, threads = 1)
  decompressDSRC(tmpStDsrc, tmpStFastq, threads = 1)

  let stRoundtrip = readAllFastq(tmpStFastq)
  assertSameRecords(source, stRoundtrip, "threads=1 default pure ST roundtrip")
  echo "OK: threads=1 operator calls route through pure backend by default"

  when defined(dsrclibLegacy):
    putEnv("DSRCLIB_FORCE_LEGACY_ST_OPERATOR", "1")
    try:
      compressDSRC(tmpPlainFastq, tmpLegacyStDsrc, threads = 1)
      decompressDSRC(tmpLegacyStDsrc, tmpLegacyStFastq, threads = 1)
    finally:
      delEnv("DSRCLIB_FORCE_LEGACY_ST_OPERATOR")

    let legacyStRoundtrip = readAllFastq(tmpLegacyStFastq)
    assertSameRecords(source, legacyStRoundtrip, "threads=1 forced legacy ST roundtrip")
    echo "OK: DSRCLIB_FORCE_LEGACY_ST_OPERATOR keeps legacy ST fallback available"
  else:
    echo "SKIP: build without -d:dsrclibLegacy does not provide legacy ST fallback"

  when compileOption("threads"):
    compressDSRC(tmpPlainFastq, tmpMtDsrc, threads = 2)
    decompressDSRC(tmpMtDsrc, tmpMtFastq, threads = 2)
    let mtRoundtrip = readAllFastq(tmpMtFastq)
    assertSameRecords(source, mtRoundtrip, "threads=2 default pure MT roundtrip")
    echo "OK: threads=2 operator calls route through pure MT backend by default"

    when defined(dsrclibLegacy):
      putEnv("DSRCLIB_FORCE_LEGACY_MT_OPERATOR", "1")
      try:
        compressDSRC(tmpPlainFastq, tmpLegacyMtDsrc, threads = 2)
        decompressDSRC(tmpLegacyMtDsrc, tmpLegacyMtFastq, threads = 2)
      finally:
        delEnv("DSRCLIB_FORCE_LEGACY_MT_OPERATOR")

      let legacyMtRoundtrip = readAllFastq(tmpLegacyMtFastq)
      assertSameRecords(source, legacyMtRoundtrip, "threads=2 forced legacy MT roundtrip")
      echo "OK: DSRCLIB_FORCE_LEGACY_MT_OPERATOR keeps legacy MT fallback available"
    else:
      echo "SKIP: build without -d:dsrclibLegacy does not provide legacy MT fallback"
  else:
    echo "SKIP: MT operator routing checks require --threads:on build"

  removeFile(tmpPlainFastq)
  removeFile(tmpStDsrc)
  removeFile(tmpStFastq)
  removeFile(tmpLegacyStDsrc)
  removeFile(tmpLegacyStFastq)
  if fileExists(tmpMtDsrc):
    removeFile(tmpMtDsrc)
  if fileExists(tmpMtFastq):
    removeFile(tmpMtFastq)
  if fileExists(tmpLegacyMtDsrc):
    removeFile(tmpLegacyMtDsrc)
  if fileExists(tmpLegacyMtFastq):
    removeFile(tmpLegacyMtFastq)

main()
