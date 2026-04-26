###########################################################
# RunModelCreator.jl
#
# One-click entry point for the Aircraft Model Creator.
# It starts the Julia backend, serves the frontend over HTTP,
# injects the chosen port into the browser-side setup file,
# and opens the app at http://localhost:<port>/.
###########################################################

project_dir = joinpath(dirname(@__FILE__), "🛫_CREATE_AIRCRAFT_MODEL")

using Pkg
using Sockets
using SHA, Dates

println("="^60)
println("  Aircraft Model Creator - Startup")
println("="^60)
println()

# ---------------------------------------------------------------
# Stamp-gated package bootstrap.
#
# Pkg.instantiate() and the missing-package check cost ~1–3 s on every start
# even when they are no-ops.  We stamp a file under
# <DEPOT>/openflight/package_bootstrap/ keyed by a SHA1 of
# Project.toml + Manifest.toml, so subsequent starts with an unchanged
# environment skip the Pkg calls entirely.  Editing Project.toml or
# Manifest.toml invalidates the stamp automatically (hash changes).
#
# Mirrors the pattern in
#   ✈_OPENFLIGHT/src/🟣JULIA🟣/1_Maths_and_Auxiliary_Functions/
#     1.0_📚_Check_packages_and_websockets_port/🎁_load_required_packages.jl
# The two projects share the bootstrap directory; the "modelcreator_" filename
# prefix keeps their stamps distinct and self-documenting.
# ---------------------------------------------------------------

function environment_signature(env_root::String)
    parts = String[]
    for filename in ("Project.toml", "Manifest.toml")
        path = joinpath(env_root, filename)
        if isfile(path)
            push!(parts, abspath(path))
            push!(parts, read(path, String))
        end
    end
    isempty(parts) && return "modelcreator_no_manifest"
    return bytes2hex(sha1(join(parts, "\n---\n")))
end

function instantiate_env_if_needed(env_root::String)
    Pkg.activate(env_root)

    depot_root = first(Base.DEPOT_PATH)
    state_dir  = joinpath(depot_root, "openflight", "package_bootstrap")
    stamp_path = joinpath(state_dir,
                          "modelcreator_$(environment_signature(env_root)).stamp")

    if isfile(stamp_path)
        println("Julia environment already instantiated — skipping Pkg.instantiate().")
        return false
    end

    println("Instantiating Julia environment (runs again only if Project/Manifest changes)...")

    required_pkgs = ["StaticArrays", "HTTP", "Sockets", "JSON", "MsgPack", "Printf"]
    installed = keys(Pkg.project().dependencies)
    missing_pkgs = filter(pkg -> !(pkg in installed), required_pkgs)
    if !isempty(missing_pkgs)
        println("Installing missing packages: ", join(missing_pkgs, ", "))
        Pkg.add(missing_pkgs)
    end

    Pkg.instantiate()

    mkpath(state_dir)
    open(stamp_path, "w") do io
        write(io, "instantiated_at=$(Dates.now())\n")
        write(io, "environment_root=$(env_root)\n")
    end
    return true
end

instantiate_env_if_needed(project_dir)

using HTTP, JSON, MsgPack, Printf

println("All packages ready.")
println()

function _port_is_free(port::Int)
    server = try
        listen(port)
    catch
        return false
    end
    close(server)
    return true
end

function find_free_port(start_port::Int=8765, max_attempts::Int=200)
    allow_fallback = lowercase(get(ENV, "OPENFLIGHT_ALLOW_PORT_FALLBACK", "false")) in ("1", "true", "yes")

    if _port_is_free(start_port)
        return start_port
    end

    if !allow_fallback
        error("Port $start_port is already in use. Close the existing Model Creator server, or set OPENFLIGHT_ALLOW_PORT_FALLBACK=true to use another port. Keeping a stable port preserves the browser-stored Gemini API key.")
    end

    for port in (start_port + 1):(start_port + max_attempts)
        server = try
            listen(port)
        catch
            continue
        end
        close(server)
        return port
    end
    error("No free port found after $max_attempts attempts starting from $start_port")
end

aeromodel_port = find_free_port()
println("HTTP/WebSocket server will use port: $aeromodel_port")
println()

function update_port_in_js(project_dir::String, port::Int)
    js_path = joinpath(project_dir, "src", "js", "analysis-setup.js")
    if !isfile(js_path)
        @warn "Could not find analysis-setup.js at: $js_path - skipping port injection"
        return false
    end

    content = read(js_path, String)
    lines = split(content, '\n', keepempty=true)
    replaced = false

    for i in eachindex(lines)
        if occursin(r"^\s*var\s+aeromodel_port\s*=", lines[i])
            lines[i] = "var aeromodel_port = $(port);  // Auto-set by RunModelCreator.jl"
            replaced = true
            break
        end
    end

    if !replaced
        @warn "Could not find 'var aeromodel_port = ...' in analysis-setup.js - port not injected"
        return false
    end

    write(js_path, join(lines, '\n'))
    println("Injected port $port into analysis-setup.js")
    return true
end

update_port_in_js(project_dir, aeromodel_port)

println("Loading AeroModel module...")
include(joinpath(project_dir, "src", "AeroModel", "AeroModel.jl"))
using .AeroModel
println("AeroModel module loaded.")
println()

function try_launch_browser(command)
    try
        run(Cmd(command; detach=true))
        return true
    catch
        return false
    end
end

function try_launch_url_batch(commands)
    for command in commands
        if try_launch_browser(command)
            return true
        end
    end
    return false
end

function launch_browser(url::String)
    println("Launching browser at $url ...")

    if Sys.iswindows()
        if try_launch_url_batch([
            `cmd /c start "" "$url"`,
            `cmd /c start msedge "$url"`,
            `cmd /c start chrome "$url"`,
            `cmd /c start firefox "$url"`,
        ])
            return
        end
    elseif Sys.isapple()
        if try_launch_url_batch([
            `open "$url"`,
            `open -a "Safari" "$url"`,
            `open -a "Google Chrome" "$url"`,
            `open -a "Firefox" "$url"`,
        ])
            return
        end
    else
        if try_launch_url_batch([
            `xdg-open "$url"`,
            `google-chrome "$url"`,
            `chromium "$url"`,
            `chromium-browser "$url"`,
            `firefox "$url"`,
        ])
            return
        end
    end

    println("Could not auto-launch browser. Please open manually:")
    println("  $url")
end

println("Starting AeroModel HTTP + WebSocket server on port $aeromodel_port...")
println("Press Ctrl-C to stop.")
println()

server_task = AeroModel.start_server_async(port=aeromodel_port)
sleep(0.4)

if istaskdone(server_task) && istaskfailed(server_task)
    wait(server_task)
end

launch_browser("http://localhost:$aeromodel_port/")
println()

wait(server_task)
