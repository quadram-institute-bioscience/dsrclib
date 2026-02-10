<img src="tests/assets/logo.svg" style="float: right; margin-left: 10px;">

# dsrclib

[![Nim Tests](https://github.com/quadram-institute-bioscience/dsrclib/actions/workflows/test.yml/badge.svg)](https://github.com/quadram-institute-bioscience/dsrclib/actions/workflows/test.yml)

Nim library for reading [DSRC2](http://sun.aei.polsl.pl/dsrc) compressed FASTQ files.
Returns [readfx](https://github.com/quadram-institute-bioscience/readfx)-compatible `FQRecord` objects.

## Installation

```
nimble install dsrclib
```

## Usage

### Reading DSRC files

```nim
import dsrclib

for rec in readDSRC("reads.fastq.dsrc"):
  echo rec.name, "\t", rec.sequence.len
```

### Writing DSRC files

Record-by-record (single-threaded):

```nim
var records: seq[FQRecord]
for rec in readDSRC("reads.fastq.dsrc"):
  records.add(rec)
writeDSRC("output.dsrc", records)
```

### File-to-file (multi-threaded, fast)

`compressDSRC` and `decompressDSRC` use `DsrcModule` internally, which runs a multi-threaded pipeline (reader, N worker threads, writer) for maximum throughput:

```nim
compressDSRC("reads.fastq", "reads.dsrc")
decompressDSRC("reads.dsrc", "reads.fastq")
```

Optional parameters:

```nim
# Limit to 4 threads (default: all available cores)
compressDSRC("reads.fastq", "reads.dsrc", threads = 4)

# Read FASTQ from stdin
compressDSRC("", "reads.dsrc", useStdIo = true)

# Write FASTQ to stdout
decompressDSRC("reads.dsrc", "", useStdIo = true)
```

### Reading FASTQ files (plain or gzipped)

A `readFastq` iterator is provided for reading FASTQ files, with gzip and stdin support:

```nim
for rec in readFastq("reads.fastq.gz"):
  echo rec.name

# Read from stdin
for rec in readFastq("-"):
  echo rec.name
```

## CLI examples

The `example/` directory contains two command-line tools:

- `fastq2dsrc INPUT_FASTQ OUTPUT_DSRC` — compress FASTQ to DSRC (supports plain, gzipped, and stdin via `-`)
- `undsrc INPUT_DSRC [OUTPUT_FASTQ]` — decompress DSRC to FASTQ (file or stdout)

## License

GPL-2.0 (DSRC2 is GPL-2.0 licensed)
