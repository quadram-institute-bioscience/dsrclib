# Examples

## `undsrc.nim`

Decompress DSRC to FASTQ (pure backend by default):

```bash
undsrc [options] INPUT_FILE.dsrc [OUTPUT_FASTQ]
```

Common options:

- `-t THREADS` set worker threads for operator path
- `--backend pure|auto|legacy` select runtime backend
- `--iterator` use `readDSRCPure` iterator path

## `fastq2dsrc.nim`

Compress FASTQ to DSRC (pure encoder by default):

```bash
fastq2dsrc [options] INPUT_FASTQ OUTPUT_DSRC
cat reads.fq | fastq2dsrc [options] - OUTPUT_DSRC
```

Pure-mode options:

- `--lossy`
- `--dna-order N`
- `--quality-order N`
- `--chunk-bytes N`
- `--crc32`
- `--debug-control-checks`

Legacy backend is available only when compiled with `-d:dsrclibLegacy`.

