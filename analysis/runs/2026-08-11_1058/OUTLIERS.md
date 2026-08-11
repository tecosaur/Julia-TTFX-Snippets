# TTFX outliers — run 2026-08-11_1058

193/195 task-version combinations ok.

## Systemic trends

Median ratio per step. Outliers below are judged against these, not against 1.0x.

| Metric | 1.10→1.11 | 1.11→1.12 | 1.12→1.13 | 1.13→nightly |
|---|---|---|---|---|
| Precompile (single sample) | 0.97x | 1.26x | 0.97x | 0.86x |
| Load (best of 3) | 1.11x | 0.91x | 0.90x | 1.39x |
| Run (best of 3) | 1.14x | 1.10x | 0.82x | 0.43x |

- **Load got broadly slower on nightly** (1.39x median, 31/32 tasks slower). Nearly the whole set moved together, scaling with dependency weight — trivial packages are flat (BaseDirs 0.007s→0.006s).
- **Run got broadly faster on nightly** (0.43x median, 29/30 faster) — the largest movement in the dataset, and the source of the -54% geomean.
- **Precompile regressed at 1.11→1.12** (1.26x median) and has since recovered.

## Big outliers

Tasks at least 2x slower across a step *and* 1.6x worse than that step's median, ignoring sub-noise absolute changes.

| Metric | Step | Task | Before | After | Ratio | vs median |
|---|---|---|---|---|---|---|
| Precompile | 1.11 → 1.12 | JET \* | 13.39s | 50.77s | **3.79x** | 1.26x |
| Precompile | 1.11 → 1.12 | ComponentArrays | 3.64s | 9.77s | **2.68x** | 1.26x |
| Precompile | 1.13-nightly → nightly | Mooncake | 63.39s | 145.01s | **2.29x** | 0.86x |
| Load | 1.10 → 1.11 | ShareAdd | 0.10s | 0.68s | **7.05x** | 1.11x |
| Load | 1.10 → 1.11 | ExplicitImports | 0.17s | 0.52s | **3.12x** | 1.11x |
| Load | 1.10 → 1.11 | Enzyme | 0.39s | 1.01s | **2.57x** | 1.11x |
| Load | 1.10 → 1.11 | QuantumAlgebra | 0.12s | 0.29s | **2.45x** | 1.11x |
| Load | 1.10 → 1.11 | JET \* | 0.18s | 0.42s | **2.37x** | 1.11x |
| Load | 1.13-nightly → nightly | Mooncake | 0.28s | 0.78s | **2.74x** | 1.39x |
| Run | 1.10 → 1.11 | JET \* | 0.19s | 9.41s | **49.39x** | 1.14x |
| Run | 1.11 → 1.12 | UnROOT | 1.24s | 3.05s | **2.45x** | 1.10x |
| Run | 1.11 → 1.12 | JLArrays | 0.83s | 1.78s | **2.15x** | 1.10x |
| Run | 1.11 → 1.12 | Enzyme | 2.77s | 5.86s | **2.12x** | 1.10x |

\* JET resolves to a different version per Julia (0.9.18 / 0.9.20 / 0.12.1 on 1.12+), so its two earliest steps span package upgrades and are not like-for-like. Every other task here resolves to an identical package version across all five Julia versions.

## Worth a closer look

**ComponentArrays** never posts a dramatic single step, but it is the only task flagged in precompilation at three consecutive steps, compounding 3.64s → 28.03s (7.7x) from 1.11 to nightly while the median task got slightly faster. Over the full range it is the worst cumulative precompile regression in the set (6.1x).

**Mooncake**'s nightly outlier needs a caveat the others don't. It resolves from a git branch carrying a Julia 1.14 compatibility patch, and although the source is identical on 1.13 and nightly, the *code path is not* — the patch is version-gated, so nightly runs the new `Compiler.OverlayCodeCache` path where 1.13 runs the old `Compiler.WorldView` one. Some or all of the 2.29x could be the migration rather than Julia. Unmeasured; don't attribute it to Julia without testing the two cache implementations on nightly alone.

## Failures

- **Enzyme** on `nightly` — precompile: process failed
- **JET** on `nightly` — task: ┌ Warning: Full JET functionality is not available on Julia 1.14.0-DEV.289

Neither is fixable here: Enzyme segfaults Julia itself (`jl_emit_native_impl`, via GPUCompiler precompilation) and JET gates itself off on unsupported versions.

## Caveats

- Precompile is a **single sample**; load and run are the **fastest of 3**. Precompile ratios therefore carry more noise.
- Load and run figures are **not comparable with runs recorded before the min-of-3 change**. Precompile is.
- All versions ran back-to-back on one machine, so they share hardware and thermal state.
