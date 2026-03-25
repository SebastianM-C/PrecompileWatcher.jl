# CLI entry point for the Pkg app

function print_usage()
    println("""
    Usage: precompile-watcher <command> [args...]

    Commands:
      watch                    Start the filesystem watcher (foreground)
      stats [options]           Show precompilation statistics
                               period: today (default), week, month, all
                               top_n:  number of packages to show (default 20, "all" for no limit)
                               --sort-by=size  sort by total bytes instead of precompilation count
      inspect <package>        Inspect a package's cache file via PkgCacheInspector

    Examples:
      precompile-watcher watch
      precompile-watcher stats week
      precompile-watcher stats month all
      precompile-watcher stats --sort-by=size
      precompile-watcher stats week 10 --sort-by=size
      precompile-watcher inspect JSON
    """)
end

function (@main)(ARGS)
    if isempty(ARGS)
        print_usage()
        return 1
    end

    cmd = ARGS[1]

    if cmd == "watch"
        cmd_watch()
    elseif cmd == "stats"
        positional = filter(a -> !startswith(a, "--"), ARGS[2:end])
        period = length(positional) >= 1 ? Symbol(positional[1]) : :today
        top_n = if length(positional) >= 2
            positional[2] == "all" ? Inf : parse(Int, positional[2])
        else
            DEFAULT_TOP_N
        end
        sort_by = any(==("--sort-by=size"), ARGS) ? :size : :precompilations
        cmd_stats(period; top_n, sort_by)
    elseif cmd == "inspect"
        if length(ARGS) < 2
            println(stderr, "Error: inspect requires a package name")
            return 1
        end
        cmd_inspect(ARGS[2])
    else
        println(stderr, "Unknown command: $cmd")
        print_usage()
        return 1
    end
    return 0
end

function cmd_watch()
    state = start_watcher()
    println("Watching for precompilation events. Press Ctrl+C to stop.")
    try
        wait()  # block forever
    catch e
        e isa InterruptException || rethrow()
    finally
        stop_watcher(state)
    end
end

function cmd_stats(period::Symbol; top_n=DEFAULT_TOP_N, sort_by=:precompilations)
    query_stats(; period, top_n, sort_by)
end

function cmd_inspect(package::String)
    inspect_package(package)
end
