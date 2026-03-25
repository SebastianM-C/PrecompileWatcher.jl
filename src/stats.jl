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
    pkg_stats = Dict{String, @NamedTuple{precompilations::Int, unique_caches::Int, rewrites::Int, bytes::Int64}}()
    pkg_stems = Dict{String, Set{String}}()
    for s in sessions
        prev = get(pkg_stats, s.package, (precompilations=0, unique_caches=0, rewrites=0, bytes=Int64(0)))
        seen = get!(Set{String}, pkg_stems, s.package)
        is_rewrite = s.stem in seen
        push!(seen, s.stem)
        pkg_stats[s.package] = (
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
            println("    $(rpad(pkg, 28)) $(lpad(string(stats.precompilations), 4)) precompilations  $(lpad(string(stats.unique_caches), 3)) caches  $(lpad(sz, 10))$rewrite_info")
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
    package_details(package::String; log_path=default_log_path(), period=:today)

Show detailed precompilation history for a specific package, including
individual sessions with timestamps, cache files, and sizes.
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

    println("Details for $package ($(period))")
    println("=" ^ 60)
    println("  Raw events: $(length(pkg_events))  |  Precompilations: $(length(sessions))")

    unique_stems = unique(s.stem for s in sessions)
    println("  Unique caches: $(length(unique_stems))")
    println()

    for (i, s) in enumerate(sessions)
        ts = Dates.format(s.start, "yyyy-mm-dd HH:MM:SS")
        ji = format_size(s.ji_size)
        so = s.so_size > 0 ? "  .so=$(format_size(s.so_size))" : ""
        println("  [$i] $ts  $(s.stem)  .ji=$(ji)$so  ($(s.event_count) events)")
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
            println("    $stem  — $count times")
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
