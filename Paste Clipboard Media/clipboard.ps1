# Clipboard helper for Paste Clipboard Media.
#
# Saves whatever media is on the Windows clipboard into OutDir and writes the result to ResultFile
# (UTF-8, one entry per line):
#   FILE<TAB><full path>     one line per saved file
#   ERROR<TAB><message>      when nothing usable was found
#
# With -MessageFile it instead shows the text of that file in a message box (used as a fallback
# when Resolve's UI Manager is not available).

param(
    [string]$OutDir,
    [string]$ResultFile,
    [string]$MessageFile,
    [string]$MessageTitle = 'Paste Clipboard Media'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($MessageFile) {
    $text = [System.IO.File]::ReadAllText($MessageFile, [System.Text.Encoding]::UTF8)
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    [void][System.Windows.Forms.MessageBox]::Show($owner, $text, $MessageTitle)
    $owner.Dispose()
    exit 0
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Result([string[]]$Lines) {
    [System.IO.File]::WriteAllText($ResultFile, ($Lines -join "`n"), $Utf8NoBom)
}

function New-Suffix {
    -join (1..4 | ForEach-Object { [char](Get-Random -Minimum 97 -Maximum 123) })
}

# File names always end in letters so Resolve never groups neighbouring files into an image sequence.
function Get-UniquePath([string]$BaseName, [string]$Extension) {
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $clean = -join ($BaseName.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } })
    if (-not $clean.Trim()) { $clean = 'Pasted' }
    do {
        $path = Join-Path $OutDir ('{0}_{1}{2}' -f $clean.Trim(), (New-Suffix), $Extension.ToLower())
    } while (Test-Path -LiteralPath $path)
    return $path
}

function Get-DefaultBaseName {
    'Pasted ' + (Get-Date -Format 'yyyy-MM-dd HH-mm-ss')
}

function Copy-IntoOutDir([string]$Source) {
    $full = [System.IO.Path]::GetFullPath($Source)
    if ([System.IO.Path]::GetDirectoryName($full).TrimEnd('\') -ieq $OutDirFull) {
        return $full
    }
    $dest = Get-UniquePath ([System.IO.Path]::GetFileNameWithoutExtension($full)) ([System.IO.Path]::GetExtension($full))
    Copy-Item -LiteralPath $full -Destination $dest
    return $dest
}

# Picks a file extension from the first bytes of a file, or returns $null if it is not recognised.
function Get-ExtensionFromBytes([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 16
        $count = $stream.Read($buffer, 0, 16)
    } finally {
        $stream.Dispose()
    }
    if ($count -lt 12) { return $null }
    $ascii = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $count)
    if ($ascii.StartsWith('GIF8')) { return '.gif' }
    if ($buffer[0] -eq 0x89 -and $ascii.Substring(1, 3) -eq 'PNG') { return '.png' }
    if ($buffer[0] -eq 0xFF -and $buffer[1] -eq 0xD8 -and $buffer[2] -eq 0xFF) { return '.jpg' }
    if ($ascii.StartsWith('RIFF') -and $ascii.Substring(8, 4) -eq 'WEBP') { return '.webp' }
    if ($ascii.StartsWith('BM')) { return '.bmp' }
    if ($ascii.StartsWith("II*`0") -or $ascii.StartsWith("MM`0*")) { return '.tif' }
    if ($ascii.Substring(4, 4) -eq 'ftyp') {
        if ($ascii.Substring(8, 4) -eq 'qt  ') { return '.mov' }
        return '.mp4'
    }
    if ($buffer[0] -eq 0x1A -and $buffer[1] -eq 0x45 -and $buffer[2] -eq 0xDF -and $buffer[3] -eq 0xA3) { return '.webm' }
    return $null
}

function Save-Url([string]$Url) {
    $tmp = Join-Path $OutDir ('download_{0}.tmp' -f (New-Suffix))
    try {
        if ($Url -match '^data:[^;,]+;base64,(.+)$') {
            [System.IO.File]::WriteAllBytes($tmp, [System.Convert]::FromBase64String($Matches[1]))
        } else {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
            $client = New-Object System.Net.WebClient
            $client.Headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            try {
                $client.DownloadFile($Url, $tmp)
            } finally {
                $client.Dispose()
            }
        }
        $ext = Get-ExtensionFromBytes $tmp
        if (-not $ext) {
            Remove-Item -LiteralPath $tmp -Force
            return $null
        }
        $name = Get-DefaultBaseName
        if ($Url -match '^https?://') {
            $segment = [System.Uri]::UnescapeDataString(([System.Uri]$Url).Segments[-1])
            $segment = [System.IO.Path]::GetFileNameWithoutExtension($segment)
            if ($segment -and $segment.Trim('/')) { $name = $segment }
        }
        $dest = Get-UniquePath $name $ext
        Move-Item -LiteralPath $tmp -Destination $dest
        return $dest
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        return $null
    }
}

# Browsers put the original <img src> into the HTML clipboard format. The bitmap they also provide is
# only the first frame of a GIF, so for GIFs the original file is downloaded instead.
function Get-GifSourceFromHtml($Data) {
    if (-not $Data.GetDataPresent('HTML Format')) { return $null }
    $html = [string]$Data.GetData('HTML Format')
    if ($html -notmatch '<img[^>]*?\ssrc\s*=\s*["'']([^"'']+)["'']') { return $null }
    $src = [System.Net.WebUtility]::HtmlDecode($Matches[1])
    if ($src -match '^https?://[^?#]+\.gif([?#].*)?$' -or $src -match '^data:image/gif;base64,') {
        return $src
    }
    return $null
}

function Get-ClipboardData {
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            return [System.Windows.Forms.Clipboard]::GetDataObject()
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    throw 'The clipboard is in use by another program. Try again.'
}

try {
    if (-not $OutDir -or -not $ResultFile) { throw 'OutDir and ResultFile are required.' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $OutDirFull = [System.IO.Path]::GetFullPath($OutDir).TrimEnd('\')

    $data = Get-ClipboardData
    if (-not $data) { throw 'The clipboard is empty.' }

    # 1. Files copied in Explorer.
    if ($data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $files = @($data.GetData([System.Windows.Forms.DataFormats]::FileDrop) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($files.Count -gt 0) {
            Write-Result ($files | ForEach-Object { "FILE`t" + (Copy-IntoOutDir $_) })
            exit 0
        }
    }

    # 2. An animated GIF copied from a web page.
    $gifSource = Get-GifSourceFromHtml $data
    if ($gifSource) {
        $saved = Save-Url $gifSource
        if ($saved) {
            Write-Result @("FILE`t$saved")
            exit 0
        }
    }

    # 3. PNG data (keeps transparency).
    foreach ($format in @('PNG', 'image/png')) {
        if ($data.GetDataPresent($format)) {
            $stream = $data.GetData($format)
            if ($stream -is [System.IO.MemoryStream]) {
                $dest = Get-UniquePath (Get-DefaultBaseName) '.png'
                [System.IO.File]::WriteAllBytes($dest, $stream.ToArray())
                Write-Result @("FILE`t$dest")
                exit 0
            }
        }
    }

    # 4. Any other bitmap (screenshots, most apps).
    if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
        $image = [System.Windows.Forms.Clipboard]::GetImage()
        $dest = Get-UniquePath (Get-DefaultBaseName) '.png'
        $image.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
        $image.Dispose()
        Write-Result @("FILE`t$dest")
        exit 0
    }

    # 5. Text holding a file path or a link to an image or video.
    if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        $text = [System.Windows.Forms.Clipboard]::GetText().Trim().Trim('"')
        if ($text -and $text.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -lt 0 -and (Test-Path -LiteralPath $text -PathType Leaf)) {
            Write-Result @("FILE`t" + (Copy-IntoOutDir $text))
            exit 0
        }
        if ($text -match '^(https?://\S+|data:\S+)$') {
            $saved = Save-Url $text
            if ($saved) {
                Write-Result @("FILE`t$saved")
                exit 0
            }
            throw "Could not download an image or video from the copied link:`n$text"
        }
    }

    throw 'The clipboard does not contain an image, GIF or media file.'
} catch {
    Write-Result @("ERROR`t" + ($_.Exception.Message -replace "`r?`n", ' '))
}
exit 0
