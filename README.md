# dsrclib

Nim library for reading [DSRC2](http://sun.aei.polsl.pl/dsrc) compressed FASTQ files.
Returns [readfx](https://github.com/quadram-institute-bioscience/readfx)-compatible `FQRecord` objects.

## Installation

```
nimble install dsrclib
```

## Usage

```nim
import dsrclib

for rec in readDSRC("reads.fastq.dsrc"):
  echo rec.name, "\t", rec.sequence.len
```

A `decompressDSRC` proc is also available for file-to-file decompression:

```nim
decompressDSRC("reads.fastq.dsrc", "reads.fastq")
```

## License

GPL-2.0 (DSRC2 is GPL-2.0 licensed)
