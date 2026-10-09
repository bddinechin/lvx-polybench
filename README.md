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

## The result: aliasing was the whole problem

`-O2`, MINI, atomic CPU, both cores, both FP widths. 22 kernels `ok`, 7 `fp-N`,
1 `fp-contract`, no mismatches in any series.

**As shipped, PolyBench measures an aliasing wall rather than the compiler.**
The kernels take their arrays as plain pointer parameters, so GCC cannot prove
the output does not overlap the inputs, and at `-O2` its `very-cheap` cost model
refuses to emit a runtime alias check. It therefore vectorizes the trivial
`C[i][j] *= beta` loop and declines the multiply-accumulate beside it:

```
gemm.c:93:22: missed: would need a runtime alias check
gemm.c:90:19: optimized: loop vectorized using 32 byte vectors, unroll 8
```

20 of 30 kernels are blocked this way. `-DPOLYBENCH_USE_RESTRICT` — upstream's
own hook at `polybench.h:69`, no source edits — removes it:

| lvx-2, `-O2`, MINI, float | |
|---|---|
| mean speedup from `restrict` | **2.15×** |
| best | `2mm` **5.28×**, `heat-3d` 4.51×, `gemm` 4.32× |
| kernels ≥1.5× faster | **14 of 30** |
| kernels slower | **0** |
| correctness regressions | **0** |

Six of the seven kernels that emitted *no* SIMD at all now vectorize —
`heat-3d` 0→47 lane-wise instructions, `fdtd-2d` 0→39, `jacobi-2d` 0→35.

**And the gain is genuinely SIMD, not better scalar code.** On lvx-1, which has
no lane-wise arithmetic, `restrict` is worth only 1.17×. Comparing the cores:

| mean lvx-2 / lvx-1 | |
|---|---|
| without `restrict` | **1.00×** — lvx-2 bought nothing at all |
| with `restrict` | **1.84×**, up to 4.81× (`heat-3d`) |

So the vectorizer and the lvx-2 back end were working all along. An earlier
version of this file concluded the opposite — that the vectorizer fired and
gained nothing because the scalar FMA count never changed. That was the
symptom: the FMA stayed scalar because the loop holding it was never vectorized.

FP32/FP64 moves with it, mean 1.01× → **1.14×**, two kernels past 1.6×
(`heat-3d` 3.25×, `2mm` 1.73×). Still short of the 2× that four f32 lanes
against two f64 should give, so vector-width selection is the open second-order
question.

### The real remaining list

Nine kernels stay at 1.00× even with `restrict`: `trmm`, `cholesky`, `durbin`,
`lu`, `ludcmp`, `trisolv`, `seidel-2d`, `floyd-warshall`, `nussinov` —
triangular solvers and dependence-carrying stencils, where the inner loop has a
genuine loop-carried dependence or a triangular bound. Those are a real
vectorizer question, unlike the 21 that only needed an aliasing fact.

`GAPS.md` §9 has the full comparison, including why `restrict` beats
`#pragma GCC ivdep` (which also works, 3.36× on `gemm`, but asserts less and
would need annotating 155 loops) and why `-O3` is counterproductive.

### Caveats that bound these numbers

`MINI` trip counts are small, so vectorization overhead is a larger share than
at scale, and the default atomic CPU charges one cycle per bundle rather than
modelling memory — `LVX_CPU=minor` is the honest cycle count and has not been
swept.

`jacobi-1d` used to read 0.82× FP32-vs-FP64, and that was a bug in the
benchmark: a bare `0.33333` is a `double` in C, so the FP32 build widened to
f64, multiplied and narrowed back. Fixed to `SCALAR_VAL(0.33333)` (`GAPS.md`
§7) — 2,241 of its 12,552 cycles had been conversions. It is the only kernel
with a bare FP literal inside `#pragma scop`, and the printed output never
changed, so only the cycle count could reveal it.
