--[[
Paste Clipboard Media for DaVinci Resolve

Takes the image, GIF or media file on the clipboard, saves it to disk, imports it into a Media Pool
bin and places it on the timeline at the playhead, on the highest video track that is free there.
A new video track is added on top when the highest track is occupied at that spot.

Run it from Workspace > Scripts, or bind it to a key in Keyboard Customization.
"Paste Clipboard Media Settings.lua" next to this file opens the settings window.
]]

local M = {}

M.NAME = "Paste Clipboard Media"
M.DEFAULT_SAVE_FOLDER = "%USERPROFILE%\\Videos\\Resolve Pasted Media\\{project}"
M.HELPER_TIMEOUT_MS = 60000

-- The kinds of media that each get their own bin and size setting.
M.KINDS = {
    { key = "image", label = "Images", defaultBin = "Pasted Media/Images" },
    { key = "gif", label = "GIFs", defaultBin = "Pasted Media/GIFs" },
    { key = "video", label = "Videos", defaultBin = "Pasted Media/Videos" },
}

local STILL_EXTENSIONS = {
    png = true, jpg = true, jpeg = true, bmp = true, tif = true, tiff = true, tga = true, exr = true,
    dpx = true, psd = true, heic = true, heif = true, webp = true, jp2 = true, j2k = true,
}

-------------------------------------------------------------------------------
-- Paths and settings
-------------------------------------------------------------------------------

function M.script_dir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        local dir = source:sub(2):match("^(.*[\\/])")
        if dir then
            return dir
        end
    end
    local candidates = {
        (os.getenv("APPDATA") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Utility\\Paste Clipboard Media\\",
        (os.getenv("PROGRAMDATA") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Fusion\\Scripts\\Utility\\Paste Clipboard Media\\",
    }
    for _, dir in ipairs(candidates) do
        local f = io.open(dir .. "clipboard.ps1", "r")
        if f then
            f:close()
            return dir
        end
    end
    return candidates[1]
end

function M.settings_path()
    return M.script_dir() .. "settings.txt"
end

local SETTING_KEYS = { "imageBin", "gifBin", "videoBin", "imageScale", "gifScale", "videoScale", "saveFolder" }

function M.default_settings()
    local settings = { saveFolder = M.DEFAULT_SAVE_FOLDER }
    for _, kind in ipairs(M.KINDS) do
        settings[kind.key .. "Bin"] = kind.defaultBin
        settings[kind.key .. "Scale"] = 100
    end
    return settings
end

function M.load_settings()
    local settings = M.default_settings()
    local f = io.open(M.settings_path(), "r")
    if not f then
        return settings
    end
    local raw = {}
    for line in f:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s?(.-)%s*$")
        if key then
            raw[key] = value
        end
    end
    f:close()

    -- Older versions had a single "bin" plus "subfolder" for everything.
    if raw.imageBin == nil and (raw.bin ~= nil or raw.subfolder ~= nil) then
        local parts = {}
        for _, part in ipairs({ raw.bin or "", raw.subfolder or "" }) do
            if part ~= "" then
                parts[#parts + 1] = part
            end
        end
        local combined = table.concat(parts, "/")
        for _, kind in ipairs(M.KINDS) do
            raw[kind.key .. "Bin"] = combined
        end
    end

    for key, default in pairs(settings) do
        if raw[key] ~= nil then
            settings[key] = type(default) == "number" and (tonumber(raw[key]) or default) or raw[key]
        end
    end
    return settings
end

function M.save_settings(settings)
    local f, err = io.open(M.settings_path(), "w")
    if not f then
        return false, err
    end
    for _, key in ipairs(SETTING_KEYS) do
        f:write(key, "=", tostring(settings[key]), "\n")
    end
    f:close()
    return true
end

-- Expands %VARIABLES% and {project} in the save folder setting.
function M.expand_save_folder(pattern, projectName)
    local safeName = (projectName or "Untitled"):gsub('[<>:"/\\|%?%*]', "_")
    local path = (pattern ~= "" and pattern or M.DEFAULT_SAVE_FOLDER)
    path = path:gsub("%%([%w_]+)%%", function(name)
        return os.getenv(name) or ("%" .. name .. "%")
    end)
    path = path:gsub("{project}", function()
        return safeName
    end)
    return (path:gsub("/", "\\"):gsub("\\+$", ""))
end

local function file_extension(path)
    return (path:match("%.([%w]+)$") or ""):lower()
end

-- Which of M.KINDS a file belongs to, judged by its extension.
function M.kind_of(path)
    local ext = file_extension(path)
    if ext == "gif" then
        return "gif"
    elseif STILL_EXTENSIONS[ext] then
        return "image"
    end
    return "video"
end

-------------------------------------------------------------------------------
-- Resolve helpers
-------------------------------------------------------------------------------

function M.app()
    local r = resolve or (Resolve and Resolve())
    local f = fusion or fu or (r and r:Fusion())
    return r, f
end

-- Resolve's Lua lists carry an extra "__flags" key, so copy out only the numbered entries.
local function list_of(t)
    local out = {}
    if type(t) ~= "table" then
        return out
    end
    local i = 1
    while t[i] ~= nil do
        out[i] = t[i]
        i = i + 1
    end
    return out
end
M.list_of = list_of

local function split_path(path)
    local parts = {}
    for part in (path or ""):gmatch("[^/\\]+") do
        local trimmed = part:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            parts[#parts + 1] = trimmed
        end
    end
    return parts
end

-- Normalises a bin path typed by the user: "Master/A/B", "A\B " and "/A/B/" all become "A/B".
function M.normalize_bin_path(text, rootName)
    local parts = split_path(text)
    if parts[1] and rootName and parts[1] == rootName then
        table.remove(parts, 1)
    end
    return table.concat(parts, "/")
end

local function find_subfolder(folder, name)
    for _, sub in ipairs(list_of(folder:GetSubFolderList())) do
        if sub:GetName() == name then
            return sub
        end
    end
    return nil
end

-- Returns every bin as { path = "A/B", folder = Folder }, with "" for the root bin.
function M.list_bins(mediaPool)
    local bins = {}
    local function walk(folder, path)
        bins[#bins + 1] = { path = path, folder = folder }
        for _, sub in ipairs(list_of(folder:GetSubFolderList())) do
            walk(sub, path == "" and sub:GetName() or (path .. "/" .. sub:GetName()))
        end
    end
    walk(mediaPool:GetRootFolder(), "")
    return bins
end

function M.folder_path(mediaPool, folder)
    if not folder then
        return nil
    end
    local id = folder:GetUniqueId()
    for _, bin in ipairs(M.list_bins(mediaPool)) do
        if bin.folder:GetUniqueId() == id then
            return bin.path
        end
    end
    return nil
end

function M.get_or_create_bin(mediaPool, binPath)
    local folder = mediaPool:GetRootFolder()
    for _, name in ipairs(split_path(M.normalize_bin_path(binPath, folder:GetName()))) do
        local sub = find_subfolder(folder, name)
        if not sub then
            sub = mediaPool:AddSubFolder(folder, name)
            if not sub then
                return nil, "Could not create the Media Pool bin \"" .. name .. "\"."
            end
        end
        folder = sub
    end
    return folder
end

local function get_setting(timeline, project, key)
    for _, obj in ipairs({ timeline, project }) do
        local ok, value = pcall(function()
            return obj:GetSetting(key)
        end)
        if ok and value ~= nil and value ~= "" then
            return value
        end
    end
    return nil
end

function M.timecode_to_frames(tc, fps, dropFrame)
    local h, m, s, f = tc:match("(%d+)[:;.,](%d+)[:;.,](%d+)[:;.,](%d+)")
    if not h then
        return nil
    end
    h, m, s, f = tonumber(h), tonumber(m), tonumber(s), tonumber(f)
    local base = math.floor(fps + 0.5)
    local frames = ((h * 60 + m) * 60 + s) * base + f
    if dropFrame then
        local dropped = math.floor(base / 30 + 0.5) * 2
        local minutes = h * 60 + m
        frames = frames - dropped * (minutes - math.floor(minutes / 10))
    end
    return frames
end

local function item_overlaps(item, startFrame, endFrame)
    return item:GetStart() < endFrame and item:GetEnd() > startFrame
end

local function track_is_free(timeline, index, startFrame, endFrame, ignoreItem)
    local ignoreId = ignoreItem and ignoreItem:GetUniqueId()
    for _, item in ipairs(list_of(timeline:GetItemListInTrack("video", index))) do
        if item:GetUniqueId() ~= ignoreId and item_overlaps(item, startFrame, endFrame) then
            return false
        end
    end
    return true
end

local function track_is_locked(timeline, index)
    local ok, locked = pcall(function()
        return timeline:GetIsTrackLocked("video", index)
    end)
    return ok and locked == true
end

local function add_top_track(timeline)
    local ok, added = pcall(function()
        return timeline:AddTrack("video")
    end)
    if not ok or not added then
        return nil, "Could not add a new video track. This script needs DaVinci Resolve 18.5 or newer."
    end
    return timeline:GetTrackCount("video")
end

-- The highest video track if it is free and unlocked over the range, otherwise a new track on top.
function M.choose_track(timeline, startFrame, endFrame)
    local top = timeline:GetTrackCount("video")
    if top >= 1 and not track_is_locked(timeline, top) and track_is_free(timeline, top, startFrame, endFrame) then
        return top
    end
    return add_top_track(timeline)
end

-- Length in timeline frames that Resolve gives a still, from Preferences > User > Editing >
-- Standard still duration. Falls back to Resolve's default of 5 seconds.
function M.still_length(timelineFps)
    local seconds, frames, inFrames = 5, nil, false
    local f = io.open((os.getenv("APPDATA") or "") .. "\\Blackmagic Design\\DaVinci Resolve\\Preferences\\config.user.xml", "r")
    if f then
        local xml = f:read("*a")
        f:close()
        seconds = tonumber(xml:match("<StillDurationSecs>%s*([%d%.]+)%s*</StillDurationSecs>")) or seconds
        frames = tonumber(xml:match("<StillDurationFrames>%s*(%d+)%s*</StillDurationFrames>"))
        inFrames = (xml:match("<StillDurationType>%s*([%w_]+)%s*</StillDurationType>") or ""):find("FRAME") ~= nil
    end
    if inFrames and frames and frames > 0 then
        return frames
    end
    return math.max(1, math.floor(seconds * timelineFps + 0.5))
end

-- Builds the AppendToTimeline info for a clip and estimates its length in timeline frames.
function M.clip_info(clip, path, timelineFps)
    local props = clip:GetClipProperty() or {}
    local clipType = tostring(props["Type"] or "")
    local frames = tonumber(props["Frames"])
    local clipFps = tonumber(props["FPS"]) or timelineFps
    local isStill = clipType:lower():find("still") ~= nil or STILL_EXTENSIONS[file_extension(path)] or (frames or 0) <= 1

    local length
    if not isStill and frames and frames > 1 then
        length = math.ceil(frames * timelineFps / clipFps)
    else
        length = M.still_length(timelineFps)
    end
    return { mediaPoolItem = clip, mediaType = 1 }, length
end

-- Sets the Zoom of a timeline item, e.g. 0.5 for half size.
local function set_zoom(item, zoom)
    local ok, done = pcall(function()
        return item:SetProperties({ ZoomX = zoom, ZoomY = zoom })
    end)
    if ok and done then
        return true
    end
    -- Resolve versions before 21.1 only have SetProperty.
    ok = pcall(function()
        item:SetProperty("ZoomX", zoom)
        item:SetProperty("ZoomY", zoom)
    end)
    return ok
end

-------------------------------------------------------------------------------
-- Windows API access through LuaJIT's FFI
-------------------------------------------------------------------------------

local ffi_ok, ffi = pcall(require, "ffi")
local bit_ok, bit = pcall(require, "bit")
local kernel32, user32, shell32, gdiplus

local function load_win32()
    if kernel32 ~= nil then
        return kernel32 ~= false
    end
    kernel32 = false
    if not ffi_ok or not bit_ok or ffi.os ~= "Windows" then
        return false
    end
    pcall(ffi.cdef, [[
        typedef struct {
            uint32_t cb; void *lpReserved; void *lpDesktop; void *lpTitle;
            uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            uint16_t wShowWindow, cbReserved2; void *lpReserved2;
            void *hStdInput, *hStdOutput, *hStdError;
        } PCM_STARTUPINFOW;
        typedef struct { void *hProcess, *hThread; uint32_t dwProcessId, dwThreadId; } PCM_PROCESS_INFORMATION;
        typedef struct { uint32_t GdiplusVersion; void *DebugEventCallback; int SuppressBackgroundThread, SuppressExternalCodecs; } PCM_GDIPLUS_STARTUP;
        typedef struct { uint32_t Data1; uint16_t Data2, Data3; uint8_t Data4[8]; } PCM_GUID;

        int CreateProcessW(const uint16_t *app, uint16_t *cmd, void *pa, void *ta, int inherit, uint32_t flags,
                           void *env, const uint16_t *cwd, PCM_STARTUPINFOW *si, PCM_PROCESS_INFORMATION *pi);
        uint32_t WaitForSingleObject(void *handle, uint32_t ms);
        int TerminateProcess(void *process, uint32_t code);
        int CloseHandle(void *handle);
        int MultiByteToWideChar(uint32_t page, uint32_t flags, const char *str, int len, uint16_t *out, int outLen);
        int WideCharToMultiByte(uint32_t page, uint32_t flags, const uint16_t *str, int len, char *out, int outLen,
                                const char *defaultChar, int *usedDefault);
        void *GlobalLock(void *mem);
        int GlobalUnlock(void *mem);
        size_t GlobalSize(void *mem);
        void Sleep(uint32_t ms);
        uint64_t GetTickCount64(void);
        uint32_t GetFileAttributesW(const uint16_t *path);
        int CreateDirectoryW(const uint16_t *path, void *security);
        int CopyFileW(const uint16_t *from, const uint16_t *to, int failIfExists);
        void *CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security, uint32_t creation,
                          uint32_t flags, void *templateFile);
        int WriteFile(void *file, const void *data, uint32_t size, uint32_t *written, void *overlapped);

        int OpenClipboard(void *owner);
        int CloseClipboard(void);
        void *GetClipboardData(uint32_t format);
        int IsClipboardFormatAvailable(uint32_t format);
        uint32_t RegisterClipboardFormatA(const char *name);

        uint32_t DragQueryFileW(void *drop, uint32_t index, uint16_t *file, uint32_t size);

        int GdiplusStartup(uintptr_t *token, const PCM_GDIPLUS_STARTUP *input, void *output);
        void GdiplusShutdown(uintptr_t token);
        int GdipCreateBitmapFromGdiDib(const void *info, const void *bits, void **bitmap);
        int GdipSaveImageToFile(void *image, const uint16_t *file, const PCM_GUID *encoder, const void *params);
        int GdipDisposeImage(void *image);
    ]])
    local ok = pcall(function()
        local k, u, s, g = ffi.load("kernel32"), ffi.load("user32"), ffi.load("shell32"), ffi.load("gdiplus")
        kernel32, user32, shell32, gdiplus = k, u, s, g
    end)
    if not ok then
        kernel32 = false
    end
    return kernel32 ~= false
end

local function to_wide(s)
    local n = kernel32.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
    local buf = ffi.new("uint16_t[?]", n)
    kernel32.MultiByteToWideChar(65001, 0, s, -1, buf, n)
    return buf
end

local function from_wide(ptr)
    local n = kernel32.WideCharToMultiByte(65001, 0, ptr, -1, nil, 0, nil, nil)
    if n <= 1 then
        return ""
    end
    local buf = ffi.new("char[?]", n)
    kernel32.WideCharToMultiByte(65001, 0, ptr, -1, buf, n, nil, nil)
    return ffi.string(buf, n - 1)
end

local INVALID_ATTRIBUTES = 0xFFFFFFFF
local FILE_ATTRIBUTE_DIRECTORY = 0x10

local function path_attributes(path)
    return kernel32.GetFileAttributesW(to_wide(path))
end

local function is_file(path)
    local attrs = path_attributes(path)
    return attrs ~= INVALID_ATTRIBUTES and bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) == 0
end

local function make_dirs(path)
    local prefix = ""
    for part in path:gmatch("[^\\]+") do
        prefix = prefix == "" and part or (prefix .. "\\" .. part)
        if not prefix:match("^%a:$") and path_attributes(prefix) == INVALID_ATTRIBUTES then
            kernel32.CreateDirectoryW(to_wide(prefix), nil)
        end
    end
    local attrs = path_attributes(path)
    return attrs ~= INVALID_ATTRIBUTES and bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

local function write_file(path, data)
    local GENERIC_WRITE, CREATE_NEW, FILE_ATTRIBUTE_NORMAL = 0x40000000, 1, 0x80
    local handle = kernel32.CreateFileW(to_wide(path), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nil)
    if ffi.cast("intptr_t", handle) == -1 then
        return false
    end
    local written = ffi.new("uint32_t[1]")
    local ok = kernel32.WriteFile(handle, data, #data, written, nil) ~= 0 and written[0] == #data
    kernel32.CloseHandle(handle)
    return ok
end

-- Runs a command line hidden. Returns true when it finished, or false and a message.
function M.run_hidden(cmdline, timeoutMs, wait)
    if not load_win32() then
        os.execute('"' .. cmdline .. '"')
        return true
    end
    local CREATE_NO_WINDOW = 0x08000000
    local si = ffi.new("PCM_STARTUPINFOW")
    si.cb = ffi.sizeof(si)
    local pi = ffi.new("PCM_PROCESS_INFORMATION")
    if kernel32.CreateProcessW(nil, to_wide(cmdline), nil, nil, 0, CREATE_NO_WINDOW, nil, nil, si, pi) == 0 then
        return false, "Could not start PowerShell."
    end
    local finished = true
    if wait ~= false then
        if kernel32.WaitForSingleObject(pi.hProcess, timeoutMs or M.HELPER_TIMEOUT_MS) ~= 0 then
            kernel32.TerminateProcess(pi.hProcess, 1)
            finished = false
        end
    end
    kernel32.CloseHandle(pi.hThread)
    kernel32.CloseHandle(pi.hProcess)
    if not finished then
        return false, "Reading the clipboard took too long and was cancelled."
    end
    return true
end

-------------------------------------------------------------------------------
-- Reading the clipboard
-------------------------------------------------------------------------------

local CF_DIB, CF_UNICODETEXT, CF_HDROP = 8, 13, 15
local NEEDS_HELPER = {}

local function random_suffix()
    local letters = {}
    for i = 1, 4 do
        letters[i] = string.char(math.random(97, 122))
    end
    return table.concat(letters)
end

-- File names always end in letters so Resolve never groups neighbouring files into an image sequence.
local function unique_path(outDir, baseName, ext)
    local clean = baseName:gsub('[%c<>:"/\\|%?%*]', "_"):match("^%s*(.-)%s*$")
    if clean == "" then
        clean = "Pasted"
    end
    local path
    repeat
        path = string.format("%s\\%s_%s%s", outDir, clean, random_suffix(), ext:lower())
    until path_attributes(path) == INVALID_ATTRIBUTES
    return path
end

local function default_base_name()
    return os.date("Pasted %Y-%m-%d %H-%M-%S")
end

local function copy_into(outDir, source)
    local dir = source:match("^(.*)\\[^\\]*$") or ""
    if dir:lower() == outDir:lower() then
        return source
    end
    local name = source:match("([^\\]+)$") or "Pasted"
    local base, ext = name:match("^(.*)(%.[^%.]+)$")
    local dest = unique_path(outDir, base or name, ext or "")
    if kernel32.CopyFileW(to_wide(source), to_wide(dest), 1) == 0 then
        return nil
    end
    return dest
end

-- Browsers put the original <img src> into the HTML clipboard format. The bitmap they also provide
-- is only the first frame of a GIF, so GIFs are downloaded by the PowerShell helper instead.
local function html_has_gif(html)
    local src = html:match("<[Ii][Mm][Gg][^>]-%s[Ss][Rr][Cc]%s*=%s*[\"']([^\"']+)[\"']")
    if not src then
        return false
    end
    src = src:gsub("&amp;", "&"):lower()
    return src:match("^https?://[^?#]+%.gif$") ~= nil or src:match("^https?://[^?#]+%.gif[?#]") ~= nil
        or src:match("^data:image/gif;base64,") ~= nil
end

local function global_bytes(handle)
    if handle == nil then
        return nil
    end
    local ptr = kernel32.GlobalLock(handle)
    if ptr == nil then
        return nil
    end
    local data = ffi.string(ptr, kernel32.GlobalSize(handle))
    kernel32.GlobalUnlock(handle)
    return data
end

local function global_wide_string(handle)
    if handle == nil then
        return nil
    end
    local ptr = kernel32.GlobalLock(handle)
    if ptr == nil then
        return nil
    end
    local text = from_wide(ffi.cast("const uint16_t *", ptr))
    kernel32.GlobalUnlock(handle)
    return text
end

-- Reads the most useful thing on the clipboard. Returns one of
--   { files = {...} }, { png = bytes }, { dib = bytes }, { text = string }, NEEDS_HELPER
-- or nil and a message.
local function read_clipboard_data()
    local opened = false
    for _ = 1, 10 do
        if user32.OpenClipboard(nil) ~= 0 then
            opened = true
            break
        end
        kernel32.Sleep(20)
    end
    if not opened then
        return nil, "The clipboard is in use by another program. Try again."
    end

    local ok, result = pcall(function()
        if user32.IsClipboardFormatAvailable(CF_HDROP) ~= 0 then
            local drop = user32.GetClipboardData(CF_HDROP)
            if drop ~= nil then
                local files = {}
                for i = 0, shell32.DragQueryFileW(drop, 0xFFFFFFFF, nil, 0) - 1 do
                    local len = shell32.DragQueryFileW(drop, i, nil, 0)
                    local buf = ffi.new("uint16_t[?]", len + 1)
                    shell32.DragQueryFileW(drop, i, buf, len + 1)
                    files[#files + 1] = from_wide(buf)
                end
                if #files > 0 then
                    return { files = files }
                end
            end
        end

        local htmlFormat = user32.RegisterClipboardFormatA("HTML Format")
        if user32.IsClipboardFormatAvailable(htmlFormat) ~= 0 then
            local html = global_bytes(user32.GetClipboardData(htmlFormat))
            if html and html_has_gif(html) then
                return NEEDS_HELPER
            end
        end

        for _, name in ipairs({ "PNG", "image/png" }) do
            local format = user32.RegisterClipboardFormatA(name)
            if user32.IsClipboardFormatAvailable(format) ~= 0 then
                local png = global_bytes(user32.GetClipboardData(format))
                if png and png:sub(2, 4) == "PNG" then
                    return { png = png }
                end
            end
        end

        if user32.IsClipboardFormatAvailable(CF_DIB) ~= 0 then
            local dib = global_bytes(user32.GetClipboardData(CF_DIB))
            if dib and #dib > 40 then
                return { dib = dib }
            end
        end

        if user32.IsClipboardFormatAvailable(CF_UNICODETEXT) ~= 0 then
            local text = global_wide_string(user32.GetClipboardData(CF_UNICODETEXT))
            if text then
                return { text = text }
            end
        end
        return nil
    end)
    user32.CloseClipboard()

    if not ok then
        return nil, tostring(result)
    end
    if not result then
        return nil, "The clipboard does not contain an image, GIF or media file."
    end
    return result
end

local function uint32_at(data, offset)
    local b1, b2, b3, b4 = data:byte(offset + 1, offset + 4)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- Saves a CF_DIB bitmap as PNG with GDI+.
local function save_dib_as_png(dib, path)
    local headerSize = uint32_at(dib, 0)
    local bitCount = dib:byte(15) + dib:byte(16) * 256
    local compression = uint32_at(dib, 16)
    local colorsUsed = uint32_at(dib, 32)
    local offset = headerSize
    if headerSize == 40 and compression == 3 then
        offset = offset + 12 -- BI_BITFIELDS colour masks
    elseif headerSize == 40 and compression == 6 then
        offset = offset + 16 -- BI_ALPHABITFIELDS colour masks
    end
    if colorsUsed == 0 and bitCount <= 8 then
        colorsUsed = bit.lshift(1, bitCount)
    end
    offset = offset + colorsUsed * 4

    local base = ffi.cast("const uint8_t *", dib)
    local token = ffi.new("uintptr_t[1]")
    local input = ffi.new("PCM_GDIPLUS_STARTUP", { GdiplusVersion = 1 })
    if gdiplus.GdiplusStartup(token, input, nil) ~= 0 then
        return false
    end
    local saved = false
    local bitmap = ffi.new("void *[1]")
    if gdiplus.GdipCreateBitmapFromGdiDib(base, base + offset, bitmap) == 0 then
        local pngEncoder = ffi.new("PCM_GUID", { 0x557CF406, 0x1A04, 0x11D3, { 0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E } })
        saved = gdiplus.GdipSaveImageToFile(bitmap[0], to_wide(path), pngEncoder, nil) == 0
        gdiplus.GdipDisposeImage(bitmap[0])
    end
    gdiplus.GdiplusShutdown(token[0])
    return saved
end

-- Saves the clipboard contents into outDir without starting another program.
-- Returns a list of file paths, NEEDS_HELPER, or nil and a message.
local function read_clipboard_native(outDir)
    local data, err = read_clipboard_data()
    if data == NEEDS_HELPER or not data then
        return data, err
    end
    if not make_dirs(outDir) then
        return nil, "Could not create the folder:\n" .. outDir
    end

    if data.files then
        local files = {}
        for _, source in ipairs(data.files) do
            if is_file(source) then
                local dest = copy_into(outDir, source)
                if not dest then
                    return nil, "Could not copy " .. source .. " to " .. outDir
                end
                files[#files + 1] = dest
            end
        end
        if #files == 0 then
            return nil, "The copied items are folders, not files."
        end
        return files
    end

    if data.png then
        local dest = unique_path(outDir, default_base_name(), ".png")
        if not write_file(dest, data.png) then
            return nil, "Could not write " .. dest
        end
        return { dest }
    end

    if data.dib then
        local dest = unique_path(outDir, default_base_name(), ".png")
        if not save_dib_as_png(data.dib, dest) then
            return NEEDS_HELPER
        end
        return { dest }
    end

    local text = data.text:match("^%s*(.-)%s*$"):gsub('^"(.*)"$', "%1")
    if text:match("^https?://%S+$") or text:match("^data:%S+$") then
        return NEEDS_HELPER
    end
    if text ~= "" and not text:find("[\r\n]") and is_file(text) then
        local dest = copy_into(outDir, text)
        if dest then
            return { dest }
        end
    end
    return nil, "The clipboard does not contain an image, GIF or media file."
end

local function powershell_command(args)
    local exe = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    local parts = { '"' .. exe .. '"', "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden", "-File", '"' .. M.script_dir() .. 'clipboard.ps1"' }
    for _, arg in ipairs(args) do
        parts[#parts + 1] = arg
    end
    return table.concat(parts, " ")
end

local function temp_file(suffix)
    local dir = os.getenv("TEMP") or os.getenv("TMP") or "."
    return string.format("%s\\paste_clipboard_media_%d_%d%s", dir, os.time(), math.random(100000, 999999), suffix)
end

-- The PowerShell helper handles everything, including downloads. It is slower to start, so it is
-- only used for downloads or when the Windows API cannot be reached.
local function read_clipboard_with_helper(outDir)
    local resultFile = temp_file(".txt")
    local ok, err = M.run_hidden(powershell_command({
        "-OutDir", '"' .. outDir .. '"', "-ResultFile", '"' .. resultFile .. '"',
    }), M.HELPER_TIMEOUT_MS)
    if not ok then
        return nil, err
    end
    local f = io.open(resultFile, "r")
    if not f then
        return nil, "The clipboard helper did not return a result. Check that PowerShell is available."
    end
    local files, message = {}, nil
    for line in f:lines() do
        local kind, value = line:match("^(%u+)\t(.*)$")
        if kind == "FILE" then
            files[#files + 1] = value
        elseif kind == "ERROR" then
            message = value
        end
    end
    f:close()
    os.remove(resultFile)
    if #files == 0 then
        return nil, message or "Nothing was found on the clipboard."
    end
    return files
end

-- Saves the clipboard contents into outDir. Returns a list of file paths, or nil and a message.
function M.read_clipboard(outDir)
    if load_win32() then
        local ok, files, err = pcall(read_clipboard_native, outDir)
        if ok and files ~= NEEDS_HELPER then
            return files, err
        end
    end
    return read_clipboard_with_helper(outDir)
end

-------------------------------------------------------------------------------
-- Messages
-------------------------------------------------------------------------------

-- A window ID that no other script (or earlier run of this one) is using.
local function unique_window_id(prefix)
    return string.format("%s%d%04d", prefix, os.time(), math.random(0, 9999))
end

-- Shows a window and runs its event loop until disp:ExitLoop(). Unlike disp:RunLoop() this ignores
-- events meant for other windows, which can otherwise crash the loop.
local function run_window(ui, disp, win, windowId)
    local data = rawget(disp, "_data")
    data.done = false
    win:Show()
    while not data.done do
        local ev = ui:GetEvent(true)
        while ev and not data.done do
            if ev.window == windowId and ev.who ~= nil then
                disp:Dispatch(ev)
            end
            ev = ui:GetEvent(false)
        end
    end
    win:Hide()
end

function M.message(text)
    print("[" .. M.NAME .. "] " .. text)
    local _, f = M.app()
    local shown = pcall(function()
        local ui = f.UIManager
        local disp = bmd.UIDispatcher(ui)
        local windowId = unique_window_id("PCMMessage")
        local win = disp:AddWindow({
            ID = windowId,
            WindowTitle = M.NAME,
            Geometry = { 500, 350, 460, 180 },
            ui:VGroup({
                ui:Label({ Text = text, WordWrap = true, Weight = 1, Alignment = { AlignTop = true, AlignLeft = true } }),
                ui:HGroup({ Weight = 0, ui:HGap(0, 1), ui:Button({ ID = "OK", Text = "OK", Weight = 0, MinimumSize = { 90, 0 } }) }),
            }),
        })
        win.On.OK.Clicked = function()
            disp:ExitLoop()
        end
        win.On[windowId].Close = function()
            disp:ExitLoop()
        end
        run_window(ui, disp, win, windowId)
    end)
    if not shown then
        local messageFile = temp_file(".txt")
        local mf = io.open(messageFile, "w")
        if mf then
            mf:write(text)
            mf:close()
            M.run_hidden(powershell_command({ "-MessageFile", '"' .. messageFile .. '"' }), 600000)
            os.remove(messageFile)
        end
    end
end

-------------------------------------------------------------------------------
-- Paste
-------------------------------------------------------------------------------

-- Appends one clip at recordFrame and returns the timeline item, or nil and a message.
local function place_clip(timeline, mediaPool, info, recordFrame, length)
    local track, err = M.choose_track(timeline, recordFrame, recordFrame + length)
    if not track then
        return nil, err
    end
    info.trackIndex = track
    info.recordFrame = recordFrame
    local item = list_of(mediaPool:AppendToTimeline({ info }))[1]
    if not item then
        return nil, "Resolve could not place the clip on the timeline."
    end

    -- Resolve never overwrites on append: if the spot was taken it shifts the clip to the next gap or
    -- trims it to fit. That only happens when the length estimate was off; then the clip is moved to a
    -- fresh track on top instead.
    local misplaced = item:GetStart() ~= recordFrame
        or not track_is_free(timeline, track, item:GetStart(), item:GetEnd(), item)
    if not misplaced and item:GetEnd() < recordFrame + length then
        misplaced = not track_is_free(timeline, track, item:GetEnd(), item:GetEnd() + 1, item)
    end
    if misplaced then
        timeline:DeleteClips({ item }, false)
        local newTrack, addErr = add_top_track(timeline)
        if not newTrack then
            return nil, addErr
        end
        info.trackIndex = newTrack
        item = list_of(mediaPool:AppendToTimeline({ info }))[1]
        if not item then
            return nil, "Resolve could not place the clip on the timeline."
        end
    end
    return item
end

function M.paste()
    local r = M.app()
    if not r then
        print("[" .. M.NAME .. "] Could not connect to DaVinci Resolve.")
        return
    end
    local project = r:GetProjectManager():GetCurrentProject()
    if not project then
        return M.message("No project is open.")
    end
    local timeline = project:GetCurrentTimeline()
    if not timeline then
        return M.message("Open a timeline first.")
    end

    local settings = M.load_settings()
    local outDir = M.expand_save_folder(settings.saveFolder, project:GetName())
    local files, readErr = M.read_clipboard(outDir)
    if not files then
        return M.message(readErr)
    end

    local timelineFps = tonumber(get_setting(timeline, project, "timelineFrameRate")) or 24
    local playheadTc = timeline:GetCurrentTimecode()
    local dropFrame = playheadTc:find(";") ~= nil or get_setting(timeline, project, "timelineDropFrameTimecode") == "1"
    local playhead = M.timecode_to_frames(playheadTc, timelineFps, dropFrame)
    if not playhead then
        return M.message("Could not read the playhead position (" .. tostring(playheadTc) .. ").")
    end

    local mediaPool = project:GetMediaPool()
    local previousFolder = mediaPool:GetCurrentFolder()

    -- Everything that touches the Media Pool runs in pcall so the bin you were viewing is always restored.
    local ok, result = pcall(function()
        local bins = {}
        local currentBin
        local cursor = playhead
        local failed = {}
        for _, path in ipairs(files) do
            local kind = M.kind_of(path)
            local bin, binErr = bins[kind], nil
            if not bin then
                bin, binErr = M.get_or_create_bin(mediaPool, settings[kind .. "Bin"])
                bins[kind] = bin
            end
            local clip
            if bin then
                if bin ~= currentBin then
                    mediaPool:SetCurrentFolder(bin)
                    currentBin = bin
                end
                clip = list_of(mediaPool:ImportMedia({ path }))[1]
                    or list_of(mediaPool:ImportMedia({ { FilePath = path } }))[1]
            end
            if not bin then
                failed[#failed + 1] = path .. "\n(" .. binErr .. ")"
            elseif not clip then
                failed[#failed + 1] = path .. "\n(Resolve could not import this file format.)"
            else
                local info, length = M.clip_info(clip, path, timelineFps)
                local item, placeErr = place_clip(timeline, mediaPool, info, cursor, length)
                if item then
                    local scale = settings[kind .. "Scale"]
                    if scale ~= 100 then
                        set_zoom(item, scale / 100)
                    end
                    cursor = item:GetEnd()
                else
                    failed[#failed + 1] = path .. "\n(" .. placeErr .. ")"
                end
            end
        end
        if #failed > 0 then
            return "Some files could not be pasted:\n\n" .. table.concat(failed, "\n\n")
        end
        return nil
    end)

    if previousFolder then
        mediaPool:SetCurrentFolder(previousFolder)
    end
    if timeline:GetCurrentTimecode() ~= playheadTc then
        timeline:SetCurrentTimecode(playheadTc)
    end

    if not ok then
        return M.message("Unexpected error: " .. tostring(result))
    elseif result then
        return M.message(result)
    end
end

-------------------------------------------------------------------------------
-- Settings window
-------------------------------------------------------------------------------

function M.open_settings()
    local r, f = M.app()
    local project = r and r:GetProjectManager():GetCurrentProject()
    if not project then
        return M.message("Open a project first, so its Media Pool bins can be listed.")
    end
    local mediaPool = project:GetMediaPool()
    local settings = M.load_settings()

    local ui = f and f.UIManager
    local okDisp, disp = pcall(function()
        return bmd.UIDispatcher(ui)
    end)
    if not ui or not okDisp then
        M.save_settings(settings)
        M.run_hidden('notepad.exe "' .. M.settings_path() .. '"', 0, false)
        return
    end

    local rootName = mediaPool:GetRootFolder():GetName()
    local function display(path)
        return path == "" and rootName or (rootName .. "/" .. path)
    end

    local rows = {}
    for _, kind in ipairs(M.KINDS) do
        rows[#rows + 1] = ui:HGroup({
            Weight = 0,
            ui:Label({ Text = kind.label, Weight = 0, MinimumSize = { 55, 0 } }),
            ui:ComboBox({ ID = kind.key .. "Bin", Editable = true, Weight = 1 }),
            ui:Button({ ID = kind.key .. "UseSelected", Text = "Use Selected Bin", Weight = 0 }),
            ui:Label({ Text = "  Size", Weight = 0 }),
            ui:SpinBox({
                ID = kind.key .. "Scale", Minimum = 1, Maximum = 1000, SingleStep = 5, Suffix = " %",
                Weight = 0, MinimumSize = { 80, 0 },
            }),
        })
    end

    local windowId = unique_window_id("PCMSettings")
    local win = disp:AddWindow({
        ID = windowId,
        WindowTitle = M.NAME .. " Settings",
        Geometry = { 450, 300, 720, 330 },
        ui:VGroup({
            Spacing = 8,
            ui:Label({ Weight = 0, Text = "Media Pool bin for each kind of file (type a path to create a new bin)" }),
            rows[1],
            rows[2],
            rows[3],
            ui:VGap(4, 0),
            ui:Label({ Weight = 0, Text = "Save pasted files to ({project} is replaced with the project name)" }),
            ui:HGroup({
                Weight = 0,
                ui:LineEdit({ ID = "SaveFolder", Weight = 1 }),
                ui:Button({ ID = "Browse", Text = "Browse...", Weight = 0 }),
            }),
            ui:Label({ Weight = 0, Text = "Size is the zoom a clip gets when placed. 50 % is half size.", StyleSheet = "color: #9a9a9a;" }),
            ui:Label({
                Weight = 0,
                Text = "Image length follows Preferences > User > Editing > Standard still duration.",
                StyleSheet = "color: #9a9a9a;",
            }),
            ui:VGap(0, 1),
            ui:HGroup({
                Weight = 0,
                ui:HGap(0, 1),
                ui:Button({ ID = "Save", Text = "Save", Weight = 0 }),
                ui:Button({ ID = "Cancel", Text = "Cancel", Weight = 0 }),
            }),
        }),
    })
    local items = win:GetItems()

    local bins = M.list_bins(mediaPool)
    for _, kind in ipairs(M.KINDS) do
        local combo = items[kind.key .. "Bin"]
        local saved = M.normalize_bin_path(settings[kind.key .. "Bin"], rootName)
        local selected
        for i, bin in ipairs(bins) do
            combo:AddItem(display(bin.path))
            if bin.path == saved then
                selected = i - 1
            end
        end
        if not selected then
            -- The bin does not exist in this project yet; it is created on the first paste.
            combo:AddItem(display(saved))
            selected = #bins
        end
        combo.CurrentIndex = selected
        items[kind.key .. "Scale"].Value = settings[kind.key .. "Scale"]

        win.On[kind.key .. "UseSelected"].Clicked = function()
            local path = M.folder_path(mediaPool, mediaPool:GetCurrentFolder())
            for i, bin in ipairs(bins) do
                if bin.path == path then
                    combo.CurrentIndex = i - 1
                    return
                end
            end
        end
    end
    items.SaveFolder.Text = settings.saveFolder

    function win.On.Browse.Clicked()
        local start = M.expand_save_folder(items.SaveFolder.Text, project:GetName())
        local okDir, dir = pcall(function()
            return f:RequestDir(start)
        end)
        if okDir and type(dir) == "string" and dir ~= "" then
            items.SaveFolder.Text = (dir:gsub("[\\/]+$", ""))
        end
    end

    function win.On.Save.Clicked()
        for _, kind in ipairs(M.KINDS) do
            settings[kind.key .. "Bin"] = M.normalize_bin_path(items[kind.key .. "Bin"].CurrentText, rootName)
            settings[kind.key .. "Scale"] = items[kind.key .. "Scale"].Value
        end
        settings.saveFolder = items.SaveFolder.Text:match("^%s*(.-)%s*$")
        if settings.saveFolder == "" then
            settings.saveFolder = M.DEFAULT_SAVE_FOLDER
        end
        local saved, err = M.save_settings(settings)
        if not saved then
            print("[" .. M.NAME .. "] Could not save settings: " .. tostring(err))
        end
        disp:ExitLoop()
    end

    function win.On.Cancel.Clicked()
        disp:ExitLoop()
    end

    win.On[windowId].Close = function()
        disp:ExitLoop()
    end

    run_window(ui, disp, win, windowId)
end

-------------------------------------------------------------------------------

if load_win32() then
    math.randomseed(tonumber(kernel32.GetTickCount64() % 2147483647))
else
    math.randomseed(os.time())
end

if select(1, ...) == "library" then
    return M
end

M.paste()
