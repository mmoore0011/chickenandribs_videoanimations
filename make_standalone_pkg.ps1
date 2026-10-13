<#
.SYNOPSIS
    Creates a .unitypackage from the current directory — the standalone-repo
    counterpart to make_unity_pkg.ps1 (which expects an mm_tools/<Dir> layout).
    Used by each tool repo's GitHub Actions release workflow; also runnable
    locally from a standalone repo's root.

.DESCRIPTION
    Same packaging logic as make_unity_pkg.ps1 (GUID/meta synthesis, exclusion
    rules, embedded-.unitypackage merging), but operates on the current
    directory directly instead of an mm_tools/<Dir> subfolder, since a
    standalone repo's root IS the tool.

    Package root detection:
      If the repo root contains an "Assets/" subfolder, package paths are
      taken from that subfolder's contents directly (e.g. Assets/MovingVehicles/...).
      Otherwise every file is placed under Assets/<PackageName>/..., preserving
      any subfolders (Editor/, Scripts/, etc.) that exist in source.

    Files skipped automatically: same as make_unity_pkg.ps1 — .blend/.blend1/
    .fbm, video files, .zip/.unitypackage, .meta, decom_* files, .claude/,
    MEMORY.md, settings.local.json, package.json. Also skips README.md,
    LICENSE.md, CONTRIBUTING.md, splash.png, and .github/ — repo-presentation
    files that don't belong in the Unity package itself.

.PARAMETER PackageName
    Folder name assets are wrapped under inside the package, used only when
    there's no existing Assets/ subfolder at the repo root (e.g. "SkyDome"
    produces Assets/SkyDome/...).

.PARAMETER OutputFile
    Path to write the .unitypackage to.

.EXAMPLE
    .\make_standalone_pkg.ps1 -PackageName SkyDome -OutputFile skydome.unitypackage
#>

param(
    [Parameter(Mandatory)] [string]$PackageName,
    [Parameter(Mandatory)] [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# UTF-8 without BOM — Unity reads pathname files as raw bytes; a BOM prefix
# produces an invisible U+FEFF character at the start of the path, causing
# Unity to create a phantom "Assets" folder instead of using the existing one.
$utf8 = [System.Text.UTF8Encoding]::new($false)

# ── Resolve paths ─────────────────────────────────────────────────────────────
$toolPath = (Get-Location).Path
# Must be absolute: the script later Push-Location's into a temp build folder,
# and a relative $OutputFile would then resolve against THAT directory instead
# of here, silently writing the package to the wrong place.
$outPkg   = Join-Path $toolPath $OutputFile

# ── Temp workspace (auto-cleaned on exit) ─────────────────────────────────────
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "unity_pkg_$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $tmp | Out-Null

# ── Source root and package path prefix ───────────────────────────────────────
$assetsDir = Join-Path $toolPath 'Assets'
if (Test-Path $assetsDir -PathType Container) {
    $sourceRoot = $assetsDir
    $pkgBase    = 'Assets'
} else {
    $sourceRoot = $toolPath
    $pkgBase    = "Assets/$PackageName"
}

# ── Exclusion rules ───────────────────────────────────────────────────────────
$excludeExts   = [System.Collections.Generic.HashSet[string]]@(
    '.blend', '.blend1', '.mp4', '.mov', '.avi',
    '.zip', '.unitypackage', '.meta', '.ps1', '.yml', '.yaml'
)
$excludeNames  = [System.Collections.Generic.HashSet[string]]@(
    'MEMORY.md', 'settings.local.json', 'package.json',
    'README.md', 'LICENSE.md', 'CONTRIBUTING.md', 'splash.png', 'TODO.md'
)

function Test-Excluded([System.IO.FileInfo]$f) {
    if ($excludeExts.Contains($f.Extension.ToLower())) { return $true }
    if ($excludeNames.Contains($f.Name))               { return $true }
    if ($f.Name.StartsWith('decom_'))                  { return $true }
    $segments = $f.FullName.Split([System.IO.Path]::DirectorySeparatorChar)
    foreach ($seg in $segments) {
        if ($seg -eq '.claude') { return $true }
        if ($seg -eq '.git')    { return $true }
        if ($seg -eq '.github') { return $true }
        if ($seg.EndsWith('.fbm')) { return $true }
        if ($seg.StartsWith('decom_') -and $seg -ne $f.Name) { return $true }
    }
    return $false
}

# ── Meta content by file type ─────────────────────────────────────────────────
function Get-Meta([string]$ext, [string]$guid, [bool]$isFolder) {
    $h = "fileFormatVersion: 2`nguid: $guid`n"
    if ($isFolder) {
        return $h + "folderAsset: yes`nDefaultImporter:`n  externalObjects: {}`n  userData: `n  assetBundleName: `n  assetBundleVariant:`n"
    }
    switch ($ext) {
        '.cs'     { return $h + "MonoImporter:`n  externalObjects: {}`n  serializedVersion: 2`n  defaultReferences: []`n  executionOrder: 0`n  icon: {instanceID: 0}`n  userData: `n  assetBundleName: `n  assetBundleVariant:`n" }
        '.shader' { return $h + "ShaderImporter:`n  externalObjects: {}`n  defaultTextures: []`n  nonModifiableTextures: []`n  userData: `n  assetBundleName: `n  assetBundleVariant:`n" }
        '.json'   { return $h + "TextScriptImporter:`n  userData: `n  assetBundleName: `n  assetBundleVariant:`n" }
        { $_ -in @('.png', '.jpg', '.jpeg') } {
            return $h + "TextureImporter:`n  serializedVersion: 4`n  mipmaps:`n    enableMipmapStreaming: 0`n  bumpmap:`n    convertToNormalMap: 0`n  userData: `n  assetBundleName: `n  assetBundleVariant:`n"
        }
        { $_ -in @('.mp3', '.wav', '.ogg') } {
            return $h + "AudioImporter:`n  externalObjects: {}`n  userData: `n  assetBundleName: `n  assetBundleVariant:`n"
        }
        '.fbx'    { return $h + "ModelImporter:`n  serializedVersion: 19300`n  userData: `n  assetBundleName: `n  assetBundleVariant:`n" }
        default   { return $h + "DefaultImporter:`n  externalObjects: {}`n  userData: `n  assetBundleName: `n  assetBundleVariant:`n" }
    }
}

function New-G { return [System.Guid]::NewGuid().ToString('N') }

function Write-Entry([string]$g, [string]$pkgPath, [string]$metaContent, [byte[]]$assetBytes) {
    $d = Join-Path $tmp $g
    New-Item -ItemType Directory -Force $d | Out-Null
    [System.IO.File]::WriteAllText("$d\pathname",   $pkgPath,     $utf8)
    [System.IO.File]::WriteAllText("$d\asset.meta", $metaContent, $utf8)
    if ($null -ne $assetBytes) {
        [System.IO.File]::WriteAllBytes("$d\asset", $assetBytes)
    }
}

# ── Collect files, derive package paths, gather required folder paths ──────────
$fileList  = [System.Collections.Generic.List[hashtable]]::new()
$folderSet = [System.Collections.Generic.HashSet[string]]::new()

foreach ($f in (Get-ChildItem $sourceRoot -Recurse -File)) {
    if (Test-Excluded $f) { continue }

    $rel     = $f.FullName.Substring($sourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
    $pkgPath = "$pkgBase/$rel"
    $fileList.Add(@{ src = $f.FullName; pkg = $pkgPath; ext = $f.Extension.ToLower() })

    $parts = $pkgPath.Split('/')
    for ($i = 2; $i -lt $parts.Length; $i++) {
        $folderSet.Add(($parts[0..($i - 1)] -join '/')) | Out-Null
    }
}

if ($fileList.Count -eq 0) {
    Write-Warning "No packagable files found under: $sourceRoot"
    exit 0
}

Write-Output "Source : $sourceRoot"
Write-Output "Base   : $pkgBase"
Write-Output "Output : $outPkg"
Write-Output ''

foreach ($fp in ($folderSet | Sort-Object)) {
    Write-Entry (New-G) $fp (Get-Meta '' (New-G) $true) $null
}

foreach ($e in $fileList) {
    Write-Entry (New-G) $e.pkg (Get-Meta $e.ext (New-G) $false) ([System.IO.File]::ReadAllBytes($e.src))
    Write-Output "  + $($e.pkg)"
}

# ── Merge embedded .unitypackage files found inside the source root ───────────
# See make_unity_pkg.ps1 for the full rationale — same logic, condensed here.
$claimedPaths = [System.Collections.Generic.HashSet[string]]::new()
foreach ($fp in $folderSet) { $claimedPaths.Add($fp) | Out-Null }
foreach ($e in $fileList)   { $claimedPaths.Add($e.pkg) | Out-Null }

$outPkgFullName = [System.IO.Path]::GetFullPath($outPkg)

$embCount = 0
foreach ($embPkg in (Get-ChildItem $sourceRoot -Recurse -Filter "*.unitypackage")) {
    if ($embPkg.FullName -eq $outPkgFullName) { continue }
    $embTmp = Join-Path ([System.IO.Path]::GetTempPath()) "unity_embed_$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force $embTmp | Out-Null
    tar -xzf $embPkg.FullName -C $embTmp 2>$null
    foreach ($guidDir in (Get-ChildItem $embTmp -Directory)) {
        $pnFile = Join-Path $guidDir.FullName "pathname"
        if (-not (Test-Path $pnFile)) { continue }
        $pkgPath = [System.IO.File]::ReadAllText($pnFile, $utf8).Trim()
        if ($claimedPaths.Contains($pkgPath)) { continue }
        $metaFile  = Join-Path $guidDir.FullName "asset.meta"
        $assetFile = Join-Path $guidDir.FullName "asset"
        if (-not (Test-Path $metaFile)) { continue }
        $metaContent = [System.IO.File]::ReadAllText($metaFile)
        $assetBytes  = if (Test-Path $assetFile) { [System.IO.File]::ReadAllBytes($assetFile) } else { $null }
        Write-Entry $guidDir.Name $pkgPath $metaContent $assetBytes
        Write-Output "  + $pkgPath  [from $($embPkg.Name)]"
        $claimedPaths.Add($pkgPath) | Out-Null
        $embCount++
    }
    Remove-Item -Recurse -Force $embTmp
}

# ── Pack ──────────────────────────────────────────────────────────────────────
$nFolders = $folderSet.Count
$nFiles   = $fileList.Count
Write-Output ''
Write-Output "Packing $($nFolders + $nFiles + $embCount) entries ($nFolders folders, $nFiles files, $embCount embedded)..."
Push-Location $tmp
$guidDirs = (Get-ChildItem -Directory | Select-Object -ExpandProperty Name)
tar -czf $outPkg $guidDirs
Pop-Location
$sizeMB = [Math]::Round((Get-Item $outPkg).Length / 1MB, 2)
Write-Output "Done: $outPkg ($sizeMB MB)"
