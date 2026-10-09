# lvx-polybench

PolyBench/C 4.2.1-beta, imported for LVX and wired up as a
**compiler-performance tracker**: 30 numerical kernels, each timed with the
machine's own cycle counter and each checked against a generated reference
before its number is believed.

- `ORIGIN.md` — provenance, and why the first commit is unmodified upstream
- `GAPS.md` — the six things porting PolyBench to LVX required, measured
- `harness/README.md` — how to run it, and why it measures what it measures
- `results/` — committed TSV series, one row per kernel
- `reference-output/` — the x86-generated correctness oracle

## Quick start

```bash
./harness/run.sh                        # lvx-2, -O2, MINI, float AND double
./harness/fpcompare.sh                  # 32- vs 64-bit FP side by side
./harness/compare.sh results/A.tsv results/B.tsv
```

A sweep is minutes. `make-reference.sh` regenerates the oracle; it is committed,
so a normal run does not need it.

## Why this suite, next to `lvx-mibench`

The two answer different questions and neither replaces the other.

`lvx-mibench` is **integer, control-flow-heavy, real application code** — jpeg,
ispell, blowfish, dijkstra — and what it exercises is the C library, the ABI,
`argv`, string handling, and the long tail of things an embedded program does.
It is the portability and realism check.

PolyBench is **dense floating-point loop nests and nothing else**: affine loops
over arrays, no input, no I/O, no system calls. That makes it the instrument for
the one thing MiBench cannot isolate — *did the vectorizer and the scheduler do
their job* — and it is far easier to run under an ISS. All 30 kernels build and
run on both cores at both FP widths; the port needed six changes, all of them in
PolyBench's own instrumentation and none in newlib, gem5 or the compiler.

Two properties make it unusually well suited here:

**The kernel is timed, not the program.** PolyBench brackets the kernel between
`polybench_start_instruments`/`polybench_stop_instruments`, which on LVX read
`$frcc` — the 64-bit free-running cycle counter, where x86's `RDTSC` was. So the
guest prints the kernel's own cycle count, excluding allocation, array
initialisation and `printf`. For `gemm` that is 109,316 cycles inside a 208,020-cycle
program: tracking the whole-program figure, as `lvx-mibench` must, would halve
every real improvement before it showed.

**The oracle is generated, not archived.** PolyBench ships no reference output,
but it ships `POLYBENCH_DUMP_ARRAYS` and kernels that read no input — so the
reference is produced by running the same source natively on x86, for any
dataset size or data type, reproducibly. Every tracked run is diffed against it,
because on this target a miscompile has already looked like a speed-up: a stale
`libgcc` object carrying eight out-of-date instruction encodings made a `gemm`
prototype return wrong results while exiting 0.

## Both FP widths are the measurement

`TYPE` defaults to `float double` and a sweep produces both. An LVX SIMD lane
group is 128 bits wide whatever it holds — four floats or two doubles — and
scalar f32 and f64 cost the same. So the per-kernel float/double ratio is a
direct read-out of how much the vectorizer achieved: **~2× means the lanes are
filling, ~1× means the kernel is effectively scalar.**

## The first result

`results/lvx-2-O2-mini-{float,double}.tsv`, 2026-10-09, `-O2`, `MINI`, atomic
CPU. 29 of 30 kernels `ok` or `fp-N`, one `fp-contract`, no mismatches — and:

```
30 kernels compared, mean speedup 1.01x
>=1.6x (lanes filling): 0    <=1.15x (effectively scalar): 29
```

**Nothing in PolyBench is being vectorized to any useful degree.** The best
kernel is `durbin` at 1.22×, two are *slower* in float than in double
(`jacobi-1d` 0.82×, `trisolv` 0.99×), and the rest sit at 1.00–1.09×. The
`gemm` figures bear this out directly: of its two loops only `C[i][j] *= beta`
vectorizes, while the multiply-accumulate that is the actual kernel stays scalar
`ffmaw`/`fmulw`.

See `harness/README.md` for the caveats that bound this — `MINI` trip counts are
small, and the atomic CPU charges one cycle per bundle rather than modelling
memory — but the conclusion is not a measurement artefact: it is the same gap
the `lvx-gcc-while-ult-plan` work is aimed at, measured across 30 kernels
instead of one.
