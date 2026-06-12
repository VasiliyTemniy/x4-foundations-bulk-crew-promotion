$mod = "vas_bulk_crew_promotion"
$pkg = Join-Path $PSScriptRoot "packages\$mod"
$ts  = Get-Date -Format "dd-MM-yyyy_HHmmss"
$zip = Join-Path $PSScriptRoot "packages\${mod}_${ts}.zip"

if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force $pkg | Out-Null

Get-ChildItem -LiteralPath "$PSScriptRoot\src" -Force |
    Copy-Item -Destination $pkg -Recurse -Force

Compress-Archive -Path "$pkg" -DestinationPath $zip -CompressionLevel Optimal

Write-Host "Packed: $zip"
