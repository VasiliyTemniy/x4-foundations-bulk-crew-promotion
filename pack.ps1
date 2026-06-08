$mod = "vas_bulk_crew_promotion"
$pkg = Join-Path $PSScriptRoot "packages\$mod"
$ts  = Get-Date -Format "dd-MM-yyyy_HHmmss"
$zip = Join-Path $PSScriptRoot "packages\${mod}_${ts}.zip"

if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force $pkg | Out-Null

Copy-Item -Force "$PSScriptRoot\src\content.xml"  "$pkg\content.xml"
Copy-Item -Force "$PSScriptRoot\src\ui.xml"       "$pkg\ui.xml"
Copy-Item -Recurse -Force "$PSScriptRoot\src\md"  "$pkg\md"
Copy-Item -Recurse -Force "$PSScriptRoot\src\t"   "$pkg\t"
Copy-Item -Recurse -Force "$PSScriptRoot\src\ui"  "$pkg\ui"

Compress-Archive -Path "$pkg" -DestinationPath $zip -CompressionLevel Optimal

Write-Host "Packed: $zip"
