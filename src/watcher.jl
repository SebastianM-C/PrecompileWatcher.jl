# Filesystem watcher for Julia precompilation cache directories

"""
    WatcherState

Holds the state for a running precompilation watcher, including
active FolderMonitors and the log file path.
"""
mutable struct WatcherState
    monitors::Dict{String, FolderMonitor}  # dir => monitor
    tasks::Vector{Task}                     # one async task per monitor
    log_path::String
    log_io::IO                              # open file handle for appending events
    running::Bool
    lock::ReentrantLock                     # protects log writes and monitors dict
    seen_files::Dict{String, DateTime}      # filepath => first seen time, for event classification
end

"""
    extract_package_name(path::String) -> String

Extract the package name from a path like `.julia/compiled/v1.12/JSON3/abc.ji`.
Returns the directory name that represents the package.
"""
function extract_package_name(path::String)
    parts = splitpath(path)
    # The package name is the parent directory of the .ji/.so file
    for (i, p) in enumerate(parts)
        if endswith(p, ".ji") || endswith(p, ".so")
            return i > 1 ? parts[i-1] : "unknown"
        end
    end
    # If it's a directory path, return the last component
    return last(parts)
end

"""
    extract_julia_version(path::String) -> String

Extract the Julia version string from a compiled cache path.
E.g., `.julia/compiled/v1.12/...` -> "1.12"
"""
function extract_julia_version(path::String)
    for part in splitpath(path)
        if startswith(part, "v") && contains(part, ".")
            return part[2:end]  # strip the 'v' prefix
        end
    end
    return string(VERSION.major, ".", VERSION.minor)
end

"""
    process_event!(state::WatcherState, dir::String, filename::String)

Handle a filesystem event in a watched directory.
"""
function process_event!(state::WatcherState, dir::String, filename::String)
    # Only care about .ji and .so files
    (endswith(filename, ".ji") || endswith(filename, ".so")) || return

    filepath = joinpath(dir, filename)
    julia_ver = extract_julia_version(dir)
    pkg_name = extract_package_name(filepath)

    if isfile(filepath)
        # Use mtime so scan-discovered files get accurate timestamps
        ts = unix2datetime(mtime(filepath))
        sz = filesize(filepath)
        lock(state.lock) do
            event_type = if haskey(state.seen_files, filepath)
                :modified
            else
                state.seen_files[filepath] = ts
                :created
            end
            append_event!(state.log_io, PrecompileEvent(ts, julia_ver, pkg_name, filename, event_type, sz))
        end
    else
        lock(state.lock) do
            delete!(state.seen_files, filepath)
            append_event!(state.log_io, PrecompileEvent(now(), julia_ver, pkg_name, filename, :removed, 0))
        end
    end
end

"""
    watch_directory!(state::WatcherState, dir::String)

Start watching a single directory. Spawns an async task that waits
for events on the FolderMonitor and processes them.
"""
function watch_directory!(state::WatcherState, dir::String)
    already_watching = lock(state.lock) do
        haskey(state.monitors, dir) && return true
        try
            fm = FolderMonitor(dir)
            state.monitors[dir] = fm
        catch e
            @warn "Failed to watch directory" dir exception=e
            return true
        end
        return false
    end
    already_watching && return

    # Scan for files that already exist before the monitor was ready.
    # This closes the race where a file is written between directory
    # creation and monitor setup.
    for f in readdir(dir)
        subpath = joinpath(dir, f)
        if isdir(subpath)
            @async watch_directory!(state, subpath)
        elseif endswith(f, ".ji") || endswith(f, ".so")
            process_event!(state, dir, f)
        end
    end

    t = @async begin
        fm = state.monitors[dir]
        while state.running
            try
                fname, _event = wait(fm)
                state.running || break

                # If a new subdirectory appeared (new package), start watching it
                subpath = joinpath(dir, fname)
                if isdir(subpath)
                    @async watch_directory!(state, subpath)
                end

                process_event!(state, dir, fname)
            catch e
                e isa EOFError && break
                state.running || break
                @warn "Error processing event" dir exception=e
            end
        end
    end
    push!(state.tasks, t)
end

"""
    lock_path(log_path::String) -> String

Return the path to the PID lockfile for a given log path.
"""
lock_path(log_path::String) = log_path * ".lock"

"""
    acquire_lock!(log_path::String)

Write the current PID to the lockfile. Errors if another live watcher
is already running (stale lockfiles from crashed processes are ignored).
"""
function acquire_lock!(log_path::String)
    lp = lock_path(log_path)
    if isfile(lp)
        old_pid = try
            parse(Int, strip(read(lp, String)))
        catch
            nothing
        end
        if old_pid !== nothing && isdir("/proc/$old_pid")
            error("Another PrecompileWatcher is already running (PID $old_pid). " *
                  "Stop it first, or remove $lp if the process is stale.")
        end
        @warn "Removing stale lockfile" path=lp old_pid
    end
    write(lp, string(getpid()))
end

"""
    release_lock!(log_path::String)

Remove the PID lockfile.
"""
function release_lock!(log_path::String)
    lp = lock_path(log_path)
    isfile(lp) && rm(lp)
end

"""
    start_watcher(; watch_dirs=default_watch_dirs(), log_path=default_log_path())

Start the background precompilation watcher. Returns a `WatcherState` that
can be used to stop the watcher later.

Watches all package subdirectories under each compiled directory.
New package directories are picked up automatically when they appear.
"""
function start_watcher(; watch_dirs=default_watch_dirs(), log_path=default_log_path())
    mkpath(dirname(log_path))
    acquire_lock!(log_path)
    log_io = open(log_path, "a")
    state = WatcherState(
        Dict{String, FolderMonitor}(),
        Task[],
        log_path,
        log_io,
        true,
        ReentrantLock(),
        Dict{String, DateTime}(),
    )

    # watch_directory! recursively scans for subdirectories,
    # so we only need to kick it off at the top-level compiled dirs.
    for compiled_dir in watch_dirs
        watch_directory!(state, compiled_dir)
    end

    n_monitors = length(state.monitors)
    check_inotify_limits(n_monitors)
    @info "PrecompileWatcher started" dirs=n_monitors log_path
    return state
end

"""
    check_inotify_limits(n_monitors::Int)

Warn if the number of monitors is approaching the system's inotify instance limit.
Only applicable on Linux; silently returns on other platforms.
"""
function check_inotify_limits(n_monitors::Int)
    Sys.islinux() || return
    max_instances_path = "/proc/sys/fs/inotify/max_user_instances"
    isfile(max_instances_path) || return
    max_instances = try
        parse(Int, strip(read(max_instances_path, String)))
    catch
        return
    end
    usage_pct = round(100 * n_monitors / max_instances; digits=1)
    if n_monitors > max_instances * 0.9
        @warn "inotify instance usage is critically high" n_monitors max_instances usage_pct
    elseif n_monitors > max_instances * 0.7
        @warn "inotify instance usage is high" n_monitors max_instances usage_pct
    end
end

"""
    stop_watcher(state::WatcherState)

Stop the background watcher and close all monitors.
"""
function stop_watcher(state::WatcherState)
    state.running = false
    lock(state.lock) do
        for (_, fm) in state.monitors
            close(fm)
        end
        empty!(state.monitors)
    end
    # Wait for tasks to finish (they'll hit EOFError or check running flag)
    for t in state.tasks
        try wait(t) catch end
    end
    empty!(state.tasks)
    close(state.log_io)
    release_lock!(state.log_path)
    @info "PrecompileWatcher stopped"
end
