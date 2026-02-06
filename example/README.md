# undsrc.nim

`undsrc` is a demo binary that uses dsrclib to deflate a 
dsrc compressed fastq file.

Usage:
```
undsrc  INPUT_FILE.dsrc > OUTPUT_FASTQ
```

* Will print to STDOUT the decompressed file
* Will print to STDERR (at the end) the total number of records printed and the total number of bases printed


