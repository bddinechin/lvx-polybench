# Running PolyBench on LVX: the gaps, measured

Status 2026-10-09. Everything below was measured against the installed
toolchain and `gem5-lvx2.opt`, not inferred from reading code.

## Summary

PolyBench ports to LVX far more easily than MiBench did, and the reason is
structural rather than lucky: **the kernels take no input and make no system
calls.** Each one allocates its arrays, fills them from index arithmetic in
`init_array`, computes, and prints. There is no `argv` to deliver, no file to
open, no data to stage, and the only library surface is `malloc`, `printf` and
some of `libm`. All 30 kernels build and run on both cores at `-O2`, at both
32-bit and 64-bit FP.

Five gaps had to be closed, all of them in `utilities/polybench.{c,h}` — the
instrumentation, never a kernel. None is an ISA gap and none needed a change to
newlib, gem5 or the compiler.

| # | gap | fix | symptom if unfixed |
|---|---|---|---|
| 1 | `RDTSC` does not exist | read `$frcc` | assembler error |
| 2 | no `posix_memalign` in newlib | `memalign` | link error |
| 3 | `polybench_flush_cache` allocates 33 MB | off by default | `fatal: readBlob(0, ...)` |
| 4 | `%Ld` is a glibc extension | `%llu` | the measurement line is **empty** |
| 5 | `POLYBENCH_CYCLE_ACCURATE_TIMER` alone prints nothing | it now implies the timer | **no output, no error** |
| 6 | the dump goes to `stderr`, which gem5 shares | `stdout` on LVX | corrupted dump, unfilterable |

Gaps 4, 5 and 6 are the dangerous ones. None produces an error message, and
each looks like a broken port or a broken benchmark rather than a missing
`#define`.

## 1. `RDTSC` does not exist — the cycle counter is `$frcc`

`polybench.c`'s `rdtsc()` is literally x86: `__asm__ volatile ("RDTSC" : "=a"
(cycles_lo), "=d" (cycles_hi))`, reassembling a 64-bit count from the EDX:EAX
pair RDTSC returns.

LVX has the same facility and it is simpler: **`$frcc`**, SRS 63, a 64-bit
free-running cycle counter read with the scalar `get`. One register, so there is
no hi/lo reassembly:

```c
__asm__ __volatile__ ("get %0 = $frcc\n\t;;" : "=r" (ret) : : "memory");
```

The `;;` terminates the VLIW bundle; the `"memory"` clobber keeps the read from
being scheduled across the kernel it is timing. This is the same register
`lvx-newlib` reads in `__lvx_cycles()` (`libgloss/lvx-mbr/counters.c`), from
which `clock()`, `times()` and `gettimeofday()` are all derived — so a cycle
count and a reported time cannot disagree here, and `_LVX_CPU_FREQ` (1 GHz) only
affects the derived *time*, never this count.

`PAPI` is not the answer, despite `polybench.h` offering `POLYBENCH_PAPI`: that
path collects hardware counters and **defines no timing function at all**
(`polybench_papi_print` prints counter values, and `polybench_print_instruments`
is redefined to it, replacing the timer). So porting PAPI would not have
produced a cycle count. `POLYBENCH_CYCLE_ACCURATE_TIMER` is the right hook.

## 2. newlib has `memalign`, not `posix_memalign`

`xmalloc` calls `posix_memalign (&ret, 4096, padded_sz)` unconditionally. newlib
ships `memalign` and `aligned_alloc` but not `posix_memalign`, so the link fails.
`memalign (4096, padded_sz)` has the same contract for the only alignment
PolyBench asks for — 4096 is a power of two and a multiple of `sizeof (void *)`
— so the fix is two lines and needs no newlib change. (A standalone
`posix_memalign` shim was the first attempt; folding it into `xmalloc` is better,
because a shim is a file every compile line has to remember.)

## 3. The cache flush allocates 33 MB and does not check — `readBlob(0, ...)`

This one is worth reading carefully, because the diagnostic names nothing.

```
src/mem/port_proxy.hh:185: fatal: readBlob(0, ...) failed
```

`polybench_flush_cache()` does:

```c
int cs = POLYBENCH_CACHE_SIZE_KB * 1024 / sizeof(double);   /* 32770 KB */
double* flush = (double*) calloc (cs, sizeof(double));      /* ~33 MB */
for (i = 0; i < cs; i++) tmp += flush[i];                   /* no NULL check */
```

The allocation fails on the ISS heap, the result is never checked, and the walk
dereferences NULL. Three things make it hard to find:

- it is reached through `polybench_prepare_instruments()`, so it fires **only
  once timing is enabled** — the kernel itself is fine, which points suspicion
  at the timer patch;
- the message names neither the allocation nor the benchmark;
- `POLYBENCH_CACHE_SIZE_KB` is an *LLC* size and looks like a tuning knob, not a
  thing that gets allocated.

There is also nothing to flush: the default atomic CPU models no cache at all,
and the pipeline model's L1s are 32 KB, so walking 33 MB would measure nothing
either way. So `POLYBENCH_NO_FLUSH_CACHE` is now the default under `__lvx__`,
with `POLYBENCH_FLUSH_CACHE` to force it back on.

## 4. `%Ld` is a glibc extension — the measurement comes out empty

`polybench_timer_print` prints the cycle delta with:

```c
printf ("%Ld\n", polybench_c_end - polybench_c_start);
```

`%Ld` is a glibc extension. newlib's `printf` does not parse it and drops the
conversion, so the program prints an empty line and exits 0. The run looks
complete and the measurement is simply gone. `%llu` with an explicit cast.

## 5. `POLYBENCH_CYCLE_ACCURATE_TIMER` on its own prints nothing

The trap in upstream's macro layering. `polybench.h` only defines the timer
macros under:

```c
# if defined(POLYBENCH_TIME) || defined(POLYBENCH_GFLOPS)
```

`POLYBENCH_CYCLE_ACCURATE_TIMER` is **not** in that list. On its own it merely
*selects* `rdtsc()` over `gettimeofday()` inside `polybench_timer_start/stop`,
while `polybench_print_instruments` stays defined as nothing. So the timer runs,
`$frcc` is read correctly twice, and the program prints no number at all —
which reads as a broken port rather than a missing `-DPOLYBENCH_TIME`.

Since defining it is only ever meant to choose the cycle counter, it now implies
the timer the way `POLYBENCH_TIME` does.

## 6. The dump must not go to `stderr`

`POLYBENCH_DUMP_TARGET` is `stderr` upstream, so that a timed run can be piped
without the dump polluting the measurement. On LVX stderr is the one stream that
cannot be trusted: the guest's fd 2 and gem5's own diagnostics land in it
together, and gem5 emits some of them **mid-run** (`Increasing stack size by one
page`). The dump prints an entire array as space-separated values with no
newline until the end, so an intrusion is not at a line boundary and **no
line-prefix filter can recover it**.

Measured: with the dump on stderr, 2 gem5 diagnostic lines sat inside it. On
stdout, which carries only gem5's banner and the guest's bytes, the dump comes
out clean and is cut free positionally (`harness/guest-output.py`, shared with
`lvx-mibench`).

The cost is that a dump and a timing print now share a stream. That was never a
combination to use: the dump's `printf` traffic dwarfs the kernel, so a dumped
run's cycle count measures `printf`. The harness builds and runs the two
separately.

## What is *not* a gap

**The ISA.** All 30 kernels assemble and link on both cores at both FP widths.
Nothing in the suite asked for an instruction the assembler could not provide.

**`gettimeofday`.** It exists — in `libgloss.a` and `libnosys.a`, not in
`libc.a`, derived from `$frcc` — so upstream's default `POLYBENCH_TIME` path
works too and reports exact *simulated* time. It is not what the harness tracks,
because a cycle count needs no clock-frequency assumption, but it is not missing.
(An earlier note in this project said it was absent; that came from an `nm` of
`libc.a` alone.)

**Dataset sizes.** `MINI` is the tracked size and runs in ~10^5 kernel cycles.
`SMALL` and above are available and correct, just slower; see `harness/README.md`
for why `MINI` is the right default for per-commit tracking.

## Open, and worth doing

- **A staleness check.** The gemm miscompile that motivated this port was a
  stale `libgcc` object — `divv.o` from an older binutils, carrying eight
  instructions whose encodings had since changed — and nothing in the build
  reported it. Both this harness and `validation/` would benefit from a `stat`
  comparison of the installed toolchain against the ISS binary.
- **The pipeline model.** Every number here is from the default atomic CPU,
  which charges one cycle per bundle and models no memory latency. That makes it
  a clean measure of *bundle count* — which is what scheduling and bundling
  changes move — but it is not a cycle count a real machine would produce.
  `LVX_CPU=minor` runs the pipeline model with L1 caches and is the honest
  measurement; it has not been run across the suite yet because it is much
  slower.
