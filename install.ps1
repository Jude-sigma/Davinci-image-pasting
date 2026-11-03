# Copies the Paste Clipboard Media scripts into DaVinci Resolve's per-user Scripts folder.

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'Paste Clipboard Media'
$target = Join-Path $env:APPDATA 'Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\Paste Clipboard Media'

New-Item -ItemType Directory -Force -Path $target | Out-Null
Get-ChildItem -LiteralPath $source -File | Where-Object { $_.Name -ne 'settings.txt' } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    Unblock-File -LiteralPath (Join-Path $target $_.Name)
}

Write-Host "Installed to $target"
Write-Host 'Restart DaVinci Resolve, then use Workspace > Scripts > Paste Clipboard Media.'
