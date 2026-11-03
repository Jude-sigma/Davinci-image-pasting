-- Opens the settings window for Paste Clipboard Media.
-- All of the logic lives in "Paste Clipboard Media.lua" in the same folder.

local function script_dir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        local dir = source:sub(2):match("^(.*[\\/])")
        if dir then
            return dir
        end
    end
    return (os.getenv("APPDATA") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Utility\\Paste Clipboard Media\\"
end

local chunk, err = loadfile(script_dir() .. "Paste Clipboard Media.lua")
if not chunk then
    print("[Paste Clipboard Media] Could not load the main script: " .. tostring(err))
    return
end
chunk("library").open_settings()
