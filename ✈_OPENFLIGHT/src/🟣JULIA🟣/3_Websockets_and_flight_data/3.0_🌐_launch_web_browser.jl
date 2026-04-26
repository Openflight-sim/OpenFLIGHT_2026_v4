# Function to attempt launching a browser with error handling.
function try_launch_browser(command)
    try
        run(Cmd(command; detach=true))
        println("Launched browser successfully.")
        return true
    catch e
        println("Failed to launch browser: ", e)
        return false
    end
end

function try_launch_url_batch(commands, description::String)
    launched_any = false
    for command in commands
        launched_any |= try_launch_browser(command)
    end

    if launched_any
        println("Opened browser using $description.")
        return true
    end

    return false
end

function default_browser_commands(urls::Vector{String})
    if Sys.iswindows()
        return [`cmd /c start "" "$url"` for url in urls]
    elseif Sys.isapple()
        return [`open "$url"` for url in urls]
    else
        return [`xdg-open "$url"` for url in urls]
    end
end

function named_browser_batches(urls::Vector{String})
    batches = Pair{String,Vector{Cmd}}[]

    if Sys.iswindows()
        push!(batches, "Microsoft Edge" => [`cmd /c start msedge "$url"` for url in urls])
        push!(batches, "Google Chrome" => [`cmd /c start chrome "$url"` for url in urls])
        push!(batches, "Mozilla Firefox" => [`cmd /c start firefox "$url"` for url in urls])
    elseif Sys.isapple()
        push!(batches, "Safari" => [`open -a "Safari" "$url"` for url in urls])
        push!(batches, "Google Chrome" => [`open -a "Google Chrome" "$url"` for url in urls])
        push!(batches, "Mozilla Firefox" => [`open -a "Firefox" "$url"` for url in urls])
        push!(batches, "Microsoft Edge" => [`open -a "Microsoft Edge" "$url"` for url in urls])
    else
        push!(batches, "Google Chrome" => [`google-chrome "$url"` for url in urls])
        push!(batches, "Chromium" => [`chromium "$url"` for url in urls])
        push!(batches, "Chromium Browser" => [`chromium-browser "$url"` for url in urls])
        push!(batches, "Mozilla Firefox" => [`firefox "$url"` for url in urls])
        push!(batches, "Microsoft Edge" => [`microsoft-edge "$url"` for url in urls])
        push!(batches, "Microsoft Edge Stable" => [`microsoft-edge-stable "$url"` for url in urls])
    end

    return batches
end

function find_javascript_root(script_dir::String)
    src_dir = joinpath(script_dir, "src")
    if !isdir(src_dir)
        error("Could not find src directory at: $src_dir")
    end

    src_entries = readdir(src_dir)
    js_idx = findfirst(name -> occursin("JAVASCRIPT", name), src_entries)
    if js_idx === nothing
        error("Could not find JAVASCRIPT directory inside: $src_dir")
    end

    return joinpath(src_dir, src_entries[js_idx])
end

function find_main_frontend_html(javascript_root::String)
    entries = readdir(javascript_root)
    html_idx = findfirst(name -> occursin("front_end_and_client.html", name), entries)
    if html_idx === nothing
        error("Could not find main frontend html inside: $javascript_root")
    end
    return joinpath(javascript_root, entries[html_idx])
end

# Main function to launch the client HTML files in a web browser.
# Uses http://localhost URLs so the browser has a secure context
# (required for Gamepad API, Web Audio, etc.).
function launch_client(script_dir)
    port = WebSockets_port
    sim_url       = "http://localhost:$port/"
    telemetry_url = "http://localhost:$port/telemetry_dashboard.html"
    aero_url      = "http://localhost:$port/aero_model_viewer.html"

    open_telemetry = get(MISSION_DATA, "telemetry_screen", true)
    # Open the simulator last so it is more likely to become the foreground tab.
    urls = open_telemetry ? [telemetry_url, aero_url, sim_url] : [sim_url]

    if open_telemetry
        println("Opening Simulation, Telemetry and Aero Model Inspector tabs at $sim_url ...")
    else
        println("Opening only Simulation tab at $sim_url ...")
    end

    if try_launch_url_batch(default_browser_commands(urls), "the system default browser")
        return
    end

    for (description, commands) in named_browser_batches(urls)
        if try_launch_url_batch(commands, description)
            return
        end
    end

    println("Failed to launch any browser.")
end
