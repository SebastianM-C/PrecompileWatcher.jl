# Query and display precompilation statistics

const DEFAULT_TOP_N = 20

"""
    query_stats(; log_path=default_log_path(), period=:today, top_n=$DEFAULT_TOP_N, sort_by=:precompilations)

Query precompilation statistics for a given time period.

`period` can be:
- `:today` — events from today
- `:week` — events from the last 7 days
- `:month` — events from the last 30 days
- `:all` — all recorded events
- A `Tuple{DateTime, DateTime}` for a custom range

`top_n` controls how many packages to show (sorted by event count).
Use `Inf` to show all.

`sort_by` controls the sort order: `:precompilations` (default) or `:size`.
"""
function query_stats(; log_path=default_log_path(), period=:today, top_n=DEFAULT_TOP_N, sort_by=:precompilations)
    events = load_events(log_path)
    isempty(events) && return println("No precompilation events recorded.")

    filtered = filter_by_period(events, period)
    isempty(filtered) && return println("No precompilation events in the selected period.")

    display_summary(filtered, period; top_n, sort_by)
end

function filter_by_period(events, period::Symbol)
    now_dt = now()
    cutoff = if period == :today
        DateTime(Date(now_dt))
    elseif period == :week
        now_dt - Day(7)
    elseif period == :month
        now_dt - Day(30)
    elseif period == :all
        DateTime(0)
    else
        error("Unknown period: $period. Use :today, :week, :month, :all")
    end
    return filter(e -> e.timestamp >= cutoff, events)
end

function filter_by_period(events, (from, to)::Tuple{DateTime, DateTime})
    return filter(e -> from <= e.timestamp <= to, events)
end

"""
    compute_file_sessions(events) -> Vector{NamedTuple}

Group raw events into precompilation sessions. A `.ji` and `.so` file
with the same stem (e.g. `abc_123.ji` + `abc_123.so`) are paired into
a single session, since Julia always produces them together.

Sessions are split when consecutive events for the same stem are more
than `SESSION_GAP` apart.
"""
# Maximum gap between events before we consider it a new session.
const SESSION_GAP = Second(60)

"""
    file_stem(filename::String) -> String

Strip `.ji` or `.so` extension to get the shared stem for pairing.
"""
file_stem(filename::String) = replace(filename, r"\.(ji|so)$" => "")

function compute_file_sessions(events)
    # Group by (package, stem) to pair .ji and .so files
    groups = Dict{Tuple{String,String}, Vector{PrecompileEvent}}()
    for e in events
        e.event_type == :removed && continue
        key = (e.package, file_stem(e.file))
        push!(get!(Vector{PrecompileEvent}, groups, key), e)
    end

    sessions = @NamedTuple{
        package::String, stem::String, julia_version::String,
        start::DateTime, stop::DateTime,
        ji_size::Int64, so_size::Int64, total_size::Int64,
        event_count::Int,
    }[]
    for ((pkg, stem), evts) in groups
        sort!(evts; by=e -> e.timestamp)
        # Split into sessions by time gaps
        session_start = 1
        for i in 2:length(evts)
            if evts[i].timestamp - evts[i-1].timestamp > SESSION_GAP
                _push_session!(sessions, pkg, stem, evts, session_start, i-1)
                session_start = i
            end
        end
        _push_session!(sessions, pkg, stem, evts, session_start, length(evts))
    end
    return sort!(sessions; by=s -> s.start)
end

function _push_session!(sessions, pkg, stem, evts, i_start, i_end)
    t_start = evts[i_start].timestamp
    t_stop = evts[i_end].timestamp
    # Find the final size of each file type
    ji_size = Int64(0)
    so_size = Int64(0)
    for i in i_end:-1:i_start
        if endswith(evts[i].file, ".ji") && ji_size == 0
            ji_size = evts[i].size_bytes
        elseif endswith(evts[i].file, ".so") && so_size == 0
            so_size = evts[i].size_bytes
        end
        ji_size > 0 && so_size > 0 && break
    end
    push!(sessions, (
        package        = pkg,
        stem           = stem,
        julia_version  = evts[i_start].julia_version,
        start          = t_start,
        stop           = t_stop,
        ji_size        = ji_size,
        so_size        = so_size,
        total_size     = ji_size + so_size,
        event_count    = i_end - i_start + 1,
    ))
end

function display_summary(events, period; top_n=DEFAULT_TOP_N, sort_by=:precompilations)
    sessions = compute_file_sessions(events)

    println("Precompilation Summary ($(period))")
    println("=" ^ 60)
    println("  Total raw events:      $(length(events))")
    println("  Precompilations:       $(length(sessions))")

    total_written = sum(s.total_size for s in sessions; init=Int64(0))
    println("  Total bytes written:   $(format_size(total_written))")

    # Net size: only the latest session per unique stem
    latest = Dict{Tuple{String,String}, Int64}()
    for s in sessions
        latest[(s.package, s.stem)] = s.total_size  # sessions are sorted by time, last write wins
    end
    net_bytes = sum(values(latest); init=Int64(0))
    println("  Net cache on disk:     $(format_size(net_bytes))")
    println()

    # Per-package breakdown, sorted by number of precompilations
    # Track unique stems to distinguish "9 environments" from "1 cache rewritten 9 times"
    # Resolve extension uuid slugs to parent packages so that e.g.
    # Statistics/SparseArraysExt and KernelAbstractions/SparseArraysExt are separate entries.
    lookup = slug_lookup()
    # Detect extension name collisions (multiple parents for the same directory name)
    pkg_parents = Dict{String, Set{String}}()  # package name => set of parent names
    for s in sessions
        us = uuid_slug(s.stem)
        parent = get(lookup, us, nothing)
        if parent !== nothing && parent != s.package
            push!(get!(Set{String}, pkg_parents, s.package), parent)
        end
    end
    # Only qualify names that have multiple parents
    has_collision = Dict(pkg => length(parents) > 1 for (pkg, parents) in pkg_parents)

    pkg_stats = Dict{String, @NamedTuple{precompilations::Int, unique_caches::Int, rewrites::Int, bytes::Int64}}()
    pkg_stems = Dict{String, Set{String}}()
    for s in sessions
        us = uuid_slug(s.stem)
        parent = get(lookup, us, nothing)
        # Only add parent qualifier when multiple parents define the same extension name
        key = if parent !== nothing && get(has_collision, s.package, false)
            "$(s.package) ($(parent))"
        else
            s.package
        end
        prev = get(pkg_stats, key, (precompilations=0, unique_caches=0, rewrites=0, bytes=Int64(0)))
        seen = get!(Set{String}, pkg_stems, key)
        is_rewrite = s.stem in seen
        push!(seen, s.stem)
        pkg_stats[key] = (
            precompilations = prev.precompilations + 1,
            unique_caches   = length(seen),
            rewrites        = prev.rewrites + is_rewrite,
            bytes           = prev.bytes + s.total_size,
        )
    end

    if !isempty(pkg_stats)
        sort_fn = if sort_by == :size
            kv -> kv[2].bytes
        elseif sort_by == :precompilations
            kv -> kv[2].precompilations
        else
            error("Unknown sort_by: $sort_by. Use :precompilations or :size")
        end
        sorted = sort(collect(pkg_stats); by=sort_fn, rev=true)
        n_total = length(sorted)
        shown = isfinite(top_n) ? sorted[1:min(Int(top_n), n_total)] : sorted

        println("  Top packages (by $(sort_by)):")
        for (pkg, stats) in shown
            sz = format_size(stats.bytes)
            rewrite_info = stats.rewrites > 0 ? "  $(stats.rewrites) rewrites" : ""
            println("    $(rpad(pkg, 40)) $(lpad(string(stats.precompilations), 4)) precompilations  $(lpad(string(stats.unique_caches), 3)) caches  $(lpad(sz, 10))$rewrite_info")
        end
        if n_total > length(shown)
            println("    ... and $(n_total - length(shown)) more (use top_n=Inf to show all)")
        end
    end

    # Per Julia version
    versions = unique(s.julia_version for s in sessions)
    if length(versions) > 1
        println()
        println("  Julia versions: $(join(sort(collect(versions)), ", "))")
    end

    # Parallelism: find peak concurrent precompilations
    peak = compute_peak_parallelism(sessions)
    if peak > 1
        println("  Peak parallelism:      $(peak) concurrent")
    end
end

"""
    uuid_slug(stem::String) -> String

Extract the UUID slug (first `_`-separated segment) from a cache file stem.
E.g., `FB5Xc_zGWII` → `FB5Xc`.
"""
function uuid_slug(stem::String)
    idx = findfirst('_', stem)
    idx === nothing && return stem
    return stem[1:idx-1]
end

"""
    config_slug(stem::String) -> String

Extract the config slug (last `_`-separated segment) from a cache file stem.
E.g., `FB5Xc_zGWII` → `zGWII`.
"""
function config_slug(stem::String)
    idx = findlast('_', stem)
    idx === nothing && return stem
    return stem[idx+1:end]
end

"""
    _scan_project_toml!(lookup::Dict, proj_path::String)

Parse a Project.toml and add extension slug → parent package name mappings.
"""
function _scan_project_toml!(lookup::Dict{String, String}, proj_path::String)
    isfile(proj_path) || return
    try
        proj = TOML.parsefile(proj_path)
        uuid_str = get(proj, "uuid", nothing)
        uuid_str === nothing && return
        pkg_name = get(proj, "name", "unknown")
        exts = get(proj, "extensions", Dict())
        for ext_name in keys(exts)
            ext_uuid = Base.uuid5(Base.UUID(uuid_str), ext_name)
            slug = Base.package_slug(ext_uuid, 5)
            lookup[slug] = pkg_name
        end
    catch
    end
end

"""
    build_slug_lookup() -> Dict{String, String}

Build a mapping from extension UUID slugs to their parent package names
by scanning all installed packages and stdlibs for extension definitions.
"""
function build_slug_lookup()
    lookup = Dict{String, String}()
    # Scan depot packages
    for depot in DEPOT_PATH
        packages_dir = joinpath(depot, "packages")
        isdir(packages_dir) || continue
        for pkg_name in readdir(packages_dir)
            pkg_dir = joinpath(packages_dir, pkg_name)
            isdir(pkg_dir) || continue
            for ver_hash in readdir(pkg_dir)
                _scan_project_toml!(lookup, joinpath(pkg_dir, ver_hash, "Project.toml"))
            end
        end
    end
    # Scan stdlib
    stdlib_dir = joinpath(Sys.BINDIR, "..", "share", "julia", "stdlib",
                          "v$(VERSION.major).$(VERSION.minor)")
    if isdir(stdlib_dir)
        for pkg_name in readdir(stdlib_dir)
            _scan_project_toml!(lookup, joinpath(stdlib_dir, pkg_name, "Project.toml"))
        end
    end
    return lookup
end

const _slug_lookup_cache = Dict{String, String}()
const _slug_lookup_built = Ref(false)

"""
    slug_lookup() -> Dict{String, String}

Return a cached mapping from extension UUID slugs to parent package names.
"""
function slug_lookup()
    _slug_lookup_built[] && return _slug_lookup_cache
    merge!(_slug_lookup_cache, build_slug_lookup())
    _slug_lookup_built[] = true
    return _slug_lookup_cache
end

"""
    find_cache_file(julia_version::String, package::String, file::String) -> Union{String, Nothing}

Search all depot paths for a compiled cache file.
"""
function find_cache_file(julia_version::String, package::String, file::String)
    for depot in DEPOT_PATH
        path = joinpath(depot, "compiled", "v$julia_version", package, file)
        isfile(path) && return path
    end
    return nothing
end

"""
    decode_cache_flags(f::UInt8) -> NamedTuple

Decode a CacheFlags byte into its components.
Layout: OOICCDDP (opt_level, inline, check_bounds, debug_level, use_pkgimages).
"""
function decode_cache_flags(f::UInt8)
    return (
        use_pkgimages = Bool(f & 1),
        debug_level   = Int((f >> 1) & 3),
        check_bounds  = Int((f >> 3) & 3),
        inline        = Bool((f >> 5) & 1),
        opt_level     = Int((f >> 6) & 3),
    )
end

"""
    read_cache_header_info(path::String)

Read CacheFlags and preferences from a `.ji` file header.
Returns a NamedTuple with `flags` and `prefs`, or `nothing` if unreadable.
"""
function read_cache_header_info(path::String)
    isfile(path) || return nothing
    try
        open(path) do io
            Base.isvalid_cache_header(io) === nothing && return nothing
            _, _, _, _, prefs, prefs_hash, _, flags = Base.parse_cache_header(io, path)
            return (flags=decode_cache_flags(flags), prefs=prefs, prefs_hash=prefs_hash)
        end
    catch
        return nothing
    end
end

"""
    format_cache_flags(cf::NamedTuple) -> String

Human-readable representation of decoded cache flags.
"""
function format_cache_flags(cf)
    bounds = cf.check_bounds == 0 ? "auto" : cf.check_bounds == 1 ? "yes" : "no"
    parts = ["O$(cf.opt_level)", "debug=$(cf.debug_level)", "bounds=$bounds"]
    cf.inline || push!(parts, "noinline")
    cf.use_pkgimages || push!(parts, "no-pkgimages")
    return join(parts, " ")
end

"""
    package_details(package::String; log_path=default_log_path(), period=:today)

Show detailed precompilation history for a specific package, including
individual sessions with timestamps, cache files, sizes, and config info.
"""
function package_details(package::String; log_path=default_log_path(), period=:today)
    events = load_events(log_path)
    filtered = filter_by_period(events, period)
    pkg_events = filter(e -> e.package == package, filtered)

    if isempty(pkg_events)
        println("No events for '$package' in the selected period.")
        return nothing
    end

    sessions = compute_file_sessions(pkg_events)
    lookup = slug_lookup()

    # Resolve uuid slugs to parent package names
    parent_map = Dict{String, String}()  # uuid_slug => parent name
    for s in sessions
        us = uuid_slug(s.stem)
        haskey(parent_map, us) && continue
        parent_map[us] = get(lookup, us, us)
    end

    println("Details for $package ($(period))")
    println("=" ^ 60)
    println("  Raw events: $(length(pkg_events))  |  Precompilations: $(length(sessions))")

    unique_stems = unique(s.stem for s in sessions)
    println("  Unique caches: $(length(unique_stems))")

    # Show parent packages if there are multiple
    if length(parent_map) > 1
        println()
        println("  Parent packages ($(length(parent_map))):")
        for (us, parent) in sort(collect(parent_map); by=kv -> kv[2])
            println("    $us  → $parent")
        end
    end

    # Group sessions by config slug and read flags from disk
    config_groups = Dict{String, @NamedTuple{stems::Set{String}, count::Int}}()
    for s in sessions
        cs = config_slug(s.stem)
        prev = get(config_groups, cs, (stems=Set{String}(), count=0))
        push!(prev.stems, s.stem)
        config_groups[cs] = (stems=prev.stems, count=prev.count + 1)
    end

    if !isempty(config_groups)
        println()
        println("  Configs ($(length(config_groups))):")
        # Read header info for each config
        config_infos = Dict{String, Any}()
        for (cs, info) in config_groups
            for s in sessions
                config_slug(s.stem) == cs || continue
                ji_file = s.stem * ".ji"
                path = find_cache_file(s.julia_version, package, ji_file)
                if path !== nothing
                    hi = read_cache_header_info(path)
                    if hi !== nothing
                        config_infos[cs] = hi
                        break
                    end
                end
            end
        end

        for (cs, info) in sort(collect(config_groups); by=kv -> kv[2].count, rev=true)
            hi = get(config_infos, cs, nothing)
            flags_str = hi !== nothing ? "  $(format_cache_flags(hi.flags))" : ""
            prefs_str = if hi !== nothing && !isempty(hi.prefs)
                "  prefs: $(join(hi.prefs, ", "))"
            else
                ""
            end
            caches_str = length(info.stems) == 1 ? "1 cache" : "$(length(info.stems)) caches"
            println("    $(rpad(cs, 7))$(rpad(flags_str, 35)) — $caches_str, $(info.count) precompilations$prefs_str")
        end

        # Note if configs differ only by project environment
        if length(config_infos) > 1
            all_flags = unique(hi.flags for hi in values(config_infos))
            all_prefs = unique(hi.prefs_hash for hi in values(config_infos))
            if length(all_flags) < length(config_infos) && length(all_prefs) < length(config_infos)
                n_same = length(config_infos) - max(length(all_flags), length(all_prefs)) + 1
                println("    ℹ  $(n_same) configs share the same flags and preferences — they differ by project environment")
            end
        end
    end
    println()

    for (i, s) in enumerate(sessions)
        ts = Dates.format(s.start, "yyyy-mm-dd HH:MM:SS")
        parent = get(parent_map, uuid_slug(s.stem), uuid_slug(s.stem))
        cs = config_slug(s.stem)
        label = length(parent_map) > 1 ? "$parent [$cs]" : s.stem
        ji = format_size(s.ji_size)
        so = s.so_size > 0 ? "  .so=$(format_size(s.so_size))" : ""
        println("  [$i] $ts  $(rpad(label, 30))  .ji=$(ji)$so  ($(s.event_count) events)")
    end

    # Identify rewrites
    stem_counts = Dict{String, Int}()
    for s in sessions
        stem_counts[s.stem] = get(stem_counts, s.stem, 0) + 1
    end
    rewrites = filter(kv -> kv[2] > 1, stem_counts)
    if !isempty(rewrites)
        println()
        println("  Rewritten caches:")
        for (stem, count) in sort(collect(rewrites); by=kv -> kv[2], rev=true)
            parent = get(parent_map, uuid_slug(stem), uuid_slug(stem))
            cs = config_slug(stem)
            label = length(parent_map) > 1 ? "$parent [$cs]" : stem
            println("    $label  — $count times")
        end
    end

    return sessions
end

"""
    compute_peak_parallelism(sessions) -> Int

Find the maximum number of overlapping precompilation sessions.
"""
function compute_peak_parallelism(sessions)
    isempty(sessions) && return 0
    # Sweep line algorithm
    timeline = Tuple{DateTime, Int}[]
    for s in sessions
        push!(timeline, (s.start, +1))
        push!(timeline, (s.stop, -1))
    end
    sort!(timeline)
    peak = 0
    current = 0
    for (_, delta) in timeline
        current += delta
        peak = max(peak, current)
    end
    return peak
end

"""
    format_size(bytes::Integer) -> String

Human-readable size string, using the most appropriate unit.
"""
function format_size(bytes::Integer)
    if bytes < 1024
        return "$(bytes) B"
    elseif bytes < 1024^2
        return "$(round(bytes / 1024; digits=1)) KB"
    elseif bytes < 1024^3
        return "$(round(bytes / 1024^2; digits=1)) MB"
    else
        return "$(round(bytes / 1024^3; digits=2)) GB"
    end
end

"""
    format_duration(d::Millisecond) -> String

Human-readable duration string.
"""
function format_duration(d::Millisecond)
    ms = d.value
    if ms < 1000
        return "$(ms)ms"
    elseif ms < 60_000
        return "$(round(ms / 1000; digits=1))s"
    elseif ms < 3_600_000
        m, s = divrem(ms, 60_000)
        return "$(Int(m))m $(round(s / 1000; digits=0))s"
    else
        h, rem = divrem(ms, 3_600_000)
        m = div(rem, 60_000)
        return "$(Int(h))h $(Int(m))m"
    end
end
