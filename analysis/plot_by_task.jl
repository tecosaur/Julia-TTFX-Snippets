#!/usr/bin/env julia --startup-file=no
# Usage: julia --project=analysis analysis/plot_by_task.jl [results.json] [output.png|svg|pdf]
#
# Groups bars by task on the x-axis, with one bar per Julia version inside each
# group, across three panes (precompile, load, run).

using JSON, Plots, Statistics, Printf, Colors

geomean(xs) = (ys = filter(x -> x > 0 && !isnan(x), xs); isempty(ys) ? NaN : exp(mean(log, ys)))

const RESULTS = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "results.json")
const OUTPUT  = length(ARGS) >= 2 ? ARGS[2] : joinpath(@__DIR__, "results-by-task.png")

const JULIA_VERSIONS = ["1.10", "1.11", "1.12", "1.13-nightly", "nightly"]
const METRICS = [
    (field = "precompile_time", title = "Precompilation"),
    (field = "load_time",       title = "Package load"),
    (field = "run_time",        title = "Script execution"),
]

records = JSON.parsefile(RESULTS)

# (package, task) => version => metric => seconds
tasks = Dict{Tuple{String, String}, Dict{String, Dict{String, Float64}}}()
for r in records
    key = (r["package"], r["task"])
    ver = r["julia_version"]
    by_ver = get!(tasks, key) do; Dict{String, Dict{String, Float64}}() end
    by_metric = get!(by_ver, ver) do; Dict{String, Float64}() end
    for m in METRICS
        v = get(r, m.field, nothing)
        v isa Number && v > 0 && (by_metric[m.field] = float(v))
    end
end

# Keep only tasks that have at least one numeric value for any metric.
task_keys = sort([k for (k, by_ver) in tasks
                  if any(!isempty(d) for d in values(by_ver))])

# Format log-axis ticks as plain decimals
function decimal_ticks(ymin, ymax)
    lo = floor(Int, log10(ymin))
    hi = ceil(Int, log10(ymax))
    vals = [10.0^e for e in lo:hi]
    labels = map(vals) do v
        v >= 1 ? @sprintf("%d", v) : rstrip(rstrip(@sprintf("%.4f", v), '0'), '.')
    end
    (vals, labels)
end

ranges = Dict{String, Tuple{Float64, Float64}}()
for m in METRICS
    vals = Float64[]
    for (_, by_ver) in tasks, (_, by_metric) in by_ver
        v = get(by_metric, m.field, 0.0)
        v > 0 && push!(vals, v)
    end
    isempty(vals) || (ranges[m.field] = (minimum(vals), maximum(vals)))
end

# Distinct colour per Julia version
version_palette = distinguishable_colors(length(JULIA_VERSIONS), [colorant"white"]; dropseed = true)

# Build matrix: rows = tasks, cols = versions. Missing -> NaN.
function value_matrix(field::String)
    M = fill(NaN, length(task_keys), length(JULIA_VERSIONS))
    for (i, key) in enumerate(task_keys), (j, v) in enumerate(JULIA_VERSIONS)
        by_ver = tasks[key]
        haskey(by_ver, v) || continue
        by_metric = by_ver[v]
        haskey(by_metric, field) && (M[i, j] = by_metric[field])
    end
    M
end

xticklabels = ["$(k[1])/$(k[2])" for k in task_keys]
# Geomean sits one slot beyond the last task, with a visible gap.
const GEOMEAN_GAP = 1.0
geomean_x = length(task_keys) + 1 + GEOMEAN_GAP
all_xticks = vcat(collect(1:length(task_keys)), geomean_x)
all_xticklabels = vcat(xticklabels, "geomean")

panels = map(enumerate(METRICS)) do (idx, m)
    is_bottom = idx == length(METRICS)
    M = value_matrix(m.field)
    gm = [geomean(M[:, j]) for j in 1:length(JULIA_VERSIONS)]
    nver = length(JULIA_VERSIONS)
    group_width = 0.82
    bar_w = group_width / nver
    if haskey(ranges, m.field)
        ymin = max(0.005, ranges[m.field][1] * 0.7)
        ymax = ranges[m.field][2] * 1.3
    else
        ymin, ymax = 0.01, 1.0
    end
    plt = plot(;
        title         = m.title,
        ylabel        = "seconds",
        yscale        = :log10,
        ylims         = (ymin, ymax),
        yticks        = decimal_ticks(ymin, ymax),
        xticks        = is_bottom ? (all_xticks, all_xticklabels) :
                                    (all_xticks, fill("", length(all_xticks))),
        xrotation     = is_bottom ? 60 : 0,
        xtickfontsize = 7,
        xlims         = (0.4, geomean_x + 0.6),
        grid          = true,
        framestyle    = :box,
        legend        = idx == 1 ? :topleft : false,
        bottom_margin = is_bottom ? 25Plots.mm : -2Plots.mm,
        top_margin    = idx == 1 ? 5Plots.mm : -2Plots.mm,
    )
    # Subtle separator before geomean
    vline!(plt, [geomean_x - (1 + GEOMEAN_GAP) / 2];
           color = :gray70, linestyle = :dash, linewidth = 1, label = "")
    for (j, ver) in enumerate(JULIA_VERSIONS)
        offset = (j - (nver + 1) / 2) * bar_w
        xs_task = collect(1:length(task_keys)) .+ offset
        ys_task = M[:, j]
        mask = .!isnan.(ys_task)
        xs = xs_task[mask]
        ys = ys_task[mask]
        # Append geomean point for this version
        if !isnan(gm[j])
            push!(xs, geomean_x + offset)
            push!(ys, gm[j])
        end
        isempty(xs) && continue
        bar!(plt, xs, ys;
             bar_width = bar_w * 0.95,
             fillto    = ymin,
             color     = version_palette[j],
             linecolor = :match,
             linewidth = 0,
             label     = idx == 1 ? ver : "")
    end
    plt
end

# Wider per-task slot and taller panes so log-scale bars are legible.
width_per_task = 70
fig_w = max(1600, width_per_task * length(task_keys) + 200)
fig_h = 420 * length(panels) + 150
final = plot(panels...;
             layout      = (length(panels), 1),
             size        = (fig_w, fig_h),
             plot_title  = "TTFX per task across Julia versions ($(length(task_keys)) tasks from tecosaur/Julia-TTFX-Snippets)",
             left_margin = 12Plots.mm, right_margin = 8Plots.mm,
             link        = :x)

savefig(final, OUTPUT)
println("Wrote $OUTPUT")
