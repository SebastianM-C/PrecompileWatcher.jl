# PrecompileWatcher.jl

> **⚠️ Experimental — use at your own risk.**
> This package is in early development and its API may change without notice.
> It was largely written by Claude (Anthropic) with human guidance and review.

A passive monitoring tool that tracks Julia precompilation activity using inotify.
It watches `~/.julia/compiled/` for cache file writes and logs every event, so you can
later query how much precompilation happened today, this week, or over any time period.

## Installation

Requires Julia 1.12+.

```julia
using Pkg
Pkg.add(url="https://github.com/SebastianM-C/PrecompileWatcher.jl")
```

As a CLI app:

```julia
Pkg.Apps.add(url="https://github.com/SebastianM-C/PrecompileWatcher.jl")
```

## Usage

### Background watcher (daemon)

Start the watcher to begin recording events:

```julia
using PrecompileWatcher
state = start_watcher()
# ... do your work, precompile packages, etc. ...
stop_watcher(state)
```

Or via the CLI:

```sh
precompile-watcher watch
```

Events are logged as JSON Lines to `~/.julia/precompile_watcher/events.log`.

### Querying statistics

```julia
using PrecompileWatcher

# Summary for today (top 20 packages by event count)
query_stats()

# Last 7 days, show all packages
query_stats(period=:week, top_n=Inf)

# Available periods: :today, :week, :month, :all
query_stats(period=:month)
```

Example output:

```
Precompilation Summary (week)
============================================================
  Total raw events:      142
  Files precompiled:     87
  Total bytes written:   1.2 GB
  Net cache on disk:     890.3 MB

  Top packages (by events):
    Makie                           12 events    4 files    256.3 MB
    Plots                            8 events    3 files    143.7 MB  1 rewrites
    DataFrames                       6 events    2 files     32.1 MB
    ...
```

### Per-package details

Drill into a specific package to see individual precompilation sessions:

```julia
sessions = package_details("Plots", period=:week)
```

```
Details for Plots (week)
============================================================
  Raw events: 8  |  Sessions: 4
  Unique cache files: 3

  [1] 2026-03-14 09:12:33  aaa_111.ji  19.1 MB  (2 events)
  [2] 2026-03-14 09:12:34  aaa_111.so  42.9 MB  (2 events)
  [3] 2026-03-16 14:05:01  aaa_222.ji  20.0 MB  (2 events)
  [4] 2026-03-16 14:05:02  aaa_222.so  43.5 MB  (2 events)

  Rewritten cache files:
    aaa_111.ji  — 2 times
```

### Cache file inspection

For a deep look at what's inside a cache file (external methods, specializations,
segment sizes), use PkgCacheInspector integration:

```julia
cf = inspect_package("JSON")
```

Note: the package must be available in the current environment.

## CLI

When installed as a Pkg app:

```sh
# Start the watcher daemon
precompile-watcher watch

# Show stats
precompile-watcher stats              # today, top 20
precompile-watcher stats week         # last 7 days
precompile-watcher stats month all    # last 30 days, all packages
precompile-watcher stats --sort-by=size  # sort by total bytes
```

## How it works

PrecompileWatcher uses Julia's `FileWatching` stdlib (which wraps inotify on Linux)
to monitor all package directories under `~/.julia/compiled/v*/`. Each directory gets
its own async `FolderMonitor` task. When a `.ji` or `.so` file is created or modified,
an event is appended to the JSON Lines log.

Julia writes precompile caches atomically (serialize to memory, write to temp file,
rename into place), so inotify sees the final file appear all at once. This means
the watcher captures *what* was precompiled and *how large* the result is, but not
*how long* compilation took — that happens in memory before any disk I/O.

## systemd service

To run the watcher automatically in the background, install the included systemd user service:

```sh
cp precompile-watcher.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now precompile-watcher
```

Check status with:

```sh
systemctl --user status precompile-watcher
journalctl --user -u precompile-watcher -f
```

## Future plans

- eBPF integration via [BPFnative.jl](https://github.com/jpsamaroo/BPFnative.jl)
  for measuring actual compilation time, CPU usage, and memory pressure
