"""
Run untrusted commands in a bubblewrap jail.

The jail has no network, a fresh process tree and an empty environment. It
sees the system directories, the Julia depot and any requested paths
read-only, with `\$HOME` otherwise hidden. Writes go to a throwaway `/tmp`,
which is also the working directory and holds a writable depot stacked in
front of the real one.
"""
module Sandbox

export sandboxed

const SYSTEM_DIRS = ("/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/etc")

const SANDBOX_DEPOT = "/tmp/depot"

"""
    sandboxed(cmd::Cmd; readable::Vector{String} = String[]) -> Cmd

Wrap `cmd` to run in the jail, with `readable` paths visible read-only at
their real locations (e.g. the Julia install and the project directory).
The exit code is that of `cmd`, and killing the returned process kills
everything inside the jail.

Throws an `ErrorException` when bubblewrap isn't installed.

# Example
```julia
run(sandboxed(`julia -e 'println("hello")'`, readable = [Sys.BINDIR]))
```
"""
function sandboxed(cmd::Cmd; readable::Vector{String} = String[])
    bwrap = Sys.which("bwrap")
    isnothing(bwrap) &&
        error("Cannot sandbox $(cmd.exec[1]): bubblewrap (`bwrap`) is not installed")
    depot = mkpath(first(DEPOT_PATH)) # Absent on fresh machines, but must exist to bind
    jailargs = String[
        "--unshare-all", "--die-with-parent", "--new-session",
        "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
        "--tmpfs", homedir(), "--chdir", "/tmp"]
    for dir in SYSTEM_DIRS
        if islink(dir)
            append!(jailargs, ("--symlink", readlink(dir), dir))
        elseif isdir(dir)
            append!(jailargs, ("--ro-bind", dir, dir))
        end
    end
    for path in unique(map(abspath, [depot; readable]))
        # Bind at the real location, so executables can find their siblings
        target = realpath(path)
        append!(jailargs, ("--ro-bind", target, target))
        target == path || append!(jailargs, ("--symlink", target, path))
    end
    # Set on bwrap itself, as `--clearenv` leaves the caller's environment
    # readable in the jail's `/proc/1/environ`. Julia 1.6+ expands the
    # trailing empty depot entry to the bundled depots.
    jailenv = ["PATH" => "/usr/bin:/bin", "HOME" => homedir(), "LANG" => "C.UTF-8",
               "JULIA_DEPOT_PATH" => "$SANDBOX_DEPOT:$depot:"]
    Cmd(Cmd([bwrap; jailargs; cmd.exec]); env = jailenv, ignorestatus = cmd.ignorestatus)
end

end
