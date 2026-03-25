# On-demand cache file inspection using PkgCacheInspector
#
# This is intended for use from the CLI (fresh process each time).
# PkgCacheInspector.info_cachefile loads the package image into the process,
# so avoid calling it from the long-running watcher daemon.

"""
    inspect_package(package::String) -> PkgCacheInfo

Inspect the active cache file for `package` and display a summary.
Returns the `PkgCacheInfo` from PkgCacheInspector for further analysis.

The package must be reachable from the current environment — if it's not
a direct or indirect dependency, activate an environment that has it first.
"""
function inspect_package(package::String)
    pkgid = Base.identify_package(package)
    if pkgid === nothing
        error("Package '$package' not found in the current environment. " *
              "Activate an environment that depends on it first (e.g. `Pkg.activate(\"path/to/project\")`)")
    end
    cf = info_cachefile(pkgid)
    display(cf)
    return cf
end
