#!/usr/bin/env julia --startup-file=no
# Usage: julia --project=analysis analysis/plot.jl [results.json] [output.png|svg|pdf]

using JSON, Plots, Statistics, Printf, Colors

const RESULTS = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "results.json")
const OUTPUT  = length(ARGS) >= 2 ? ARGS[2] : joinpath(@__DIR__, "results.png")

const METRICS = [
    (field = "precompile_time", title = "Precompilation"),
    (field = "load_time",       title = "Package load"),
    (field = "run_time",        title = "Script execution"),
]

records = JSON.parsefile(RESULTS)

# Order versions: numeric releases ascending, then dev-nightlies (e.g. "1.13-nightly"),
# then "nightly", then any "pr*" builds last.
function version_sort_key(v::AbstractString)
    group = startswith(v, "pr") ? 3 :
            v == "nightly"      ? 2 :
            occursin("nightly", v) ? 1 : 0
    m = match(r"^(\d+)\.(\d+)", v)
    nums = m === nothing ? (0, 0) : (parse(Int, m.captures[1]), parse(Int, m.captures[2]))
    (group, nums, v)
end
const JULIA_VERSIONS = sort!(unique(r["julia_version"] for r in records); by = version_sort_key)

# Group by task: (package, task) => Dict(version => Dict(metric => seconds))
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
# Per-metric: a task contributes to a metric's geomean only if it has a positive
# value for that metric on every version.
clean_keys_per_metric = Dict{String, Vector{Tuple{String,String}}}()
for m in METRICS
    ks = Tuple{String,String}[]
    for (key, by_ver) in tasks
        if all(haskey(get(by_ver, v, Dict{String,Float64}()), m.field) for v in JULIA_VERSIONS)
            push!(ks, key)
        end
    end
    clean_keys_per_metric[m.field] = ks
end

# Geometric mean (skipping missing/non-positive)
geomean(xs) = (ys = filter(x -> x > 0, xs); isempty(ys) ? NaN : exp(mean(log, ys)))

# Format log-axis ticks as plain decimals (0.01, 0.1, 1, 10, 100, ...)
function decimal_ticks(ymin, ymax)
    lo = floor(Int, log10(ymin))
    hi = ceil(Int, log10(ymax))
    # Only decades that actually fall within the axis limits: a tick outside them is still
    # drawn by Plots, but outside the frame, where it collides with whatever is below.
    vals = [10.0^e for e in lo:hi if ymin <= 10.0^e <= ymax]
    labels = map(vals) do v
        v >= 1 ? @sprintf("%d", v) : rstrip(rstrip(@sprintf("%.4f", v), '0'), '.')
    end
    (vals, labels)
end

# Compute global y-range per metric to set consistent decimal ticks
ranges = Dict{String, Tuple{Float64, Float64}}()
for m in METRICS
    vals = Float64[]
    for (_, by_ver) in tasks, (_, by_metric) in by_ver
        v = get(by_metric, m.field, 0.0)
        v > 0 && push!(vals, v)
    end
    isempty(vals) || (ranges[m.field] = (minimum(vals), maximum(vals)))
end

panels = map(enumerate(METRICS)) do (idx, m)
    plt = plot(;
        title       = m.title,
        ylabel      = idx == 1 ? "seconds" : "",
        yscale      = :log10,
        xticks      = (1:length(JULIA_VERSIONS), JULIA_VERSIONS),
        xrotation   = 20,
        legend      = false,
        grid        = true,
        framestyle  = :box,
    )

    if haskey(ranges, m.field)
        dlo, dhi = ranges[m.field]
        # Track the data closely, padded just enough that extreme markers aren't clipped
        # by the frame. Rounding out to whole decades instead would waste a lot of height.
        ylo, yhi = dlo * 0.8, dhi * 1.25
        tickvals, ticklabels = decimal_ticks(ylo, yhi)
        if length(tickvals) < 2
            # Span too narrow to contain two decades -- widen to whole ones so the axis
            # still carries labelled ticks, all of them inside the frame.
            ylo, yhi = 10.0^floor(Int, log10(dlo)), 10.0^ceil(Int, log10(dhi))
            tickvals, ticklabels = decimal_ticks(ylo, yhi)
        end
        ylims!(plt, (ylo, yhi))
        yticks!(plt, (tickvals, ticklabels))
    end

    # One faded line per task, labelled with the task name
    task_keys = sort(collect(keys(tasks)))
    palette = distinguishable_colors(length(task_keys), [colorant"gray"]; dropseed = true)
    for (i, key) in enumerate(task_keys)
        by_ver = tasks[key]
        ys = [get(get(by_ver, v, Dict{String,Float64}()), m.field, NaN) for v in JULIA_VERSIONS]
        any(isfinite, ys) || continue
        plot!(plt, 1:length(JULIA_VERSIONS), ys;
              color = palette[i], alpha = 0.55, linewidth = 1.8,
              markershape = :circle, markersize = 2.5, markerstrokewidth = 0,
              label = key[2])
    end

    # Geometric mean across tasks per version (per-metric: only tasks with a
    # positive value for this metric on every version contribute).
    metric_keys = clean_keys_per_metric[m.field]
    gm = [geomean([tasks[k][v][m.field] for k in metric_keys])
          for v in JULIA_VERSIONS]
    plot!(plt, 1:length(JULIA_VERSIONS), gm;
          color = :crimson, linewidth = 3, markershape = :diamond, markersize = 6,
          label = "")

    # Per-panel count of contributing tasks
    title!(plt, string(m.title, " (geomean of ", length(metric_keys), "/", length(tasks), ")"))

    # Annotate each geomean marker with +/- % relative to 1.10
    baseline = gm[1]
    if isfinite(baseline) && baseline > 0
        for (i, v) in enumerate(gm)
            isfinite(v) && v > 0 || continue
            if i > 1
                pct = 100 * (v / baseline - 1)
                label = @sprintf("%+.0f%%", pct)
                colour = pct > 0 ? colorant"#c0392b" : colorant"#1e8449"
                annotate!(plt, i, v * 1.15, text(@sprintf("%+.0f%%", pct), 12, colour, :center, :bottom))
            end
        end
    end

    plt
end

# Build legend pane manually with scatter markers + text annotations so we have
# full control over wrapping (Plots' built-in legend clips multi-column layouts).
const LEGEND_COLS = 4
task_keys = sort(collect(keys(tasks)))
palette = distinguishable_colors(length(task_keys), [colorant"gray"]; dropseed = true)

# Include geomean as the first entry, then per-task entries.
legend_entries = vcat(
    [(label = "Geometric mean of all (%'s relative to $(JULIA_VERSIONS[1]))", color = colorant"crimson", shape = :diamond, size = 6)],
    [(label = string(k[1], " / ", k[2]),
      color = palette[i], shape = :circle, size = 5) for (i, k) in enumerate(task_keys)],
)

n_entries = length(legend_entries)
n_rows = cld(n_entries, LEGEND_COLS)

legend_pane = plot(;
    framestyle = :none, grid = false, legend = false,
    xlims = (0, 1), ylims = (0, 1),
    showaxis = false, ticks = nothing,
    left_margin = 5Plots.mm, right_margin = 5Plots.mm,
    top_margin = 0Plots.mm, bottom_margin = 5Plots.mm)

for (i, entry) in enumerate(legend_entries)
    col = (i - 1) % LEGEND_COLS
    row = (i - 1) ÷ LEGEND_COLS
    col_x = (col + 0.02) / LEGEND_COLS              # marker x within pane
    text_x = col_x + 0.012                           # label x (just right of marker)
    y = 1 - (row + 0.5) / n_rows                     # top-down rows
    scatter!(legend_pane, [col_x], [y];
             color = entry.color, markershape = entry.shape, markersize = entry.size,
             markerstrokewidth = 0, label = "")
    annotate!(legend_pane, text_x, y, text(entry.label, 8, :left, :vcenter))
end

# Approx: each row ~ 22 px; total figure body ~ 500 px above legend
legend_px = 30 + 22 * n_rows
plot_px   = 500
total_px  = plot_px + legend_px
legend_frac = legend_px / total_px

# Layout: 3 panels on top, full-width legend pane below.
# Use eval/Meta.parse because @layout doesn't allow interpolation of fractions.
layout = eval(Meta.parse("Plots.@layout [a b c; d{$(legend_frac)h}]"))

final = plot(panels..., legend_pane;
             layout      = layout,
             size        = (1500, total_px),
             plot_title  = "TTFX across Julia versions ($(length(tasks)) tasks from tecosaur/Julia-TTFX-Snippets)\ngeomean per panel uses only tasks with a value for that metric on every version",
             plot_titlefontsize = 11,
             plot_titlevspan = 0.08,
             left_margin = 10Plots.mm, right_margin = 5Plots.mm, bottom_margin = 5Plots.mm)

savefig(final, OUTPUT)
println("Wrote $OUTPUT")
