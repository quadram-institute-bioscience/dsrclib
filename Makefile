NIM ?= nim
NIMFLAGS = -d:danger --gc:arc --opt:speed --path:. --passC:-march=native
TEST_NIMCACHE ?= .nimcache
BINDIR = bin
EXAMPLES = fastq2dsrc undsrc
DSRC_CMD ?= $(shell \
	if command -v dsrc >/dev/null 2>&1; then \
		command -v dsrc; \
	elif command -v micromamba >/dev/null 2>&1; then \
		echo "micromamba run -n base dsrc"; \
	fi)

TARGETS = $(addprefix $(BINDIR)/, $(EXAMPLES))
TEST_SOURCES = $(sort $(wildcard tests/test_*.nim))

INPUT_GZ =  tests/data/large.fastq.gz
BENCHDIR = benchmark

.PHONY: all clean bench benchpure test testpure

all: $(TARGETS)

$(BINDIR):
	mkdir -p $(BINDIR)

$(BINDIR)/fastq2dsrc: example/fastq2dsrc.nim dsrclib.nim dsrclib/dsrc_bindings.nim | $(BINDIR)
	$(NIM) c $(NIMFLAGS) --out:$@ example/fastq2dsrc.nim

$(BINDIR)/undsrc: example/undsrc.nim dsrclib.nim dsrclib/dsrc_bindings.nim | $(BINDIR)
	$(NIM) c $(NIMFLAGS) --out:$@ example/undsrc.nim

bench: $(TARGETS)
	@mkdir -p $(BENCHDIR)
	$(eval TMPDIR := $(shell mktemp -d))
	@echo "=== Decompressing $(INPUT_GZ) to $(TMPDIR)/test.fastq ==="
	gunzip -c $(INPUT_GZ) > $(TMPDIR)/test.fastq
	@echo ""
	@echo "=== Compression: single thread ==="
	hyperfine \
		"dsrc c -t1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc1" \
		"$(BINDIR)/fastq2dsrc -t 1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc2" \
		--prepare "rm -f $(TMPDIR)/test.dsrc1 $(TMPDIR)/test.dsrc2" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/compression_single.csv \
		--export-markdown $(BENCHDIR)/compression_single.md
	@echo ""
	@echo "=== Compression: threaded (4 threads) ==="
	hyperfine \
		"dsrc c -t4 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc1" \
		"$(BINDIR)/fastq2dsrc -t 4 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc2" \
		--prepare "rm -f $(TMPDIR)/test.dsrc1 $(TMPDIR)/test.dsrc2" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/compression_threaded.csv \
		--export-markdown $(BENCHDIR)/compression_threaded.md
	@echo ""
	@echo "--- Preparing DSRC file for decompression benchmarks ---"
	dsrc c -t1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc
	@echo ""
	@echo "=== Decompression: single thread ==="
	hyperfine \
		"dsrc d -t1 $(TMPDIR)/test.dsrc $(TMPDIR)/out1.fastq" \
		"$(BINDIR)/undsrc -t 1 $(TMPDIR)/test.dsrc $(TMPDIR)/out2.fastq" \
		--prepare "rm -f $(TMPDIR)/out1.fastq $(TMPDIR)/out2.fastq" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/decompression_single.csv \
		--export-markdown $(BENCHDIR)/decompression_single.md
	@echo ""
	@echo "=== Decompression: threaded (4 threads) ==="
	hyperfine \
		"dsrc d -t4 $(TMPDIR)/test.dsrc $(TMPDIR)/out1.fastq" \
		"$(BINDIR)/undsrc -t 4 $(TMPDIR)/test.dsrc $(TMPDIR)/out2.fastq" \
		--prepare "rm -f $(TMPDIR)/out1.fastq $(TMPDIR)/out2.fastq" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/decompression_threaded.csv \
		--export-markdown $(BENCHDIR)/decompression_threaded.md
	@echo ""
	@echo "=== Cleaning up temp dir ==="
	rm -rf $(TMPDIR)
	@echo "Results saved to $(BENCHDIR)/"
	@echo ""
	@echo "=== Analysing results ==="
	python3 $(BENCHDIR)/bench_summary.py

benchpure: $(TARGETS)
	@mkdir -p $(BENCHDIR)
	$(eval TMPDIR := $(shell mktemp -d))
	@echo "=== Decompressing $(INPUT_GZ) to $(TMPDIR)/test.fastq ==="
	gunzip -c $(INPUT_GZ) > $(TMPDIR)/test.fastq
	@echo ""
	@echo "=== Pure-only Compression: single thread ==="
	hyperfine \
		"$(BINDIR)/fastq2dsrc -t 1 $(TMPDIR)/test.fastq $(TMPDIR)/test.pure.st.dsrc" \
		--prepare "rm -f $(TMPDIR)/test.pure.st.dsrc" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/pure_compression_single.csv \
		--export-markdown $(BENCHDIR)/pure_compression_single.md
	@echo ""
	@echo "=== Pure-only Compression: threaded (4 threads) ==="
	hyperfine \
		"$(BINDIR)/fastq2dsrc -t 4 $(TMPDIR)/test.fastq $(TMPDIR)/test.pure.mt.dsrc" \
		--prepare "rm -f $(TMPDIR)/test.pure.mt.dsrc" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/pure_compression_threaded.csv \
		--export-markdown $(BENCHDIR)/pure_compression_threaded.md
	@echo ""
	@echo "--- Preparing pure DSRC file for decompression benchmarks ---"
	$(BINDIR)/fastq2dsrc -t 1 $(TMPDIR)/test.fastq $(TMPDIR)/test.pure.dsrc
	@echo ""
	@echo "=== Pure-only Decompression: single thread ==="
	hyperfine \
		"$(BINDIR)/undsrc -t 1 $(TMPDIR)/test.pure.dsrc $(TMPDIR)/out.pure.st.fastq" \
		--prepare "rm -f $(TMPDIR)/out.pure.st.fastq" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/pure_decompression_single.csv \
		--export-markdown $(BENCHDIR)/pure_decompression_single.md
	@echo ""
	@echo "=== Pure-only Decompression: threaded (4 threads) ==="
	hyperfine \
		"$(BINDIR)/undsrc -t 4 $(TMPDIR)/test.pure.dsrc $(TMPDIR)/out.pure.mt.fastq" \
		--prepare "rm -f $(TMPDIR)/out.pure.mt.fastq" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/pure_decompression_threaded.csv \
		--export-markdown $(BENCHDIR)/pure_decompression_threaded.md
	@echo ""
	@echo "=== Cleaning up temp dir ==="
	rm -rf $(TMPDIR)
	@echo "Pure benchmark results saved to $(BENCHDIR)/"

test:
	@echo "=== Core test suite (default mm) ==="
	@for t in $(TEST_SOURCES); do \
		if [ "$$t" = "tests/test_oracle_harness.nim" ]; then \
			echo ">>> $$t (oracle CLI auto-probe disabled)"; \
			DSRCLIB_DSRC_CMD=__skip_dsrc__ \
			$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/default --threads:on -r $$t; \
		else \
			echo ">>> $$t"; \
			$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/default -r $$t; \
		fi; \
	done
	@echo ""
	@echo "=== Core test suite (ARC mm) ==="
	@for t in $(TEST_SOURCES); do \
		if [ "$$t" = "tests/test_oracle_harness.nim" ]; then \
			echo ">>> $$t (oracle CLI auto-probe disabled)"; \
			DSRCLIB_DSRC_CMD=__skip_dsrc__ \
			$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/arc --mm:arc --threads:on -r $$t; \
		else \
			echo ">>> $$t"; \
			$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/arc --mm:arc -r $$t; \
		fi; \
	done
	@echo ""
	@echo "=== Example build + smoke test (default) ==="
	$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/example-default -o:example/undsrc example/undsrc.nim
	./example/undsrc tests/data/test.fastq.dsrc > /tmp/out.fq
	test $$(wc -l < /tmp/out.fq) -eq 16
	@echo ""
	@echo "=== Pure-default oracle harness (strict) ==="
	@if [ -z "$(DSRC_CMD)" ]; then \
		echo "Error: dsrc CLI not found. Install dsrc or run with DSRC_CMD=/path/to/dsrc (or DSRC_CMD='micromamba run -n base dsrc')"; \
		exit 1; \
	fi
	DSRCLIB_DSRC_CMD="$(DSRC_CMD)" \
	DSRCLIB_ORACLE_REQUIRE_CLI=1 \
	DSRCLIB_ORACLE_REQUIRE_PURE_ST_OPERATOR=1 \
	DSRCLIB_ORACLE_REQUIRE_PURE_MT_OPERATOR=1 \
	DSRCLIB_ORACLE_REQUIRE_PURE_MT_STRESS=1 \
	DSRCLIB_ORACLE_MT_STRESS_REPEAT=2 \
	$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/oracle-strict --threads:on -r tests/test_oracle_harness.nim
	@echo ""
	@echo "=== Example build + smoke test (pure-default) ==="
	$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/example-pure -o:example/undsrc_pure example/undsrc.nim
	./example/undsrc_pure tests/data/test.fastq.dsrc > /tmp/out_pure.fq
	test $$(wc -l < /tmp/out_pure.fq) -eq 16
	@echo ""
	@echo "=== Legacy backend opt-in build check ==="
	$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/legacy-check -d:dsrclibLegacy -r tests/test_basic.nim

testpure:
	@echo "=== Pure-only test suite (default mm) ==="
	@for t in $(TEST_SOURCES); do \
		if [ "$$t" = "tests/test_oracle_harness.nim" ]; then \
			echo ">>> $$t (oracle CLI disabled)"; \
			DSRCLIB_DSRC_CMD=__skip_dsrc__ \
			$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/pure-default --threads:on -r $$t; \
		else \
			echo ">>> $$t"; \
			$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/pure-default -r $$t; \
		fi; \
	done
	@echo ""
	@echo "=== Pure-only test suite (ARC mm) ==="
	@for t in $(TEST_SOURCES); do \
		if [ "$$t" = "tests/test_oracle_harness.nim" ]; then \
			echo ">>> $$t (oracle CLI disabled)"; \
			DSRCLIB_DSRC_CMD=__skip_dsrc__ \
			$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/pure-arc --mm:arc --threads:on -r $$t; \
		else \
			echo ">>> $$t"; \
			$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/pure-arc --mm:arc -r $$t; \
		fi; \
	done
	@echo ""
	@echo "=== Example build + smoke test (pure-only) ==="
	$(NIM) cpp --path:. --nimcache:$(TEST_NIMCACHE)/pure-example -o:example/undsrc_pure example/undsrc.nim
	./example/undsrc_pure tests/data/test.fastq.dsrc > /tmp/out_pure.fq
	test $$(wc -l < /tmp/out_pure.fq) -eq 16

clean:
	rm -rf $(BINDIR)
	bash tests/clean.sh
