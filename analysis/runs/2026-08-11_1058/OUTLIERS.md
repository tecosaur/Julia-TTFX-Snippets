# TTFX outliers — run 2026-08-11_1058

193/195 task-version combinations ok.

## Systemic trends

Median ratio per step. Outliers below are judged against these, not against 1.0x.

| Metric | 1.10→1.11 | 1.11→1.12 | 1.12→1.13 | 1.13→nightly |
|---|---|---|---|---|
| Precompile (single sample) | 0.97x | 1.25x | 0.97x | 0.86x |
| Load (best of 3) | 1.11x | 0.91x | 0.90x | 1.39x |
| Run (best of 3) | 1.14x | 1.10x | 0.82x | 0.43x |

- **Load got broadly slower on nightly** (1.39x median, 31/32 tasks slower). Nearly the whole set moved together, scaling with dependency weight — trivial packages are flat (BaseDirs 0.007s→0.006s).
- **Run got broadly faster on nightly** (0.43x median, 29/31 faster) — the largest movement in the dataset, and the source of the -54% geomean.
- **Precompile regressed at 1.11→1.12** (1.25x median) and has since recovered.

## Big outliers

Tasks at least 2x slower across a step *and* 1.6x worse than that step's median, ignoring sub-noise absolute changes. The noise floor applies to the larger of the two values, so a task that starts fast and ends slow still qualifies.

| Metric | Step | Task | Before | After | Ratio | vs median |
|---|---|---|---|---|---|---|
| Precompile | 1.11 → 1.12 | JET \* | 13.39s | 50.77s | **3.79x** | 1.25x |
| Precompile | 1.11 → 1.12 | ComponentArrays | 3.64s | 9.77s | **2.68x** | 1.25x |
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
| Run | 1.13-nightly → nightly | GMT | 0.01s | 3.62s | **366.99x** | 0.43x |

\* JET resolves to a different version per Julia (0.9.18 / 0.9.20 / 0.12.1 on 1.12+), so its two earliest steps span package upgrades and are not like-for-like. Every other task here resolves to an identical package version across all five Julia versions.

## Worth a closer look

**GMT** is the largest single movement in the dataset: script execution goes 0.0099s → 3.62s (367x) from 1.13 to nightly, while its precompile and load are flat-to-improving, so nothing else about the package regressed.

**Cause found: invalidation of precompiled code, not slow compilation.** On nightly the call is 99.5% `recompile_time` — GMT's pkgimage `plot` path is discarded and re-inferred on first use — against exactly zero recompilation on 1.12 and 1.13. Fresh compilation accounts for only 51.5ms of it. Counting invalidations during `using GMT`, the classic method-invalidation log *shrinks* while pkgimage **edge-validation** events go 74 (1.13) → 5959 (nightly), an ~80x jump. `ComponentArrays` is flat across the same boundary (282 → 261), so this is not universal.

Note this is the opposite mechanism to the ComponentArrays finding above, where edge validation contributed nothing and the classic path exploded — two independent invalidation regressions in the same nightly. Write-up: [`../../ISSUE-gmt-edge-invalidation.md`](../../ISSUE-gmt-edge-invalidation.md).

Two caveats on the number itself. It is variable — the same task measured 7.42s as a single sample and 3.62s as the best of 3 — and the task produced no data at all before the `rm("gmt.history"; force=true)` fix earlier in this branch, so the jump is absent from every prior result set. The ~10ms on 1.12/1.13 is genuine, not work being skipped: `plot` returns `nothing` and writes no files on every version, including 1.10 where it takes 0.108s.

**ComponentArrays** never posts a dramatic single step, but it is the only task flagged in precompilation at three consecutive steps, compounding 3.64s → 28.03s (7.7x) from 1.11 to nightly while the median task got slightly faster. Over the full range it is the worst cumulative precompile regression in the set (6.1x).

**Root cause found — and it is not ComponentArrays.** Per-package precompile timings put all of the growth in two dependencies, with ComponentArrays itself flat throughout:

| Julia | Static | StaticArrayInterface | ComponentArrays | env total |
|---|---|---|---|---|
| 1.11 | 1.13s | 1.56s | 1.18s | 7.88s |
| 1.12 | 14.29s | 2.25s | 1.28s | 21.51s |
| 1.13-nightly | 27.7s | 6.2s | 1.10s | 39.8s |
| nightly | 26.3s | 21.3s | 1.30s | 56.07s |

Both packages wrap their imports in PrecompileTools' `@recompile_invalidations`, which force-recompiles every method instance invalidated inside the block. That single trivial block costs 0.05s on 1.11 and ~22s on 1.12+: the invalidated leaf `MethodInstance`s rise from 20 to 279, *and* the cost of recompiling one rises from ~2.5ms to ~80ms. Removing just the macro takes Static from 32.5s to 1.3s on nightly — back to roughly its 1.11 cost.

Write-up for a Julia issue, with reproducers: [`../../ISSUE-recompile-invalidations.md`](../../ISSUE-recompile-invalidations.md). The practical fix is in the packages (drop the macro); the open question for Julia is the 32-45x increase in per-instance re-inference cost.

**Mooncake**'s nightly outlier needs a caveat the others don't. It resolves from a git branch carrying a Julia 1.14 compatibility patch, and although the source is identical on 1.13 and nightly, the *code path is not* — the patch is version-gated, so nightly runs the new `Compiler.OverlayCodeCache` path where 1.13 runs the old `Compiler.WorldView` one. Some or all of the 2.29x could be the migration rather than Julia. Unmeasured; don't attribute it to Julia without testing the two cache implementations on nightly alone.

## Failures

- **Enzyme** on `nightly` — precompile: process failed
- **JET** on `nightly` — task: ┌ Warning: Full JET functionality is not available on Julia 1.14.0-DEV.289

Neither is fixable here: Enzyme segfaults Julia itself (`jl_emit_native_impl`, via GPUCompiler precompilation) and JET gates itself off on unsupported versions.

## Caveats

- Precompile is a **single sample**; load and run are the **fastest of 3**. Precompile ratios therefore carry more noise.
- Load and run figures are **not comparable with runs recorded before the min-of-3 change**. Precompile is.
- All versions ran back-to-back on one machine, so they share hardware and thermal state.
