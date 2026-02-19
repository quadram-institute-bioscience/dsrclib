import std/[os, strutils, times]
import dsrclib
import support/oracle_harness

proc formatDiffs(diffs: seq[string]; context: string): string =
  if diffs.len == 0:
    return ""
  result = context & ":\n"
  for d in diffs:
    result.add("  - " & d & "\n")

proc assertNoDiffs(diffs: seq[string]; context: string) =
  if diffs.len > 0:
    raise newException(AssertionDefect, formatDiffs(diffs, context))

proc materializeFastq(fastqPath, outPath: string) =
  if fastqPath.endsWith(".gz"):
    gzDecompressFile(fastqPath, outPath)
  else:
    copyFile(fastqPath, outPath)

type
  EncodeMode = object
    id: string
    description: string
    records: seq[FQRecord]
    lossy: bool
    dnaOrder: uint32
    qualityOrder: uint32
    cliD: int
    cliQ: int
    cliLossy: bool

proc fq(name, seq, qua: string; comment = ""): FQRecord =
  FQRecord(name: name, comment: comment, sequence: seq, quality: qua)

proc writeFastq(path: string; records: openArray[FQRecord]) =
  var f = open(path, fmWrite)
  defer: f.close()
  for r in records:
    f.write("@")
    f.write(r.name)
    if r.comment.len > 0:
      f.write(" ")
      f.write(r.comment)
    f.write("\n")
    f.write(r.sequence)
    f.write("\n+\n")
    f.write(r.quality)
    f.write("\n")

proc readAllDsrcPure(path: string): seq[FQRecord] =
  for rec in readDSRCPure(path):
    result.add(rec)

proc runCliCompress(mode: EncodeMode; inputFastq, outDsrc: string): tuple[code: int, output: string] =
  var args = @["c", "-t1", "-d" & $mode.cliD, "-q" & $mode.cliQ]
  if mode.cliLossy:
    args.add("-l")
  args.add(inputFastq)
  args.add(outDsrc)
  runDsrcCli(args)

proc runCliDecompress(inDsrc, outFastq: string): tuple[code: int, output: string] =
  runDsrcCli(["d", "-t1", inDsrc, outFastq])

proc parseEnvInt(name: string; defaultValue: int): int =
  let raw = getEnv(name, "")
  if raw.len == 0:
    return defaultValue
  try:
    parseInt(raw)
  except ValueError:
    raise newException(AssertionDefect, "Invalid integer env " & name & "=" & raw)

proc parseEnvFloat(name: string; defaultValue: float): float =
  let raw = getEnv(name, "")
  if raw.len == 0:
    return defaultValue
  try:
    parseFloat(raw)
  except ValueError:
    raise newException(AssertionDefect, "Invalid float env " & name & "=" & raw)

proc binaryFileEqual(pathA, pathB: string): bool =
  if getFileSize(pathA) != getFileSize(pathB):
    return false
  readFile(pathA) == readFile(pathB)

proc runMtStressDeterminism(
  fixtures: openArray[OracleFixture];
  repoRoot, tmpDir: string;
  useDebugControlChecks: bool
) =
  const ForceLegacyMtEnv = "DSRCLIB_FORCE_LEGACY_MT_OPERATOR"
  const PureDbgCtlEnv = "DSRCLIB_PURE_DEBUG_CONTROL_CHECKS"
  let hadLegacy = existsEnv(ForceLegacyMtEnv)
  let prevLegacy = getEnv(ForceLegacyMtEnv, "")
  let hadDbg = existsEnv(PureDbgCtlEnv)
  let prevDbg = getEnv(PureDbgCtlEnv, "")
  delEnv(ForceLegacyMtEnv)
  putEnv(PureDbgCtlEnv, if useDebugControlChecks: "1" else: "0")
  defer:
    if hadLegacy:
      putEnv(ForceLegacyMtEnv, prevLegacy)
    else:
      delEnv(ForceLegacyMtEnv)
    if hadDbg:
      putEnv(PureDbgCtlEnv, prevDbg)
    else:
      delEnv(PureDbgCtlEnv)

  let rounds = max(parseEnvInt("DSRCLIB_ORACLE_MT_STRESS_ROUNDS", 2), 2)
  let repeatFactor = max(parseEnvInt("DSRCLIB_ORACLE_MT_STRESS_REPEAT", 4), 1)
  let maxSecPerRun = parseEnvFloat("DSRCLIB_ORACLE_MT_MAX_SEC_PER_RUN", 120.0)
  let minEncodeMiBps = parseEnvFloat("DSRCLIB_ORACLE_MT_MIN_ENCODE_MIBPS", 0.0)
  let minDecodeMiBps = parseEnvFloat("DSRCLIB_ORACLE_MT_MIN_DECODE_MIBPS", 0.0)
  let maxHeapMiB = parseEnvFloat("DSRCLIB_ORACLE_MT_MAX_HEAP_MIB", 0.0)
  let threadSet = [2'u32, 4'u32, 8'u32]

  var baseFixture: OracleFixture
  var foundFixture = false
  for fx in fixtures:
    let fastqAbs = repoRoot / fx.fastqPath
    if not fileExists(fastqAbs):
      continue
    if (not foundFixture) or fx.expectedRecords > baseFixture.expectedRecords:
      baseFixture = fx
      foundFixture = true
  if not foundFixture:
    raise newException(AssertionDefect, "No FASTQ fixture available for MT stress gate")

  let baseFastq = tmpDir / "mt_stress_base.fastq"
  let stressFastq = tmpDir / "mt_stress_input.fastq"
  materializeFastq(repoRoot / baseFixture.fastqPath, baseFastq)

  if repeatFactor == 1:
    copyFile(baseFastq, stressFastq)
  else:
    let payload = readFile(baseFastq)
    var outFile = open(stressFastq, fmWrite)
    defer: outFile.close()
    for _ in 0 ..< repeatFactor:
      outFile.write(payload)

  let srcSizeBytes = float(getFileSize(stressFastq))
  if srcSizeBytes <= 0.0:
    raise newException(AssertionDefect, "MT stress input is empty: " & stressFastq)

  var totalRuns = 0
  var peakHeapMiB = 0.0

  for threads in threadSet:
    let refDsrc = tmpDir / ("mt_stress_t" & $threads & "_ref.dsrc")
    if fileExists(refDsrc):
      removeFile(refDsrc)

    for round in 0 ..< rounds:
      let outDsrc = tmpDir / ("mt_stress_t" & $threads & "_r" & $round & ".dsrc")
      let outFastq = tmpDir / ("mt_stress_t" & $threads & "_r" & $round & ".fastq")
      if fileExists(outDsrc):
        removeFile(outDsrc)
      if fileExists(outFastq):
        removeFile(outFastq)

      let t0 = epochTime()
      compressDSRC(stressFastq, outDsrc, threads = threads)
      let encSec = max(epochTime() - t0, 1e-9)
      if encSec > maxSecPerRun:
        raise newException(
          AssertionDefect,
          "MT stress encode timeout for threads=" & $threads & " round=" & $round &
          " (" & $encSec & "s > " & $maxSecPerRun & "s)"
        )
      let encMiBps = (srcSizeBytes / (1024.0 * 1024.0)) / encSec
      if minEncodeMiBps > 0.0 and encMiBps < minEncodeMiBps:
        raise newException(
          AssertionDefect,
          "MT stress encode throughput below threshold for threads=" & $threads &
          ": " & $encMiBps & " MiB/s < " & $minEncodeMiBps & " MiB/s"
        )

      if round == 0:
        copyFile(outDsrc, refDsrc)
      else:
        if not binaryFileEqual(refDsrc, outDsrc):
          raise newException(
            AssertionDefect,
            "MT stress determinism failed for threads=" & $threads &
            " (round " & $round & " DSRC bytes differ from round 0)"
          )

      let t1 = epochTime()
      decompressDSRC(outDsrc, outFastq, threads = threads)
      let decSec = max(epochTime() - t1, 1e-9)
      if decSec > maxSecPerRun:
        raise newException(
          AssertionDefect,
          "MT stress decode timeout for threads=" & $threads & " round=" & $round &
          " (" & $decSec & "s > " & $maxSecPerRun & "s)"
        )
      let decMiBps = (srcSizeBytes / (1024.0 * 1024.0)) / decSec
      if minDecodeMiBps > 0.0 and decMiBps < minDecodeMiBps:
        raise newException(
          AssertionDefect,
          "MT stress decode throughput below threshold for threads=" & $threads &
          ": " & $decMiBps & " MiB/s < " & $minDecodeMiBps & " MiB/s"
        )

      let diffs = diffFastqLogical(stressFastq, outFastq)
      if diffs.len > 0:
        raise newException(
          AssertionDefect,
          formatDiffs(diffs, "MT stress logical mismatch threads=" & $threads & " round=" & $round)
        )

      peakHeapMiB = max(peakHeapMiB, float(getOccupiedMem()) / (1024.0 * 1024.0))
      inc totalRuns
      removeFile(outDsrc)
      removeFile(outFastq)

    removeFile(refDsrc)

  if maxHeapMiB > 0.0 and peakHeapMiB > maxHeapMiB:
    raise newException(
      AssertionDefect,
      "MT stress heap usage exceeded threshold: " & $peakHeapMiB & " MiB > " & $maxHeapMiB & " MiB"
    )

  echo "OK: required pure MT stress/determinism checks passed for ", totalRuns,
    " runs (threads=2/4/8, rounds=", rounds, ", repeat=", repeatFactor, ")"

proc runEncodeOracleMatrix(tmpDir: string; useDebugControlChecks: bool) =
  let modes = @[
    EncodeMode(
      id: "plain_lossless",
      description: "quality plain + DNA B2",
      records: @[
        fq("P1", "ACGTACGTACGT", "ABCDEFGHIJKL", "plain"),
        fq("P2", "TGCATGCATGCA", "LKJIHGFEDCBA"),
        fq("P3", "AACCGGTTAACC", "BCDEFGHIJKLM")
      ],
      lossy: false,
      dnaOrder: 0'u32,
      qualityOrder: 0'u32,
      cliD: 0,
      cliQ: 1,
      cliLossy: false
    ),
    EncodeMode(
      id: "truncated_lossless",
      description: "quality truncated + DNA B2",
      records: @[
        fq("T1", "ACGTACGTACGT", "ABCDEFGH####", "trunc"),
        fq("T2", "TGCATGCATGCA", "BCDEFGHI####"),
        fq("T3", "AACCGGTTAACC", "CDEFGHIJ####")
      ],
      lossy: false,
      dnaOrder: 0'u32,
      qualityOrder: 0'u32,
      cliD: 0,
      cliQ: 1,
      cliLossy: false
    ),
    EncodeMode(
      id: "rle_lossless",
      description: "quality rle + DNA B2",
      records: @[
        fq("R1", "ACGTACGTACGT", "IIIIIIIIIIII", "rle"),
        fq("R2", "TGCATGCATGCA", "JJJJJJJJJJJJ"),
        fq("R3", "AACCGGTTAACC", "KKKKKKKKKKKK")
      ],
      lossy: false,
      dnaOrder: 0'u32,
      qualityOrder: 0'u32,
      cliD: 0,
      cliQ: 1,
      cliLossy: false
    ),
    EncodeMode(
      id: "order_lossless",
      description: "DNA order + quality order lossless",
      records: @[
        fq("O1", "ACGTNACGTNAA", "ABCDEFGHIJKL", "order"),
        fq("O2", "NNNNACGTNNNN", "LKJIHGFEDCBA"),
        fq("O3", "ACGTNNNNACGT", "BCDEFGHIJKLM")
      ],
      lossy: false,
      dnaOrder: 2'u32,
      qualityOrder: 1'u32,
      cliD: 1,
      cliQ: 1,
      cliLossy: false
    ),
    EncodeMode(
      id: "order_lossy",
      description: "DNA order + quality order lossy",
      records: @[
        fq("L1", "ACGTACGTACGT", "!!!!!+++++++"),
        fq("L2", "TGCATGCATGCA", "######******"),
        fq("L3", "AACCGGTTAACC", "$$$$$$$$$$$$")
      ],
      lossy: true,
      dnaOrder: 1'u32,
      qualityOrder: 1'u32,
      cliD: 1,
      cliQ: 1,
      cliLossy: true
    )
  ]

  var ran = 0
  for mode in modes:
    let inputFastq = tmpDir / (mode.id & ".fastq")
    let pureDsrc = tmpDir / (mode.id & ".pure.dsrc")
    let cliDsrc = tmpDir / (mode.id & ".cli.dsrc")
    let cliOutFromPure = tmpDir / (mode.id & ".pure.cli.fastq")
    let cliOutFromCli = tmpDir / (mode.id & ".cli.cli.fastq")

    writeFastq(inputFastq, mode.records)

    writeDSRCPure(
      pureDsrc,
      mode.records,
      qualityOffset = 33'u32,
      calculateCrc32 = true,
      lossy = mode.lossy,
      dnaOrder = mode.dnaOrder,
      qualityOrder = mode.qualityOrder,
      debugControlChecks = useDebugControlChecks
    )

    let (dPureCode, dPureOut) = runCliDecompress(pureDsrc, cliOutFromPure)
    assert dPureCode == 0, mode.id & ": CLI failed to decode pure archive\n" & dPureOut

    let pureDecodedByNim = readAllDsrcPure(pureDsrc)
    let pureDecodedByCli = loadFastqRecords(cliOutFromPure)
    assertNoDiffs(
      diffRecordSeqs(pureDecodedByNim, pureDecodedByCli),
      mode.id & ": Pure encode -> CLI decode parity"
    )

    if not mode.lossy:
      assertNoDiffs(
        diffRecordSeqs(mode.records, pureDecodedByCli),
        mode.id & ": Pure lossless encode should roundtrip records"
      )

    let (cCliCode, cCliOut) = runCliCompress(mode, inputFastq, cliDsrc)
    assert cCliCode == 0, mode.id & ": CLI encode failed\n" & cCliOut

    let (dCliCode, dCliOut) = runCliDecompress(cliDsrc, cliOutFromCli)
    assert dCliCode == 0, mode.id & ": CLI decode failed for CLI archive\n" & dCliOut

    let cliDecodedByNimPure = readAllDsrcPure(cliDsrc)
    let cliDecodedByCli = loadFastqRecords(cliOutFromCli)

    assertNoDiffs(
      diffRecordSeqs(cliDecodedByNimPure, cliDecodedByCli),
      mode.id & ": CLI encode -> pure decode parity"
    )

    inc ran

  echo "OK: encode oracle matrix passed for ", ran, " modes"

proc runLegacyFixtureCase(
  fx: OracleFixture;
  repoRoot, tmpDir: string;
  threads: uint32;
  modeTag: string
) =
  let fastqAbs = repoRoot / fx.fastqPath
  let plainFastq = tmpDir / (fx.id & "." & modeTag & ".fastq")
  materializeFastq(fastqAbs, plainFastq)

  let nimDsrc = tmpDir / (fx.id & "." & modeTag & ".nim.dsrc")
  let cliOutFastq = tmpDir / (fx.id & "." & modeTag & ".cli_out.fastq")
  compressDSRC(plainFastq, nimDsrc, threads = threads)
  let (dCode, dOut) = runDsrcCli(["d", "-t1", nimDsrc, cliOutFastq])
  if dCode != 0:
    raise newException(IOError, fx.id & ": dsrc decompress failed\n" & dOut)
  let nimToCliDiffs = diffFastqLogical(plainFastq, cliOutFastq)
  if nimToCliDiffs.len > 0:
    raise newException(IOError, formatDiffs(nimToCliDiffs, fx.id & ": Nim compress -> CLI decompress"))

  let cliDsrc = tmpDir / (fx.id & "." & modeTag & ".cli.dsrc")
  let nimOutFastq = tmpDir / (fx.id & "." & modeTag & ".nim_out.fastq")
  let (cCode, cOut) = runDsrcCli(["c", "-t1", plainFastq, cliDsrc])
  if cCode != 0:
    raise newException(IOError, fx.id & ": dsrc compress failed\n" & cOut)
  decompressDSRC(cliDsrc, nimOutFastq, threads = threads)
  let cliToNimDiffs = diffFastqLogical(plainFastq, nimOutFastq)
  if cliToNimDiffs.len > 0:
    raise newException(IOError, formatDiffs(cliToNimDiffs, fx.id & ": CLI compress -> Nim decompress"))

  if fx.dsrcPath.len > 0:
    let fixtureDsrc = repoRoot / fx.dsrcPath
    let nimFromFixture = tmpDir / (fx.id & "." & modeTag & ".nim_fixture.fastq")
    decompressDSRC(fixtureDsrc, nimFromFixture, threads = threads)
    let fixtureDiffs = diffFastqLogical(plainFastq, nimFromFixture)
    if fixtureDiffs.len > 0:
      raise newException(IOError, formatDiffs(fixtureDiffs, fx.id & ": Fixture DSRC -> Nim decompress"))

proc runLegacyFixtureCrossCompat(
  fixtures: openArray[OracleFixture];
  repoRoot, tmpDir: string;
  strict: bool;
  threads: uint32;
  modeTag: string
): tuple[passed: int, skipped: int] =
  for fx in fixtures:
    if not fx.crossCompat:
      continue
    if strict:
      runLegacyFixtureCase(fx, repoRoot, tmpDir, threads, modeTag)
      inc result.passed
      continue
    try:
      runLegacyFixtureCase(fx, repoRoot, tmpDir, threads, modeTag)
      inc result.passed
    except CatchableError as e:
      inc result.skipped
      let line0 = e.msg.splitLines()[0]
      echo "WARN: ", fx.id, ": ", modeTag, " cross-compat skipped (", line0, ")"

proc runStOperatorCrossCompat(
  fixtures: openArray[OracleFixture];
  repoRoot, tmpDir: string;
  strict: bool;
  useDebugControlChecks: bool;
  forceLegacy: bool
): tuple[passed: int, skipped: int] =
  const ForceLegacyStEnv = "DSRCLIB_FORCE_LEGACY_ST_OPERATOR"
  const PureDbgCtlEnv = "DSRCLIB_PURE_DEBUG_CONTROL_CHECKS"
  let hadLegacy = existsEnv(ForceLegacyStEnv)
  let prevLegacy = getEnv(ForceLegacyStEnv, "")
  let hadDbg = existsEnv(PureDbgCtlEnv)
  let prevDbg = getEnv(PureDbgCtlEnv, "")
  if forceLegacy:
    putEnv(ForceLegacyStEnv, "1")
  else:
    delEnv(ForceLegacyStEnv)
  putEnv(PureDbgCtlEnv, if useDebugControlChecks: "1" else: "0")
  try:
    result = runLegacyFixtureCrossCompat(
      fixtures,
      repoRoot,
      tmpDir,
      strict,
      threads = 1'u32,
      modeTag = "st"
    )
  finally:
    if hadLegacy:
      putEnv(ForceLegacyStEnv, prevLegacy)
    else:
      delEnv(ForceLegacyStEnv)
    if hadDbg:
      putEnv(PureDbgCtlEnv, prevDbg)
    else:
      delEnv(PureDbgCtlEnv)

proc runMtOperatorCrossCompat(
  fixtures: openArray[OracleFixture];
  repoRoot, tmpDir: string;
  strict: bool;
  useDebugControlChecks: bool;
  forceLegacy: bool
): tuple[passed: int, skipped: int] =
  const ForceLegacyMtEnv = "DSRCLIB_FORCE_LEGACY_MT_OPERATOR"
  const PureDbgCtlEnv = "DSRCLIB_PURE_DEBUG_CONTROL_CHECKS"
  let hadLegacy = existsEnv(ForceLegacyMtEnv)
  let prevLegacy = getEnv(ForceLegacyMtEnv, "")
  let hadDbg = existsEnv(PureDbgCtlEnv)
  let prevDbg = getEnv(PureDbgCtlEnv, "")
  if forceLegacy:
    putEnv(ForceLegacyMtEnv, "1")
  else:
    delEnv(ForceLegacyMtEnv)
  putEnv(PureDbgCtlEnv, if useDebugControlChecks: "1" else: "0")
  try:
    result = runLegacyFixtureCrossCompat(
      fixtures,
      repoRoot,
      tmpDir,
      strict,
      threads = 2'u32,
      modeTag = "mt"
    )
  finally:
    if hadLegacy:
      putEnv(ForceLegacyMtEnv, prevLegacy)
    else:
      delEnv(ForceLegacyMtEnv)
    if hadDbg:
      putEnv(PureDbgCtlEnv, prevDbg)
    else:
      delEnv(PureDbgCtlEnv)

proc main() =
  let testsDir = currentSourcePath().parentDir
  let repoRoot = testsDir.parentDir
  let manifestPath = repoRoot / "tests" / "oracle" / "fixtures.json"

  let fixtures = loadOracleFixtures(manifestPath)
  assert fixtures.len > 0

  for fx in fixtures:
    let fastqAbs = repoRoot / fx.fastqPath
    assert fileExists(fastqAbs), "missing FASTQ fixture: " & fastqAbs

    let fastqFp = fingerprintFastqPath(fastqAbs)
    assert fastqFp.records == fx.expectedRecords,
      fx.id & ": expected records " & $fx.expectedRecords & ", got " & $fastqFp.records
    assert fastqFp.fingerprint == fx.expectedFingerprint,
      fx.id & ": expected fingerprint " & fx.expectedFingerprint & ", got " & fastqFp.fingerprint

    if fx.dsrcPath.len > 0:
      let dsrcAbs = repoRoot / fx.dsrcPath
      assert fileExists(dsrcAbs), "missing DSRC fixture: " & dsrcAbs
      let dsrcFp = fingerprintDsrcPath(dsrcAbs)
      assert dsrcFp.records == fx.expectedRecords,
        fx.id & ": DSRC records " & $dsrcFp.records & " != expected " & $fx.expectedRecords
      assert dsrcFp.fingerprint == fx.expectedFingerprint,
        fx.id & ": DSRC fingerprint " & dsrcFp.fingerprint & " != expected " & fx.expectedFingerprint

  echo "OK: fixture manifest checks passed for ", fixtures.len, " fixtures"

  if getEnv("DSRCLIB_DSRC_CMD", "").len == 0:
    # In constrained environments, force mamba cache to /tmp where writes are permitted.
    let mambaExe = getEnv("MAMBA_EXE", "")
    if mambaExe.len > 0:
      putEnv("DSRCLIB_DSRC_CMD", "XDG_CACHE_HOME=/tmp " & quoteShell(mambaExe) & " run -n base dsrc")
    else:
      putEnv("DSRCLIB_DSRC_CMD", "XDG_CACHE_HOME=/tmp micromamba run -n base dsrc")

  let requireCli = getEnv("DSRCLIB_ORACLE_REQUIRE_CLI", "0") == "1"
  if not hasDsrcCli():
    if requireCli:
      raise newException(AssertionDefect, "dsrc CLI required but unavailable (set DSRCLIB_ORACLE_REQUIRE_CLI=0 to allow skip)")
    echo "SKIP: dsrc CLI not found in PATH; cross-compat CLI checks skipped"
    return

  let tmpDir = getTempDir() / "dsrclib_oracle_harness"
  if dirExists(tmpDir):
    removeDir(tmpDir)
  createDir(tmpDir)
  defer:
    if dirExists(tmpDir):
      removeDir(tmpDir)

  let useDebugControlChecks = dsrcCliUsesDebugControlChecks(tmpDir)
  echo "INFO: CLI debug control-check markers: ", useDebugControlChecks

  runEncodeOracleMatrix(tmpDir, useDebugControlChecks)

  let requirePureSt = getEnv("DSRCLIB_ORACLE_REQUIRE_PURE_ST_OPERATOR", "1") == "1"
  if requirePureSt:
    let st = runStOperatorCrossCompat(
      fixtures,
      repoRoot,
      tmpDir,
      strict = true,
      useDebugControlChecks = useDebugControlChecks,
      forceLegacy = false
    )
    echo "OK: required pure ST-operator cross-compat checks passed for ", st.passed, " fixtures (threads=1 default path)"
  else:
    echo "INFO: pure ST-operator cross-compat checks disabled; set DSRCLIB_ORACLE_REQUIRE_PURE_ST_OPERATOR=1 to require"

  when compileOption("threads"):
    let requirePureMt = getEnv("DSRCLIB_ORACLE_REQUIRE_PURE_MT_OPERATOR", "1") == "1"
    if requirePureMt:
      let mt = runMtOperatorCrossCompat(
        fixtures,
        repoRoot,
        tmpDir,
        strict = true,
        useDebugControlChecks = useDebugControlChecks,
        forceLegacy = false
      )
      echo "OK: required pure MT-operator cross-compat checks passed for ", mt.passed, " fixtures (threads=2 default path)"
    else:
      echo "INFO: pure MT-operator cross-compat checks disabled; set DSRCLIB_ORACLE_REQUIRE_PURE_MT_OPERATOR=1 to require"

    let requirePureMtStress = getEnv("DSRCLIB_ORACLE_REQUIRE_PURE_MT_STRESS", "1") == "1"
    if requirePureMtStress:
      runMtStressDeterminism(fixtures, repoRoot, tmpDir, useDebugControlChecks)
    else:
      echo "INFO: pure MT stress checks disabled; set DSRCLIB_ORACLE_REQUIRE_PURE_MT_STRESS=1 to require"
  else:
    echo "INFO: pure MT-operator checks unavailable without --threads:on build"

  let runLegacy = getEnv("DSRCLIB_ORACLE_RUN_LEGACY_CLI_COMPAT", "0") == "1"
  let requireLegacy = getEnv("DSRCLIB_ORACLE_REQUIRE_LEGACY_CLI_COMPAT", "0") == "1"
  if runLegacy or requireLegacy:
    let strictLegacy = requireLegacy
    let legacy = runStOperatorCrossCompat(
      fixtures,
      repoRoot,
      tmpDir,
      strict = strictLegacy,
      useDebugControlChecks = false,
      forceLegacy = true
    )
    if strictLegacy:
      echo "OK: required legacy fixture cross-compat checks passed for ", legacy.passed, " fixtures"
    else:
      echo "OK: optional legacy fixture cross-compat checks passed for ", legacy.passed,
        " fixtures (skipped ", legacy.skipped, ")"
  else:
    echo "INFO: legacy fixture cross-compat checks skipped; set DSRCLIB_ORACLE_RUN_LEGACY_CLI_COMPAT=1 to run"

main()
