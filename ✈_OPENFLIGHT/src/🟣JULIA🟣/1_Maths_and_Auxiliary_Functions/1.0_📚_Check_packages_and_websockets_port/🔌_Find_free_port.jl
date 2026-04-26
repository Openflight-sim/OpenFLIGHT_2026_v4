using Sockets

# Get the directory path of the current script
current_path = @__DIR__

# Construct path to the JavaScript initialization file that needs modification
filepath = joinpath(
    current_path,
    "..",
    "..",
    "..",
    "🟡JAVASCRIPT🟡",
    "0_INITIALIZATION",
    "0.1_🧾_initializations.js"
)

function find_free_port(start_port::Int=8000, max_attempts::Int=1000)
    for port in start_port:(start_port + max_attempts)
        server = try
            listen(port)
        catch
            continue
        end
        close(server)
        return port
    end
    error("No free port found after $(max_attempts) attempts")
end

function update_freeport_in_content(content::String, freeport::Int)
    lines = split(content, '\n', keepempty=true)
    replaced = false
    for i in eachindex(lines)
        if occursin(r"^\s*let\s+freeport\s*=", lines[i])
            lines[i] = "let freeport = $(freeport)  // Default aircraft configuration file name"
            replaced = true
            break
        end
    end
    if !replaced
        error("Could not find `let freeport = ...` in $filepath")
    end
    return join(lines, '\n')
end

function update_port_in_file(filepath::String)
    freeport = find_free_port()
    content = read(filepath, String)
    new_content = update_freeport_in_content(content, freeport)
    write(filepath, new_content)
    println("WebSockets connection will use port: $freeport")
    return freeport
end

# Execute the port update and store the selected port number
WebSockets_port = update_port_in_file(filepath)
