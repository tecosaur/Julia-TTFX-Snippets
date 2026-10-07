#!/usr/bin/env julia --startup-file=no

using Pkg
using Dates

include("sandbox.jl")
using .Sandbox

task = let
    task_name = ""
    primary_pkg = ""
    deps = String[]
    attrib = ""
    snippet = ""
    author = ""
    while !isempty(ARGS)
        arg = popfirst!(ARGS)
        if arg ∈ ("-n", "--name")
            task_name = titlecase(replace(popfirst!(ARGS), '\n' => ' '))
        elseif arg ∈ ("-p", "--package")
            primary_pkg = popfirst!(ARGS)
        elseif arg ∈ ("-d", "--deps")
            deps = map(String ∘ strip, split(popfirst!(ARGS), ',', keepempty=false))
        elseif arg ∈ ("-a", "--author")
            author = replace(popfirst!(ARGS), '\n' => ' ')
        elseif arg ∈ ("-r", "--attribution")
            attrib = replace(popfirst!(ARGS), '\n' => ' ')
        elseif arg ∈ ("-s", "--snippet")
            snippet = popfirst!(ARGS)
        elseif arg ∈ ("-f", "--snippet-file")
            snippet = read(popfirst!(ARGS), String)
        else
            throw(ArgumentError("Unknown argument: $arg"))
        end
    end
    snippet = String(strip(chopsuffix(chopprefix(strip(snippet), "```julia\n"), "\n```")))
    if any(isempty, (task_name, primary_pkg, author, snippet))
        for (arg, val) in (("--name", task_name),
                           ("--package", primary_pkg),
                           ("--author", author),
                           ("--snippet", snippet))
            if isempty(val)
                println("Argument error: missing/empty $arg")
            end
        end
        println("\n  Usage: create-snippet.jl --name <task name> --package <pkg> [--deps <dep1,dep2>] --author <name> [--attribution <text>] --snippet <code>")
        exit(1)
    end
    (name = task_name, package = primary_pkg, deps = deps,
     author = author, attribution = attrib, snippet = snippet)
end


# Github action setup

function cierror(msg::String)
    if haskey(ENV, "CI")
        println(stdout, "```\n**🚨 Error:**\n```")
        st = Base.StackTraces.stacktrace(backtrace())
        i = firstindex(st)
        reachedself = false
        while i <= length(st)
            sf = st[i]
            if sf.file == Symbol(@__FILE__)
                reachedself = true
            end
            if sf.func == :include && reachedself
                deleteat!(st, i:length(st))
                break
            end
            i += 1
        end
        print(stdout, "ERROR: ")
        showerror(stdout, ErrorException(strip(msg) * '\n'), st)
        exit(1)
    else
        error(msg)
    end
end

const gh_token = get(ENV, "GITHUB_TOKEN", "")
const gh_repo = get(ENV, "GITHUB_REPOSITORY", "")
const gh_issue = get(ENV, "GITHUB_ISSUE_NUMBER", "")

const IssueItemState =
    @NamedTuple{state::Base.RefValue{Symbol}, duration::Base.RefValue{Float64}, desc::String}

IssueItemState(desc::String) = IssueItemState((Ref(:blocked), Ref(0.0), desc))

const issue_checkboxes = (;
    taskdir = IssueItemState("Create task directory"),
    taskenv = IssueItemState("Initialise task environment"),
    taskscript = IssueItemState("Create task script"),
    taskrun = IssueItemState("Run task script"),
    taskjulia = IssueItemState("Determine minimum Julia version"))

const issue_checkboxes_julia_versions = @NamedTuple{ver::String, status::Symbol, extra::String}[]

issue_checkboxes_lastfinished::Float64 = time()

function issue_comment()
    cbox(item::IssueItemState) =
        string("- ", if item.state[] == :blocked
                   '🚧'
               elseif item.state[] == :running
                   '⏳'
               elseif item.state[] == :done
                   '✅'
               else
                   '❔'
               end, ' ',
               item.desc,
               if item.state[] == :done
                   string(" (", round(item.duration[], digits=1), "s)")
               else "" end)
    cio = IOBuffer()
    println(cio, "## Task creation status")
    println(cio, "\nBased on the provided information, we're creating a new task PR.\n")
    for (name, item) in pairs(issue_checkboxes)
        println(cio, cbox(item))
        if name === :taskjulia
            for (; ver, status, extra) in issue_checkboxes_julia_versions
                println(cio, "  - $ver: ", if status == :success
                            "✅ succeeded"
                        elseif status == :testing
                            "❔ testing"
                        elseif status == :noinit
                            "⛔ couldn't resolve/instantiate"
                        elseif status == :failed
                            "🚨 failed"
                        elseif status == :timeout
                            "⏰ timed out"
                        elseif status == :skipped
                            "⏭️ skipped (below the registered Julia compat)"
                        else
                            ""
                        end, extra)
            end
        end
    end
    String(take!(cio))
end

gh_comment_id::Union{Nothing, String} = nothing

gh_comment_id = if any(isempty, (gh_token, gh_repo, gh_issue))
    nothing
else
    read(`gh api \
          repos/$gh_repo/issues/$gh_issue/comments \
          -F body="$(issue_comment())" \
          --jq .id`, String) |> strip
end

function update_issue_comment()
    isnothing(gh_comment_id) && return
    cmd = addenv(
      `gh api \
        /repos/$gh_repo/issues/comments/$gh_comment_id \
        --method PATCH \
        -F body="$(issue_comment())"`,
      "GITHUB_TOKEN" => gh_token)
    out = IOBuffer()
    if !success(pipeline(cmd, stdout=out))
        @error "GitHub API call failed:\n\n$(read(seekstart(out), String))"
        exit(2)
    end
end

function checkstage!(name::Symbol, next::Union{Symbol, Nothing} = nothing)
    global issue_checkboxes_lastfinished
    ctime = time()
    issue_checkboxes[name].state[] = :done
    issue_checkboxes[name].duration[] = ctime - issue_checkboxes_lastfinished
    issue_checkboxes_lastfinished = ctime
    if !isnothing(next)
        issue_checkboxes[next].state[] = :running
    end
    update_issue_comment()
end

const gh_output = if haskey(ENV, "GITHUB_OUTPUT")
    open(ENV["GITHUB_OUTPUT"], "a")
else
    devnull
end

# Remove all potentially sensitive environment variables
for key in keys(ENV)
    if startswith(key, "GITHUB_")
        delete!(ENV, key)
    end
end


# Task folder creation

const git_initial_head = readchomp(`git rev-parse HEAD`)
const git_initial_index = readchomp(`git hash-object .git/index`)

const taskdir = joinpath(@__DIR__,
                         "tasks",
                         string(uppercase(first(task.package))),
                         task.package,
                         strip(replace(task.name, r"[^A-Za-z0-9\-_]" => '-'), '-'))
const taskfile = joinpath(taskdir, "task.jl")

@info "Creating task $(relpath(taskdir, @__DIR__))"

if isfile(taskfile)
    local taskauthor = ""
    for line in eachline(taskfile)
        if startswith(line, "# Author: ")
            if line[ncodeunits("# Author: ")+1] == '@'
                taskauthor = line[ncodeunits("# Author: @"):end]
            end
            break
        elseif isempty(line)
            break
        end
    end
    if isempty(taskauthor)
        cierror("Task already exists: $taskdir")
    else
        @info "Task already exists, replacing"
        rm(taskdir, recursive=true, force=true)
        mkdir(taskdir)
    end
else
    mkpath(taskdir)
end

println(gh_output, "task_dir=", relpath(taskdir, @__DIR__))

Pkg.activate(taskdir)

checkstage!(:taskdir, :taskenv)
@info "Creating environment"

const time_preinstall = time()

const allpkgs = if task.package == "Base" String[] else String[task.package] end
append!(allpkgs, task.deps)
!isempty(allpkgs) && Pkg.add(allpkgs)

const time_to_install = time() - time_preinstall


# Registry queries (private Pkg API)

function registry_pkginfos(name::AbstractString)
    pkginfos = Pkg.Registry.PkgInfo[]
    for reg in Pkg.Registry.reachable_registries(), (_, regpkg) in reg
        regpkg.name == name || continue
        # Julia 1.13 added the registry argument
        push!(pkginfos, if applicable(Pkg.Registry.registry_info, reg, regpkg)
                  Pkg.Registry.registry_info(reg, regpkg)
              else
                  Pkg.Registry.registry_info(regpkg)
              end)
    end
    pkginfos
end

function registry_min_julia(pkginfo::Pkg.Registry.PkgInfo)
    # Julia 1.13 replaced `compat_info`
    release_compat = if isdefined(Pkg.Registry, :query_compat_for_version)
        ver -> Pkg.Registry.query_compat_for_version(pkginfo, ver)
    else
        let allcompat = Pkg.Registry.compat_info(pkginfo)
            ver -> allcompat[ver]
        end
    end
    function julia_lower(ver::VersionNumber)
        spec = get(release_compat(ver), Pkg.Registry.JULIA_UUID, nothing)
        isnothing(spec) && return v"0.0"
        isempty(spec.ranges) && return nothing
        bound = first(spec.ranges).lower
        VersionNumber(ntuple(i -> i <= bound.n ? Int(bound.t[i]) : 0, 2)...)
    end
    releases = Iterators.filter(ver -> !Pkg.Registry.isyanked(pkginfo, ver), keys(pkginfo.version_info))
    minimum(Iterators.filter(!isnothing, Iterators.map(julia_lower, releases)))
end


# Task script creation

checkstage!(:taskenv, :taskscript)
@info "Constructing task script"

const using_lines = String[]
const imported_pkgs = String[]
const script_lines = String[]

using_rx = r"^\s*using ([^ ,]*(?:\s*,\s*[^ ,]*)*)(?:$|\s|:)(?:$|\s|:)"
import_rx = r"^\s*import ([^ ,]*(?:\s*,\s*[^ ,]*)*)(?:$|\s|:)(?:$|\s|:)"

for line in eachline(IOBuffer(task.snippet))
    if !isempty(script_lines)
        push!(script_lines, line)
    elseif all(isspace, line)
    else
        umatch = match(using_rx, line)
        if isnothing(umatch)
            umatch = match(import_rx, line)
        end
        if isnothing(umatch)  
            push!(script_lines, line)
        else
            pkgs = umatch.captures[1]
            for pkg in eachsplit(pkgs, ',')
                pkg = strip(pkg)
                pkg ∉ imported_pkgs &&
                    push!(imported_pkgs, pkg)
            end
            push!(using_lines, line)
        end
    end
end

for dep in append!(String[task.package], task.deps)
    if dep ∉ imported_pkgs
        push!(using_lines, "using $dep")
    end
end

const tasktimeplaceholder = string(rand(UInt64), base=62)

open(taskfile, "w") do io
    println(io, "# Task: ", task.name)
    println(io, "# Package: ", task.package)
    if !isempty(task.deps)
        println(io, "# Dependencies: ", join(task.deps, ", "))
    end
    println(io, "# Author: @", task.author)
    if !isempty(task.attribution)
        println(io, "# Attribution: ", task.attribution)
    end
    println(io, "# Created: ", string(Date(now())))
    println(io, "# Sample timings: ", tasktimeplaceholder)
    println(io, "\n__t1 = time()\n")
    join(io, using_lines, '\n')
    println(io, "\n\n__t2 = time()\n")
    join(io, script_lines, '\n')
    println(io, "\n\n__t3 = time()\n")
    println(io, raw"""
    __t_using = __t2 - __t1
    __t_script = __t3 - __t2
    __t_total = __t3 - __t1
    println(stdout, "$__t_using, $__t_script, $__t_total seconds")
    """)
end

const taskhash = readchomp(`git hash-object $taskfile`)


# Validation

checkstage!(:taskscript, :taskrun)
@info "Performing trial run of task"

# Returns the real binary (not the juliaup launcher), so it also runs in the sandbox
function juliacmd(version::VersionNumber)
    channel = "$(version.major).$(version.minor)"
    juliaup, launcher = Sys.which("juliaup"), Sys.which("julia")
    isnothing(juliaup) && error("Cannot install Julia $channel: juliaup is not installed")
    log = IOBuffer()
    success(pipeline(`$juliaup add $channel`, stdout = log, stderr = log)) ||
        error("Installing Julia $channel with juliaup failed:\n", String(take!(log)))
    bindir = readchomp(`$launcher +$channel --startup-file=no -e 'print(Sys.BINDIR)'`)
    Cmd([joinpath(bindir, "julia"), "--startup-file=no"])
end

# Installs run in the background, so downloads overlap with testing other versions
const julia_installs = Dict{VersionNumber, Task}()

prefetch_julia(version::VersionNumber) =
    get!(() -> @async(juliacmd(version)), julia_installs, VersionNumber(version.major, version.minor))

function installed_julia(version::VersionNumber)
    install = prefetch_julia(version)
    try
        fetch(install)
    catch
        cierror(sprint(showerror, install.exception))
    end
end

sandboxed_task(julia::Cmd) =
    sandboxed(`$julia --project=$taskdir $taskfile`,
              readable = [taskdir, dirname(dirname(first(julia.exec)))])

const registry_julia_bound = try
    pkgbounds = [minimum(registry_min_julia, pkginfos) for pkginfos in map(registry_pkginfos, allpkgs)
                 if !isempty(pkginfos)]
    maximum(pkgbounds, init = v"1.0")
catch err
    @warn "Couldn't read Julia compat bounds from the registry, testing from Julia 1.0" exception = (err, catch_backtrace())
    v"1.0"
end

const first_minorver = registry_julia_bound.major == 1 ? min(registry_julia_bound.minor, VERSION.minor) : 0

# Overlap the first install with instantiating, but finish it before timing the task.
# Install failures are reported when the version is used.
let first_install = prefetch_julia(VersionNumber(1, first_minorver))
    run(`julia --startup-file=no --project=$taskdir -e 'using Pkg; Pkg.instantiate()'`)
    while !istaskdone(first_install)
        sleep(0.1)
    end
end

const taskoutput = last(collect(eachline(sandboxed_task(installed_julia(VERSION)))))

readchomp(`git hash-object $taskfile`) == taskhash ||
    cierror("Task script was modified during run")

const tasktimes = map(t -> parse(Float64, t), split(chopsuffix(taskoutput, " seconds"), ','))
@assert length(tasktimes) == 3

println(gh_output, "task_time_install=", round(time_to_install, digits=3))
println(gh_output, "task_time_using=", round(tasktimes[1], digits=3))
println(gh_output, "task_time_script=", round(tasktimes[2], digits=3))
println(gh_output, "task_time_total=", round(tasktimes[3], digits=3))

let taskstr = read(taskfile, String)
    timestr = "install in $(round(time_to_install, digits=1))s, run in $(round(tasktimes[3], digits=3))s"
    write(taskfile, replace(taskstr, tasktimeplaceholder => timestr))
end

checkstage!(:taskrun, :taskjulia)
@info "Determining minimum Julia version"

const trialrun_timeout = 60 * 5 # seconds

if first_minorver > 0
    push!(issue_checkboxes_julia_versions,
          (; ver = if first_minorver == 1 "1.0" else "1.0–1.$(first_minorver - 1)" end,
           status = :skipped, extra = ""))
end

minjulia::VersionNumber = VERSION
for minorver in first_minorver:VERSION.minor
    # We could do a binary search, but it's probably quicker to fail to resolve on old versions
    # than succeed and install all the packages etc. on newer versions.
    push!(issue_checkboxes_julia_versions, (; ver = "1.$minorver", status = :testing, extra = ""))
    update_issue_comment()
    @info "Trying Julia 1.$minorver"
    julia = installed_julia(VersionNumber(1, minorver))
    minorver < VERSION.minor && prefetch_julia(VersionNumber(1, minorver + 1))
    rm(joinpath(taskdir, "Manifest.toml"), force=true)
    resolved = success(pipeline(`$julia --project=$taskdir -e 'using Pkg; Pkg.resolve()'`; stdout, stderr))
    instantiated = resolved && success(pipeline(`$julia --project=$taskdir -e 'using Pkg; Pkg.instantiate()'`; stdout, stderr))
    if !instantiated
        issue_checkboxes_julia_versions[end] = (; ver = issue_checkboxes_julia_versions[end].ver, status = :noinit, extra = "")
        continue
    end
    trialrun = run(sandboxed_task(julia), wait = false)
    for _ in 1:trialrun_timeout
        process_running(trialrun) || break
        sleep(1)
    end
    if process_running(trialrun)
        kill(trialrun)
        issue_checkboxes_julia_versions[end] = (; ver = issue_checkboxes_julia_versions[end].ver, status = :timeout, extra = "")
    elseif trialrun.exitcode == 0
        global minjulia = VersionNumber(1, minorver)
        issue_checkboxes_julia_versions[end] = (; ver = issue_checkboxes_julia_versions[end].ver, status = :success, extra = "")
        update_issue_comment()
        Pkg.compat("julia", "$minjulia")
        break
    else
        issue_checkboxes_julia_versions[end] = (; ver = issue_checkboxes_julia_versions[end].ver, status = :failed, extra = "(exit code: $(trialrun.exitcode))")
    end
end

const mdeps = Pkg.Types.read_manifest(joinpath(taskdir, "Manifest.toml")).deps
rm(joinpath(taskdir, "Manifest.toml"), force=true)

for (uuid, pkg) in mdeps
    if pkg.name == task.package || pkg.name ∈ task.deps
        Pkg.compat(pkg.name, ">=$(pkg.version)")
    end
end


# Cleanup

checkstage!(:taskjulia)
@info "Finishing up"

rm(joinpath(taskdir, "Manifest.toml"), force=true)

let allowed = (relpath(taskfile, @__DIR__),
               relpath(joinpath(taskdir, "Project.toml"), @__DIR__),
               "create-snippet-logs.txt",
               "snippet.jl")
    unautherised = String[]
    for line in eachline(`git status --untracked-files=all --porcelain=v1`)
        if !(startswith(line, "?? ") && line[4:end] in allowed)
            push!(unautherised, line[4:end])
        end
    end
    if !isempty(unautherised)
        cierror("""
                Unauthorized change$(ifelse(length(unautherised) == 1, "s", "")) detected:
                - $(join(unautherised, "\n- "))
                The only allowed files are:
                - $(relpath(taskfile, @__DIR__))
                - $(relpath(joinpath(taskdir, "Project.toml"), @__DIR__))

                If there's no easy way to avoid creating these files, we recommend
                either creating them in the temp directory, or limiting them to the
                task directory and cleaning them up (i.e. invoking `rm`) yourself
                (yes, it will increase the task runtime slightly, but if you're creating
                tempfiles it probably won't be enough to matter anyway).
                """)
    end
end

const git_final_head  = readchomp(`git rev-parse HEAD`)
const git_final_index = readchomp(`git hash-object .git/index`)

if git_initial_head != git_final_head
    cierror("Git HEAD was sneakily rewritten from $git_initial_head to $git_final_head")
end
if git_initial_index != git_final_index
    cierror("Git index was sneakily modified from $git_initial_index to $git_final_index")
end

#= # Delete the progress comment if the task was created successfully
if !isnothing(gh_comment_id)
    run(addenv(
      `gh api \
        /repos/$gh_repo/issues/comments/$gh_comment_id \
        --method DELETE`,
      "GITHUB_TOKEN" => gh_token))
end
=#
