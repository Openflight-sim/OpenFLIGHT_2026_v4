"""
    server.jl — WebSocket server for real-time analysis (MsgPack protocol)

Provides a WebSocket server that listens for analysis requests from the
HTML app, dispatches to AeroModel.run_analysis(), and streams progress
updates and results back to the client.

Uses the same HTTP.listen + HTTP.WebSockets.upgrade + MsgPack binary
protocol pattern proven in the example_msgpack framework.

Protocol (all messages are MsgPack-encoded):
  Client → Server:
    {"type": "run_analysis", "aircraft": {...extended JSON...}}
    {"type": "ping"}

  Server → Client:
    {"type": "status",   "message": "..."}
    {"type": "progress", "backend": "vlm", "status": "running", "percent": 45, "message": "..."}
    {"type": "results",  "model": {...schema v2.1 model...}}
    {"type": "error",    "message": "...", "backend": "vlm"}
"""

using HTTP
using HTTP.WebSockets
using MsgPack
using Sockets

# ─── Workspace root (set by start_server) ────────────────────────
const _workspace_dir = Ref{String}("")

function _request_path(target::String)
    raw_target = strip(target)
    isempty(raw_target) && return "/"

    if startswith(raw_target, "http://") || startswith(raw_target, "https://")
        uri = HTTP.URI(raw_target)
        raw_target = isempty(uri.path) ? "/" : uri.path
        if !isempty(uri.query)
            raw_target *= "?" * uri.query
        end
    end

    decoded = HTTP.URIs.unescapeuri(split(raw_target, '?'; limit=2)[1])
    return isempty(decoded) ? "/" : decoded
end

function _normalized_path_parts(path::String)
    normalized = normpath(abspath(path))
    if Sys.iswindows()
        normalized = lowercase(normalized)
    end
    return splitpath(normalized)
end

function _path_is_within_root(path::String, root::String)
    # Compare path components so trailing separators on Windows do not break the guard.
    path_parts = _normalized_path_parts(path)
    root_parts = _normalized_path_parts(root)
    length(path_parts) >= length(root_parts) || return false
    return path_parts[1:length(root_parts)] == root_parts
end

function _static_content_type(path::String)
    lower = lowercase(path)
    if endswith(lower, ".html")
        return "text/html; charset=utf-8"
    elseif endswith(lower, ".js")
        return "application/javascript; charset=utf-8"
    elseif endswith(lower, ".css")
        return "text/css; charset=utf-8"
    elseif endswith(lower, ".json")
        return "application/json; charset=utf-8"
    elseif endswith(lower, ".svg")
        return "image/svg+xml"
    elseif endswith(lower, ".png")
        return "image/png"
    elseif endswith(lower, ".jpg") || endswith(lower, ".jpeg")
        return "image/jpeg"
    elseif endswith(lower, ".gif")
        return "image/gif"
    elseif endswith(lower, ".ico")
        return "image/x-icon"
    elseif endswith(lower, ".glb")
        return "model/gltf-binary"
    elseif endswith(lower, ".yaml") || endswith(lower, ".yml")
        return "text/yaml; charset=utf-8"
    else
        return "application/octet-stream"
    end
end

function _resolve_static_path(target::String)
    root = _workspace_dir[]
    isempty(root) && return nothing

    decoded = _request_path(target)
    relpath = strip(decoded)

    if isempty(relpath) || relpath == "/"
        relpath = "create_aircraft_model.html"
    else
        relpath = lstrip(relpath, ['/', '\\'])
    end

    fullpath = abspath(joinpath(root, relpath))
    if !_path_is_within_root(fullpath, root)
        return nothing
    end

    return fullpath
end

function serve_static_request(http)
    filepath = _resolve_static_path(http.message.target)
    if filepath === nothing
        HTTP.setstatus(http, 403)
        HTTP.setheader(http, "Content-Type" => "text/plain; charset=utf-8")
        HTTP.startwrite(http)
        HTTP.write(http, "Forbidden\n")
        return
    end

    if !isfile(filepath)
        if _request_path(http.message.target) == "/favicon.ico"
            HTTP.setstatus(http, 204)
            HTTP.startwrite(http)
            return
        end

        HTTP.setstatus(http, 404)
        HTTP.setheader(http, "Content-Type" => "text/plain; charset=utf-8")
        HTTP.startwrite(http)
        HTTP.write(http, "Not found\n")
        return
    end

    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => _static_content_type(filepath))
    HTTP.startwrite(http)
    open(filepath, "r") do io
        write(http, read(io))
    end
end

# ─── MsgPack encode/decode helpers ─────────────────────────────────

"""Encode a Dict to MsgPack binary."""
function msgpack_encode(data)
    io = IOBuffer()
    MsgPack.pack(io, data)
    return take!(io)
end

"""Decode MsgPack binary to a Dict."""
function msgpack_decode(msg)
    return MsgPack.unpack(IOBuffer(msg))
end

# ─── Send helper ───────────────────────────────────────────────────

"""
    send_msg(ws, data::Dict)

MsgPack-encode `data` and send it over the WebSocket.
Silently catches send errors (client may have disconnected).
"""
function send_msg(ws, data::Dict)
    try
        encoded = msgpack_encode(data)
        send(ws, encoded)
    catch e
        @warn "Failed to send WebSocket message" exception = e
    end
end

# ─── Message handlers ──────────────────────────────────────────────

"""
    handle_run_analysis(ws, data::Dict)

Run the full analysis pipeline and stream progress/results to the client.
"""
function handle_run_analysis(ws, data::Dict)
    aircraft_json = get(data, "aircraft", nothing)

    if isnothing(aircraft_json) || !isa(aircraft_json, Dict)
        send_msg(ws, Dict(
            "type"    => "error",
            "message" => "Missing or invalid 'aircraft' field in run_analysis request."
        ))
        return
    end

    send_msg(ws, Dict(
        "type"    => "status",
        "message" => "Analysis request received. Starting pipeline..."
    ))

    # Build a progress callback that forwards to the WebSocket via MsgPack
    function progress_callback(backend, status, percent, message)
        send_msg(ws, Dict(
            "type"    => "progress",
            "backend" => string(backend),
            "status"  => string(status),
            "percent" => percent,
            "message" => string(message)
        ))
    end

    try
        model = run_analysis(aircraft_json; progress_callback = progress_callback)

        send_msg(ws, Dict(
            "type"  => "results",
            "model" => model
        ))
    catch e
        bt = sprint(showerror, e, catch_backtrace())
        @error "Analysis failed" exception = bt
        send_msg(ws, Dict(
            "type"    => "error",
            "message" => "Analysis failed: $(sprint(showerror, e))",
            "details" => bt
        ))
    end
end

# ─── File-system handlers ─────────────────────────────────────────

"""
    handle_list_directory(ws, data::Dict)

Return the contents of a directory so the browser can render a folder picker.
If `data["path"]` is empty, uses the workspace root set by `start_server`.
"""
function handle_list_directory(ws, data::Dict)
    path = get(data, "path", "")
    if isempty(path)
        path = _workspace_dir[]
    end
    path = abspath(path)

    if !isdir(path)
        send_msg(ws, Dict(
            "type"  => "directory_listing",
            "error" => "Not a directory: $path"
        ))
        return
    end

    entries = Dict{String,Any}[]
    try
        for name in readdir(path)
            full = joinpath(path, name)
            push!(entries, Dict(
                "name"   => name,
                "path"   => replace(full, '\\' => '/'),
                "is_dir" => isdir(full)
            ))
        end
    catch e
        send_msg(ws, Dict(
            "type"  => "directory_listing",
            "error" => "Cannot read directory: $(sprint(showerror, e))"
        ))
        return
    end

    # Directories first, then files; alphabetical within each group
    sort!(entries, by = e -> (!e["is_dir"], lowercase(e["name"])))

    parent_path = dirname(path)
    send_msg(ws, Dict(
        "type"    => "directory_listing",
        "path"    => replace(path, '\\' => '/'),
        "parent"  => replace(parent_path, '\\' => '/'),
        "entries" => entries
    ))
end

"""
    handle_save_file(ws, data::Dict)

Write `data["content"]` to the file `data["path"] / data["filename"]`.
"""
function handle_save_file(ws, data::Dict)
    dir      = abspath(get(data, "path", ""))
    filename = get(data, "filename", "output.txt")
    content  = get(data, "content", "")

    if isempty(dir) || !isdir(dir)
        send_msg(ws, Dict(
            "type"    => "file_saved",
            "success" => false,
            "error"   => "Invalid directory: $dir"
        ))
        return
    end

    filepath = joinpath(dir, filename)
    try
        write(filepath, isa(content, Vector{UInt8}) ? content : string(content))
        @info "Saved: $filepath"
        send_msg(ws, Dict(
            "type"    => "file_saved",
            "success" => true,
            "path"    => replace(filepath, '\\' => '/')
        ))
    catch e
        send_msg(ws, Dict(
            "type"    => "file_saved",
            "success" => false,
            "error"   => "Write error: $(sprint(showerror, e))"
        ))
    end
end

# ─── WebSocket connection handler ──────────────────────────────────

"""
    handle_websocket(ws)

Handle an individual WebSocket client connection.
Decodes incoming MsgPack messages and dispatches to the appropriate handler.
"""
function handle_websocket(ws)
    client_id = string(hash(ws), base=16)[1:8]
    @info "Client connected: $client_id"

    send_msg(ws, Dict(
        "type"    => "status",
        "message" => "Connected to AeroModel server v1.0"
    ))

    try
        for raw_msg in ws
            @info "[$client_id] Received $(length(raw_msg)) bytes"

            local data
            try
                data = msgpack_decode(raw_msg)
            catch parse_err
                send_msg(ws, Dict(
                    "type"    => "error",
                    "message" => "Invalid MsgPack message: $(sprint(showerror, parse_err))"
                ))
                continue
            end

            if !isa(data, Dict)
                send_msg(ws, Dict(
                    "type"    => "error",
                    "message" => "Expected a MsgPack object, got $(typeof(data))"
                ))
                continue
            end

            @info "[$client_id] Message type: $(get(data, "type", "unknown"))"

            # Dispatch by message type
            msg_type = get(data, "type", "")
            if msg_type == "run_analysis"
                handle_run_analysis(ws, data)
            elseif msg_type == "list_directory"
                handle_list_directory(ws, data)
            elseif msg_type == "save_file"
                handle_save_file(ws, data)
            elseif msg_type == "ping"
                send_msg(ws, Dict("type" => "status", "message" => "pong"))
            else
                send_msg(ws, Dict(
                    "type"    => "error",
                    "message" => "Unknown message type: $msg_type"
                ))
            end
        end
    catch e
        if isa(e, HTTP.WebSockets.WebSocketError) ||
           isa(e, EOFError) ||
           isa(e, Base.IOError)
            @info "Client disconnected: $client_id"
        else
            @error "Error handling client" exception = sprint(showerror, e, catch_backtrace())
        end
    end

    @info "Client session ended: $client_id"
end

# ─── HTTP request handler (upgrade to WebSocket) ──────────────────

"""
    handle_http_request(http)

Handle HTTP requests — upgrade to WebSocket if appropriate.
"""
function handle_http_request(http)
    if HTTP.WebSockets.is_upgrade(http.message)
        try
            HTTP.WebSockets.upgrade(http) do ws
                handle_websocket(ws)
            end
        catch e
            @error "WebSocket upgrade error" exception = sprint(showerror, e, catch_backtrace())
        end
    else
        try
            serve_static_request(http)
        catch e
            @error "Error sending HTTP response" exception = e
        end
    end
end

# ─── Check port availability ──────────────────────────────────────

function is_port_available(port::Int, host::String)
    try
        server = listen(IPv4(host), port)
        close(server)
        return true
    catch
        return false
    end
end

# ─── Server entry points ──────────────────────────────────────────

"""
    start_server(; host="127.0.0.1", port=8765)

Start the WebSocket server. Blocks until interrupted (Ctrl-C).

# Example
```julia
include("AeroModel.jl")
using .AeroModel
AeroModel.start_server()          # default: ws://127.0.0.1:8765
AeroModel.start_server(port=9000) # custom port
```
"""
function start_server(; host::String = "127.0.0.1", port::Int = 8765)
    # Set workspace root to the project directory (grandparent of src/AeroModel/)
    _workspace_dir[] = normpath(joinpath(@__DIR__, "..", ".."))

    println("=" ^ 60)
    println("AeroModel WebSocket Server")
    println("=" ^ 60)
    println("Protocol: MessagePack (binary)")
    println("Listening on: $host:$port")
    println("=" ^ 60)

    if !is_port_available(port, host)
        error("""
        Port $port is already in use!
        Please either:
          1. Stop the process using port $port
          2. Change the port: start_server(port=9000)
        To find process: netstat -ano | findstr :$port
        """)
    end

    @info "Press Ctrl-C to stop."

    server_handle = nothing

    try
        server_handle = HTTP.listen(host, port;
                                    readtimeout = 0,
                                    connection_limit = 100) do http
            handle_http_request(http)
        end
    catch e
        if isa(e, InterruptException)
            println("\n\nServer stopped by user.")
        elseif isa(e, Base.IOError) && occursin("EADDRINUSE", string(e))
            println("\n\nERROR: Address already in use! Port $port is taken.")
        else
            println("\n\nServer error: ", e)
            showerror(stdout, e, catch_backtrace())
            rethrow(e)
        end
    finally
        if server_handle !== nothing
            try
                close(server_handle)
                println("\nServer closed cleanly.")
            catch e
                println("\nError closing server: ", e)
            end
        end
    end

    return server_handle
end

"""
    start_server_async(; host="127.0.0.1", port=8765) -> Task

Start the WebSocket server in a background task.
Returns the Task object for monitoring.
"""
function start_server_async(; host::String = "127.0.0.1", port::Int = 8765)
    task = @async start_server(; host = host, port = port)
    @info "Server task started. Use `schedule(task, InterruptException(); error=true)` to stop."
    return task
end
