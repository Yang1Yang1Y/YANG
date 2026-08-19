[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SkipBuild,
    [switch]$Draft
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$versionInfo = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'version.json') | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string]$versionInfo.version }
$repository = [string]$versionInfo.repository
$tag = 'v' + $Version.TrimStart('v')
$Version = $Version.TrimStart('v')

if ($null -eq (Get-Command gh.exe -ErrorAction SilentlyContinue)) { throw '发布需要 GitHub CLI（gh）。' }
& gh.exe auth status | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI 尚未登录。' }
if ((& git.exe -C $repoRoot branch --show-current) -ne 'main') { throw '只能从 main 分支发布正式版本。' }
if (@(& git.exe -C $repoRoot status --porcelain).Count -gt 0) { throw '发布前工作区必须干净。' }

& git.exe -C $repoRoot fetch origin main --tags
if ($LASTEXITCODE -ne 0) { throw '无法同步远端分支和标签。' }
$head = [string](& git.exe -C $repoRoot rev-parse HEAD)
$remoteHead = [string](& git.exe -C $repoRoot rev-parse origin/main)
if (-not $head.Equals($remoteHead, [StringComparison]::OrdinalIgnoreCase)) { throw '本地 main 与 origin/main 不一致。' }

if (-not $SkipBuild) { & (Join-Path $repoRoot 'scripts\Build-Release.ps1') -Version $Version }
$distRoot = Join-Path $repoRoot 'dist'
$assets = @(
    (Join-Path $distRoot ("CodexUsagePet-Setup-v{0}.exe" -f $Version)),
    (Join-Path $distRoot ("CodexUsagePet-portable-v{0}.zip" -f $Version)),
    (Join-Path $distRoot 'SHA256SUMS.txt'),
    (Join-Path $distRoot 'release-manifest.json')
)
foreach ($asset in $assets) { if (-not (Test-Path -LiteralPath $asset)) { throw "缺少发布文件：$asset" } }
$notesPath = Join-Path $repoRoot ("release-notes-v{0}.md" -f $Version)
if (-not (Test-Path -LiteralPath $notesPath)) { throw "缺少发布说明：$notesPath" }
$previousErrorPreference = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$existingRelease = @(& gh.exe release view $tag --repo $repository --json tagName 2>$null)
$releaseViewExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorPreference
if ($releaseViewExitCode -eq 0 -and $existingRelease.Count -gt 0) { throw "GitHub Release $tag 已存在。" }

$existingTag = [string](& git.exe -C $repoRoot tag --list $tag)
if ([string]::IsNullOrWhiteSpace($existingTag)) {
    & git.exe -C $repoRoot tag -a $tag -m ("Codex 用量宠物 {0}" -f $tag)
    if ($LASTEXITCODE -ne 0) { throw '创建版本标签失败。' }
    & git.exe -C $repoRoot push origin $tag
    if ($LASTEXITCODE -ne 0) { throw '推送版本标签失败。' }
} elseif (([string](& git.exe -C $repoRoot rev-list -n 1 $tag)) -ne $head) {
    throw "标签 $tag 没有指向当前 main。"
}

$arguments = @('release','create',$tag,'--repo',$repository,'--verify-tag','--title',("Codex 用量宠物 {0}" -f $tag),'--notes-file',$notesPath)
if ($Draft) { $arguments += '--draft' }
$arguments += $assets
& gh.exe @arguments
if ($LASTEXITCODE -ne 0) { throw '创建 GitHub Release 失败。' }
& gh.exe release view $tag --repo $repository --json name,tagName,isDraft,url,publishedAt
