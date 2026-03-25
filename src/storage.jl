# Event storage for precompilation events
#
# Each event is one JSON object per line (JSON Lines format).

struct PrecompileEvent
    timestamp::DateTime
    julia_version::String
    package::String
    file::String
    event_type::Symbol  # :created, :modified, :removed
    size_bytes::Int64
end

const DATETIME_FORMAT = dateformat"yyyy-mm-ddTHH:MM:SS.s"

"""
    format_event(event::PrecompileEvent) -> String

Serialize an event to a JSON line.
"""
function format_event(event::PrecompileEvent)
    d = Dict{String, Any}(
        "timestamp"     => Dates.format(event.timestamp, DATETIME_FORMAT),
        "julia_version" => event.julia_version,
        "package"       => event.package,
        "file"          => event.file,
        "event_type"    => String(event.event_type),
        "size_bytes"    => event.size_bytes,
    )
    return JSON.json(d)
end

"""
    parse_event(line::String) -> PrecompileEvent

Deserialize a JSON line back into a PrecompileEvent.
"""
function parse_event(line::String)
    d = JSON.parse(line)
    return PrecompileEvent(
        DateTime(d["timestamp"], DATETIME_FORMAT),
        d["julia_version"],
        d["package"],
        d["file"],
        Symbol(d["event_type"]),
        Int64(d["size_bytes"]),
    )
end

"""
    append_event!(io::IO, event::PrecompileEvent)

Append a single event to an open log stream and flush.
"""
function append_event!(io::IO, event::PrecompileEvent)
    println(io, format_event(event))
    flush(io)
end

"""
    load_events(path::String) -> Vector{PrecompileEvent}

Read all events from the log file.
"""
function load_events(path::String)
    isfile(path) || return PrecompileEvent[]
    events = PrecompileEvent[]
    for (i, line) in enumerate(eachline(path))
        isempty(strip(line)) && continue
        try
            push!(events, parse_event(line))
        catch e
            @warn "Skipping malformed event" line_number=i exception=e
        end
    end
    return events
end
