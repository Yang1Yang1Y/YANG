[CmdletBinding()]
param(
    [switch]$SkipUpdate,
    [switch]$UpdateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$petScript = Join-Path $projectRoot 'CodexUsagePet.ps1'
$releaseUpdaterScript = Join-Path $projectRoot 'Update-CodexUsagePet.ps1'
$settingsPath = Join-Path $projectRoot '.pet-settings.json'
$updateLogPath = Join-Path $projectRoot 'update.log'
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-UpdateLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $updateLogPath -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch {}
}

function Get-AutoUpdateEnabled {
    if ($UpdateOnly) { return $true }
    if (-not (Test-Path -LiteralPath $settingsPath)) { return $true }
    try {
        $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
        $property = $settings.PSObject.Properties['auto_update_enabled']
        if ($null -ne $property -and $null -ne $property.Value) { return [bool]$property.Value }
    } catch {
        Write-UpdateLog ('读取自动更新设置失败，按启用处理：' + $_.Exception.Message)
    }
    return $true
}

function Get-NormalizedPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Invoke-ReleasePetUpdate {
    $result = [pscustomobject]@{ updated = $false; status = 'not_configured'; message = '安装版更新器不存在' }
    if (-not (Test-Path -LiteralPath $releaseUpdaterScript)) { return $result }
    try {
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$releaseUpdaterScript,'-Json')
        if ($UpdateOnly) { $arguments += '-Force' }
        $output = @(& $powerShellExe @arguments 2>&1)
        $jsonLine = [string]($output | Select-Object -Last 1)
        $releaseResult = $jsonLine | ConvertFrom-Json
        return [pscustomobject]@{
            updated = [bool]$releaseResult.updated
            status = [string]$releaseResult.status
            message = [string]$releaseResult.message
        }
    } catch {
        $result.status = 'error'
        $result.message = 'Release 更新检查失败：' + $_.Exception.Message
        return $result
    }
}

function Invoke-SafePetUpdate {
    $result = [pscustomobject]@{ updated = $false; status = 'skipped'; message = '' }
    if ($SkipUpdate -or -not (Get-AutoUpdateEnabled)) {
        $result.message = '自动更新已跳过'
        return $result
    }
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.git'))) {
        return Invoke-ReleasePetUpdate
    }
    if ($null -eq (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        $result.status = 'error'; $result.message = '未安装 Git，无法检查更新'
        return $result
    }

    $gitRootOutput = @(& git.exe -C $projectRoot rev-parse --show-toplevel 2>$null)
    $gitRootExitCode = $LASTEXITCODE
    $gitRoot = [string]($gitRootOutput | Select-Object -First 1)
    if ($gitRootExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($gitRoot)) {
        $result.status = 'not_configured'; $result.message = '助手尚未建立独立 Git 仓库'
        return $result
    }
    if (-not (Get-NormalizedPath $gitRoot).Equals((Get-NormalizedPath $projectRoot), [StringComparison]::OrdinalIgnoreCase)) {
        $result.status = 'not_configured'; $result.message = '检测到的是其他项目仓库，已禁止自动拉取'
        return $result
    }

    $remoteOutput = @(& git.exe -C $projectRoot remote get-url origin 2>$null)
    $remoteExitCode = $LASTEXITCODE
    $remote = [string]($remoteOutput | Select-Object -First 1)
    if ($remoteExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
        $result.status = 'not_configured'; $result.message = '助手仓库尚未连接 GitHub origin'
        return $result
    }

    $branchOutput = @(& git.exe -C $projectRoot branch --show-current 2>$null)
    $branchExitCode = $LASTEXITCODE
    $branch = [string]($branchOutput | Select-Object -First 1)
    if ($branchExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        $result.status = 'error'; $result.message = '无法识别当前更新分支'
        return $result
    }

    $fetchOutput = @(& git.exe -C $projectRoot fetch --quiet origin $branch 2>&1)
    $fetchExitCode = $LASTEXITCODE
    if ($fetchExitCode -ne 0) {
        $result.status = 'error'; $result.message = '连接 GitHub 检查更新失败'
        return $result
    }

    $remoteRef = 'origin/' + $branch
    $behindOutput = @(& git.exe -C $projectRoot rev-list --count ("HEAD..{0}" -f $remoteRef) 2>$null)
    $behindExitCode = $LASTEXITCODE
    $behindText = [string]($behindOutput | Select-Object -First 1)
    if ($behindExitCode -ne 0) {
        $result.status = 'error'; $result.message = '无法比较本地与远程版本'
        return $result
    }
    $behind = 0
    if (-not [int]::TryParse($behindText.Trim(), [ref]$behind)) {
        $result.status = 'error'; $result.message = '远程版本结果无法解析'
        return $result
    }
    if ($behind -le 0) {
        $result.status = 'current'; $result.message = '已经是最新版本'
        return $result
    }

    $trackedChanges = @(& git.exe -C $projectRoot status --porcelain --untracked-files=no 2>$null)
    $statusExitCode = $LASTEXITCODE
    if ($statusExitCode -ne 0) {
        $result.status = 'error'; $result.message = '无法检查本地文件状态'
        return $result
    }
    if ($trackedChanges.Count -gt 0) {
        $result.status = 'local_changes'; $result.message = '检测到未提交的本地修改，为防止覆盖已跳过更新'
        return $result
    }

    $oldRevisionOutput = @(& git.exe -C $projectRoot rev-parse --short HEAD 2>$null)
    $oldRevision = [string]($oldRevisionOutput | Select-Object -First 1)
    $mergeOutput = @(& git.exe -C $projectRoot merge --ff-only $remoteRef 2>&1)
    $mergeExitCode = $LASTEXITCODE
    if ($mergeExitCode -ne 0) {
        $result.status = 'error'; $result.message = '更新无法快进合并：' + ($mergeOutput -join ' ')
        return $result
    }
    $newRevisionOutput = @(& git.exe -C $projectRoot rev-parse --short HEAD 2>$null)
    $newRevision = [string]($newRevisionOutput | Select-Object -First 1)
    $result.updated = $true
    $result.status = 'updated'
    $result.message = "已自动更新 $oldRevision → $newRevision"
    return $result
}

function Stop-RunningPetInstances {
    try {
        $resolvedPetScript = (Get-NormalizedPath $petScript)
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -ne $PID -and $_.Name -in @('powershell.exe', 'pwsh.exe') -and
            -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
            $_.CommandLine.IndexOf($resolvedPetScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        foreach ($process in $processes) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 500 }
    } catch {
        Write-UpdateLog ('关闭旧版本失败：' + $_.Exception.Message)
    }
}

function Start-PetApplication {
    if (-not (Test-Path -LiteralPath $petScript)) { throw "找不到程序：$petScript" }
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$petScript`""
    Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden
}

try {
    $updateResult = Invoke-SafePetUpdate
    Write-UpdateLog $updateResult.message
    if ($updateResult.updated) {
        Stop-RunningPetInstances
        Start-PetApplication
    } elseif (-not $UpdateOnly) {
        Start-PetApplication
    }
} catch {
    Write-UpdateLog ('更新启动器异常：' + $_.Exception.Message)
    if (-not $UpdateOnly) {
        try { Start-PetApplication } catch { Write-UpdateLog ('启动助手失败：' + $_.Exception.Message) }
    }
}
