#!/usr/bin/env julia --startup-file=no

using Printf, Dates

const JULIA_VERSIONS = ["nightly", "1.13", "1.12", "1.11", "1.10"]
# Label => juliaup channel, for arms that run something other than the channel of their
# name (a PR build standing in for a release, say). Empty: every label is its own channel.
const VERSION_CHANNEL = Dict{String, String}()
const VERSION_OPT = Dict{String,Int}()
# The task script is run this many times in fresh processes, with the compiled cache and
# JIT object cache cleared once per task beforehand. Each repeat's load and run
# times are recorded individually (`*_times`, in run order): the first repeat is the true
# cold TTFX, while later repeats can hit on-disk caches populated by the first (master's
# JIT object cache), making them TTSX. The legacy `load_time`/`run_time`/`total_time`
# fields keep the fastest-of-repeats value.
const TASK_REPEATS = 3
# Precompilation is measured this many times per task and version, clearing the compiled
# cache and the JIT object cache before each; `precompile_time` keeps the fastest and
# `precompile_times` every sample. A single reading of a minutes-long parallel job has
# produced phantom outliers before; a second one shows them for what they are.
const PRECOMPILE_REPEATS = parse(Int, get(ENV, "TTFX_PRECOMPILE_REPEATS", "2"))
# Wall-clock limit per subprocess. A hung process then fails its task instead of stalling
# the run; the driver is sent SIGINT first so Pkg can stop its workers, then SIGTERM.
const PROCESS_TIMEOUT_S = parse(Float64, get(ENV, "TTFX_PROCESS_TIMEOUT", "1800"))
const TASKS_DIR = joinpath(@__DIR__, "..", "tasks")
const RESULTS_FILE = joinpath(@__DIR__, "results.json")
# Provenance for the run: exact build of every Julia channel plus the machine it ran on.
# Written before any measurement so an interrupted run is still identifiable.
const META_FILE = joinpath(@__DIR__, "results-meta.json")

struct TaskInfo
    dir::String
    package::String
    task::String
end

function find_tasks()::Vector{TaskInfo}
    tasks = TaskInfo[]
    for (root, _, files) in walkdir(TASKS_DIR)
        if "task.jl" ∈ files && "Project.toml" ∈ files
            parts = splitpath(relpath(root, TASKS_DIR))
            length(parts) == 3 || continue  # letter/package/task-name
            push!(tasks, TaskInfo(root, parts[2], parts[3]))
        end
    end
    sort!(tasks, by = t -> (t.package, t.task))
end

function clear_compiled!(depot::String)
    compiled = joinpath(depot, "compiled")
    isdir(compiled) && rm(compiled; recursive = true)
    # Also drop the JIT object cache (depot/cache/vX.Y/objcache-lmdb1 on master), so no
    # snippet or Julia version benefits from JIT work another one did. It is cleared only
    # here, before a task's precompile, so within a task the first repeat still populates
    # it and later repeats measure TTSX.
    objcache = joinpath(depot, "cache")
    isdir(objcache) && rm(objcache; recursive = true)
end

"""
    julia_build_info(ver) -> NamedTuple or nothing

Identify the build behind a channel: the full version string, the commit it was built
from, and its target triple. `nothing` means the channel is not installed, so this
doubles as the availability check.
"""
function julia_build_info(ver::String)
    ch = get(VERSION_CHANNEL, ver, ver)
    code = """
    let g = Base.GIT_VERSION_INFO
        join(stdout, [string(VERSION), g.commit, g.commit_short, g.date_string,
                      g.branch, Sys.MACHINE, string(Sys.WORD_SIZE), string(Sys.CPU_THREADS)], '\\n')
    end"""
    out, _, ok = capture_soft(`julia +$ch --startup-file=no -e $code`)
    ok || return nothing
    f = split(out, '\n')
    length(f) == 8 || return nothing
    (; channel = ch, version = f[1], commit = f[2], commit_short = f[3],
       commit_date = f[4], branch = f[5], machine = f[6],
       word_size = parse(Int, f[7]),
       # What this build sees, and so how many precompile workers it uses by default
       cpu_threads = parse(Int, f[8]))
end

# Run a subprocess capturing stdout and stderr under PROCESS_TIMEOUT_S.
# Returns (stdout, stderr, succeeded, timed_out).
function run_timed(cmd::Cmd)
    err = IOBuffer()
    proc = open(pipeline(cmd; stderr = err), "r")
    timed_out = Ref(false)
    interrupt = Timer(PROCESS_TIMEOUT_S) do _
        timed_out[] = true
        process_running(proc) && kill(proc, Base.SIGINT)
    end
    terminate = Timer(PROCESS_TIMEOUT_S + 30) do _
        process_running(proc) && kill(proc)
    end
    out = try
        read(proc, String)
    finally
        close(interrupt); close(terminate)
    end
    wait(proc)
    out, String(take!(err)), success(proc) && !timed_out[], timed_out[]
end

# Like run_timed, but throws on failure with stderr in the message.
function capture(cmd::Cmd)
    out, err, ok, timed_out = run_timed(cmd)
    if !ok
        why = timed_out ? "process timed out after $(PROCESS_TIMEOUT_S)s" : "process failed"
        # Omit the full Cmd (which includes env vars) from the message; only keep stderr.
        throw(ErrorException("$why\n--- stderr ---\n$err"))
    end
    out, err
end

# Never throws; returns (stdout, stderr, succeeded::Bool).
function capture_soft(cmd::Cmd)
    out, err, ok, _ = run_timed(cmd)
    out, err, ok
end

function run_task(ver::String, depot::String, task::TaskInfo)
    ch = get(VERSION_CHANNEL, ver, ver)
    depot_path = depot * ":"
    proj = task.dir
    base_env    = ("JULIA_DEPOT_PATH" => depot_path,)
    inst_env    = ("JULIA_DEPOT_PATH" => depot_path, "JULIA_PKG_PRECOMPILE_AUTO" => "0")
    precomp_env = inst_env

    # 1. Instantiate packages without triggering precompilation, then rename
    #    Manifest.toml to Manifest-vX.Y.toml to preserve per-version manifests.
    inst_code = """using Pkg
Pkg.instantiate()
let
    d = dirname(Base.active_project())
    src = joinpath(d, "Manifest.toml")
    dst = joinpath(d, "Manifest-v\$(VERSION.major).\$(VERSION.minor).toml")
    isfile(src) && mv(src, dst; force = true)
end"""
    try
        capture(addenv(
            `julia +$ch --startup-file=no --project=$proj -e $inst_code`,
            inst_env...))
    catch e
        return (; status = "error", error = "instantiate: $(sprint(showerror, e))")
    end

    # 2/3. Precompile from a cleared cache and measure elapsed time, PRECOMPILE_REPEATS times.
    #    Use a marker so any stray stdout from Pkg can't contaminate the parse.
    opt = get(VERSION_OPT, ver, nothing)
    precomp_code = if opt === nothing
        "using Pkg; t = @elapsed Pkg.precompile(); print(\"__TTFX_T__:\", t)"
    else
        "t = @elapsed Base.Precompilation.precompilepkgs(configs=`` => Base.CacheFlags(opt_level=$opt)); print(\"__TTFX_T__:\", t)"
    end
    precompile_ts = Float64[]
    for _ in 1:PRECOMPILE_REPEATS
        clear_compiled!(depot)
        try
            precomp_out, _ = capture(addenv(
                `julia +$ch --startup-file=no --project=$proj -e $precomp_code`,
                precomp_env...))
            pm = match(r"__TTFX_T__:([\d.eE+-]+)", precomp_out)
            pm === nothing && error("could not parse precompile time from: $(repr(precomp_out))")
            push!(precompile_ts, parse(Float64, pm.captures[1]))
        catch e
            return (; status = "error", error = "precompile: $(sprint(showerror, e))",
                      precompile_time = isempty(precompile_ts) ? nothing : minimum(precompile_ts),
                      precompile_times = precompile_ts)
        end
    end
    precompile_time = minimum(precompile_ts)

    # 4. Run the task script `TASK_REPEATS` times in fresh processes, keeping the fastest
    #    measurement of each phase.  Both metrics are cold-start by design, so the repeats
    #    have to be separate processes -- a second `using` in the same process is already
    #    loaded, and a second call already compiled.  Capture output even on failure so
    #    partial timing can be recovered.
    #    Expected stdout per run: "$load_t, $run_t, $total_t seconds"
    task_jl = joinpath(task.dir, "task.jl")
    opt_flag = opt === nothing ? `` : `-O$opt`
    task_cmd = addenv(
        `julia +$ch $opt_flag --startup-file=no --project=$proj $task_jl`,
        base_env...)

    load_ts, run_ts, total_ts = Float64[], Float64[], Float64[]
    all_exited_ok = true
    task_out = task_err = ""
    for _ in 1:TASK_REPEATS
        task_out, task_err, task_ok = capture_soft(task_cmd)
        all_exited_ok &= task_ok
        m = match(r"([\d.]+),\s*([\d.]+),\s*([\d.]+)\s+seconds", task_out)
        if m !== nothing
            lt, rt, tt = parse.(Float64, m.captures)
            push!(load_ts, lt); push!(run_ts, rt); push!(total_ts, tt)
        end
    end

    # Legacy summary fields keep the fastest of the repeats, each phase minimised
    # independently; the per-repeat arrays carry the TTFX/TTSX distinction.
    if !isempty(load_ts)
        n_failed = TASK_REPEATS - length(load_ts)
        status = (n_failed == 0 && all_exited_ok) ? "ok" : "partial"
        err_msg = if status == "ok"
            nothing
        elseif n_failed > 0
            "task produced no timing on $n_failed of $TASK_REPEATS runs"
        else
            "task exited with non-zero status"
        end
        return (; status, error = err_msg, precompile_time, precompile_times = precompile_ts,
                  load_time = minimum(load_ts), run_time = minimum(run_ts),
                  total_time = minimum(total_ts),
                  load_times = load_ts, run_times = run_ts, total_times = total_ts)
    end

    # Load + run times only (script body printed before crashing)
    m2 = match(r"([\d.]+),\s*([\d.]+)", task_out)
    if m2 !== nothing
        load_t, run_t = parse.(Float64, m2.captures)
        return (; status = "partial", error = "task failed after run",
                  precompile_time, precompile_times = precompile_ts,
                  load_time = load_t, run_time = run_t,
                  load_times = [load_t], run_times = [run_t])
    end

    # No parseable timing — report first stderr line for context
    err_lines = split(strip(task_err), '\n')
    first_err = isempty(err_lines) ? "no output" : err_lines[1]
    return (; status = "error", error = "task: $first_err", precompile_time,
              precompile_times = precompile_ts)
end

# JSON string escaper: handles ", \, control chars, and non-BMP via surrogate pairs.
function json_escape(s::AbstractString)
    io = IOBuffer()
    write(io, '"')
    for c in s
        if c == '"'      ; write(io, "\\\"")
        elseif c == '\\' ; write(io, "\\\\")
        elseif c == '\b' ; write(io, "\\b")
        elseif c == '\f' ; write(io, "\\f")
        elseif c == '\n' ; write(io, "\\n")
        elseif c == '\r' ; write(io, "\\r")
        elseif c == '\t' ; write(io, "\\t")
        elseif c < '\u0020'
            write(io, "\\u", lpad(string(UInt32(c), base = 16), 4, '0'))
        else
            write(io, c)
        end
    end
    write(io, '"')
    String(take!(io))
end

# Recursive JSON serialisation for the nested metadata (records use `record_to_json`).
function to_json(v, indent::Int = 0)
    pad = " "^indent
    if v === nothing
        "null"
    elseif v isa AbstractString
        json_escape(v)
    elseif v isa Bool
        string(v)
    elseif v isa AbstractFloat
        isfinite(v) ? string(v) : "null"
    elseif v isa Number
        string(v)
    elseif v isa NamedTuple || v isa AbstractDict
        ks = v isa NamedTuple ? collect(keys(v)) : sort!(collect(keys(v)); by = string)
        isempty(ks) && return "{}"
        items = ["$pad  $(json_escape(string(k))): $(to_json(v[k], indent + 2))" for k in ks]
        "{\n" * join(items, ",\n") * "\n$pad}"
    elseif v isa AbstractVector
        isempty(v) && return "[]"
        "[\n" * join(["$pad  " * to_json(x, indent + 2) for x in v], ",\n") * "\n$pad]"
    else
        json_escape(string(v))
    end
end

# Best-effort shell-out; "" when the command is missing or fails (e.g. no git, non-Linux).
function try_read(cmd::Cmd)
    out, _, ok = capture_soft(cmd)
    ok ? strip(out) : ""
end

# The machine's logical CPU count, independent of what any Julia detects: Julia before
# JuliaLang/julia#62891 sees only 5 of this Mac's 15 cores. Each arm runs with its own
# defaults (that is what a user of that version gets), and `julia_build_info` records what
# each one saw, so precompile parallelism can be read alongside the times.
function cpu_count()
    n = Sys.isapple() ? tryparse(Int, try_read(`sysctl -n hw.logicalcpu`)) :
        Sys.islinux() ? tryparse(Int, try_read(`nproc`)) : nothing
    something(n, Sys.CPU_THREADS)
end

# Everything about the machine that plausibly moves a timing.
function system_info()
    cpus = Sys.cpu_info()
    # `Sys.cpu_info()` reports a per-core model on Linux and the chip on macOS; either way
    # the first entry names the part. Speed is nominal, not the clock actually sustained.
    model = isempty(cpus) ? "unknown" : strip(cpus[1].model)
    speed = isempty(cpus) ? nothing : cpus[1].speed
    (; hostname = gethostname(),
       cpu = model,
       # The hardware count, not what the driver's own Julia detects (see cpu_count).
       cpu_threads = cpu_count(),
       cpu_speed_mhz = speed,
       cpu_target = get(ENV, "JULIA_CPU_TARGET", ""),
       total_memory_gb = round(Sys.total_memory() / 2^30; digits = 1),
       machine = Sys.MACHINE,
       kernel = string(Sys.KERNEL),
       uname = try_read(`uname -sr`),
       # Load averages when the run started: anything else busy here voids the timings.
       load_avg = try_read(`uptime`),
       # The driver's own build, distinct from the versions under test.
       driver_julia = string(VERSION))
end

# Repo state, so a run can be tied back to the task definitions that produced it.
function repo_info()
    dir = @__DIR__
    (; commit = try_read(`git -C $dir rev-parse HEAD`),
       branch = try_read(`git -C $dir rev-parse --abbrev-ref HEAD`),
       dirty  = !isempty(try_read(`git -C $dir status --porcelain`)))
end

# Env vars that change what is measured; recorded so a run's settings are self-describing.
const RECORDED_ENV = ["JULIA_IMAGE_THREADS", "JULIA_NUM_THREADS", "JULIA_NUM_PRECOMPILE_TASKS",
                      "JULIA_CPU_TARGET", "JULIA_PKG_PRECOMPILE_AUTO"]

function run_metadata(depot::String, tasks::Vector{TaskInfo}, builds::AbstractDict)
    (; timestamp = string(Dates.now(Dates.UTC)) * "Z",
       system = system_info(),
       repo = repo_info(),
       settings = (; task_repeats = TASK_REPEATS,
                     precompile_repeats = PRECOMPILE_REPEATS,
                     process_timeout_s = PROCESS_TIMEOUT_S,
                     interleaved = true,
                     depot = depot,
                     n_tasks = length(tasks),
                     version_opt = Dict(k => v for (k, v) in VERSION_OPT),
                     env = Dict(k => get(ENV, k, "") for k in RECORDED_ENV if haskey(ENV, k))),
       julia_builds = Dict(v => builds[v] for v in keys(builds)))
end

# Minimal JSON serialisation for flat NamedTuple records — no external deps needed
function record_to_json(r::NamedTuple)
    fields = map(zip(keys(r), values(r))) do (k, v)
        vstr = v === nothing         ? "null" :
               v isa AbstractVector  ? "[" * join((x isa AbstractFloat && !isfinite(x) ? "null" : string(x) for x in v), ", ") * "]" :
               v isa AbstractString  ? json_escape(v) :
               v isa Bool            ? string(v) :
               v isa AbstractFloat   ? (isfinite(v) ? string(v) : "null") :
               v isa Number          ? string(v) :
                                       json_escape(string(v))
        "    \"$k\": $vstr"
    end
    "  {\n" * join(fields, ",\n") * "\n  }"
end

# Normalise record so JSON rows share a consistent schema.
function normalise(rec::NamedTuple)
    schema = (:julia_version, :package, :task, :status, :error,
              :precompile_time, :load_time, :run_time, :total_time,
              :precompile_times, :load_times, :run_times, :total_times)
    NamedTuple{schema}(map(k -> get(rec, k, nothing), schema))
end

function main()
    depot = get(ENV, "TTFX_DEPOT_PATH", mktempdir(; prefix = "julia-ttfx-"))
    mkpath(depot)
    tasks = find_tasks()

    println("Found $(length(tasks)) tasks across $(length(JULIA_VERSIONS)) Julia versions")
    println("Depot:   $depot")
    println("Results: $RESULTS_FILE")
    println("Tip: set TTFX_DEPOT_PATH=$depot to reuse downloaded packages on subsequent runs\n")

    # Probe every channel up front so the run's provenance is on disk before the first
    # measurement, and reuse the result as the availability check below.
    builds = Dict{String,Any}(v => julia_build_info(v) for v in JULIA_VERSIONS)
    meta = run_metadata(depot, tasks, builds)
    write(META_FILE, to_json(meta) * "\n")

    sys = meta.system
    println("Machine: $(sys.hostname)  $(sys.cpu)  $(sys.cpu_threads) threads  $(sys.total_memory_gb) GiB  $(sys.uname)")
    for ver in JULIA_VERSIONS
        b = builds[ver]
        println("  $(rpad(ver, 14)) ", b === nothing ? "(not installed)" :
                "$(b.version)  $(b.commit_short)  $(b.commit_date)  sees $(b.cpu_threads) CPU threads")
    end
    println("Precompile repeats: $PRECOMPILE_REPEATS  task repeats: $TASK_REPEATS  timeout: $(PROCESS_TIMEOUT_S)s")
    println("Load at start: $(sys.load_avg)")
    println("Metadata: $META_FILE\n")

    open(RESULTS_FILE, "w") do io
        println(io, "[")
        is_first = Ref(true)

        function write_record(record)
            is_first[] || print(io, ",\n")
            print(io, record_to_json(normalise(record)))
            flush(io)
            is_first[] = false
        end

        # Arms are interleaved per task rather than run one after another, so that drift
        # over the hours of a run (thermal state, registry updates, background load) lands
        # on every version alike, and the order rotates so no version always goes first.
        for (ti, task) in enumerate(tasks)
            label = task.package * "/" * task.task
            println("=== $label ===")
            for ver in circshift(JULIA_VERSIONS, -(ti - 1))
                if builds[ver] === nothing
                    write_record((; julia_version = ver, package = task.package,
                                    task = task.task, status = "skipped",
                                    error = "julia +$ver not available"))
                    continue
                end
                print("  $(rpad(ver, 14))")
                flush(stdout)

                result = try
                    run_task(ver, depot, task)
                catch e
                    (; status = "error", error = sprint(showerror, e))
                end

                write_record((; julia_version = ver, package = task.package,
                                task = task.task, result...))

                if result.status == "ok"
                    @printf("precompile=%6.2fs  load=%5.2fs  run=%5.2fs\n",
                            result.precompile_time, result.load_time, result.run_time)
                elseif result.status == "partial"
                    pt = get(result, :precompile_time, nothing)
                    lt = get(result, :load_time, nothing)
                    rt = get(result, :run_time, nothing)
                    parts = filter(!isnothing, [
                        isnothing(pt) ? nothing : @sprintf("precompile=%6.2fs", pt),
                        isnothing(lt) ? nothing : @sprintf("load=%5.2fs", lt),
                        isnothing(rt) ? nothing : @sprintf("run=%5.2fs", rt),
                    ])
                    println(join(parts, "  "), "  (partial: ", result.error, ")")
                else
                    println("ERROR: ", result.error)
                end
            end
        end

        println(io, "\n]")
    end

    println("Done. Results written to $RESULTS_FILE")
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
