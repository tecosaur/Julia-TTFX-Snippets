# Run with `julia test/sandbox.jl`

using Test

include(joinpath(@__DIR__, "..", "sandbox.jl"))
using .Sandbox

const julia = joinpath(Sys.BINDIR, Base.julia_exename())

jailed(cmd::Cmd; readable::Vector{String} = String[]) =
    sandboxed(cmd, readable = [dirname(Sys.BINDIR); readable])

jailed(code::String; kwargs...) = jailed(`$julia --startup-file=no -e $code`; kwargs...)

@testset "Sandbox" begin
    @testset "Runs commands" begin
        @test readchomp(jailed("print(1 + 1)")) == "2"
        @test !success(jailed("exit(3)"))
        @test run(ignorestatus(jailed("exit(3)"))).exitcode == 3
        @test readchomp(jailed(`pwd`)) == "/tmp"
        @test success(jailed(`touch /tmp/scratch`))
    end
    @testset "Hides the environment" begin
        withenv("SANDBOX_CANARY" => "secret") do
            # Includes `/proc/1/environ`, which `--clearenv` alone would leave exposed
            allenv = read(jailed(`sh -c 'env; cat /proc/[0-9]*/environ'`), String)
            @test !contains(allenv, "SANDBOX_CANARY")
        end
    end
    @testset "Hides other processes" begin
        @test getpid() ∉ parse.(Int, split(readchomp(jailed(`sh -c 'cd /proc; echo [0-9]*'`))))
        @test !success(jailed(`kill -0 $(getpid())`))
    end
    @testset "Has no network" begin
        @test readchomp(jailed(`sh -c 'ls /sys/class/net 2>/dev/null || cat /proc/net/dev'`)) |>
            !contains(r"eth|en[a-z]|wl")
        @test !success(jailed("using Sockets; connect(ip\"1.1.1.1\", 53)"))
    end
    mktempdir(homedir(); prefix = ".sandbox-test-") do dir
        secret = joinpath(dir, "secret")
        write(secret, "secret")
        @testset "Hides the home directory" begin
            @test !success(jailed(`cat $secret`))
            @test !success(jailed(`ls $(homedir())/.ssh`))
        end
        @testset "Exposes readable paths read-only" begin
            @test readchomp(jailed(`cat $secret`, readable = [dir])) == "secret"
            @test !success(jailed(`touch $dir/new`, readable = [dir]))
            @test !success(jailed(`rm $secret`, readable = [dir]))
            @test isfile(secret) && !isfile(joinpath(dir, "new"))
        end
        @testset "Follows symlinked readable paths" begin
            link = joinpath(dir, "link")
            symlink(dir, link)
            @test readchomp(jailed(`cat $link/secret`, readable = [link])) == "secret"
        end
    end
    @testset "Keeps the depot read-only behind a writable one" begin
        depots = split(readchomp(jailed("print(join(DEPOT_PATH, ':'))")), ':')
        @test depots[1] == Sandbox.SANDBOX_DEPOT
        @test depots[2] == first(DEPOT_PATH)
        @test success(jailed("mkpath(joinpath(DEPOT_PATH[1], \"compiled\"))"))
        @test !success(jailed("touch(joinpath(DEPOT_PATH[2], \"sandbox-test\"))"))
        @test !ispath(joinpath(first(DEPOT_PATH), "sandbox-test"))
    end
    @testset "Works before the depot exists" begin
        mktempdir() do dir
            sandboxjl = joinpath(@__DIR__, "..", "sandbox.jl")
            code = "include($(repr(sandboxjl))); using .Sandbox; run(sandboxed(`true`))"
            fresh = addenv(`$julia --startup-file=no -e $code`, "JULIA_DEPOT_PATH" => joinpath(dir, "depot"))
            @test success(pipeline(fresh, stderr = devnull))
        end
    end
    @testset "Kills the jail with the process" begin
        proc = run(jailed(`sleep 60`), wait = false)
        sleep(1)
        kill(proc)
        @test timedwait(() -> process_exited(proc), 5) === :ok
    end
end
