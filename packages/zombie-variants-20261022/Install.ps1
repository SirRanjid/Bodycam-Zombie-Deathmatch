param(
    [string]$GameDirectory = 'D:\Steam\steamapps\common\Bodycam\Bodycam\Binaries\Win64',
    [switch]$ValidateOnly,
    [switch]$CheckGameClosed,
    [switch]$UpdateExisting
)
$ErrorActionPreference = 'Stop'
$packageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'manifest.json') -Raw | ConvertFrom-Json
$gameRoot = (Resolve-Path -LiteralPath $GameDirectory).Path
$exe = Join-Path $gameRoot 'Bodycam-Win64-Shipping.exe'
$ue4ss = Join-Path $gameRoot 'ue4ss\UE4SS.dll'
foreach ($entry in @(@($exe, $manifest.supported_exe_sha256), @($ue4ss, $manifest.supported_ue4ss_sha256))) {
    if ((Get-FileHash -LiteralPath $entry[0] -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry[1]) {
        throw "Unsupported game or UE4SS version: $($entry[0])"
    }
}
foreach ($entry in $manifest.files.PSObject.Properties) {
    if ($entry.Name -notmatch '^BodycamZombieVariants/(Scripts/[a-z_]+\.lua|Native/(bodycam_variants_native\.dll|MinHook-LICENSE\.txt)|README\.md|enabled\.txt)$') {
        throw "Unexpected package file: $($entry.Name)"
    }
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $packageRoot $entry.Name))
    if (-not $sourcePath.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Package path escapes its root' }
    if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value) { throw "Package checksum mismatch: $($entry.Name)" }
}
if ($ValidateOnly) { Write-Output 'Package and supported game versions verified. No files changed.'; return }
function Assert-GameClosed {
    # WMI also catches game processes hidden from a restricted process listing.
    # A failed system-wide query aborts installation rather than assuming closed.
    $gameProcesses = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Bodycam.exe' OR Name = 'Bodycam-Win64-Shipping.exe'" -ErrorAction Stop
    if ($gameProcesses) { throw 'Close Bodycam before installing. No live installation or reload is supported.' }
    if (Get-Process -Name 'Bodycam*' -ErrorAction SilentlyContinue) { throw 'Close Bodycam before installing. No live installation or reload is supported.' }
}
Assert-GameClosed
if ($CheckGameClosed) { Write-Output 'Bodycam is closed. No files changed.'; return }
$modsRoot = (Resolve-Path -LiteralPath (Join-Path $gameRoot 'ue4ss\Mods')).Path
$destination = [IO.Path]::GetFullPath((Join-Path $modsRoot 'BodycamZombieVariants'))
if (-not $destination.StartsWith($modsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid destination' }
$existing = Test-Path -LiteralPath $destination
if ($existing -and -not $UpdateExisting) { throw 'BodycamZombieVariants already exists. Use -UpdateExisting for a cold update with a retained backup.' }
if ($existing -and (Get-Item -LiteralPath $destination).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'Refusing a linked mod directory' }
# Prepare outside Mods; UE4SS cannot discover a partially copied mod.
$staging = Join-Path (Split-Path -Parent $modsRoot) ('variants-staging-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
foreach ($entry in $manifest.files.PSObject.Properties) {
    $relative = $entry.Name.Substring('BodycamZombieVariants/'.Length)
    $target = Join-Path $staging $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $packageRoot $entry.Name) -Destination $target
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value) { throw "Copied file verification failed: $relative. Staging retained at $staging" }
}
Assert-GameClosed
# Same-volume directory rename exposes only the complete new mod.
$backup = $null
if ($existing) {
    $backup = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $modsRoot) ('variants-backup-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))))
    $ue4ssRoot = [IO.Path]::GetFullPath((Split-Path -Parent $modsRoot))
    if (-not $backup.StartsWith($ue4ssRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid backup destination' }
    [IO.Directory]::Move($destination, $backup)
}
try {
    Assert-GameClosed
    [IO.Directory]::Move($staging, $destination)
} catch {
    if ($backup -and -not (Test-Path -LiteralPath $destination)) { [IO.Directory]::Move($backup, $destination) }
    throw
}
Write-Output "Installed separate variant mod: $destination"
if ($backup) { Write-Output "Previous variant files retained: $backup" }
Write-Output 'Start Bodycam normally. Existing Z-Deathmatch files were not changed. Live acceptance testing is still required.'
