#!/usr/bin/env julia --startup-file=no

using Printf

const JULIA_VERSIONS = ["pr61920", "nightly", "1.13-nightly", "1.12", "1.11", "1.10"]
const VERSION_CHANNEL = Dict{String,String}()
const VERSION_OPT = Dict{String,Int}()
const TASKS_DIR = joinpath(@__DIR__, "..", "tasks")
const RESULTS_FILE = joinpath(@__DIR__, "results.json")

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
end

function version_available(ver::String)::Bool
    ch = get(VERSION_CHANNEL, ver, ver)
    try
        run(pipeline(`julia +$ch --startup-file=no --version`; stdout = devnull, stderr = devnull))
        true
    catch
        false
    end
end

# Run a subprocess capturing stdout and stderr; on failure include stderr in the error.
function capture(cmd::Cmd)
    out = IOBuffer()
    err = IOBuffer()
    try
        run(pipeline(cmd; stdout = out, stderr = err))
    catch
        # Omit the full Cmd (which includes env vars) from the message; only keep stderr.
        throw(ErrorException("process failed\n--- stderr ---\n$(String(take!(err)))"))
    end
    String(take!(out)), String(take!(err))
end

# Like capture, but never throws; returns (stdout, stderr, succeeded::Bool).
function capture_soft(cmd::Cmd)
    out = IOBuffer()
    err = IOBuffer()
    succeeded = true
    try
        run(pipeline(cmd; stdout = out, stderr = err))
    catch
        succeeded = false
    end
    String(take!(out)), String(take!(err)), succeeded
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

    # 2. Clear compiled cache so precompilation is measured from scratch
    clear_compiled!(depot)

    # 3. Precompile and measure elapsed time.
    #    Use a marker so any stray stdout from Pkg can't contaminate the parse.
    opt = get(VERSION_OPT, ver, nothing)
    precomp_code = if opt === nothing
        "using Pkg; t = @elapsed Pkg.precompile(); print(\"__TTFX_T__:\", t)"
    else
        "t = @elapsed Base.Precompilation.precompilepkgs(configs=`` => Base.CacheFlags(opt_level=$opt)); print(\"__TTFX_T__:\", t)"
    end
    precompile_time = nothing
    try
        precomp_out, _ = capture(addenv(
            `julia +$ch --startup-file=no --project=$proj -e $precomp_code`,
            precomp_env...))
        pm = match(r"__TTFX_T__:([\d.eE+-]+)", precomp_out)
        pm === nothing && error("could not parse precompile time from: $(repr(precomp_out))")
        precompile_time = parse(Float64, pm.captures[1])
    catch e
        return (; status = "error", error = "precompile: $(sprint(showerror, e))",
                  precompile_time)
    end

    # 4. Run the task script; capture output even on failure so partial timing can
    #    be recovered.  Expected stdout: "$load_t, $run_t, $total_t seconds"
    task_jl = joinpath(task.dir, "task.jl")
    opt_flag = opt === nothing ? `` : `-O$opt`
    task_out, task_err, task_ok = capture_soft(addenv(
        `julia +$ch $opt_flag --startup-file=no --project=$proj $task_jl`,
        base_env...))

    # All three times present
    m3 = match(r"([\d.]+),\s*([\d.]+),\s*([\d.]+)\s+seconds", task_out)
    if m3 !== nothing
        load_t, run_t, total_t = parse.(Float64, m3.captures)
        status  = task_ok ? "ok" : "partial"
        err_msg = task_ok ? nothing : "task exited with non-zero status"
        return (; status, error = err_msg,
                  precompile_time, load_time = load_t, run_time = run_t, total_time = total_t)
    end

    # Load + run times only (script body printed before crashing)
    m2 = match(r"([\d.]+),\s*([\d.]+)", task_out)
    if m2 !== nothing
        load_t, run_t = parse.(Float64, m2.captures)
        return (; status = "partial", error = "task failed after run",
                  precompile_time, load_time = load_t, run_time = run_t)
    end

    # No parseable timing — report first stderr line for context
    err_lines = split(strip(task_err), '\n')
    first_err = isempty(err_lines) ? "no output" : err_lines[1]
    return (; status = "error", error = "task: $first_err", precompile_time)
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

# Minimal JSON serialisation for flat NamedTuple records — no external deps needed
function record_to_json(r::NamedTuple)
    fields = map(zip(keys(r), values(r))) do (k, v)
        vstr = v === nothing         ? "null" :
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
              :precompile_time, :load_time, :run_time, :total_time)
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

    open(RESULTS_FILE, "w") do io
        println(io, "[")
        is_first = Ref(true)

        function write_record(record)
            is_first[] || print(io, ",\n")
            print(io, record_to_json(normalise(record)))
            flush(io)
            is_first[] = false
        end

        for ver in JULIA_VERSIONS
            println("=== Julia $ver ===")
            if !version_available(ver)
                println("  (not available, skipping)\n")
                for task in tasks
                    write_record((; julia_version = ver, package = task.package,
                                    task = task.task, status = "skipped",
                                    error = "julia +$ver not available"))
                end
                continue
            end

            for task in tasks
                label = task.package * "/" * task.task
                print("  $(rpad(label, 52))")
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
            println()
        end

        println(io, "\n]")
    end

    println("Done. Results written to $RESULTS_FILE")
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
