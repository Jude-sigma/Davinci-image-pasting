# Installs Paste Clipboard Media into DaVinci Resolve's per-user Scripts folder.
#
# From a downloaded copy of the repository:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# Straight from GitHub, without downloading anything first:
#   irm https://raw.githubusercontent.com/Jude-sigma/Davinci-image-pasting/main/install.ps1 | iex

function Install-PasteClipboardMedia {
    $ErrorActionPreference = 'Stop'

    $repoBase = 'https://raw.githubusercontent.com/Jude-sigma/Davinci-image-pasting/main/Paste%20Clipboard%20Media'
    $files = @('Paste Clipboard Media.lua', 'Paste Clipboard Media Settings.lua', 'clipboard.ps1')
    $target = Join-Path $env:APPDATA 'Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\Paste Clipboard Media'

    New-Item -ItemType Directory -Force -Path $target | Out-Null

    $localSource = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Paste Clipboard Media' } else { $null }
    if ($localSource -and (Test-Path -LiteralPath $localSource)) {
        foreach ($name in $files) {
            Copy-Item -LiteralPath (Join-Path $localSource $name) -Destination $target -Force
        }
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $client = New-Object System.Net.WebClient
        try {
            foreach ($name in $files) {
                Write-Host "Downloading $name"
                $client.DownloadFile("$repoBase/" + [Uri]::EscapeDataString($name), (Join-Path $target $name))
            }
        } finally {
            $client.Dispose()
        }
    }

    foreach ($name in $files) {
        Unblock-File -LiteralPath (Join-Path $target $name)
    }

    Write-Host "Installed to $target"
    Write-Host 'Restart DaVinci Resolve, then use Workspace > Scripts > Paste Clipboard Media.'
}

Install-PasteClipboardMedia
