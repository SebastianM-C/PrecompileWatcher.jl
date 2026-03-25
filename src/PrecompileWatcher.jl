module PrecompileWatcher

using FileWatching: FolderMonitor, close
using Dates
using JSON
using PkgCacheInspector: info_cachefile, PkgCacheInfo

export start_watcher, stop_watcher, query_stats, package_details, inspect_package

include("storage.jl")
include("watcher.jl")
include("stats.jl")
include("inspect.jl")
include("cli.jl")

"""
    default_watch_dirs()

Return all `compiled/vX.Y/` directories found in Julia depot paths.
"""
function default_watch_dirs()
    dirs = String[]
    for depot in DEPOT_PATH
        compiled = joinpath(depot, "compiled")
        isdir(compiled) || continue
        for entry in readdir(compiled)
            d = joinpath(compiled, entry)
            if isdir(d) && startswith(entry, "v")
                push!(dirs, d)
            end
        end
    end
    return dirs
end

"""
    default_log_path()

Return the default path for the event log file.
"""
function default_log_path()
    return joinpath(first(DEPOT_PATH), "precompile_watcher", "events.log")
end

end # module PrecompileWatcher
