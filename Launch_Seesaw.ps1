param([switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$rootPrefix = $root.TrimEnd('\') + '\'
$cache = Join-Path $root '.seesaw-cache'
$app = Join-Path $root 'Seesaw_demo-portable-Windows-x64'
$start = Join-Path $app 'Start_Seesaw.cmd'
$lock = $null
try {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Windows 10/11 x64 is required.' }
    $manifest = Get-Content -LiteralPath (Join-Path $root 'package\manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.version -ne '1.1.1' -or $manifest.sha256 -ne '4a0145fb48a54506cd1c104e5e57a959bbf18ab57bf421870a2539cfdc58c438') { throw 'The package manifest is not valid.' }
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    do {
        try { $lock = [IO.File]::Open((Join-Path $cache 'prepare.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { if ([DateTime]::UtcNow -ge $deadline) { throw 'Another startup is still preparing the application. Try again shortly.' }; Start-Sleep -Milliseconds 300 }
    } until ($null -ne $lock)
    $ready = Join-Path $cache 'ready-v1.1.1.json'
    $prepared = $false
    if (Test-Path -LiteralPath $ready -PathType Leaf) {
        $receipt = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
        $prepared = ($receipt.sha256 -eq $manifest.sha256) -and (Test-Path -LiteralPath $start -PathType Leaf)
    }
    if (-not $prepared) {
        if (Test-Path -LiteralPath $app) { throw 'An incomplete application folder already exists. Extract a fresh copy of the download into a new folder.' }
        Write-Host 'Preparing Seesaw Demo v1.1.1. This is needed only once.'
        $archive = Join-Path $cache 'Seesaw_demo-1.1.1-Windows-x64.zip'
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            $partial = $archive + '.partial'
            $output = [IO.File]::Open($partial, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                foreach ($part in $manifest.parts) {
                    $path = [IO.Path]::GetFullPath((Join-Path $root $part.path))
                    if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'A package path is invalid.' }
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A package file is missing. Extract the entire download.' }
                    if ((Get-Item -LiteralPath $path).Length -ne $part.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $part.sha256) { throw 'A package file failed verification. Download a fresh copy.' }
                    $inputStream = [IO.File]::OpenRead($path)
                    try { $inputStream.CopyTo($output) } finally { $inputStream.Dispose() }
                }
            } finally { $output.Dispose() }
            if ((Get-Item -LiteralPath $partial).Length -ne $manifest.size -or (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $manifest.sha256) { throw 'The restored package failed verification.' }
            Move-Item -LiteralPath $partial -Destination $archive
        }
        if ((Get-Item -LiteralPath $archive).Length -ne $manifest.size -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $manifest.sha256) { throw 'The saved package failed verification. Extract a fresh copy of the download.' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($entry in $zip.Entries) {
                if (-not $entry.FullName.StartsWith('Seesaw_demo-portable-Windows-x64/', [StringComparison]::Ordinal)) { throw 'An unexpected archive entry was found.' }
                $target = [IO.Path]::GetFullPath((Join-Path $root $entry.FullName))
                if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'An archive path is invalid.' }
            }
        } finally { $zip.Dispose() }
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $root)
        if (-not (Test-Path -LiteralPath $start -PathType Leaf)) { throw 'The application launcher is missing.' }
        @{version=$manifest.version;sha256=$manifest.sha256} | ConvertTo-Json | Set-Content -LiteralPath $ready -Encoding UTF8
        Write-Host 'Package verified and ready.'
    }
} catch {
    Write-Host ('Seesaw startup failed: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally { if ($null -ne $lock) { $lock.Dispose() } }
if ($PrepareOnly) { Write-Output $app; exit 0 }
& $start
exit $LASTEXITCODE
