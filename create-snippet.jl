#!/usr/bin/env julia --startup-file=no

using Pkg
using Dates

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

const issue_checkboxes_julia_versions = @NamedTuple{ver::String, status::Symbol}[]

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
            for (; ver, status) in issue_checkboxes_julia_versions
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
                        else
                            ""
                        end)
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
    elseif taskauthor != task.author
        cierror("Task already exists from a different author: $taskdir")
    else
        @info "Task already exists, replacing"
        println(gh_output, "task_nature=", "Task update")
        rm(taskdir, recursive=true, force=true)
        mkdir(taskdir)
    end
else
    println(gh_output, "task_nature=", "New task")
    mkpath(taskdir)
end

Pkg.activate(taskdir)

checkstage!(:taskdir, :taskenv)
@info "Creating environment"

const time_preinstall = time()

const allpkgs = if task.package == "Base" String[] else String[task.package] end
append!(allpkgs, task.deps)
!isempty(allpkgs) && Pkg.add(allpkgs)

const time_to_install = time() - time_preinstall


# Package authorship

for reg in Pkg.Registry.reachable_registries()
    for (uuid, regpkg) in reg
        if regpkg.name == task.package
            repourl = chopsuffix(Pkg.Registry.registry_info(regpkg).repo, ".git")
            ghrepo = match(r"https://github.com/(?<owner>[^/]+)/(?<repo>[^/]+)", repourl)
            if !isnothing(ghrepo)
                println(gh_output, "pkg_repo_owner=", ghrepo["owner"])
                println(gh_output, "pkg_repo_name=", ghrepo["repo"])
            end
        end
    end
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

function unshared(cmd::Cmd)
    @static if occursin("Ubuntu", read(`lsb_release -si`, String))
        `unshare --user --net --ipc --pid --kill-child $cmd`
    else
        `unshare --map-current-user --mount --net --ipc --pid --kill-child $cmd`
    end
end

checkstage!(:taskscript, :taskrun)
@info "Performing trial run of task"

function juliacmd(version::VersionNumber = VERSION)
    jlbin = Sys.which(string("julia-", version.major, ".", version.minor))
    isnothing(jlbin) ||return Cmd([jlbin, "--startup-file=no"])
    for jlupdir in ("~/.julia/juliaup", "~/.juliaup")
        jlupdir = expanduser(jlupdir)
        if isdir(jlupdir)
            jlupbin = joinpath(jlupdir, "bin", "juliaup")
            isfile(jlupbin) && success(`$jlupbin add $(version.major).$(version.minor)`) || continue
            jlbin = joinpath(expanduser(jlupdir), "bin", "julia")
            isfile(jlbin) && return Cmd([jlbin, "+$(version.major).$(version.minor)", "--startup-file=no"])
        end
    end
    cierror("Julia binary for $version not found")
end

run(`julia --startup-file=no --project=$taskdir -e 'using Pkg; Pkg.instantiate()'`)

const taskoutput = last(collect(eachline(unshared(`julia --startup-file=no --project=$taskdir $taskfile`))))

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

minjulia::VersionNumber = VERSION
for minorver in 0:VERSION.minor
    # We could do a binary search, but it's probably quicker to fail to resolve on old versions
    # than succeed and install all the packages etc. on newer versions.
    push!(issue_checkboxes_julia_versions, (; ver = "1.$minorver", status = :testing))
    update_issue_comment()
    @info "Trying Julia 1.$minorver"
    julia = juliacmd(VersionNumber(1, minorver))
    rm(joinpath(taskdir, "Manifest.toml"), force=true)
    resolved = success(pipeline(`$julia --project=$taskdir -e 'using Pkg; Pkg.resolve()'`; stdout, stderr))
    instantiated = resolved && success(pipeline(`$julia --project=$taskdir -e 'using Pkg; Pkg.instantiate()'`; stdout, stderr))
    if !instantiated
        issue_checkboxes_julia_versions[end] = (; ver = issue_checkboxes_julia_versions[end].ver, status = :noinit)
        continue
    end
    trialrun = run(`$(unshared(julia)) --project=$taskdir $taskfile`, wait = false)
    for _ in 1:trialrun_timeout
        process_running(trialrun) || break
        sleep(1)
    end
    if process_running(trialrun)
        kill(trialrun)
        issue_checkboxes_julia_versions[end] = (; ver = issue_checkboxes_julia_versions[end].ver, status = :timeout)
    elseif trialrun.exitcode == 0
        global minjulia = VersionNumber(1, minorver)
        issue_checkboxes_julia_versions[end] = (; ver = issue_checkboxes_julia_versions[end].ver, status = :success)
        update_issue_comment()
        Pkg.compat("julia", "$minjulia")
        break
    else
        issue_checkboxes_julia_versions[end] = (; ver = issue_checkboxes_julia_versions[end].ver, status = :failed)
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
