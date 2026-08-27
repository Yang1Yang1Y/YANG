[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$AccountSnapshotWorker,
    [string]$AccountSnapshotResultPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-UsageBucket {
    return @{
        input_tokens = [int64]0
        cached_input_tokens = [int64]0
        cache_write_input_tokens = [int64]0
        output_tokens = [int64]0
        reasoning_output_tokens = [int64]0
        total_tokens = [int64]0
    }
}

function Copy-UsageBucket {
    param($Source)
    $copy = New-UsageBucket
    if ($null -eq $Source) { return $copy }
    foreach ($key in @($copy.Keys)) {
        if ($null -ne $Source.PSObject.Properties[$key]) {
            $copy[$key] = [int64]$Source.$key
        } elseif ($Source -is [hashtable] -and $Source.ContainsKey($key)) {
            $copy[$key] = [int64]$Source[$key]
        }
    }
    return $copy
}

function Subtract-UsageBucket {
    param($Current, $Baseline)
    $result = New-UsageBucket
    foreach ($key in @($result.Keys)) {
        $value = [int64]$Current[$key] - [int64]$Baseline[$key]
        $result[$key] = [Math]::Max([int64]0, $value)
    }
    return $result
}

function Add-UsageBucket {
    param($Target, $Source)
    foreach ($key in @($Target.Keys)) {
        $Target[$key] = [int64]$Target[$key] + [int64]$Source[$key]
    }
}

function Convert-UsageObject {
    param($UsageObject)
    $bucket = New-UsageBucket
    if ($null -eq $UsageObject) { return $bucket }
    foreach ($key in @($bucket.Keys)) {
        $property = $UsageObject.PSObject.Properties[$key]
        if ($null -ne $property -and $null -ne $property.Value) {
            $bucket[$key] = [int64]$property.Value
        }
    }
    return $bucket
}

function New-SessionState {
    param([string]$Path)
    return [pscustomobject]@{
        Path = $Path
        Offset = [int64]0
        Current = New-UsageBucket
        HistoryLast = New-UsageBucket
        Baseline = New-UsageBucket
        TodayLast = New-UsageBucket
        LastCall = New-UsageBucket
        HasTodayEvent = $false
        LastEventAt = [DateTimeOffset]::MinValue
        LastTokenAt = [DateTimeOffset]::MinValue
        TaskActive = $false
        TaskStart = New-UsageBucket
        LastTask = New-UsageBucket
        TaskStartedAt = [DateTimeOffset]::MinValue
        SessionId = ''
        Model = ''
        ProjectPath = ''
        ProjectName = '未识别项目'
        RateLimit = $null
        RateLimitAt = [DateTimeOffset]::MinValue
    }
}

$script:projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:petScriptPath = $MyInvocation.MyCommand.Path
$script:launcherScriptPath = Join-Path $script:projectRoot 'Start-CodexUsagePet.ps1'
$script:releaseUpdaterPath = Join-Path $script:projectRoot 'Update-CodexUsagePet.ps1'
$script:versionInfoPath = Join-Path $script:projectRoot 'version.json'
$script:appVersion = '3.2.0'
try {
    if (Test-Path -LiteralPath $script:versionInfoPath) {
        $versionInfo = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:versionInfoPath | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$versionInfo.version)) {
            $script:appVersion = [string]$versionInfo.version
        }
    }
} catch {}
$script:runtimeLogPath = Join-Path $script:projectRoot 'runtime-error.log'
trap {
    try {
        $detail = "[{0}] {1}`r`n{2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message, ($_ | Out-String)
        Add-Content -LiteralPath $script:runtimeLogPath -Value $detail -Encoding UTF8
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(
            "Codex 用量宠物发生错误。`r`n`r`n$($_.Exception.Message)`r`n`r`n错误日志：$script:runtimeLogPath",
            'Codex 用量宠物',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } catch {}
    exit 1
}
$script:codexDataRoot = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE '.codex'
} else {
    $env:CODEX_HOME
}
$script:sessionsRoot = Join-Path $script:codexDataRoot 'sessions'
$script:codexGlobalStatePath = Join-Path $script:codexDataRoot '.codex-global-state.json'
$script:historyCachePath = Join-Path $script:projectRoot '.usage-history-cache.json'
$script:projectLifetimeCachePath = Join-Path $script:projectRoot '.project-lifetime-cache.json'
$script:projectLifetimeEntries = @{}
$script:codexProjectNames = @{}
$script:codexProjectPaths = @{}
$script:threadProjectIds = @{}
$script:threadDescriptions = @{}
$script:codexUnreadThreadIds = @{}
$script:codexUnreadStateAvailable = $false
$script:unreadCompletedProjects = @{}
$script:projectMetadataLastWriteTicks = [int64]0
$script:sessionStates = @{}
$script:dailyHistory = @{}
$script:historyLoaded = $false
$script:dayStart = [DateTimeOffset]::Now.Date
$script:lastSamplePath = ''
$script:lastSampleTotal = [int64]0
$script:lastSampleAt = [DateTimeOffset]::Now
$script:lastMetrics = $null
$script:accountRateLimit = $null
$script:accountRateLimitAt = [DateTimeOffset]::MinValue
$script:accountRefreshLastAttempt = [DateTimeOffset]::MinValue
$script:accountRefreshIntervalSeconds = 60
$script:accountRefreshLastSucceeded = $false
$script:accountRefreshLastError = ''
$script:accountHelperSourcePath = ''
$script:accountRefreshProcess = $null
$script:accountRefreshResultPath = ''
$script:manualAccountRefreshPending = $false
$script:statusOverrideText = ''
$script:statusOverrideUntil = [DateTimeOffset]::MinValue

function Process-CodexRecord {
    param($State, [string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $record = $Line | ConvertFrom-Json } catch { return }
    if ($null -eq $record.timestamp) { return }
    try { $stamp = [DateTimeOffset]::Parse([string]$record.timestamp).ToLocalTime() } catch { return }
    if ($stamp -gt $State.LastEventAt) { $State.LastEventAt = $stamp }

    if ($record.type -in @('session_meta','turn_context')) {
        if ($record.type -eq 'session_meta') {
            $sessionIdProperty = $record.payload.PSObject.Properties['session_id']
            if ($null -eq $sessionIdProperty) { $sessionIdProperty = $record.payload.PSObject.Properties['id'] }
            if ($null -ne $sessionIdProperty -and -not [string]::IsNullOrWhiteSpace([string]$sessionIdProperty.Value)) {
                $State.SessionId = [string]$sessionIdProperty.Value
            }
        }
        $cwdProperty = $record.payload.PSObject.Properties['cwd']
        if ($null -ne $cwdProperty -and -not [string]::IsNullOrWhiteSpace([string]$cwdProperty.Value)) {
            $State.ProjectPath = [string]$cwdProperty.Value
            $trimmedPath = $State.ProjectPath.TrimEnd([char[]]@('\','/'))
            $leafName = [System.IO.Path]::GetFileName($trimmedPath)
            $State.ProjectName = if ([string]::IsNullOrWhiteSpace($leafName)) { $trimmedPath } else { $leafName }
        }
        $modelProperty = $record.payload.PSObject.Properties['model']
        if ($null -ne $modelProperty -and $null -ne $modelProperty.Value) { $State.Model = [string]$modelProperty.Value }
        return
    }
    if ($record.type -ne 'event_msg' -or $null -eq $record.payload.type) { return }

    switch ([string]$record.payload.type) {
        'token_count' {
            if ($null -eq $record.payload.info -or $null -eq $record.payload.info.total_token_usage) { return }
            $usage = Convert-UsageObject $record.payload.info.total_token_usage
            $historyDelta = Subtract-UsageBucket $usage $State.HistoryLast
            $historyKey = $stamp.ToString('yyyy-MM-dd')
            if (-not $script:dailyHistory.ContainsKey($historyKey)) {
                $script:dailyHistory[$historyKey] = New-UsageBucket
            }
            Add-UsageBucket $script:dailyHistory[$historyKey] $historyDelta
            $State.HistoryLast = Copy-UsageBucket $usage
            $State.Current = $usage
            if ($null -ne $record.payload.info.last_token_usage) {
                $State.LastCall = Convert-UsageObject $record.payload.info.last_token_usage
            }
            $State.LastTokenAt = $stamp

            if ($stamp -lt $script:dayStart) {
                $State.Baseline = Copy-UsageBucket $usage
            } else {
                $State.TodayLast = Copy-UsageBucket $usage
                $State.HasTodayEvent = $true
            }

            if ($null -ne $record.payload.rate_limits -and $null -ne $record.payload.rate_limits.primary) {
                $primary = $record.payload.rate_limits.primary
                $secondary = $record.payload.rate_limits.secondary
                $State.RateLimit = [pscustomobject]@{
                    used_percent = [double]$primary.used_percent
                    window_minutes = [int64]$primary.window_minutes
                    resets_at = [int64]$primary.resets_at
                    secondary_used_percent = if ($null -ne $secondary) { [double]$secondary.used_percent } else { $null }
                    secondary_window_minutes = if ($null -ne $secondary) { [int64]$secondary.window_minutes } else { $null }
                    secondary_resets_at = if ($null -ne $secondary) { [int64]$secondary.resets_at } else { $null }
                    plan_type = [string]$record.payload.rate_limits.plan_type
                    limit_id = [string]$record.payload.rate_limits.limit_id
                }
                $State.RateLimitAt = $stamp
            }
        }
        'task_started' {
            $State.TaskActive = $true
            $State.TaskStart = Copy-UsageBucket $State.Current
            $State.TaskStartedAt = $stamp
        }
        'task_complete' {
            $State.LastTask = Subtract-UsageBucket $State.Current $State.TaskStart
            $State.TaskActive = $false
        }
        'turn_aborted' {
            $State.LastTask = Subtract-UsageBucket $State.Current $State.TaskStart
            $State.TaskActive = $false
        }
    }
}

function Read-SessionGrowth {
    param($State)

    try {
        $fileInfo = Get-Item -LiteralPath $State.Path -ErrorAction Stop
        if ($fileInfo.Length -lt $State.Offset) {
            $State.Offset = [int64]0
        }
        if ($fileInfo.Length -eq $State.Offset) { return }

        $stream = [System.IO.File]::Open(
            $State.Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            [void]$stream.Seek($State.Offset, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 65536, $true)
            try {
                while (($line = $reader.ReadLine()) -ne $null) {
                    Process-CodexRecord $State $line
                }
            } finally {
                $reader.Dispose()
            }
            $State.Offset = $stream.Length
        } finally {
            $stream.Dispose()
        }
    } catch {
        # Codex may rotate or briefly lock a log. The next refresh retries it.
    }
}

function Format-TokenCount {
    param([int64]$Value)
    if ($Value -ge 100000000) { return ('{0:0.00}亿' -f ($Value / 100000000.0)) }
    if ($Value -ge 10000) { return ('{0:0.00}万' -f ($Value / 10000.0)) }
    return $Value.ToString('N0')
}

function Get-WindowLabel {
    param([int64]$Minutes)
    if ($Minutes -ge 10080) { return ('{0:0.#} 天' -f ($Minutes / 1440.0)) }
    if ($Minutes -ge 60) { return ('{0:0.#} 小时' -f ($Minutes / 60.0)) }
    return "$Minutes 分钟"
}

function Get-ResetLabel {
    param([int64]$UnixSeconds)
    if ($UnixSeconds -le 0) { return '重置时间未知' }
    $resetAt = [DateTimeOffset]::FromUnixTimeSeconds($UnixSeconds).ToLocalTime()
    $remaining = $resetAt - [DateTimeOffset]::Now
    if ($remaining.TotalSeconds -le 0) { return '额度即将刷新' }
    if ($remaining.TotalDays -ge 1) {
        return ('{0}天 {1}小时后重置' -f [Math]::Floor($remaining.TotalDays), $remaining.Hours)
    }
    if ($remaining.TotalHours -ge 1) {
        return ('{0}小时 {1}分钟后重置' -f [Math]::Floor($remaining.TotalHours), $remaining.Minutes)
    }
    return ('{0}分钟后重置' -f [Math]::Max(1, [Math]::Floor($remaining.TotalMinutes)))
}

function Get-DailyHistoryArray {
    param([int]$Days = 42)
    $items = @()
    for ($offset = $Days - 1; $offset -ge 0; $offset--) {
        $date = [DateTime]::Today.AddDays(-$offset)
        $key = $date.ToString('yyyy-MM-dd')
        $usage = if ($script:dailyHistory.ContainsKey($key)) { $script:dailyHistory[$key] } else { New-UsageBucket }
        $items += [pscustomobject]@{
            date = $key
            label = $date.ToString('M/d')
            weekday = @('日','一','二','三','四','五','六')[[int]$date.DayOfWeek]
            total_tokens = [int64]$usage.total_tokens
            input_tokens = [int64]$usage.input_tokens
            cached_input_tokens = [int64]$usage.cached_input_tokens
            output_tokens = [int64]$usage.output_tokens
        }
    }
    return @($items)
}

function Get-WeeklyHistoryArray {
    param([int]$Weeks = 8)
    $today = [DateTime]::Today
    $daysFromMonday = (([int]$today.DayOfWeek + 6) % 7)
    $currentWeekStart = $today.AddDays(-$daysFromMonday)
    $items = @()
    for ($offset = $Weeks - 1; $offset -ge 0; $offset--) {
        $weekStart = $currentWeekStart.AddDays(-7 * $offset)
        $usage = New-UsageBucket
        for ($day = 0; $day -lt 7; $day++) {
            $key = $weekStart.AddDays($day).ToString('yyyy-MM-dd')
            if ($script:dailyHistory.ContainsKey($key)) { Add-UsageBucket $usage $script:dailyHistory[$key] }
        }
        $items += [pscustomobject]@{
            week_start = $weekStart.ToString('yyyy-MM-dd')
            label = $weekStart.ToString('M/d')
            total_tokens = [int64]$usage.total_tokens
            input_tokens = [int64]$usage.input_tokens
            cached_input_tokens = [int64]$usage.cached_input_tokens
            output_tokens = [int64]$usage.output_tokens
        }
    }
    return @($items)
}

function Get-ArchiveFiles {
    if (-not (Test-Path -LiteralPath $script:sessionsRoot)) { return @() }
    $archiveStart = $script:dayStart.AddDays(-60)
    $recentCutoff = $script:dayStart.AddDays(-1)
    return @(Get-ChildItem -LiteralPath $script:sessionsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $archiveStart -and $_.LastWriteTime -lt $recentCutoff } |
        Sort-Object LastWriteTime)
}

function Get-ArchiveSignature {
    param($Files)
    $count = @($Files).Count
    $length = [int64]0
    $latestTicks = [int64]0
    foreach ($file in @($Files)) {
        $length += [int64]$file.Length
        if ($file.LastWriteTimeUtc.Ticks -gt $latestTicks) { $latestTicks = $file.LastWriteTimeUtc.Ticks }
    }
    return "$count|$length|$latestTicks"
}

function Load-HistoryCache {
    if (-not (Test-Path -LiteralPath $script:historyCachePath)) { return }
    try {
        $files = Get-ArchiveFiles
        $cache = Get-Content -Raw -LiteralPath $script:historyCachePath | ConvertFrom-Json
        if ([string]$cache.signature -ne (Get-ArchiveSignature $files)) { return }
        foreach ($item in @($cache.days)) {
            $bucket = New-UsageBucket
            foreach ($key in @($bucket.Keys)) {
                $property = $item.PSObject.Properties[$key]
                if ($null -ne $property) { $bucket[$key] = [int64]$property.Value }
            }
            $script:dailyHistory[[string]$item.date] = $bucket
        }
        $script:historyLoaded = $true
    } catch {}
}

function Save-HistoryCache {
    param($Files)
    try {
        $recentCutoffKey = $script:dayStart.AddDays(-1).ToString('yyyy-MM-dd')
        $days = @()
        foreach ($key in @($script:dailyHistory.Keys | Sort-Object)) {
            if ($key -ge $recentCutoffKey) { continue }
            $usage = $script:dailyHistory[$key]
            $days += [pscustomobject]@{
                date = $key
                input_tokens = [int64]$usage.input_tokens
                cached_input_tokens = [int64]$usage.cached_input_tokens
                cache_write_input_tokens = [int64]$usage.cache_write_input_tokens
                output_tokens = [int64]$usage.output_tokens
                reasoning_output_tokens = [int64]$usage.reasoning_output_tokens
                total_tokens = [int64]$usage.total_tokens
            }
        }
        [pscustomobject]@{
            signature = Get-ArchiveSignature $Files
            generated_at = (Get-Date).ToString('s')
            days = $days
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:historyCachePath -Encoding UTF8
    } catch {}
}

function Ensure-HistoryLoaded {
    if ($script:historyLoaded -or -not (Test-Path -LiteralPath $script:sessionsRoot)) { return }
    $archiveFiles = Get-ArchiveFiles
    foreach ($file in $archiveFiles) {
        if (-not $script:sessionStates.ContainsKey($file.FullName)) {
            $script:sessionStates[$file.FullName] = New-SessionState $file.FullName
            Read-SessionGrowth $script:sessionStates[$file.FullName]
        }
    }
    $script:historyLoaded = $true
    Save-HistoryCache $archiveFiles
}

function Update-CodexProjectMetadata {
    if (-not (Test-Path -LiteralPath $script:codexGlobalStatePath)) { return }
    try {
        $stateFile = Get-Item -LiteralPath $script:codexGlobalStatePath
        $writeTicks = [int64]$stateFile.LastWriteTimeUtc.Ticks
        if ($writeTicks -eq $script:projectMetadataLastWriteTicks) { return }

        # Windows PowerShell 5.1 对无 BOM 文件的默认编码不是 UTF-8。Codex 状态文件含中文，必须显式指定 UTF-8。
        $globalState = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:codexGlobalStatePath | ConvertFrom-Json
        $projectNames = @{}
        $projectPaths = @{}
        $assignments = @{}
        $threadDescriptions = @{}
        $unreadThreadIds = @{}
        $unreadStateAvailable = $false

        $localProjectsProperty = $globalState.PSObject.Properties['local-projects']
        if ($null -ne $localProjectsProperty -and $null -ne $localProjectsProperty.Value) {
            foreach ($property in @($localProjectsProperty.Value.PSObject.Properties)) {
                $projectId = [string]$property.Name
                $project = $property.Value
                $nameProperty = $project.PSObject.Properties['name']
                if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
                    $projectNames[$projectId] = [string]$nameProperty.Value
                }
                $rootsProperty = $project.PSObject.Properties['rootPaths']
                if ($null -ne $rootsProperty -and @($rootsProperty.Value).Count -gt 0) {
                    $projectPaths[$projectId] = [string]@($rootsProperty.Value)[0]
                }
            }
        }

        $assignmentProperty = $globalState.PSObject.Properties['thread-project-assignments']
        if ($null -ne $assignmentProperty -and $null -ne $assignmentProperty.Value) {
            foreach ($property in @($assignmentProperty.Value.PSObject.Properties)) {
                $projectIdProperty = $property.Value.PSObject.Properties['projectId']
                if ($null -ne $projectIdProperty -and -not [string]::IsNullOrWhiteSpace([string]$projectIdProperty.Value)) {
                    $assignments[[string]$property.Name] = [string]$projectIdProperty.Value
                }
            }
        }

        $persistedProperty = $globalState.PSObject.Properties['electron-persisted-atom-state']
        if ($null -ne $persistedProperty -and $null -ne $persistedProperty.Value) {
            $descriptionsProperty = $persistedProperty.Value.PSObject.Properties['thread-descriptions-v1']
            if ($null -ne $descriptionsProperty -and $null -ne $descriptionsProperty.Value) {
                foreach ($descriptionProperty in @($descriptionsProperty.Value.PSObject.Properties)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$descriptionProperty.Value)) {
                        $threadDescriptions[[string]$descriptionProperty.Name] = [string]$descriptionProperty.Value
                    }
                }
            }
            $unreadProperty = $persistedProperty.Value.PSObject.Properties['unread-thread-ids-by-host-v1']
            if ($null -ne $unreadProperty -and $null -ne $unreadProperty.Value) {
                $unreadStateAvailable = $true
                foreach ($hostProperty in @($unreadProperty.Value.PSObject.Properties)) {
                    foreach ($threadId in @($hostProperty.Value)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$threadId)) { $unreadThreadIds[[string]$threadId] = $true }
                    }
                }
            }
        }

        $script:codexProjectNames = $projectNames
        $script:codexProjectPaths = $projectPaths
        $script:threadProjectIds = $assignments
        $script:threadDescriptions = $threadDescriptions
        $script:codexUnreadThreadIds = $unreadThreadIds
        $script:codexUnreadStateAvailable = $unreadStateAvailable
        if ($unreadStateAvailable) {
            $staleUnreadProjectKeys = @()
            foreach ($entry in @($script:unreadCompletedProjects.GetEnumerator())) {
                $sessionId = [string]$entry.Value.session_id
                if (-not [string]::IsNullOrWhiteSpace($sessionId) -and -not $unreadThreadIds.ContainsKey($sessionId)) {
                    $staleUnreadProjectKeys += [string]$entry.Key
                }
            }
            foreach ($projectKey in $staleUnreadProjectKeys) { [void]$script:unreadCompletedProjects.Remove($projectKey) }
        }
        $script:projectMetadataLastWriteTicks = $writeTicks
    } catch {
        # Codex 更新状态文件时可能短暂被占用，保留旧映射并在下次刷新重试。
    }
}

function Get-SessionIdFromPath {
    param([string]$SessionPath)
    if ($SessionPath -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$') {
        return [string]$Matches[1]
    }
    return ''
}

function Resolve-ProjectIdentity {
    param([string]$ProjectPath, [string]$SessionPath, [string]$SessionId, [string]$FallbackName)

    if ([string]::IsNullOrWhiteSpace($SessionId)) { $SessionId = Get-SessionIdFromPath $SessionPath }
    $projectId = if (-not [string]::IsNullOrWhiteSpace($SessionId) -and $script:threadProjectIds.ContainsKey($SessionId)) {
        [string]$script:threadProjectIds[$SessionId]
    } else { '' }

    $resolvedName = $FallbackName
    $resolvedPath = $ProjectPath
    if (-not [string]::IsNullOrWhiteSpace($projectId)) {
        if ($script:codexProjectNames.ContainsKey($projectId)) { $resolvedName = [string]$script:codexProjectNames[$projectId] }
        if ($script:codexProjectPaths.ContainsKey($projectId)) { $resolvedPath = [string]$script:codexProjectPaths[$projectId] }
    }
    $projectKey = if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
        'project:' + $resolvedPath.TrimEnd([char[]]@('\','/')).ToLowerInvariant()
    } elseif (-not [string]::IsNullOrWhiteSpace($projectId)) {
        'codex-project:' + $projectId.ToLowerInvariant()
    } else {
        'session:' + $SessionPath.ToLowerInvariant()
    }
    if ([string]::IsNullOrWhiteSpace($resolvedName)) { $resolvedName = '未识别项目' }

    return [pscustomobject]@{
        project_id = $projectId
        project_key = $projectKey
        project_name = $resolvedName
        project_path = $resolvedPath
        session_id = $SessionId
    }
}

function Get-ProjectKeyValue {
    param([string]$ProjectPath, [string]$SessionPath, [string]$SessionId = '')
    return (Resolve-ProjectIdentity $ProjectPath $SessionPath $SessionId '').project_key
}

function Read-SessionLifetimeSummary {
    param($FileInfo)
    $sessionId = Get-SessionIdFromPath $FileInfo.FullName
    $projectPath = ''
    $projectName = '未识别项目'
    $usage = New-UsageBucket
    $stream = [System.IO.File]::Open($FileInfo.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 65536, $true)
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $record = $line | ConvertFrom-Json } catch { continue }
                if ($record.type -in @('session_meta','turn_context')) {
                    if ($record.type -eq 'session_meta') {
                        $sessionIdProperty = $record.payload.PSObject.Properties['session_id']
                        if ($null -eq $sessionIdProperty) { $sessionIdProperty = $record.payload.PSObject.Properties['id'] }
                        if ($null -ne $sessionIdProperty -and -not [string]::IsNullOrWhiteSpace([string]$sessionIdProperty.Value)) {
                            $sessionId = [string]$sessionIdProperty.Value
                        }
                    }
                    $cwdProperty = $record.payload.PSObject.Properties['cwd']
                    if ($null -ne $cwdProperty -and -not [string]::IsNullOrWhiteSpace([string]$cwdProperty.Value)) {
                        $projectPath = [string]$cwdProperty.Value
                        $trimmedPath = $projectPath.TrimEnd([char[]]@('\','/'))
                        $leafName = [System.IO.Path]::GetFileName($trimmedPath)
                        $projectName = if ([string]::IsNullOrWhiteSpace($leafName)) { $trimmedPath } else { $leafName }
                    }
                } elseif ($record.type -eq 'event_msg' -and $record.payload.type -eq 'token_count' -and $null -ne $record.payload.info.total_token_usage) {
                    $usage = Convert-UsageObject $record.payload.info.total_token_usage
                }
            }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    $identity = Resolve-ProjectIdentity $projectPath $FileInfo.FullName $sessionId $projectName
    return [pscustomobject]@{
        path = [string]$FileInfo.FullName
        length = [int64]$FileInfo.Length
        modified_ticks = [int64]$FileInfo.LastWriteTimeUtc.Ticks
        session_id = [string]$identity.session_id
        project_key = [string]$identity.project_key
        project_name = [string]$identity.project_name
        project_path = [string]$identity.project_path
        usage = $usage
    }
}

function Sync-ProjectLifetimeCache {
    Update-CodexProjectMetadata
    if ($script:projectLifetimeEntries.Count -eq 0 -and (Test-Path -LiteralPath $script:projectLifetimeCachePath)) {
        try {
            $cache = Get-Content -Raw -LiteralPath $script:projectLifetimeCachePath | ConvertFrom-Json
            foreach ($entry in @($cache.files)) {
                $script:projectLifetimeEntries[[string]$entry.path] = [pscustomobject]@{
                    path = [string]$entry.path
                    length = [int64]$entry.length
                    modified_ticks = [int64]$entry.modified_ticks
                    session_id = if ($null -ne $entry.PSObject.Properties['session_id']) { [string]$entry.session_id } else { Get-SessionIdFromPath ([string]$entry.path) }
                    project_key = [string]$entry.project_key
                    project_name = [string]$entry.project_name
                    project_path = [string]$entry.project_path
                    usage = Convert-UsageObject $entry.usage
                }
            }
        } catch { $script:projectLifetimeEntries = @{} }
    }

    $changed = $false
    $livePaths = @{}
    $files = @(Get-ChildItem -LiteralPath $script:sessionsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        $livePaths[$file.FullName] = $true
        if ($script:sessionStates.ContainsKey($file.FullName)) {
            $state = $script:sessionStates[$file.FullName]
            $identity = Resolve-ProjectIdentity ([string]$state.ProjectPath) $file.FullName ([string]$state.SessionId) ([string]$state.ProjectName)
            $liveEntry = [pscustomobject]@{
                path = [string]$file.FullName
                length = [int64]$file.Length
                modified_ticks = [int64]$file.LastWriteTimeUtc.Ticks
                session_id = [string]$identity.session_id
                project_key = [string]$identity.project_key
                project_name = [string]$identity.project_name
                project_path = [string]$identity.project_path
                usage = Copy-UsageBucket $state.Current
            }
            $cached = if ($script:projectLifetimeEntries.ContainsKey($file.FullName)) { $script:projectLifetimeEntries[$file.FullName] } else { $null }
            $entryChanged = $null -eq $cached -or
                [int64]$cached.length -ne [int64]$liveEntry.length -or
                [int64]$cached.modified_ticks -ne [int64]$liveEntry.modified_ticks -or
                [string]$cached.project_key -ne [string]$liveEntry.project_key -or
                [string]$cached.project_name -ne [string]$liveEntry.project_name -or
                [string]$cached.project_path -ne [string]$liveEntry.project_path -or
                [int64]$cached.usage.total_tokens -ne [int64]$liveEntry.usage.total_tokens
            if ($entryChanged) {
                $script:projectLifetimeEntries[$file.FullName] = $liveEntry
                $changed = $true
            }
            continue
        }
        $cached = if ($script:projectLifetimeEntries.ContainsKey($file.FullName)) { $script:projectLifetimeEntries[$file.FullName] } else { $null }
        if ($null -ne $cached -and [int64]$cached.length -eq [int64]$file.Length -and [int64]$cached.modified_ticks -eq [int64]$file.LastWriteTimeUtc.Ticks) {
            $identity = Resolve-ProjectIdentity ([string]$cached.project_path) $file.FullName ([string]$cached.session_id) ([string]$cached.project_name)
            if ([string]$cached.project_key -ne [string]$identity.project_key -or
                [string]$cached.project_name -ne [string]$identity.project_name -or
                [string]$cached.project_path -ne [string]$identity.project_path) {
                $cached.session_id = [string]$identity.session_id
                $cached.project_key = [string]$identity.project_key
                $cached.project_name = [string]$identity.project_name
                $cached.project_path = [string]$identity.project_path
                $changed = $true
            }
            continue
        }
        $script:projectLifetimeEntries[$file.FullName] = Read-SessionLifetimeSummary $file
        $changed = $true
    }
    foreach ($path in @($script:projectLifetimeEntries.Keys)) {
        if (-not $livePaths.ContainsKey($path)) {
            [void]$script:projectLifetimeEntries.Remove($path)
            $changed = $true
        }
    }

    if ($changed) {
        try {
            $cacheFiles = @($script:projectLifetimeEntries.Values | ForEach-Object {
                [pscustomobject]@{
                    path = $_.path
                    length = $_.length
                    modified_ticks = $_.modified_ticks
                    session_id = $_.session_id
                    project_key = $_.project_key
                    project_name = $_.project_name
                    project_path = $_.project_path
                    usage = [pscustomobject](Copy-UsageBucket $_.usage)
                }
            })
            [pscustomobject]@{ generated_at = (Get-Date).ToString('s'); files = $cacheFiles } |
                ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $script:projectLifetimeCachePath -Encoding UTF8
        } catch {}
    }
}

function Get-ProjectLifetimeUsage {
    param([string]$ProjectKey)
    Sync-ProjectLifetimeCache
    $total = New-UsageBucket
    foreach ($entry in @($script:projectLifetimeEntries.Values | Where-Object { $_.project_key -eq $ProjectKey })) {
        Add-UsageBucket $total $entry.usage
    }
    return [pscustomobject]$total
}

function Get-AllProjectLifetimeTotals {
    Sync-ProjectLifetimeCache
    $totals = @{}
    foreach ($entry in @($script:projectLifetimeEntries.Values)) {
        $projectKey = [string]$entry.project_key
        if ([string]::IsNullOrWhiteSpace($projectKey)) { continue }
        if (-not $totals.ContainsKey($projectKey)) { $totals[$projectKey] = New-UsageBucket }
        Add-UsageBucket $totals[$projectKey] $entry.usage
    }
    return $totals
}

function Get-ProjectLifetimeRanking {
    param($Totals)
    $metadata = @{}
    foreach ($entry in @($script:projectLifetimeEntries.Values)) {
        $key = [string]$entry.project_key
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if (-not $metadata.ContainsKey($key) -or [int64]$entry.modified_ticks -gt [int64]$metadata[$key].modified_ticks) {
            $metadata[$key] = $entry
        }
    }
    $grandTotal = [int64]0
    foreach ($bucket in @($Totals.Values)) { $grandTotal += [int64]$bucket.total_tokens }
    $ranking = @()
    foreach ($key in @($Totals.Keys)) {
        $entry = if ($metadata.ContainsKey($key)) { $metadata[$key] } else { $null }
        $total = [int64]$Totals[$key].total_tokens
        $sessionId = ''
        if ($null -ne $entry -and $null -ne $entry.PSObject.Properties['session_id']) { $sessionId = [string]$entry.session_id }
        $ranking += [pscustomobject]@{
            project_key = [string]$key
            project_name = if ($null -ne $entry) { [string]$entry.project_name } else { '未识别项目' }
            project_path = if ($null -ne $entry) { [string]$entry.project_path } else { '' }
            session_id = $sessionId
            total_tokens = $total
            share_percent = if ($grandTotal -gt 0) { [Math]::Round(100.0 * $total / $grandTotal, 2) } else { 0.0 }
        }
    }
    return @($ranking | Sort-Object -Property @{ Expression = { [int64]$_.total_tokens }; Descending = $true })
}

function Find-CodexAccountExecutable {
    $candidates = New-Object System.Collections.ArrayList
    try {
        foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)) {
            $packageExecutable = Join-Path ([string]$package.InstallLocation) 'app\resources\codex.exe'
            if (Test-Path -LiteralPath $packageExecutable) { [void]$candidates.Add($packageExecutable) }
        }
    } catch {}
    try {
        $windowsAppsRoot = Join-Path $env:ProgramFiles 'WindowsApps'
        foreach ($packageRoot in @(Get-ChildItem -LiteralPath $windowsAppsRoot -Directory -Filter 'OpenAI.Codex_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
            $packageExecutable = Join-Path $packageRoot.FullName 'app\resources\codex.exe'
            if (Test-Path -LiteralPath $packageExecutable) { [void]$candidates.Add($packageExecutable) }
        }
    } catch {}
    try {
        foreach ($command in @(Get-Command codex.exe -All -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
                [void]$candidates.Add([string]$command.Source)
            }
        }
    } catch {}
    try {
        foreach ($process in @(Get-Process -Name 'codex' -ErrorAction SilentlyContinue)) {
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) {
                    [void]$candidates.Add([string]$process.Path)
                }
            } catch {}
        }
    } catch {}
    foreach ($candidate in @($candidates)) {
        if ((Test-Path -LiteralPath $candidate) -and [System.IO.Path]::GetExtension($candidate) -ieq '.exe') {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw '未找到 Codex 桌面版自带的账户同步组件，请确认 Codex 已安装。'
}

function Get-CodexAccountHelperPath {
    $sourcePath = Find-CodexAccountExecutable
    $script:accountHelperSourcePath = $sourcePath

    # Microsoft Store apps can be read but cannot be launched directly by a normal
    # PowerShell process. Keep a version-matched user-local copy for the account RPC.
    if ($sourcePath -notlike '*\WindowsApps\*') { return $sourcePath }

    $localRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:TEMP 'CodexUsagePet'
    } else {
        Join-Path $env:LOCALAPPDATA 'CodexUsagePet'
    }
    $helperRoot = Join-Path $localRoot 'account-sync'
    $helperPath = Join-Path $helperRoot 'codex-account-helper.exe'
    $metadataPath = Join-Path $helperRoot 'helper-source.json'
    $sourceInfo = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
    $fingerprint = '{0}|{1}|{2}' -f $sourceInfo.FullName, $sourceInfo.Length, $sourceInfo.LastWriteTimeUtc.Ticks
    $cacheValid = $false

    if ((Test-Path -LiteralPath $helperPath) -and (Test-Path -LiteralPath $metadataPath)) {
        try {
            $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath | ConvertFrom-Json
            $helperInfo = Get-Item -LiteralPath $helperPath -ErrorAction Stop
            $cacheValid = ([string]$metadata.fingerprint -eq $fingerprint -and [int64]$helperInfo.Length -eq [int64]$sourceInfo.Length)
        } catch { $cacheValid = $false }
    }
    if ($cacheValid) { return $helperPath }

    New-Item -ItemType Directory -Path $helperRoot -Force | Out-Null
    $temporaryPath = Join-Path $helperRoot ('codex-account-helper-' + [guid]::NewGuid().ToString('N') + '.tmp.exe')
    Copy-Item -LiteralPath $sourcePath -Destination $temporaryPath -Force
    Move-Item -LiteralPath $temporaryPath -Destination $helperPath -Force
    [pscustomobject]@{
        fingerprint = $fingerprint
        source = $sourceInfo.FullName
        cached_at = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    return $helperPath
}

function Invoke-CodexAccountRequest {
    param([string]$Method)

    $executablePath = Get-CodexAccountHelperPath
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executablePath
    $startInfo.Arguments = 'app-server --stdio'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    try {
        $initializeRequest = @{
            id = 1
            method = 'initialize'
            params = @{
                clientInfo = @{ name = 'codex-usage-pet'; version = $script:appVersion }
                capabilities = @{}
            }
        } | ConvertTo-Json -Compress -Depth 10
        $accountRequest = @{ id = 2; method = $Method; params = $null } | ConvertTo-Json -Compress -Depth 10
        $process.StandardInput.WriteLine($initializeRequest)
        $process.StandardInput.WriteLine($accountRequest)
        $process.StandardInput.Flush()

        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remainingMilliseconds = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $readTask = $process.StandardOutput.ReadLineAsync()
            if (-not $readTask.Wait($remainingMilliseconds)) { break }
            $line = $readTask.Result
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $response = $line | ConvertFrom-Json } catch { continue }
            if ($null -eq $response.PSObject.Properties['id'] -or [int]$response.id -ne 2) { continue }
            if ($null -ne $response.PSObject.Properties['error'] -and $null -ne $response.error) {
                $errorText = if ($null -ne $response.error.PSObject.Properties['message']) { [string]$response.error.message } else { [string]($response.error | ConvertTo-Json -Compress -Depth 5) }
                throw ('Codex 账户接口返回错误：' + $errorText)
            }
            return $response.result
        }
        throw 'Codex 账户同步超时。'
    } finally {
        try { $process.StandardInput.Close() } catch {}
        try { if (-not $process.HasExited) { $process.Kill() } } catch {}
        $process.Dispose()
    }
}

function Update-CodexAccountSnapshot {
    param([switch]$Force)

    $now = [DateTimeOffset]::Now
    if (-not $Force -and ($now - $script:accountRefreshLastAttempt).TotalSeconds -lt $script:accountRefreshIntervalSeconds) {
        return [pscustomobject]@{ attempted = $false; succeeded = $script:accountRefreshLastSucceeded; message = $script:accountRefreshLastError }
    }
    $script:accountRefreshLastAttempt = $now
    try {
        $response = Invoke-CodexAccountRequest 'account/rateLimits/read'
        $snapshot = $null
        if ($null -ne $response.PSObject.Properties['rateLimitsByLimitId'] -and $null -ne $response.rateLimitsByLimitId) {
            $codexProperty = $response.rateLimitsByLimitId.PSObject.Properties['codex']
            if ($null -ne $codexProperty) { $snapshot = $codexProperty.Value }
        }
        if ($null -eq $snapshot -and $null -ne $response.PSObject.Properties['rateLimits']) {
            $snapshot = $response.rateLimits
        }
        if ($null -eq $snapshot -or $null -eq $snapshot.primary) { throw '账户接口没有返回 Codex 主额度窗口。' }
        $primary = $snapshot.primary
        if ($null -eq $primary.resetsAt -or $null -eq $primary.windowDurationMins) { throw '账户额度窗口信息不完整。' }
        $limitIdProperty = $snapshot.PSObject.Properties['limitId']
        $planTypeProperty = $snapshot.PSObject.Properties['planType']
        $script:accountRateLimit = [pscustomobject]@{
            limit_id = if ($null -ne $limitIdProperty -and $null -ne $limitIdProperty.Value) { [string]$limitIdProperty.Value } else { 'codex' }
            used_percent = [double]$primary.usedPercent
            window_minutes = [int64]$primary.windowDurationMins
            resets_at = [int64]$primary.resetsAt
            plan_type = if ($null -ne $planTypeProperty -and $null -ne $planTypeProperty.Value) { [string]$planTypeProperty.Value } else { '' }
        }
        $script:accountRateLimitAt = [DateTimeOffset]::Now
        $script:accountRefreshLastSucceeded = $true
        $script:accountRefreshLastError = ''
        return [pscustomobject]@{ attempted = $true; succeeded = $true; message = '账户额度已同步' }
    } catch {
        $script:accountRefreshLastSucceeded = $false
        $script:accountRefreshLastError = $_.Exception.Message
        return [pscustomobject]@{ attempted = $true; succeeded = $false; message = $_.Exception.Message }
    }
}

function Start-CodexAccountRefresh {
    param([switch]$Force)

    $now = [DateTimeOffset]::Now
    if ($null -ne $script:accountRefreshProcess) { return $false }
    if (-not $Force -and ($now - $script:accountRefreshLastAttempt).TotalSeconds -lt $script:accountRefreshIntervalSeconds) { return $false }

    $resultRoot = Join-Path $env:TEMP 'CodexUsagePet\account-results'
    New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
    $resultPath = Join-Path $resultRoot ('account-' + [guid]::NewGuid().ToString('N') + '.json')
    $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -AccountSnapshotWorker -AccountSnapshotResultPath "{1}"' -f $script:petScriptPath, $resultPath
    try {
        $script:accountRefreshLastAttempt = $now
        $script:accountRefreshLastSucceeded = $false
        $script:accountRefreshLastError = ''
        $script:accountRefreshProcess = Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $script:accountRefreshResultPath = $resultPath
        return $true
    } catch {
        $script:accountRefreshProcess = $null
        $script:accountRefreshResultPath = ''
        $script:accountRefreshLastSucceeded = $false
        $script:accountRefreshLastError = $_.Exception.Message
        return $false
    }
}

function Complete-CodexAccountRefresh {
    if ($null -eq $script:accountRefreshProcess -or -not $script:accountRefreshProcess.HasExited) { return $false }

    $resultPath = [string]$script:accountRefreshResultPath
    try {
        if (-not (Test-Path -LiteralPath $resultPath)) { throw '账户同步进程未返回结果。' }
        $result = Get-Content -Raw -Encoding UTF8 -LiteralPath $resultPath | ConvertFrom-Json
        if (-not [bool]$result.succeeded) { throw [string]$result.message }
        $rate = $result.rate_limit
        $script:accountRateLimit = [pscustomobject]@{
            limit_id = [string]$rate.limit_id
            used_percent = [double]$rate.used_percent
            window_minutes = [int64]$rate.window_minutes
            resets_at = [int64]$rate.resets_at
            plan_type = [string]$rate.plan_type
        }
        $script:accountRateLimitAt = [DateTimeOffset]::Parse([string]$result.synced_at).ToLocalTime()
        $script:accountRefreshLastSucceeded = $true
        $script:accountRefreshLastError = ''
        if ($script:manualAccountRefreshPending) {
            $script:statusOverrideText = '已刷新 · 账户额度已同步 ' + (Get-Date -Format 'HH:mm:ss')
            $script:statusOverrideUntil = [DateTimeOffset]::Now.AddSeconds(6)
        }
    } catch {
        $script:accountRefreshLastSucceeded = $false
        $script:accountRefreshLastError = $_.Exception.Message
        if ($script:manualAccountRefreshPending) {
            $script:statusOverrideText = '本机日志已刷新 · 账户同步失败'
            $script:statusOverrideUntil = [DateTimeOffset]::Now.AddSeconds(6)
        }
    } finally {
        try { $script:accountRefreshProcess.Dispose() } catch {}
        $script:accountRefreshProcess = $null
        $script:accountRefreshResultPath = ''
        $script:manualAccountRefreshPending = $false
        if (-not [string]::IsNullOrWhiteSpace($resultPath) -and (Test-Path -LiteralPath $resultPath)) {
            try { Remove-Item -LiteralPath $resultPath -Force } catch {}
        }
    }
    return $true
}

function Get-CodexMetrics {
    param([switch]$ForceAccountSync)

    [void](Complete-CodexAccountRefresh)
    [void](Start-CodexAccountRefresh -Force:$ForceAccountSync)
    $now = [DateTimeOffset]::Now
    Update-CodexProjectMetadata
    if ($now.Date -ne $script:dayStart.Date) {
        $script:dayStart = $now.Date
        $script:sessionStates = @{}
        $script:dailyHistory = @{}
        $script:historyLoaded = $false
        Load-HistoryCache
        $script:lastSamplePath = ''
        $script:lastSampleTotal = 0
        $script:lastSampleAt = $now
    }

    if (-not (Test-Path -LiteralPath $script:sessionsRoot)) {
        return [pscustomobject]@{ available = $false; message = "未找到 Codex 会话目录：$script:sessionsRoot" }
    }

    $scanSince = $script:dayStart.AddDays(-1)
    $files = Get-ChildItem -LiteralPath $script:sessionsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $scanSince } |
        Sort-Object LastWriteTime -Descending

    foreach ($file in $files) {
        if (-not $script:sessionStates.ContainsKey($file.FullName)) {
            $script:sessionStates[$file.FullName] = New-SessionState $file.FullName
        }
        Read-SessionGrowth $script:sessionStates[$file.FullName]
    }

    $states = @($script:sessionStates.Values)
    if ($states.Count -eq 0) {
        return [pscustomobject]@{ available = $false; message = '还没有可读取的 Codex 用量记录' }
    }

    $currentState = $states | Sort-Object LastEventAt -Descending | Select-Object -First 1
    $todayKey = ([DateTime]::Today).ToString('yyyy-MM-dd')
    $today = if ($script:dailyHistory.ContainsKey($todayKey)) { Copy-UsageBucket $script:dailyHistory[$todayKey] } else { New-UsageBucket }

    $nowUnix = $now.ToUnixTimeSeconds()
    $validRateStates = @($states | Where-Object {
        $null -ne $_.RateLimit -and
        [int64]$_.RateLimit.window_minutes -gt 0 -and
        [int64]$_.RateLimit.resets_at -gt $nowUnix -and
        [double]$_.RateLimit.used_percent -ge 0 -and
        [double]$_.RateLimit.used_percent -le 100
    })
    # Model-specific pools (for example Codex Spark) can be written between general
    # Codex records. Prefer the general pool so the main card does not jump between
    # unrelated quota windows merely because another project wrote the newest event.
    $generalRateStates = @($validRateStates | Where-Object { [string]$_.RateLimit.limit_id -eq 'codex' })
    $rateStateCandidates = if ($generalRateStates.Count -gt 0) { $generalRateStates } else { $validRateStates }
    $latestRateState = $rateStateCandidates | Sort-Object RateLimitAt -Descending | Select-Object -First 1
    $rate = if ($null -ne $latestRateState) { $latestRateState.RateLimit } else { $null }
    $quotaSource = if ($null -ne $rate) { 'local_log' } else { 'unavailable' }
    if ($null -ne $script:accountRateLimit -and
        [int64]$script:accountRateLimit.window_minutes -gt 0 -and
        [int64]$script:accountRateLimit.resets_at -gt $nowUnix -and
        [double]$script:accountRateLimit.used_percent -ge 0 -and
        [double]$script:accountRateLimit.used_percent -le 100) {
        $rate = $script:accountRateLimit
        $quotaSource = if ($script:accountRefreshLastSucceeded) { 'account_live' } else { 'account_cached' }
    }
    $remainingPercent = if ($null -ne $rate) { [Math]::Max(0, [Math]::Min(100, 100.0 - [double]$rate.used_percent)) } else { $null }

    $taskUsage = if ($currentState.TaskActive) {
        Subtract-UsageBucket $currentState.Current $currentState.TaskStart
    } else {
        Copy-UsageBucket $currentState.LastTask
    }

    $projectTodayBuckets = @{}
    foreach ($state in $states) {
        $stateIdentity = Resolve-ProjectIdentity ([string]$state.ProjectPath) ([string]$state.Path) ([string]$state.SessionId) ([string]$state.ProjectName)
        $stateProjectKey = [string]$stateIdentity.project_key
        if (-not $projectTodayBuckets.ContainsKey($stateProjectKey)) { $projectTodayBuckets[$stateProjectKey] = New-UsageBucket }
        if ($state.HasTodayEvent) {
            Add-UsageBucket $projectTodayBuckets[$stateProjectKey] (Subtract-UsageBucket $state.TodayLast $state.Baseline)
        }
    }
    $projectLifetimeBuckets = Get-AllProjectLifetimeTotals
    $projectLifetimeRanking = Get-ProjectLifetimeRanking $projectLifetimeBuckets

    $projects = @()
    $seenProjectKeys = @{}
    foreach ($state in @($states | Where-Object { $_.LastEventAt -ge $scanSince } | Sort-Object LastEventAt -Descending)) {
        $identity = Resolve-ProjectIdentity ([string]$state.ProjectPath) ([string]$state.Path) ([string]$state.SessionId) ([string]$state.ProjectName)
        $projectKey = [string]$identity.project_key
        if ($seenProjectKeys.ContainsKey($projectKey)) { continue }
        $seenProjectKeys[$projectKey] = $true
        $projectTaskUsage = if ($state.TaskActive) {
            Subtract-UsageBucket $state.Current $state.TaskStart
        } else {
            Copy-UsageBucket $state.LastTask
        }
        $projectLifetimeUsage = if ($projectLifetimeBuckets.ContainsKey($projectKey)) {
            Copy-UsageBucket $projectLifetimeBuckets[$projectKey]
        } else {
            New-UsageBucket
        }
        $projects += [pscustomobject]@{
            project_key = $projectKey
            project_id = [string]$identity.project_id
            project_name = [string]$identity.project_name
            project_path = [string]$identity.project_path
            session_id = [string]$identity.session_id
            session_path = [string]$state.Path
            active = [bool]$state.TaskActive
            task = [pscustomobject]$projectTaskUsage
            session = [pscustomobject](Copy-UsageBucket $state.Current)
            today = [pscustomobject](Copy-UsageBucket $projectTodayBuckets[$projectKey])
            lifetime = [pscustomobject]$projectLifetimeUsage
            model = [string]$state.Model
            last_event_at = $state.LastEventAt.ToString('o')
            task_started_ticks = [int64]$state.TaskStartedAt.UtcDateTime.Ticks
        }
    }
    $projects = @($projects | Sort-Object -Property @(
        @{ Expression = { [int64]$_.lifetime.total_tokens }; Descending = $true },
        @{ Expression = { [string]$_.last_event_at }; Descending = $true }
    ))
    $anyProjectActive = @($projects | Where-Object { $_.active }).Count -gt 0

    $speed = [double]0
    $elapsed = ($now - $script:lastSampleAt).TotalSeconds
    if ($script:lastSamplePath -eq $currentState.Path -and $elapsed -gt 0) {
        $delta = [int64]$currentState.Current.total_tokens - $script:lastSampleTotal
        if ($delta -gt 0) { $speed = $delta * 60.0 / $elapsed }
    }
    $script:lastSamplePath = $currentState.Path
    $script:lastSampleTotal = [int64]$currentState.Current.total_tokens
    $script:lastSampleAt = $now

    $nonCachedInput = [Math]::Max([int64]0, [int64]$today.input_tokens - [int64]$today.cached_input_tokens)
    $cacheRatio = if ($today.input_tokens -gt 0) { 100.0 * $today.cached_input_tokens / $today.input_tokens } else { 0.0 }
    $currentIdentity = Resolve-ProjectIdentity ([string]$currentState.ProjectPath) ([string]$currentState.Path) ([string]$currentState.SessionId) ([string]$currentState.ProjectName)
    $dataAgeSeconds = if ($currentState.LastEventAt -eq [DateTimeOffset]::MinValue) { [int64]::MaxValue } else { [int64][Math]::Max(0, ($now - $currentState.LastEventAt).TotalSeconds) }

    return [pscustomobject]@{
        available = $true
        active = [bool]$anyProjectActive
        model = $currentState.Model
        project_name = [string]$currentIdentity.project_name
        project_path = [string]$currentIdentity.project_path
        session = [pscustomobject](Copy-UsageBucket $currentState.Current)
        task = [pscustomobject]$taskUsage
        last_call = [pscustomobject](Copy-UsageBucket $currentState.LastCall)
        today = [pscustomobject]$today
        today_non_cached_input = $nonCachedInput
        cache_ratio = [Math]::Round($cacheRatio, 1)
        tokens_per_minute = [Math]::Round($speed)
        remaining_percent = if ($null -ne $remainingPercent) { [Math]::Round($remainingPercent, 1) } else { $null }
        used_percent = if ($null -ne $rate) { [Math]::Round([double]$rate.used_percent, 1) } else { $null }
        window_minutes = if ($null -ne $rate) { [int64]$rate.window_minutes } else { $null }
        resets_at = if ($null -ne $rate) { [int64]$rate.resets_at } else { $null }
        reset_label = if ($null -ne $rate) { Get-ResetLabel ([int64]$rate.resets_at) } else { '额度信息等待 Codex 更新' }
        plan_type = if ($null -ne $rate) { $rate.plan_type } else { '' }
        quota_source = $quotaSource
        account_synced_at = if ($script:accountRateLimitAt -ne [DateTimeOffset]::MinValue) { $script:accountRateLimitAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        account_sync_error = [string]$script:accountRefreshLastError
        projects = @($projects)
        lifetime_ranking = @($projectLifetimeRanking)
        daily_history = @(Get-DailyHistoryArray 42)
        weekly_history = @(Get-WeeklyHistoryArray 8)
        updated_at = $now.ToString('yyyy-MM-dd HH:mm:ss')
        latest_event_at = $currentState.LastEventAt.ToString('o')
        data_age_seconds = $dataAgeSeconds
        source_file_count = @($files).Count
        project_metadata_count = $script:codexProjectNames.Count
        current_log = $currentState.Path
    }
}

if ($AccountSnapshotWorker) {
    if ([string]::IsNullOrWhiteSpace($AccountSnapshotResultPath)) { throw '账户同步结果路径不能为空。' }
    $workerResult = Update-CodexAccountSnapshot -Force
    $payload = [pscustomobject]@{
        succeeded = [bool]$workerResult.succeeded
        message = [string]$workerResult.message
        synced_at = if ($script:accountRateLimitAt -ne [DateTimeOffset]::MinValue) { $script:accountRateLimitAt.ToString('o') } else { [DateTimeOffset]::Now.ToString('o') }
        rate_limit = $script:accountRateLimit
    } | ConvertTo-Json -Depth 8
    $resultDirectory = Split-Path -Parent $AccountSnapshotResultPath
    New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
    $temporaryResultPath = $AccountSnapshotResultPath + '.tmp'
    Set-Content -LiteralPath $temporaryResultPath -Value $payload -Encoding UTF8
    Move-Item -LiteralPath $temporaryResultPath -Destination $AccountSnapshotResultPath -Force
    exit $(if ($workerResult.succeeded) { 0 } else { 1 })
}

Load-HistoryCache

if ($Once) {
    [void](Update-CodexAccountSnapshot -Force)
    Get-CodexMetrics | ConvertTo-Json -Depth 8
    exit 0
}

$createdNew = $false
$userKey = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value.Replace('-', '_')
$mutexName = 'Local\CodexUsagePet_' + $userKey
$showEventName = 'Local\CodexUsagePet_Show_' + $userKey
$showEventCreated = $false
$script:showExistingEvent = New-Object System.Threading.EventWaitHandle(
    $false,
    [System.Threading.EventResetMode]::AutoReset,
    $showEventName,
    [ref]$showEventCreated
)
$script:singleInstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    [void]$script:showExistingEvent.Set()
    $script:showExistingEvent.Dispose()
    $script:singleInstanceMutex.Dispose()
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex 用量宠物" Width="240" Height="264"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" MinWidth="220" MinHeight="135" Topmost="True" ShowInTaskbar="False">
  <Grid>
    <Grid.Resources>
      <Style x:Key="ResizeThumbStyle" TargetType="{x:Type Thumb}">
        <Setter Property="Background" Value="#01000000"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Opacity" Value="1"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="{x:Type Thumb}">
              <Border Background="{TemplateBinding Background}"/>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
    </Grid.Resources>
    <Border x:Name="RootCard" CornerRadius="20" Background="#F2202634" BorderBrush="#3B82F6" BorderThickness="1.5" Padding="12">
        <Border.Effect>
            <DropShadowEffect Color="#90000000" BlurRadius="24" ShadowDepth="5" Opacity="0.65"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition x:Name="HeaderRow" Height="48"/>
                <RowDefinition x:Name="QuotaRow" Height="60"/>
                <RowDefinition x:Name="ProjectsRow" Height="*"/>
                <RowDefinition x:Name="DetailRow" Height="50"/>
                <RowDefinition x:Name="FooterRow" Height="22"/>
            </Grid.RowDefinitions>

            <Grid x:Name="HeaderPanel" Grid.Row="0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition x:Name="PetColumn" Width="46"/>
                    <ColumnDefinition x:Name="TitleColumn" Width="*"/>
                    <ColumnDefinition x:Name="HistoryColumn" Width="20"/>
                    <ColumnDefinition x:Name="RefreshColumn" Width="20"/>
                    <ColumnDefinition x:Name="ShowAllColumn" Width="20"/>
                    <ColumnDefinition x:Name="SettingsColumn" Width="20"/>
                    <ColumnDefinition x:Name="MinimizeColumn" Width="20"/>
                    <ColumnDefinition x:Name="HideColumn" Width="20"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="PetFrame" Width="44" Height="44" CornerRadius="13" Background="Transparent" BorderThickness="0" ToolTip="双击只显示小猫；再次双击恢复详情">
                    <Grid x:Name="PetStage" RenderTransformOrigin="0.5,0.5">
                        <Grid.RenderTransform><TranslateTransform x:Name="PetBounce"/></Grid.RenderTransform>
                        <Image x:Name="PetSprite" Stretch="Uniform" SnapsToDevicePixels="True"/>
                    </Grid>
                </Border>
                <StackPanel x:Name="TitlePanel" Grid.Column="1" VerticalAlignment="Center" Margin="6,0,0,0">
                    <TextBlock Text="Codex 助手" Foreground="White" FontSize="13" FontWeight="SemiBold"/>
                    <TextBlock x:Name="StatusText" Text="正在读取用量…" Foreground="#AAB6CC" FontSize="9" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <Button x:Name="HistoryButton" Grid.Column="2" Content="▥" Width="19" Height="19" VerticalAlignment="Top" Foreground="#7DB4FF" Background="Transparent" BorderThickness="0" FontSize="11" Cursor="Hand" ToolTip="用量历史"/>
                <Button x:Name="RefreshButton" Grid.Column="3" Content="↺" Width="19" Height="19" VerticalAlignment="Top" Foreground="#A58BFA" Background="Transparent" BorderThickness="0" FontSize="12" Cursor="Hand" ToolTip="立即刷新账户额度和本机日志"/>
                <Button x:Name="ShowAllProjectsButton" Grid.Column="4" Content="☰" Width="19" Height="19" VerticalAlignment="Top" Foreground="#7DB4FF" Background="Transparent" BorderThickness="0" FontSize="11" Cursor="Hand" ToolTip="恢复隐藏项目" Opacity="0.45" IsEnabled="False"/>
                <Button x:Name="SettingsButton" Grid.Column="5" Content="⚙" Width="19" Height="19" VerticalAlignment="Top" Foreground="#7FD7C4" Background="Transparent" BorderThickness="0" FontSize="11" Cursor="Hand" ToolTip="控制中心"/>
                <Button x:Name="MinimizeButton" Grid.Column="6" Content="—" Width="19" Height="19" VerticalAlignment="Top" Foreground="#AAB6CC" Background="Transparent" BorderThickness="0" FontSize="11" Cursor="Hand" ToolTip="最小化"/>
                <Button x:Name="HideButton" Grid.Column="7" Content="×" Width="19" Height="19" VerticalAlignment="Top" Foreground="#AAB6CC" Background="Transparent" BorderThickness="0" FontSize="14" Cursor="Hand" ToolTip="隐藏到托盘"/>
            </Grid>

            <Border x:Name="QuotaPanel" Grid.Row="1" Background="#161B27" CornerRadius="12" Padding="9,7">
                <Grid>
                    <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="9"/><RowDefinition/></Grid.RowDefinitions>
                    <Grid>
                        <TextBlock x:Name="LimitTitle" Text="额度剩余" Foreground="#AAB6CC" FontSize="11"/>
                        <TextBlock x:Name="RemainingText" Text="--%" Foreground="#70D6A3" FontSize="17" FontWeight="Bold" HorizontalAlignment="Right"/>
                    </Grid>
                    <Border Grid.Row="1" Background="#30394A" CornerRadius="5" Height="7">
                        <Grid x:Name="ProgressHost">
                            <Border x:Name="ProgressFill" Background="#4FD19A" CornerRadius="5" Height="7" HorizontalAlignment="Left" Width="0"/>
                        </Grid>
                    </Border>
                    <TextBlock x:Name="ResetText" Grid.Row="2" Text="等待额度信息" Foreground="#7F8CA5" FontSize="10" Margin="0,3,0,0"/>
                </Grid>
            </Border>

            <ScrollViewer x:Name="ProjectsScrollViewer" Grid.Row="2" Margin="0,6,0,0" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled" BorderThickness="0" Background="Transparent" PanningMode="VerticalOnly">
                <StackPanel x:Name="ProjectsPanel"/>
            </ScrollViewer>

            <Border x:Name="DetailPanel" Grid.Row="3" Background="#111622" CornerRadius="11" Margin="0,6,0,0" Padding="8,5">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="今日累计" Foreground="#6F7B91" FontSize="9"/>
                        <TextBlock x:Name="TodayTokensText" Text="--" Foreground="#CBD5E8" FontSize="10" Margin="0,2,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1">
                        <TextBlock Text="今日输出" Foreground="#6F7B91" FontSize="9"/>
                        <TextBlock x:Name="OutputText" Text="--" Foreground="#CBD5E8" FontSize="10" Margin="0,2,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                        <TextBlock Text="缓存命中" Foreground="#6F7B91" FontSize="9"/>
                        <TextBlock x:Name="CacheText" Text="--" Foreground="#CBD5E8" FontSize="10" Margin="0,2,0,0"/>
                    </StackPanel>
                </Grid>
            </Border>

            <Grid x:Name="FooterPanel" Grid.Row="4" Margin="2,5,2,0">
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="72"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <TextBlock x:Name="ModelText" Grid.Column="0" Text="Codex" Foreground="#6F7B91" FontSize="8" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <Button x:Name="DetailToggleButton" Grid.Column="1" Content="⌃" Width="68" Height="20" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#A9BAD1" Background="#182131" BorderBrush="#344055" BorderThickness="1" FontSize="14" FontWeight="SemiBold" Cursor="Hand" ToolTip="收起今日累计" Padding="0"/>
                <TextBlock x:Name="HealthText" Grid.Column="2" Text="● 检查中" Foreground="#7F8CA5" FontSize="8" HorizontalAlignment="Right" VerticalAlignment="Center" ToolTip="数据源健康状态"/>
            </Grid>
        </Grid>
    </Border>
    <Thumb x:Name="ResizeLeft" Style="{StaticResource ResizeThumbStyle}" Width="10" HorizontalAlignment="Left" Cursor="SizeWE"/>
    <Thumb x:Name="ResizeRight" Style="{StaticResource ResizeThumbStyle}" Width="10" HorizontalAlignment="Right" Cursor="SizeWE"/>
    <Thumb x:Name="ResizeTop" Style="{StaticResource ResizeThumbStyle}" Height="10" VerticalAlignment="Top" Cursor="SizeNS"/>
    <Thumb x:Name="ResizeBottom" Style="{StaticResource ResizeThumbStyle}" Height="10" VerticalAlignment="Bottom" Cursor="SizeNS"/>
    <Thumb x:Name="ResizeTopLeft" Style="{StaticResource ResizeThumbStyle}" Width="22" Height="22" HorizontalAlignment="Left" VerticalAlignment="Top" Cursor="SizeNWSE"/>
    <Thumb x:Name="ResizeTopRight" Style="{StaticResource ResizeThumbStyle}" Width="22" Height="22" HorizontalAlignment="Right" VerticalAlignment="Top" Cursor="SizeNESW"/>
    <Thumb x:Name="ResizeBottomLeft" Style="{StaticResource ResizeThumbStyle}" Width="22" Height="22" HorizontalAlignment="Left" VerticalAlignment="Bottom" Cursor="SizeNESW"/>
    <Thumb x:Name="ResizeBottomRight" Style="{StaticResource ResizeThumbStyle}" Width="24" Height="24" HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="SizeNWSE" ToolTip="拖动调整小猫或窗口尺寸"/>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$rootCard = $window.FindName('RootCard')
$script:normalRootEffect = $rootCard.Effect
$headerPanel = $window.FindName('HeaderPanel')
$headerRow = $window.FindName('HeaderRow')
$petColumn = $window.FindName('PetColumn')
$titleColumn = $window.FindName('TitleColumn')
$historyColumn = $window.FindName('HistoryColumn')
$refreshColumn = $window.FindName('RefreshColumn')
$showAllColumn = $window.FindName('ShowAllColumn')
$settingsColumn = $window.FindName('SettingsColumn')
$minimizeColumn = $window.FindName('MinimizeColumn')
$hideColumn = $window.FindName('HideColumn')
$quotaRow = $window.FindName('QuotaRow')
$petFrame = $window.FindName('PetFrame')
$petStage = $window.FindName('PetStage')
$titlePanel = $window.FindName('TitlePanel')
$resizeLeft = $window.FindName('ResizeLeft')
$resizeRight = $window.FindName('ResizeRight')
$resizeTop = $window.FindName('ResizeTop')
$resizeBottom = $window.FindName('ResizeBottom')
$resizeTopLeft = $window.FindName('ResizeTopLeft')
$resizeTopRight = $window.FindName('ResizeTopRight')
$resizeBottomLeft = $window.FindName('ResizeBottomLeft')
$resizeBottomRight = $window.FindName('ResizeBottomRight')
$petSprite = $window.FindName('PetSprite')
$petBounce = $window.FindName('PetBounce')
$statusText = $window.FindName('StatusText')
$historyButton = $window.FindName('HistoryButton')
$refreshButton = $window.FindName('RefreshButton')
$showAllProjectsButton = $window.FindName('ShowAllProjectsButton')
$detailToggleButton = $window.FindName('DetailToggleButton')
$settingsButton = $window.FindName('SettingsButton')
$minimizeButton = $window.FindName('MinimizeButton')
$hideButton = $window.FindName('HideButton')
$limitTitle = $window.FindName('LimitTitle')
$remainingText = $window.FindName('RemainingText')
$progressHost = $window.FindName('ProgressHost')
$progressFill = $window.FindName('ProgressFill')
$resetText = $window.FindName('ResetText')
$quotaPanel = $window.FindName('QuotaPanel')
$projectsPanel = $window.FindName('ProjectsPanel')
$projectsScrollViewer = $window.FindName('ProjectsScrollViewer')
$projectsRow = $window.FindName('ProjectsRow')
$todayTokensText = $window.FindName('TodayTokensText')
$detailPanel = $window.FindName('DetailPanel')
$detailRow = $window.FindName('DetailRow')
$outputText = $window.FindName('OutputText')
$cacheText = $window.FindName('CacheText')
$footerPanel = $window.FindName('FooterPanel')
$footerRow = $window.FindName('FooterRow')
$modelText = $window.FindName('ModelText')
$healthText = $window.FindName('HealthText')

function Import-PetBitmap {
    param([string]$Path)
    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]::new($Path, [UriKind]::Absolute)
    $bitmap.EndInit()
    $bitmap.Freeze()
    return $bitmap
}

$catAssetRoot = Join-Path $script:projectRoot 'assets\cat'
$script:busyCatFrames = @(1..4 | ForEach-Object { Import-PetBitmap (Join-Path $catAssetRoot ("cat-busy-$_.png")) })
$script:idleCatFrames = @(1..4 | ForEach-Object { Import-PetBitmap (Join-Path $catAssetRoot ("cat-idle-$_.png")) })

$script:isCompact = $true
$script:isExiting = $false
$script:alerted80 = $false
$script:alerted90 = $false
$script:alertResetAt = [int64]0
$script:hiddenProjects = @{}
$script:projectByKey = @{}
$script:projectRowUi = @{}
$script:lifetimeDisplayProjects = @{}
$script:projectLifetimeTotals = @{}
$script:visibleProjectCount = 0
$script:notifyOnCompletion = $true
$script:completionBubbleDurationSeconds = 10
$script:quotaAlertsEnabled = $true
$script:healthStatusVisible = $true
$script:projectSortMode = 'lifetime'
$script:refreshSeconds = 2
$script:animationSpeed = 'normal'
$script:topmostEnabled = $true
$script:autoUpdateEnabled = $true
$script:windowOpacityPercent = 100
$script:isPetOnly = $false
$script:startPetOnly = $false
$script:petOnlySize = [double]58
$script:petOnlyMinSize = [double]48
$script:petOnlyMaxSize = [double]240
$script:expandedWindowWidth = [double]240
$script:expandedWindowHeight = [double]272
$script:baseWindowHeight = [double]272
$script:userResized = $false
$script:savedWindowWidth = [double]240
$script:savedWindowHeight = [double]272
$script:layoutProjectCount = [int]-1
$script:isUserSizing = $false
$script:isPetDragPending = $false
$script:petDragMoved = $false
$script:petDragStartCursor = $null
$script:petDragStartLeft = [double]0
$script:petDragStartTop = [double]0
$script:lastPetClickAt = [DateTime]::MinValue
$script:lastPetClickCursor = $null
$script:projectActivityStates = @{}
$script:activityStateInitialized = $false
$script:completionBubbleQueue = New-Object System.Collections.ArrayList
$script:currentCompletionBubble = $null
$script:completionBubbleWindow = $null
$script:completionBubbleCard = $null
$script:completionBubbleTail = $null
$script:completionBubbleTitle = $null
$script:completionBubbleProject = $null
$script:completionBubbleHint = $null
$script:completionBubbleTimer = $null
$script:codexProcessLastChecked = [DateTimeOffset]::MinValue
$script:codexProcessRunning = $false
$script:updateCheckTimer = $null
$script:updateCheckStartedAt = [DateTime]::MinValue
$settingsPath = Join-Path $script:projectRoot '.pet-settings.json'
$script:autoStartShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex 用量宠物.lnk'
function Get-SettingValue {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
        $savedLeft = Get-SettingValue $settings 'left' $null
        $savedTop = Get-SettingValue $settings 'top' $null
        if ($null -ne $savedLeft -and $null -ne $savedTop) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = [double]$savedLeft
            $window.Top = [double]$savedTop
        }
        $script:alerted80 = [bool](Get-SettingValue $settings 'alerted80' $false)
        $script:alerted90 = [bool](Get-SettingValue $settings 'alerted90' $false)
        $script:alertResetAt = [int64](Get-SettingValue $settings 'alertResetAt' 0)
        $script:notifyOnCompletion = [bool](Get-SettingValue $settings 'notify_on_completion' $true)
        $loadedBubbleDuration = [int](Get-SettingValue $settings 'completion_bubble_seconds' 10)
        $script:completionBubbleDurationSeconds = if (@(0,5,10,30) -contains $loadedBubbleDuration) { $loadedBubbleDuration } else { 10 }
        $script:quotaAlertsEnabled = [bool](Get-SettingValue $settings 'quota_alerts_enabled' $true)
        $script:healthStatusVisible = [bool](Get-SettingValue $settings 'health_status_visible' $true)
        $script:projectSortMode = [string](Get-SettingValue $settings 'project_sort_mode' 'lifetime')
        $script:refreshSeconds = [Math]::Max(2, [Math]::Min(30, [int](Get-SettingValue $settings 'refresh_seconds' 2)))
        $script:animationSpeed = [string](Get-SettingValue $settings 'animation_speed' 'normal')
        $script:topmostEnabled = [bool](Get-SettingValue $settings 'topmost_enabled' $true)
        $script:autoUpdateEnabled = [bool](Get-SettingValue $settings 'auto_update_enabled' $true)
        $script:windowOpacityPercent = [Math]::Max(40, [Math]::Min(100, [int](Get-SettingValue $settings 'window_opacity_percent' 100)))
        $script:startPetOnly = [bool](Get-SettingValue $settings 'pet_only_mode' $false)
        $script:petOnlySize = [Math]::Max($script:petOnlyMinSize, [Math]::Min($script:petOnlyMaxSize, [double](Get-SettingValue $settings 'pet_only_size' 58)))
        $script:userResized = [bool](Get-SettingValue $settings 'user_resized' $false)
        $script:savedWindowWidth = [Math]::Max(220, [Math]::Min(900, [double](Get-SettingValue $settings 'window_width' 240)))
        $script:savedWindowHeight = [Math]::Max(178, [Math]::Min(1200, [double](Get-SettingValue $settings 'window_height' 272)))
        $script:layoutProjectCount = [int](Get-SettingValue $settings 'layout_project_count' -1)
        if ($script:userResized) {
            $window.Width = $script:savedWindowWidth
            $window.Height = $script:savedWindowHeight
        }
        $window.Topmost = $script:topmostEnabled
        foreach ($hidden in @((Get-SettingValue $settings 'hidden_projects' @()))) {
            $hiddenKey = [string](Get-SettingValue $hidden 'project_key' '')
            if (-not [string]::IsNullOrWhiteSpace($hiddenKey)) {
                $script:hiddenProjects[$hiddenKey] = [pscustomobject]@{
                    session_path = [string](Get-SettingValue $hidden 'session_path' '')
                    task_started_ticks = [int64](Get-SettingValue $hidden 'task_started_ticks' 0)
                }
            }
        }
        foreach ($unread in @((Get-SettingValue $settings 'unread_completed_projects' @()))) {
            $unreadKey = [string](Get-SettingValue $unread 'project_key' '')
            if (-not [string]::IsNullOrWhiteSpace($unreadKey)) {
                $script:unreadCompletedProjects[$unreadKey] = [pscustomobject]@{
                    session_id = [string](Get-SettingValue $unread 'session_id' '')
                    session_path = [string](Get-SettingValue $unread 'session_path' '')
                    completed_ticks = [int64](Get-SettingValue $unread 'completed_ticks' 0)
                }
            }
        }
    } catch {}
} else {
    $window.WindowStartupLocation = 'CenterScreen'
}
$window.Opacity = [double]$script:windowOpacityPercent / 100.0
$script:expandedWindowWidth = [double]$window.Width
$script:expandedWindowHeight = [double]$window.Height

function Save-PetPosition {
    try {
        $widthToSave = if ($script:isPetOnly) { $script:expandedWindowWidth } else { [double]$window.Width }
        $heightToSave = if ($script:isPetOnly) { $script:expandedWindowHeight } else { [double]$window.Height }
        $hiddenProjectSettings = @($script:hiddenProjects.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{
                project_key = [string]$_.Key
                session_path = [string]$_.Value.session_path
                task_started_ticks = [int64]$_.Value.task_started_ticks
            }
        })
        $unreadCompletedSettings = @($script:unreadCompletedProjects.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{
                project_key = [string]$_.Key
                session_id = [string]$_.Value.session_id
                session_path = [string]$_.Value.session_path
                completed_ticks = [int64]$_.Value.completed_ticks
            }
        })
        @{
            left = $window.Left
            top = $window.Top
            alerted80 = $script:alerted80
            alerted90 = $script:alerted90
            alertResetAt = $script:alertResetAt
            notify_on_completion = $script:notifyOnCompletion
            completion_bubble_seconds = $script:completionBubbleDurationSeconds
            quota_alerts_enabled = $script:quotaAlertsEnabled
            health_status_visible = $script:healthStatusVisible
            project_sort_mode = $script:projectSortMode
            refresh_seconds = $script:refreshSeconds
            animation_speed = $script:animationSpeed
            topmost_enabled = $script:topmostEnabled
            auto_update_enabled = $script:autoUpdateEnabled
            window_opacity_percent = $script:windowOpacityPercent
            pet_only_mode = $script:isPetOnly
            pet_only_size = $script:petOnlySize
            user_resized = $script:userResized
            window_width = $widthToSave
            window_height = $heightToSave
            layout_project_count = $script:layoutProjectCount
            hidden_projects = $hiddenProjectSettings
            unread_completed_projects = $unreadCompletedSettings
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    } catch {}
}

function Toggle-PetCompact {
    $oldHeight = [double]$window.Height
    $script:isCompact = -not $script:isCompact
    Update-PetWindowLayout
    if ($script:userResized -and $script:visibleProjectCount -gt 0) {
        $heightChange = if ($script:isCompact) { -50 } else { 50 }
        $window.Height = [Math]::Max($window.MinHeight, [Math]::Min(1200, $oldHeight + $heightChange))
        Save-PetPosition
    }
}

function Update-PetOnlyVisualSize {
    if (-not $script:isPetOnly) { return }
    $innerSize = [Math]::Max(38, [double]$window.Width - 10)
    $headerRow.Height = [System.Windows.GridLength]::new($innerSize)
    $headerPanel.Width = $innerSize
    $petFrame.Width = $innerSize
    $petFrame.Height = $innerSize
}

function Keep-PetWindowOnScreen {
    try {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $screen = [System.Windows.Forms.Screen]::FromHandle($handle)
        $workArea = $screen.WorkingArea
        $source = [System.Windows.PresentationSource]::FromVisual($window)

        if ($null -ne $source -and $null -ne $source.CompositionTarget) {
            $fromDevice = $source.CompositionTarget.TransformFromDevice
            $topLeft = $fromDevice.Transform([System.Windows.Point]::new($workArea.Left, $workArea.Top))
            $bottomRight = $fromDevice.Transform([System.Windows.Point]::new($workArea.Right, $workArea.Bottom))
        } else {
            $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
            $topLeft = [System.Windows.Point]::new($workArea.Left / $dpi.DpiScaleX, $workArea.Top / $dpi.DpiScaleY)
            $bottomRight = [System.Windows.Point]::new($workArea.Right / $dpi.DpiScaleX, $workArea.Bottom / $dpi.DpiScaleY)
        }

        $margin = [double]4
        $maxLeft = [Math]::Max($topLeft.X + $margin, $bottomRight.X - [double]$window.Width - $margin)
        $maxTop = [Math]::Max($topLeft.Y + $margin, $bottomRight.Y - [double]$window.Height - $margin)
        $window.Left = [Math]::Max($topLeft.X + $margin, [Math]::Min($maxLeft, [double]$window.Left))
        $window.Top = [Math]::Max($topLeft.Y + $margin, [Math]::Min($maxTop, [double]$window.Top))
    } catch {}
}

function Set-PetOnlyMode {
    param([bool]$Enabled, [bool]$Persist = $true)
    if ($Enabled -eq $script:isPetOnly) { return }

    if ($Enabled) {
        $script:expandedWindowWidth = [double]$window.Width
        $script:expandedWindowHeight = [double]$window.Height
        $script:isPetOnly = $true

        $titlePanel.Visibility = 'Collapsed'
        $historyButton.Visibility = 'Collapsed'
        $refreshButton.Visibility = 'Collapsed'
        $showAllProjectsButton.Visibility = 'Collapsed'
        $settingsButton.Visibility = 'Collapsed'
        $minimizeButton.Visibility = 'Collapsed'
        $hideButton.Visibility = 'Collapsed'
        $quotaPanel.Visibility = 'Collapsed'
        $projectsScrollViewer.Visibility = 'Collapsed'
        $detailPanel.Visibility = 'Collapsed'
        $footerPanel.Visibility = 'Collapsed'
        $quotaRow.Height = [System.Windows.GridLength]::new(0)
        $projectsRow.Height = [System.Windows.GridLength]::new(0)
        $detailRow.Height = [System.Windows.GridLength]::new(0)
        $footerRow.Height = [System.Windows.GridLength]::new(0)
        $headerPanel.Width = 48
        $headerPanel.HorizontalAlignment = 'Center'
        $rootCard.Background = [System.Windows.Media.Brushes]::Transparent
        $rootCard.BorderThickness = [System.Windows.Thickness]::new(0)
        $rootCard.Padding = [System.Windows.Thickness]::new(5)
        $rootCard.Effect = $null
        $petColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        foreach ($column in @($titleColumn,$historyColumn,$refreshColumn,$showAllColumn,$settingsColumn,$minimizeColumn,$hideColumn)) {
            $column.Width = [System.Windows.GridLength]::new(0)
        }
        [System.Windows.Controls.Grid]::SetColumnSpan($petFrame, 1)
        foreach ($thumb in @($resizeLeft,$resizeRight,$resizeTop,$resizeBottom,$resizeTopLeft,$resizeTopRight,$resizeBottomLeft,$resizeBottomRight)) {
            $thumb.Visibility = 'Visible'
        }
        $window.MinWidth = $script:petOnlyMinSize
        $window.MinHeight = $script:petOnlyMinSize
        $script:petOnlySize = [Math]::Max($script:petOnlyMinSize, [Math]::Min($script:petOnlyMaxSize, $script:petOnlySize))
        $window.Width = $script:petOnlySize
        $window.Height = $script:petOnlySize
        Update-PetOnlyVisualSize
        Keep-PetWindowOnScreen
    } else {
        $script:isPetOnly = $false
        $window.MinWidth = 220
        $headerRow.Height = [System.Windows.GridLength]::new(48)
        $headerPanel.Width = [double]::NaN
        $headerPanel.HorizontalAlignment = 'Stretch'
        $petFrame.Width = 44
        $petFrame.Height = 44
        $petColumn.Width = [System.Windows.GridLength]::new(46)
        $titleColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        foreach ($column in @($historyColumn,$refreshColumn,$showAllColumn,$settingsColumn,$minimizeColumn,$hideColumn)) {
            $column.Width = [System.Windows.GridLength]::new(20)
        }
        [System.Windows.Controls.Grid]::SetColumnSpan($petFrame, 1)
        $rootCard.Background = Get-PetBrush '#F2202634'
        $rootCard.BorderThickness = [System.Windows.Thickness]::new(1.5)
        $rootCard.Padding = [System.Windows.Thickness]::new(12)
        $rootCard.Effect = $script:normalRootEffect
        foreach ($thumb in @($resizeLeft,$resizeRight,$resizeTop,$resizeBottom,$resizeTopLeft,$resizeTopRight,$resizeBottomLeft,$resizeBottomRight)) {
            $thumb.Visibility = 'Visible'
        }
        $titlePanel.Visibility = 'Visible'
        $historyButton.Visibility = 'Visible'
        $refreshButton.Visibility = 'Visible'
        $showAllProjectsButton.Visibility = 'Visible'
        $settingsButton.Visibility = 'Visible'
        $minimizeButton.Visibility = 'Visible'
        $hideButton.Visibility = 'Visible'
        $quotaPanel.Visibility = 'Visible'
        $quotaRow.Height = [System.Windows.GridLength]::new(60)
        $window.Width = [Math]::Max(220, $script:expandedWindowWidth)
        $window.Height = [Math]::Max(178, $script:expandedWindowHeight)
        Update-PetWindowLayout
        if ($null -ne $script:lastMetrics) { Update-PetUi }
    }

    if ($Persist) { Save-PetPosition }
}

function Open-CodexThread {
    param([string]$SessionId, [string]$ProjectName)
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        $statusText.Text = '该项目暂无可跳转的 Codex 任务'
        return $false
    }
    try {
        Start-Process ('codex://threads/' + $SessionId)
        $statusText.Text = '已打开：' + $ProjectName
        return $true
    } catch {
        try { Start-Process 'codex://' } catch {}
        $statusText.Text = '无法直接跳转，已尝试唤醒 Codex'
        return $false
    }
}

function Test-ProjectCompletionUnread {
    param($Project)
    if ($null -eq $Project -or [bool]$Project.active) { return $false }
    $sessionId = [string]$Project.session_id
    if (-not [string]::IsNullOrWhiteSpace($sessionId) -and $script:codexUnreadThreadIds.ContainsKey($sessionId)) { return $true }
    $key = [string]$Project.project_key
    if (-not $script:unreadCompletedProjects.ContainsKey($key)) { return $false }
    $entry = $script:unreadCompletedProjects[$key]
    $entrySessionId = [string]$entry.session_id
    $entrySessionPath = [string]$entry.session_path
    if (-not [string]::IsNullOrWhiteSpace($entrySessionId) -and
        -not [string]::IsNullOrWhiteSpace([string]$Project.session_id)) {
        return $entrySessionId -eq [string]$Project.session_id
    }
    return $entrySessionPath -eq [string]$Project.session_path
}

function Set-ProjectCompletionUnread {
    param($Project)
    if ($null -eq $Project) { return }
    $key = [string]$Project.project_key
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $script:unreadCompletedProjects[$key] = [pscustomobject]@{
        session_id = [string]$Project.session_id
        session_path = [string]$Project.session_path
        completed_ticks = [DateTimeOffset]::Now.UtcDateTime.Ticks
    }
    Save-PetPosition
}

function Clear-ProjectCompletionUnread {
    param([string]$ProjectKey)
    if ([string]::IsNullOrWhiteSpace($ProjectKey)) { return }
    if ($null -ne $script:lastMetrics -and $script:lastMetrics.available) {
        $project = @($script:lastMetrics.projects | Where-Object { [string]$_.project_key -eq $ProjectKey } | Select-Object -First 1)
        if ($project.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$project[0].session_id)) {
            [void]$script:codexUnreadThreadIds.Remove([string]$project[0].session_id)
        }
    }
    if ($script:unreadCompletedProjects.ContainsKey($ProjectKey)) {
        [void]$script:unreadCompletedProjects.Remove($ProjectKey)
        Save-PetPosition
    }
    if ($null -ne $script:lastMetrics) { Render-ProjectRows $script:lastMetrics }
}

function Open-CodexProject {
    param($Project)
    if ($null -eq $Project) { return $false }
    $opened = Open-CodexThread ([string]$Project.session_id) ([string]$Project.project_name)
    if ($opened) { Clear-ProjectCompletionUnread ([string]$Project.project_key) }
    return $opened
}

function Set-CompletionBubbleTailDirection {
    param([bool]$BubbleOnLeft)
    if ($null -eq $script:completionBubbleCard -or $null -eq $script:completionBubbleTail) { return }

    $points = New-Object System.Windows.Media.PointCollection
    if ($BubbleOnLeft) {
        $script:completionBubbleCard.Margin = [System.Windows.Thickness]::new(0,0,14,0)
        [void]$points.Add([System.Windows.Point]::new(245,35))
        [void]$points.Add([System.Windows.Point]::new(245,59))
        [void]$points.Add([System.Windows.Point]::new(259,47))
    } else {
        $script:completionBubbleCard.Margin = [System.Windows.Thickness]::new(14,0,0,0)
        [void]$points.Add([System.Windows.Point]::new(15,35))
        [void]$points.Add([System.Windows.Point]::new(15,59))
        [void]$points.Add([System.Windows.Point]::new(1,47))
    }
    $script:completionBubbleTail.Points = $points
}

function Stop-CompletionBubbleTimer {
    if ($null -ne $script:completionBubbleTimer) { $script:completionBubbleTimer.Stop() }
}

function Start-CompletionBubbleTimer {
    Stop-CompletionBubbleTimer
    if ($script:completionBubbleDurationSeconds -le 0 -or
        $null -eq $script:currentCompletionBubble -or
        $null -eq $script:completionBubbleWindow -or
        -not $script:completionBubbleWindow.IsVisible) { return }

    if ($null -eq $script:completionBubbleTimer) {
        $script:completionBubbleTimer = New-Object Windows.Threading.DispatcherTimer
        $script:completionBubbleTimer.Add_Tick({
            Stop-CompletionBubbleTimer
            Dismiss-CompletionBubble $true
        })
    }
    $script:completionBubbleTimer.Interval = [TimeSpan]::FromSeconds($script:completionBubbleDurationSeconds)
    $script:completionBubbleTimer.Start()
}

function Suspend-CompletionBubble {
    Stop-CompletionBubbleTimer
    if ($null -ne $script:completionBubbleWindow -and $script:completionBubbleWindow.IsVisible) {
        $script:completionBubbleWindow.Hide()
    }
}

function Update-CompletionBubblePosition {
    if ($null -eq $script:completionBubbleWindow -or -not $script:completionBubbleWindow.IsVisible) { return }
    try {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $screen = [System.Windows.Forms.Screen]::FromHandle($handle)
        $workArea = $screen.WorkingArea
        $source = [System.Windows.PresentationSource]::FromVisual($window)
        if ($null -ne $source -and $null -ne $source.CompositionTarget) {
            $fromDevice = $source.CompositionTarget.TransformFromDevice
            $topLeft = $fromDevice.Transform([System.Windows.Point]::new($workArea.Left, $workArea.Top))
            $bottomRight = $fromDevice.Transform([System.Windows.Point]::new($workArea.Right, $workArea.Bottom))
        } else {
            $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
            $topLeft = [System.Windows.Point]::new($workArea.Left / $dpi.DpiScaleX, $workArea.Top / $dpi.DpiScaleY)
            $bottomRight = [System.Windows.Point]::new($workArea.Right / $dpi.DpiScaleX, $workArea.Bottom / $dpi.DpiScaleY)
        }

        $petOrigin = $petFrame.TranslatePoint([System.Windows.Point]::new(0,0), $window)
        $catLeft = [double]$window.Left + $petOrigin.X
        $catTop = [double]$window.Top + $petOrigin.Y
        $catWidth = if ($petFrame.ActualWidth -gt 0) { [double]$petFrame.ActualWidth } else { [double]$petFrame.Width }
        $catHeight = if ($petFrame.ActualHeight -gt 0) { [double]$petFrame.ActualHeight } else { [double]$petFrame.Height }
        $bubbleWidth = [double]$script:completionBubbleWindow.Width
        $bubbleHeight = [double]$script:completionBubbleWindow.Height

        $rightCandidate = $catLeft + $catWidth - 2
        $bubbleOnLeft = ($rightCandidate + $bubbleWidth -gt $bottomRight.X - 4)
        if ($bubbleOnLeft) {
            $left = $catLeft - $bubbleWidth + 2
        } else {
            $left = $rightCandidate
        }
        $left = [Math]::Max($topLeft.X + 4, [Math]::Min($bottomRight.X - $bubbleWidth - 4, $left))
        $top = $catTop + (($catHeight - $bubbleHeight) / 2)
        $top = [Math]::Max($topLeft.Y + 4, [Math]::Min($bottomRight.Y - $bubbleHeight - 4, $top))
        Set-CompletionBubbleTailDirection $bubbleOnLeft
        $script:completionBubbleWindow.Left = $left
        $script:completionBubbleWindow.Top = $top
    } catch {}
}

function Initialize-CompletionBubble {
    if ($null -ne $script:completionBubbleWindow) { return }
    [xml]$bubbleXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex 完成提示" Width="260" Height="94"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" ShowActivated="False"
        Topmost="False" WindowStartupLocation="Manual">
  <Grid Background="Transparent">
    <Polygon x:Name="BubbleTail" Points="245,35 245,59 259,47" Fill="#FFFFFFFF"
             Stroke="#CBD5E1" StrokeThickness="1.2" StrokeLineJoin="Round" />
    <Border x:Name="BubbleCard" Margin="0,0,14,0" Padding="15,11,10,10" CornerRadius="22"
            Background="#FFFFFFFF" BorderBrush="#CBD5E1" BorderThickness="1.2" Cursor="Hand">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="27" />
        </Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="BubbleTitle" Foreground="#1F2937" FontSize="13" FontWeight="SemiBold"
                     TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="BubbleProject" Margin="0,2,0,0" Foreground="#475569" FontSize="11"
                     TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="BubbleHint" Margin="0,2,0,0" Foreground="#8491A3" FontSize="10" />
        </StackPanel>
        <Button x:Name="BubbleClose" Grid.Column="1" Content="×" Width="24" Height="24"
                VerticalAlignment="Top" Background="Transparent" BorderThickness="0"
                Foreground="#64748B" FontSize="17" Cursor="Hand" ToolTip="关闭这条完成提示" />
      </Grid>
    </Border>
  </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $bubbleXaml
    $script:completionBubbleWindow = [Windows.Markup.XamlReader]::Load($reader)
    $script:completionBubbleCard = $script:completionBubbleWindow.FindName('BubbleCard')
    $script:completionBubbleTail = $script:completionBubbleWindow.FindName('BubbleTail')
    $script:completionBubbleTitle = $script:completionBubbleWindow.FindName('BubbleTitle')
    $script:completionBubbleProject = $script:completionBubbleWindow.FindName('BubbleProject')
    $script:completionBubbleHint = $script:completionBubbleWindow.FindName('BubbleHint')
    $bubbleCard = $script:completionBubbleCard
    $bubbleClose = $script:completionBubbleWindow.FindName('BubbleClose')

    $bubbleClose.Add_Click({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        Dismiss-CompletionBubble $true
    })
    $bubbleCard.Add_MouseLeftButtonUp({
        param($sender, $eventArgs)
        $source = $eventArgs.OriginalSource
        while ($null -ne $source -and $source -ne $sender) {
            if ($source -is [System.Windows.Controls.Button]) { return }
            try { $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source) } catch { break }
        }
        if ($null -eq $script:currentCompletionBubble) { return }
        $entry = $script:currentCompletionBubble
        Dismiss-CompletionBubble $false
        $opened = Open-CodexThread ([string]$entry.session_id) ([string]$entry.project_name)
        if ($opened) { Clear-ProjectCompletionUnread ([string]$entry.project_key) }
        Show-NextCompletionBubble
        $eventArgs.Handled = $true
    })
    $script:completionBubbleWindow.Add_Closing({
        param($sender, $eventArgs)
        if (-not $script:isExiting) {
            $eventArgs.Cancel = $true
            Dismiss-CompletionBubble $true
        }
    })
}

function Show-NextCompletionBubble {
    if ($null -eq $script:currentCompletionBubble) {
        if ($script:completionBubbleQueue.Count -eq 0) { return }
        $script:currentCompletionBubble = $script:completionBubbleQueue[0]
        $script:completionBubbleQueue.RemoveAt(0)
    }
    if (-not $window.IsVisible) { return }

    $wasVisible = $null -ne $script:completionBubbleWindow -and $script:completionBubbleWindow.IsVisible
    Initialize-CompletionBubble
    $entry = $script:currentCompletionBubble
    $script:completionBubbleTitle.Text = '✓ 任务弄好了'
    $script:completionBubbleProject.Text = [string]$entry.project_name
    $remaining = $script:completionBubbleQueue.Count
    $script:completionBubbleHint.Text = if ($remaining -gt 0) { "点击打开对应对话 · 还有 $remaining 条" } else { '点击打开对应对话' }
    $script:completionBubbleWindow.Topmost = $false
    $script:completionBubbleWindow.Opacity = [double]$script:windowOpacityPercent / 100.0
    if (-not $script:completionBubbleWindow.IsVisible) { $script:completionBubbleWindow.Show() }
    Update-CompletionBubblePosition
    if (-not $wasVisible) { Start-CompletionBubbleTimer }
}

function Dismiss-CompletionBubble {
    param([bool]$ShowNext = $true)
    Suspend-CompletionBubble
    $script:currentCompletionBubble = $null
    if ($ShowNext) { Show-NextCompletionBubble }
}

function Queue-CompletionBubble {
    param($Project)
    $sessionId = [string]$Project.session_id
    $projectKey = [string]$Project.project_key
    if ($null -ne $script:currentCompletionBubble -and
        [string]$script:currentCompletionBubble.project_key -eq $projectKey -and
        [string]$script:currentCompletionBubble.session_id -eq $sessionId) { return }
    foreach ($pending in @($script:completionBubbleQueue)) {
        if ([string]$pending.project_key -eq $projectKey -and [string]$pending.session_id -eq $sessionId) { return }
    }
    [void]$script:completionBubbleQueue.Add([pscustomobject]@{
        project_key = $projectKey
        project_name = [string]$Project.project_name
        session_id = $sessionId
    })
    Show-NextCompletionBubble
}

function Set-PetAutoStart {
    param([bool]$Enabled)
    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($script:autoStartShortcutPath)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $startupScript = if (Test-Path -LiteralPath $script:launcherScriptPath) { $script:launcherScriptPath } else { $script:petScriptPath }
        $shortcut.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startupScript`""
        $shortcut.WorkingDirectory = $script:projectRoot
        $appIconPath = Join-Path $script:projectRoot 'assets\app.ico'
        $shortcut.IconLocation = if (Test-Path -LiteralPath $appIconPath) { $appIconPath } else { "$env:SystemRoot\System32\shell32.dll,13" }
        $shortcut.Description = '登录 Windows 后启动 Codex 用量宠物'
        $shortcut.Save()
    } elseif (Test-Path -LiteralPath $script:autoStartShortcutPath) {
        Remove-Item -LiteralPath $script:autoStartShortcutPath -Force
    }
}

function Start-PetUpdateCheck {
    if (-not (Test-Path -LiteralPath $script:launcherScriptPath)) {
        if ($null -ne $script:updateStatus) { $script:updateStatus.Text = '找不到更新启动器' }
        return
    }
    try {
        $script:updateCheckStartedAt = Get-Date
        if ($null -ne $script:updateStatus) {
            $script:updateStatus.Text = '正在后台检查；有更新时助手会自动重启…'
            $script:updateStatus.Foreground = Get-PetBrush '#79AFFF'
        }
        $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:launcherScriptPath`" -UpdateOnly"
        Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WorkingDirectory $script:projectRoot -WindowStyle Hidden
        if ($null -eq $script:updateCheckTimer) {
            $script:updateCheckTimer = New-Object Windows.Threading.DispatcherTimer
            $script:updateCheckTimer.Interval = [TimeSpan]::FromSeconds(1)
            $script:updateCheckTimer.Add_Tick({
                $updateLogPath = Join-Path $script:projectRoot 'update.log'
                if ((Get-Date) -gt $script:updateCheckStartedAt.AddSeconds(30)) {
                    $script:updateCheckTimer.Stop()
                    $script:updateStatus.Text = '检查更新超时，请确认网络后重试'
                    $script:updateStatus.Foreground = Get-PetBrush '#F87171'
                    return
                }
                if (-not (Test-Path -LiteralPath $updateLogPath)) { return }
                $logInfo = Get-Item -LiteralPath $updateLogPath
                if ($logInfo.LastWriteTime -lt $script:updateCheckStartedAt) { return }
                $lastLine = [string](Get-Content -LiteralPath $updateLogPath -Encoding UTF8 -Tail 1)
                $message = if ($lastLine -match '^\[[^\]]+\]\s*(.+)$') { $Matches[1] } else { $lastLine }
                $script:updateStatus.Text = $message
                $script:updateStatus.Foreground = Get-PetBrush $(if ($message -match '最新版本|已自动更新|已更新') { '#4FD19A' } elseif ($message -match '尚未|禁止|跳过|未连接|本地修改|暂不更新|不足 6 小时') { '#FBBF24' } else { '#F87171' })
                $script:updateCheckTimer.Stop()
            })
        }
        $script:updateCheckTimer.Start()
    } catch {
        if ($null -ne $script:updateStatus) {
            $script:updateStatus.Text = '检查更新失败：' + $_.Exception.Message
            $script:updateStatus.Foreground = Get-PetBrush '#F87171'
        }
    }
}

function Get-PetUpdateConnectionStatus {
    if (-not (Test-Path -LiteralPath $script:launcherScriptPath)) {
        return [pscustomobject]@{ status = 'FAIL'; detail = '缺少 Start-CodexUsagePet.ps1' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:projectRoot '.git'))) {
        if ((Test-Path -LiteralPath $script:releaseUpdaterPath) -and (Test-Path -LiteralPath $script:versionInfoPath)) {
            return [pscustomobject]@{ status = 'PASS'; detail = 'GitHub Release 更新器 · 当前版本 ' + $script:appVersion }
        }
        return [pscustomobject]@{ status = 'FAIL'; detail = '安装版更新器或版本文件缺失' }
    }
    if ($null -eq (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ status = 'FAIL'; detail = '未安装 Git' }
    }
    try {
        $gitRootOutput = @(& git.exe -C $script:projectRoot rev-parse --show-toplevel 2>$null)
        $gitRootExitCode = $LASTEXITCODE
        $gitRoot = [string]($gitRootOutput | Select-Object -First 1)
        if ($gitRootExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($gitRoot)) {
            return [pscustomobject]@{ status = 'WARN'; detail = '尚未建立独立 Git 仓库' }
        }
        $expected = [System.IO.Path]::GetFullPath($script:projectRoot).TrimEnd('\')
        $actual = [System.IO.Path]::GetFullPath($gitRoot).TrimEnd('\')
        if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ status = 'WARN'; detail = '当前位于其他仓库中，已禁止误更新' }
        }
        $remoteOutput = @(& git.exe -C $script:projectRoot remote get-url origin 2>$null)
        $remoteExitCode = $LASTEXITCODE
        $remote = [string]($remoteOutput | Select-Object -First 1)
        if ($remoteExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
            return [pscustomobject]@{ status = 'WARN'; detail = '独立仓库尚未连接 GitHub origin' }
        }
        return [pscustomobject]@{ status = 'PASS'; detail = '已连接：' + $remote }
    } catch {
        return [pscustomobject]@{ status = 'FAIL'; detail = $_.Exception.Message }
    }
}

function Test-CodexDesktopRunning {
    $now = [DateTimeOffset]::Now
    if (($now - $script:codexProcessLastChecked).TotalSeconds -ge 10) {
        $script:codexProcessRunning = @(
            Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -like '*OpenAI.Codex*' } catch { $false }
            }
        ).Count -gt 0
        $script:codexProcessLastChecked = $now
    }
    return [bool]$script:codexProcessRunning
}

function Update-DataHealthStatus {
    param($Metrics, [string]$ErrorMessage = '')
    if (-not $script:healthStatusVisible) {
        $healthText.Visibility = 'Collapsed'
        return
    }
    $healthText.Visibility = 'Visible'
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage) -or $null -eq $Metrics -or -not $Metrics.available) {
        $healthText.Text = '● 数据异常'
        $healthText.Foreground = Get-PetBrush '#F87171'
        $healthText.ToolTip = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { '无法读取 Codex 用量数据' } else { $ErrorMessage }
        return
    }
    if (-not (Test-CodexDesktopRunning)) {
        $healthText.Text = '● Codex未运行'
        $healthText.Foreground = Get-PetBrush '#7F8CA5'
        $healthText.ToolTip = '日志可读，但未检测到 Codex 桌面进程'
    } elseif ($Metrics.active -and [int64]$Metrics.data_age_seconds -gt 60) {
        $healthText.Text = '● 更新延迟'
        $healthText.Foreground = Get-PetBrush '#FBBF24'
        $healthText.ToolTip = "有任务运行，但数据已 $($Metrics.data_age_seconds) 秒未更新"
    } else {
        $healthText.Text = '● 数据正常'
        $healthText.Foreground = Get-PetBrush '#4FD19A'
        $quotaHealth = if ([string]$Metrics.quota_source -eq 'account_live') {
            "账户额度已同步 $($Metrics.account_synced_at)"
        } elseif ([string]$Metrics.quota_source -eq 'account_cached') {
            "账户额度同步中或暂时失败，显示 $($Metrics.account_synced_at) 的快照"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$Metrics.account_sync_error)) {
            '账户额度同步失败：' + [string]$Metrics.account_sync_error
        } else {
            '账户额度等待同步'
        }
        $healthText.ToolTip = "最后更新 $($Metrics.updated_at)`n$quotaHealth`n会话文件 $($Metrics.source_file_count) 个`n项目映射 $($Metrics.project_metadata_count) 个"
    }
}

function Check-ProjectCompletionNotifications {
    param($Metrics)
    $orderedProjects = if ($script:projectSortMode -eq 'recent') {
        @($Metrics.projects | Sort-Object -Property @{ Expression = { [string]$_.last_event_at }; Descending = $true })
    } else {
        @($Metrics.projects)
    }
    foreach ($project in $orderedProjects) {
        $key = [string]$project.project_key
        $active = [bool]$project.active
        if ($script:activityStateInitialized -and $script:projectActivityStates.ContainsKey($key) -and
            [bool]$script:projectActivityStates[$key] -and -not $active) {
            Set-ProjectCompletionUnread $project
            if (-not [bool]$Metrics.active -and $script:idleCatFrames.Count -gt 0) {
                $petSprite.Source = $script:idleCatFrames[0]
                $petBounce.X = 0
                $petBounce.Y = 0
            }
            if ($script:notifyOnCompletion) {
                Queue-CompletionBubble $project
                $notifyIcon.BalloonTipTitle = 'Codex 任务已完成'
                $notifyIcon.BalloonTipText = ([string]$project.project_name) + '已完成但尚未查看，双击项目可回到对应任务。'
                $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
                $notifyIcon.ShowBalloonTip(9000)
            }
        }
        $script:projectActivityStates[$key] = $active
    }
    $script:activityStateInitialized = $true
}

$script:historyWindow = $null
$script:dailyChartCanvas = $null
$script:weeklyChartCanvas = $null
$script:calendarGrid = $null
$script:historySummary = $null
$script:controlCenterWindow = $null
$script:controlCenterLoaded = $false
$script:migrationTasks = @()

function Get-PetBrush {
    param([string]$Color)
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color)
}

function Get-PetMaximumContentHeight {
    try {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $screen = [System.Windows.Forms.Screen]::FromHandle($handle)
        $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
        return [Math]::Max(178, [Math]::Min(1200, ([double]$screen.WorkingArea.Height / [double]$dpi.DpiScaleY) - 8))
    } catch {
        return [double]900
    }
}

function Get-PetContentHeight {
    param([int]$ProjectCount)
    if ($ProjectCount -le 0) { return [double]135 }
    $chromeHeight = if ($script:isCompact) { 163 } else { 213 }
    $desiredHeight = [double]($chromeHeight + (52 * $ProjectCount))
    return [Math]::Min((Get-PetMaximumContentHeight), $desiredHeight)
}

function Apply-PetWindowSize {
    param([switch]$FitContent)

    $count = [int]$script:visibleProjectCount
    $targetHeight = Get-PetContentHeight $count
    $projectCountChanged = $script:layoutProjectCount -ne $count
    $shouldFitHeight = -not $script:userResized -or $FitContent -or $projectCountChanged
    $heightChanged = $false

    if (-not $script:userResized) { $window.Width = 240 }
    if ($shouldFitHeight -and [Math]::Abs([double]$window.Height - $targetHeight) -ge 0.5) {
        $window.Height = [Math]::Max([double]$window.MinHeight, $targetHeight)
        $heightChanged = $true
    }
    $script:baseWindowHeight = $targetHeight
    $script:layoutProjectCount = $count
    if (-not $script:isPetOnly) {
        $script:expandedWindowHeight = [double]$window.Height
        if ($script:userResized -and ($heightChanged -or $projectCountChanged)) {
            $script:savedWindowHeight = [double]$window.Height
            Save-PetPosition
        }
    }
    if ($heightChanged) { Keep-PetWindowOnScreen }
}

function Update-PetWindowLayout {
    if ($script:isPetOnly) { return }
    $count = [int]$script:visibleProjectCount
    if ($count -le 0) {
        $window.MinHeight = 135
        $detailToggleButton.Visibility = 'Collapsed'
        $projectsScrollViewer.Visibility = 'Collapsed'
        $projectsRow.Height = [System.Windows.GridLength]::new(0)
        $detailPanel.Visibility = 'Collapsed'
        $detailRow.Height = [System.Windows.GridLength]::new(0)
        $footerPanel.Visibility = 'Collapsed'
        $footerRow.Height = [System.Windows.GridLength]::new(0)
        Apply-PetWindowSize
        return
    }

    $window.MinHeight = if ($script:isCompact) { 178 } else { 228 }
    $detailToggleButton.Visibility = 'Visible'
    $projectsScrollViewer.Visibility = 'Visible'
    $projectsRow.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $footerPanel.Visibility = 'Visible'
    $footerRow.Height = [System.Windows.GridLength]::new(22)
    if ($script:isCompact) {
        $detailToggleButton.Content = '⌄'
        $detailToggleButton.ToolTip = '展开今日累计'
        $detailPanel.Visibility = 'Collapsed'
        $detailRow.Height = [System.Windows.GridLength]::new(0)
    } else {
        $detailToggleButton.Content = '⌃'
        $detailToggleButton.ToolTip = '收起今日累计'
        $detailPanel.Visibility = 'Visible'
        $detailRow.Height = [System.Windows.GridLength]::new(50)
    }
    Apply-PetWindowSize
}

function New-ProjectStatusRow {
    param($Project)

    $isUnreadComplete = Test-ProjectCompletionUnread $Project
    $border = New-Object System.Windows.Controls.Border
    $border.Height = 48
    $border.CornerRadius = [System.Windows.CornerRadius]::new(11)
    $border.Background = Get-PetBrush $(if ($Project.active) { '#182234' } elseif ($isUnreadComplete) { '#193029' } else { '#151A26' })
    $border.BorderBrush = Get-PetBrush $(if ($Project.active) { '#345F96' } elseif ($isUnreadComplete) { '#4FD19A' } else { '#252D3C' })
    $border.BorderThickness = [System.Windows.Thickness]::new($(if ($isUnreadComplete) { 1.5 } else { 1 }))
    $border.Padding = [System.Windows.Thickness]::new(8,4,4,4)
    $border.Margin = [System.Windows.Thickness]::new(0,0,0,4)
    $border.Tag = $Project
    $border.Cursor = 'Hand'
    $unreadTip = if ($isUnreadComplete) { "已完成但尚未查看`n" } else { '' }
    $border.ToolTip = $unreadTip + ([string]$Project.project_path) + "`n项目累计 " + (Format-TokenCount $Project.lifetime.total_tokens) + "`n当前会话 " + (Format-TokenCount $Project.session.total_tokens) + "`n双击打开对应 Codex 任务"
    $border.Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.ClickCount -lt 2) { return }
        $source = $eventArgs.OriginalSource
        while ($null -ne $source -and $source -ne $sender) {
            if ($source -is [System.Windows.Controls.Button]) { return }
            try { $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source) } catch { break }
        }
        $project = $sender.Tag
        [void](Open-CodexProject $project)
        $eventArgs.Handled = $true
    })

    $grid = New-Object System.Windows.Controls.Grid
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(10) }))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(30) }))

    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 6
    $dot.Height = 6
    $dot.Fill = Get-PetBrush $(if ($Project.active -or $isUnreadComplete) { '#4FD19A' } else { '#657086' })
    $dot.VerticalAlignment = 'Center'
    if ($isUnreadComplete) {
        $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
        $pulse.From = 0.35
        $pulse.To = 1.0
        $pulse.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(850))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
    }
    [System.Windows.Controls.Grid]::SetColumn($dot, 0)
    [void]$grid.Children.Add($dot)

    $textPanel = New-Object System.Windows.Controls.StackPanel
    $textPanel.Margin = [System.Windows.Thickness]::new(3,0,2,0)
    [System.Windows.Controls.Grid]::SetColumn($textPanel, 1)
    $nameHeader = New-Object System.Windows.Controls.Grid
    [void]$nameHeader.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    [void]$nameHeader.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))
    $nameText = New-Object System.Windows.Controls.TextBlock
    $nameText.Text = [string]$Project.project_name
    $nameText.Foreground = Get-PetBrush '#F1F5FF'
    $nameText.FontSize = 10
    $nameText.FontWeight = 'SemiBold'
    $nameText.TextTrimming = 'CharacterEllipsis'
    [void]$nameHeader.Children.Add($nameText)
    if ($isUnreadComplete) {
        $unreadBadge = New-Object System.Windows.Controls.Border
        $unreadBadge.Background = Get-PetBrush '#294D40'
        $unreadBadge.BorderBrush = Get-PetBrush '#4FD19A'
        $unreadBadge.BorderThickness = [System.Windows.Thickness]::new(0.7)
        $unreadBadge.CornerRadius = [System.Windows.CornerRadius]::new(5)
        $unreadBadge.Padding = [System.Windows.Thickness]::new(4,0,4,0)
        $unreadBadge.Margin = [System.Windows.Thickness]::new(4,0,0,0)
        $unreadBadge.VerticalAlignment = 'Center'
        $unreadText = New-Object System.Windows.Controls.TextBlock
        $unreadText.Text = '完成未读'
        $unreadText.Foreground = Get-PetBrush '#8BE3BC'
        $unreadText.FontSize = 7.5
        $unreadBadge.Child = $unreadText
        [System.Windows.Controls.Grid]::SetColumn($unreadBadge, 1)
        [void]$nameHeader.Children.Add($unreadBadge)
    }
    [void]$textPanel.Children.Add($nameHeader)
    $usageText = New-Object System.Windows.Controls.TextBlock
    $normalUsageText = '本轮 ' + (Format-TokenCount $Project.task.total_tokens) + ' · 今日 ' + (Format-TokenCount $Project.today.total_tokens)
    $key = [string]$Project.project_key
    if ($null -ne $Project.PSObject.Properties['lifetime']) {
        $script:projectLifetimeTotals[$key] = $Project.lifetime
    }
    $showingLifetime = $script:lifetimeDisplayProjects.ContainsKey($key) -and $script:projectLifetimeTotals.ContainsKey($key)
    $usageText.Text = if ($showingLifetime) { '项目累计 ' + (Format-TokenCount $script:projectLifetimeTotals[$key].total_tokens) } else { $normalUsageText }
    $usageText.Foreground = Get-PetBrush $(if ($Project.active) { '#68A7FF' } elseif ($isUnreadComplete) { '#9BCFB8' } else { '#7F8CA5' })
    $usageText.FontSize = 9
    $usageText.Margin = [System.Windows.Thickness]::new(0,2,0,0)
    $usageText.TextTrimming = 'CharacterEllipsis'
    [void]$textPanel.Children.Add($usageText)
    [void]$grid.Children.Add($textPanel)

    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($buttonPanel, 2)

    $closeButton = New-Object System.Windows.Controls.Button
    $closeButton.Content = '×'
    $closeButton.Tag = [string]$Project.project_key
    $closeButton.Width = 18
    $closeButton.Height = 18
    $closeButton.Foreground = Get-PetBrush '#8D99AE'
    $closeButton.Background = Get-PetBrush '#00111111'
    $closeButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $closeButton.FontSize = 12
    $closeButton.Cursor = 'Hand'
    $closeButton.ToolTip = '隐藏此项目；有新对话时自动恢复'
    $closeButton.Add_Click({
        param($sender, $eventArgs)
        $key = [string]$sender.Tag
        if ($script:projectByKey.ContainsKey($key)) {
            $project = $script:projectByKey[$key]
            $script:hiddenProjects[$key] = [pscustomobject]@{
                session_path = [string]$project.session_path
                task_started_ticks = [int64]$project.task_started_ticks
            }
            Save-PetPosition
            Render-ProjectRows $script:lastMetrics
        }
        $eventArgs.Handled = $true
    })
    [void]$buttonPanel.Children.Add($closeButton)

    $lifetimeButton = New-Object System.Windows.Controls.Button
    $lifetimeButton.Content = if ($showingLifetime) { '今日' } else { '累计' }
    $lifetimeButton.Tag = $key
    $lifetimeButton.Width = 28
    $lifetimeButton.Height = 15
    $lifetimeButton.Foreground = Get-PetBrush '#A58BFA'
    $lifetimeButton.Background = Get-PetBrush '#00111111'
    $lifetimeButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $lifetimeButton.FontSize = 8
    $lifetimeButton.Cursor = 'Hand'
    $lifetimeButton.ToolTip = '切换今日用量与项目创建以来累计用量'
    $lifetimeButton.Margin = [System.Windows.Thickness]::new(0,1,0,0)
    $lifetimeButton.Add_Click({
        param($sender, $eventArgs)
        $projectKey = [string]$sender.Tag
        if ($script:lifetimeDisplayProjects.ContainsKey($projectKey)) {
            [void]$script:lifetimeDisplayProjects.Remove($projectKey)
            Render-ProjectRows $script:lastMetrics
        } else {
            if (-not $script:projectLifetimeTotals.ContainsKey($projectKey)) {
                $sender.Content = '…'
                $sender.IsEnabled = $false
                $statusText.Text = '正在统计项目全部历史用量…'
                $window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
                try {
                    $script:projectLifetimeTotals[$projectKey] = Get-ProjectLifetimeUsage $projectKey
                } catch {
                    $statusText.Text = '项目累计统计失败，将在下次重试'
                }
            }
            if ($script:projectLifetimeTotals.ContainsKey($projectKey)) { $script:lifetimeDisplayProjects[$projectKey] = $true }
            Render-ProjectRows $script:lastMetrics
        }
        $eventArgs.Handled = $true
    })
    [void]$buttonPanel.Children.Add($lifetimeButton)
    [void]$grid.Children.Add($buttonPanel)
    $border.Child = $grid
    return $border
}

function Render-ProjectRows {
    param($Metrics)
    $projectsPanel.Children.Clear()
    $script:projectByKey = @{}
    $eligibleProjects = @()

    foreach ($project in @($Metrics.projects)) {
        $key = [string]$project.project_key
        if ($script:hiddenProjects.ContainsKey($key)) {
            $hidden = $script:hiddenProjects[$key]
            $hasNewSession = [string]$project.session_path -ne [string]$hidden.session_path
            $hasNewTask = [int64]$project.task_started_ticks -gt [int64]$hidden.task_started_ticks
            if ($hasNewSession -or $hasNewTask) {
                [void]$script:hiddenProjects.Remove($key)
                Save-PetPosition
            } else {
                continue
            }
        }
        $eligibleProjects += $project
    }
    $visibleProjects = @($eligibleProjects)

    foreach ($project in $visibleProjects) {
        $script:projectByKey[[string]$project.project_key] = $project
        [void]$projectsPanel.Children.Add((New-ProjectStatusRow $project))
    }
    $script:visibleProjectCount = $visibleProjects.Count
    $showAllProjectsButton.ToolTip = "恢复隐藏项目（$($script:hiddenProjects.Count)）"
    $showAllProjectsButton.IsEnabled = $script:hiddenProjects.Count -gt 0
    $showAllProjectsButton.Opacity = if ($script:hiddenProjects.Count -gt 0) { 1.0 } else { 0.45 }

    if ($visibleProjects.Count -eq 0) {
        $statusText.Text = '项目已隐藏 · 新对话会自动出现'
    } else {
        $activeCount = @($visibleProjects | Where-Object { $_.active }).Count
        $unreadCount = @($visibleProjects | Where-Object { Test-ProjectCompletionUnread $_ }).Count
        $statusText.Text = if ($activeCount -gt 0 -and $unreadCount -gt 0) {
            "$activeCount 个工作中 · $unreadCount 个完成未读"
        } elseif ($activeCount -gt 0) {
            "$activeCount 个项目工作中 · 共 $($visibleProjects.Count) 个"
        } elseif ($unreadCount -gt 0) {
            "$unreadCount 个任务完成未查看"
        } else {
            "$($visibleProjects.Count) 个项目待命"
        }
    }
    Update-PetWindowLayout
}

function Restore-AllProjectRows {
    $script:hiddenProjects.Clear()
    Save-PetPosition
    Update-PetUi
}

function Add-ChartLabel {
    param($Canvas, [string]$Text, [double]$Left, [double]$Top, [string]$Color = '#748198', [double]$Size = 10)
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.Foreground = Get-PetBrush $Color
    $label.FontSize = $Size
    [System.Windows.Controls.Canvas]::SetLeft($label, $Left)
    [System.Windows.Controls.Canvas]::SetTop($label, $Top)
    [void]$Canvas.Children.Add($label)
}

function Render-HistoryWindow {
    if ($null -eq $script:historyWindow) { return }
    $metrics = if ($null -ne $script:lastMetrics -and $script:lastMetrics.available) { $script:lastMetrics } else { Get-CodexMetrics }
    if (-not $metrics.available) { return }

    $daily = @($metrics.daily_history)
    $weekly = @($metrics.weekly_history)
    $last7 = [int64](($daily | Select-Object -Last 7 | Measure-Object -Property total_tokens -Sum).Sum)
    $last30 = [int64](($daily | Select-Object -Last 30 | Measure-Object -Property total_tokens -Sum).Sum)
    $script:historySummary.Text = '近 7 天 ' + (Format-TokenCount $last7) + '   ·   近 30 天 ' + (Format-TokenCount $last30)

    $script:dailyChartCanvas.Children.Clear()
    $chartDays = @($daily | Select-Object -Last 14)
    $chartWidth = 574.0
    $chartHeight = 118.0
    $maxDay = [double](($chartDays | Measure-Object -Property total_tokens -Maximum).Maximum)
    if ($maxDay -le 0) { $maxDay = 1 }
    $barSlot = $chartWidth / [Math]::Max(1, $chartDays.Count)
    $points = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $chartDays.Count; $i++) {
        $item = $chartDays[$i]
        $x = $i * $barSlot + 5
        $usableHeight = 82.0
        $height = [Math]::Max(2, $usableHeight * [double]$item.total_tokens / $maxDay)
        $top = 86.0 - $height
        $bar = New-Object System.Windows.Shapes.Rectangle
        $bar.Width = [Math]::Max(5, $barSlot - 9)
        $bar.Height = $height
        $bar.RadiusX = 3
        $bar.RadiusY = 3
        $bar.Fill = Get-PetBrush '#27466F'
        $bar.ToolTip = "$($item.date)：$(Format-TokenCount $item.total_tokens) Token"
        [System.Windows.Controls.Canvas]::SetLeft($bar, $x)
        [System.Windows.Controls.Canvas]::SetTop($bar, $top)
        [void]$script:dailyChartCanvas.Children.Add($bar)
        [void]$points.Add([System.Windows.Point]::new($x + ($bar.Width / 2), $top))
        if (($i % 3) -eq 0 -or $i -eq ($chartDays.Count - 1)) {
            Add-ChartLabel $script:dailyChartCanvas $item.label ($x - 2) 94 '#66738A' 9
        }
    }
    $line = New-Object System.Windows.Shapes.Polyline
    $line.Points = $points
    $line.Stroke = Get-PetBrush '#6EA8FF'
    $line.StrokeThickness = 2
    [void]$script:dailyChartCanvas.Children.Add($line)
    Add-ChartLabel $script:dailyChartCanvas ('峰值 ' + (Format-TokenCount ([int64]$maxDay))) 4 0 '#94A3BA' 10

    $script:weeklyChartCanvas.Children.Clear()
    $weekWidth = 574.0
    $weekMax = [double](($weekly | Measure-Object -Property total_tokens -Maximum).Maximum)
    if ($weekMax -le 0) { $weekMax = 1 }
    $weekSlot = $weekWidth / [Math]::Max(1, $weekly.Count)
    for ($i = 0; $i -lt $weekly.Count; $i++) {
        $item = $weekly[$i]
        $height = [Math]::Max(2, 62.0 * [double]$item.total_tokens / $weekMax)
        $bar = New-Object System.Windows.Shapes.Rectangle
        $bar.Width = [Math]::Max(12, $weekSlot - 15)
        $bar.Height = $height
        $bar.RadiusX = 5
        $bar.RadiusY = 5
        $bar.Fill = if ($i -eq ($weekly.Count - 1)) { Get-PetBrush '#57D6A2' } else { Get-PetBrush '#805AD5' }
        $bar.ToolTip = "$($item.week_start) 起：$(Format-TokenCount $item.total_tokens) Token"
        $x = $i * $weekSlot + 7
        [System.Windows.Controls.Canvas]::SetLeft($bar, $x)
        [System.Windows.Controls.Canvas]::SetTop($bar, 66.0 - $height)
        [void]$script:weeklyChartCanvas.Children.Add($bar)
        Add-ChartLabel $script:weeklyChartCanvas $item.label ($x - 2) 72 '#66738A' 9
    }

    $script:calendarGrid.Children.Clear()
    $dailyMap = @{}
    foreach ($item in $daily) { $dailyMap[$item.date] = $item }
    $today = [DateTime]::Today
    $daysFromMonday = (([int]$today.DayOfWeek + 6) % 7)
    $calendarStart = $today.AddDays(-$daysFromMonday - 35)
    $calendarItems = @()
    for ($i = 0; $i -lt 42; $i++) {
        $date = $calendarStart.AddDays($i)
        $key = $date.ToString('yyyy-MM-dd')
        $calendarItems += if ($dailyMap.ContainsKey($key)) { $dailyMap[$key] } else { [pscustomobject]@{ date=$key; total_tokens=0 } }
    }
    $calendarMax = [double](($calendarItems | Measure-Object -Property total_tokens -Maximum).Maximum)
    if ($calendarMax -le 0) { $calendarMax = 1 }
    foreach ($item in $calendarItems) {
        $date = [DateTime]::ParseExact($item.date, 'yyyy-MM-dd', $null)
        $ratio = [double]$item.total_tokens / $calendarMax
        $fill = if ($item.total_tokens -le 0) { '#151B27' } elseif ($ratio -lt 0.25) { '#19375B' } elseif ($ratio -lt 0.5) { '#24578E' } elseif ($ratio -lt 0.75) { '#3277C7' } else { '#5B9BFF' }
        $cell = New-Object System.Windows.Controls.Border
        $cell.Margin = [System.Windows.Thickness]::new(3)
        $cell.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $cell.Background = Get-PetBrush $fill
        $cell.BorderThickness = [System.Windows.Thickness]::new($(if ($date.Date -eq $today) { 1.5 } else { 0 }))
        $cell.BorderBrush = Get-PetBrush '#9EE8C6'
        $cell.ToolTip = "$($item.date)：$(Format-TokenCount $item.total_tokens) Token"
        $dayText = New-Object System.Windows.Controls.TextBlock
        $dayText.Text = $date.Day.ToString()
        $dayText.Foreground = Get-PetBrush $(if ($date.Date -gt $today) { '#4B5568' } else { '#DDE7F7' })
        $dayText.FontSize = 10
        $dayText.HorizontalAlignment = 'Center'
        $dayText.VerticalAlignment = 'Center'
        $cell.Child = $dayText
        [void]$script:calendarGrid.Children.Add($cell)
    }
}

function Show-HistoryWindow {
    if ($null -eq $script:historyWindow) {
        [xml]$historyXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex 用量历史" Width="650" Height="650" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" Topmost="False" ShowInTaskbar="False" WindowStartupLocation="CenterScreen">
  <Border x:Name="HistoryRoot" CornerRadius="24" Background="#F5202634" BorderBrush="#3B82F6" BorderThickness="1.5" Padding="22">
    <Border.Effect><DropShadowEffect Color="#90000000" BlurRadius="25" ShadowDepth="6" Opacity="0.7"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="58"/><RowDefinition Height="42"/><RowDefinition Height="165"/><RowDefinition Height="132"/><RowDefinition Height="205"/></Grid.RowDefinitions>
      <Grid>
        <StackPanel><TextBlock Text="Codex 用量历史" Foreground="White" FontSize="20" FontWeight="SemiBold"/><TextBlock Text="本地日志统计 · 最近 90 天" Foreground="#7F8CA5" FontSize="11" Margin="0,5,0,0"/></StackPanel>
        <Button x:Name="HistoryClose" Content="×" HorizontalAlignment="Right" VerticalAlignment="Top" Width="30" Height="30" Foreground="#AAB6CC" Background="Transparent" BorderThickness="0" FontSize="19" Cursor="Hand"/>
      </Grid>
      <Border Grid.Row="1" Background="#161B27" CornerRadius="12" Padding="12,8"><TextBlock x:Name="HistorySummary" Foreground="#A9B8CF" FontSize="12"/></Border>
      <Border Grid.Row="2" Background="#161B27" CornerRadius="14" Padding="12" Margin="0,10,0,0"><Grid><TextBlock Text="每日趋势 · 近 14 天" Foreground="#CBD5E8" FontSize="12"/><Canvas x:Name="DailyChart" Width="574" Height="118" Margin="0,24,0,0"/></Grid></Border>
      <Border Grid.Row="3" Background="#161B27" CornerRadius="14" Padding="12" Margin="0,10,0,0"><Grid><TextBlock Text="每周用量 · 近 8 周" Foreground="#CBD5E8" FontSize="12"/><Canvas x:Name="WeeklyChart" Width="574" Height="94" Margin="0,22,0,0"/></Grid></Border>
      <Border Grid.Row="4" Background="#161B27" CornerRadius="14" Padding="12" Margin="0,10,0,0"><Grid><Grid.RowDefinitions><RowDefinition Height="22"/><RowDefinition Height="22"/><RowDefinition/></Grid.RowDefinitions><TextBlock Text="每日用量日历 · 颜色越亮消耗越高" Foreground="#CBD5E8" FontSize="12"/><UniformGrid Grid.Row="1" Columns="7"><TextBlock Text="一" Foreground="#657188" HorizontalAlignment="Center"/><TextBlock Text="二" Foreground="#657188" HorizontalAlignment="Center"/><TextBlock Text="三" Foreground="#657188" HorizontalAlignment="Center"/><TextBlock Text="四" Foreground="#657188" HorizontalAlignment="Center"/><TextBlock Text="五" Foreground="#657188" HorizontalAlignment="Center"/><TextBlock Text="六" Foreground="#657188" HorizontalAlignment="Center"/><TextBlock Text="日" Foreground="#657188" HorizontalAlignment="Center"/></UniformGrid><UniformGrid x:Name="CalendarGrid" Grid.Row="2" Columns="7" Rows="6"/></Grid></Border>
    </Grid>
  </Border>
</Window>
'@
        $historyReader = New-Object System.Xml.XmlNodeReader $historyXaml
        $script:historyWindow = [Windows.Markup.XamlReader]::Load($historyReader)
        $script:dailyChartCanvas = $script:historyWindow.FindName('DailyChart')
        $script:weeklyChartCanvas = $script:historyWindow.FindName('WeeklyChart')
        $script:calendarGrid = $script:historyWindow.FindName('CalendarGrid')
        $script:historySummary = $script:historyWindow.FindName('HistorySummary')
        $historyRoot = $script:historyWindow.FindName('HistoryRoot')
        $historyClose = $script:historyWindow.FindName('HistoryClose')
        $historyRoot.Add_MouseLeftButtonDown({ try { $script:historyWindow.DragMove() } catch {} })
        $historyClose.Add_Click({ $script:historyWindow.Hide() })
        $script:historyWindow.Add_Closing({ param($sender,$eventArgs); if (-not $script:isExiting) { $eventArgs.Cancel = $true; $script:historyWindow.Hide() } })
    }
    $script:historyWindow.Show()
    $script:historyWindow.Activate()
    if (-not $script:historyLoaded) {
        $script:historySummary.Text = '首次加载历史日志，请稍候…'
        $script:historyWindow.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        Ensure-HistoryLoaded
        $script:lastMetrics = Get-CodexMetrics
    }
    Render-HistoryWindow
}

function Add-ComboChoice {
    param($Combo, [string]$Text, [string]$Value)
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $Text
    $item.Tag = $Value
    [void]$Combo.Items.Add($item)
}

function Select-ComboChoice {
    param($Combo, [string]$Value)
    foreach ($item in @($Combo.Items)) {
        if ([string]$item.Tag -eq $Value) { $Combo.SelectedItem = $item; return }
    }
    if ($Combo.Items.Count -gt 0) { $Combo.SelectedIndex = 0 }
}

function Sync-SettingsControls {
    Select-ComboChoice $script:refreshCombo ([string]$script:refreshSeconds)
    Select-ComboChoice $script:sortCombo $script:projectSortMode
    Select-ComboChoice $script:animationCombo $script:animationSpeed
    $script:opacitySlider.Value = $script:windowOpacityPercent
    $script:opacityValue.Text = "$($script:windowOpacityPercent)%"
    $script:completionCheck.IsChecked = $script:notifyOnCompletion
    Select-ComboChoice $script:completionDurationCombo ([string]$script:completionBubbleDurationSeconds)
    $script:completionDurationCombo.IsEnabled = $script:notifyOnCompletion
    $script:quotaCheck.IsChecked = $script:quotaAlertsEnabled
    $script:healthCheck.IsChecked = $script:healthStatusVisible
    $script:topmostCheck.IsChecked = $script:topmostEnabled
    $script:autoStartCheck.IsChecked = Test-Path -LiteralPath $script:autoStartShortcutPath
    $script:autoUpdateCheck.IsChecked = $script:autoUpdateEnabled
    $updateConnection = Get-PetUpdateConnectionStatus
    $script:updateStatus.Text = $updateConnection.detail
    $script:updateStatus.Foreground = Get-PetBrush $(if ($updateConnection.status -eq 'PASS') { '#4FD19A' } elseif ($updateConnection.status -eq 'WARN') { '#FBBF24' } else { '#F87171' })
}

function Save-ControlCenterSettings {
    try {
        $script:refreshSeconds = [int]$script:refreshCombo.SelectedItem.Tag
        $script:projectSortMode = [string]$script:sortCombo.SelectedItem.Tag
        $script:animationSpeed = [string]$script:animationCombo.SelectedItem.Tag
        $script:windowOpacityPercent = [Math]::Max(40, [Math]::Min(100, [int][Math]::Round($script:opacitySlider.Value)))
        $script:notifyOnCompletion = [bool]$script:completionCheck.IsChecked
        $script:completionBubbleDurationSeconds = [int]$script:completionDurationCombo.SelectedItem.Tag
        $script:quotaAlertsEnabled = [bool]$script:quotaCheck.IsChecked
        $script:healthStatusVisible = [bool]$script:healthCheck.IsChecked
        $script:topmostEnabled = [bool]$script:topmostCheck.IsChecked
        $script:autoUpdateEnabled = [bool]$script:autoUpdateCheck.IsChecked
        $window.Topmost = $script:topmostEnabled
        $window.Opacity = [double]$script:windowOpacityPercent / 100.0
        $script:controlCenterWindow.Topmost = $false
        if ($null -ne $script:completionBubbleWindow) {
            $script:completionBubbleWindow.Topmost = $false
            $script:completionBubbleWindow.Opacity = [double]$script:windowOpacityPercent / 100.0
        }
        Start-CompletionBubbleTimer
        $refreshTimer.Interval = [TimeSpan]::FromSeconds($script:refreshSeconds)
        Set-PetAutoStart ([bool]$script:autoStartCheck.IsChecked)
        Save-PetPosition
        Update-PetUi
        $script:settingsStatus.Text = '设置已保存并立即生效'
        $script:settingsStatus.Foreground = Get-PetBrush '#4FD19A'
    } catch {
        $script:settingsStatus.Text = '保存失败：' + $_.Exception.Message
        $script:settingsStatus.Foreground = Get-PetBrush '#F87171'
    }
}

function New-RankingRow {
    param($Item, [int]$Rank)
    $border = New-Object System.Windows.Controls.Border
    $border.Background = Get-PetBrush '#151B27'
    $border.BorderBrush = Get-PetBrush $(if ($Rank -le 3) { '#365D91' } else { '#252D3C' })
    $border.BorderThickness = [System.Windows.Thickness]::new(1)
    $border.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $border.Padding = [System.Windows.Thickness]::new(10,7,10,7)
    $border.Margin = [System.Windows.Thickness]::new(0,0,0,6)
    $border.Cursor = 'Hand'
    $border.Tag = $Item
    $border.ToolTip = ([string]$Item.project_path) + "`n双击打开该项目最近的 Codex 任务"

    $panel = New-Object System.Windows.Controls.StackPanel
    $header = New-Object System.Windows.Controls.Grid
    [void]$header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(30) }))
    [void]$header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    [void]$header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(105) }))
    $rankText = New-Object System.Windows.Controls.TextBlock
    $rankText.Text = "#$Rank"
    $rankText.Foreground = Get-PetBrush $(if ($Rank -eq 1) { '#FBBF24' } elseif ($Rank -le 3) { '#8CC2FF' } else { '#657188' })
    $rankText.FontWeight = 'Bold'
    [void]$header.Children.Add($rankText)
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = [string]$Item.project_name
    $name.Foreground = Get-PetBrush '#E7EEF9'
    $name.FontWeight = 'SemiBold'
    $name.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($name, 1)
    [void]$header.Children.Add($name)
    $value = New-Object System.Windows.Controls.TextBlock
    $value.Text = (Format-TokenCount ([int64]$Item.total_tokens)) + ' · ' + ('{0:0.00}%' -f [double]$Item.share_percent)
    $value.Foreground = Get-PetBrush '#9BB8DD'
    $value.HorizontalAlignment = 'Right'
    $value.FontSize = 11
    [System.Windows.Controls.Grid]::SetColumn($value, 2)
    [void]$header.Children.Add($value)
    [void]$panel.Children.Add($header)
    $track = New-Object System.Windows.Controls.Border
    $track.Height = 6
    $track.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $track.Background = Get-PetBrush '#2A3241'
    $track.Margin = [System.Windows.Thickness]::new(30,6,0,0)
    $barGrid = New-Object System.Windows.Controls.Grid
    $bar = New-Object System.Windows.Controls.Border
    $bar.Height = 6
    $bar.HorizontalAlignment = 'Left'
    $bar.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $bar.Background = Get-PetBrush $(if ($Rank -eq 1) { '#FBBF24' } else { '#5B9BFF' })
    $bar.Width = [Math]::Max(3, 365.0 * [double]$Item.share_percent / 100.0)
    [void]$barGrid.Children.Add($bar)
    $track.Child = $barGrid
    [void]$panel.Children.Add($track)
    $border.Child = $panel
    $border.Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        if ($eventArgs.ClickCount -lt 2) { return }
        $item = $sender.Tag
        Open-CodexThread ([string]$item.session_id) ([string]$item.project_name)
        $eventArgs.Handled = $true
    })
    return $border
}

function Render-ControlCenter {
    if ($null -eq $script:controlCenterWindow -or -not $script:controlCenterWindow.IsVisible) { return }
    if ($script:controlTabs.SelectedIndex -ne 0) { return }
    $metrics = if ($null -ne $script:lastMetrics -and $script:lastMetrics.available) { $script:lastMetrics } else { Get-CodexMetrics }
    $script:rankingPanel.Children.Clear()
    if (-not $metrics.available) {
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = '暂时无法读取用量排行'
        $label.Foreground = Get-PetBrush '#F87171'
        [void]$script:rankingPanel.Children.Add($label)
        return
    }
    $ranking = @($metrics.lifetime_ranking)
    $grandTotal = [int64](($ranking | Measure-Object -Property total_tokens -Sum).Sum)
    $script:rankingSummary.Text = "全部项目累计 $(Format-TokenCount $grandTotal) Token · 共 $($ranking.Count) 个项目"
    $rank = 0
    foreach ($item in $ranking) {
        $rank++
        [void]$script:rankingPanel.Children.Add((New-RankingRow $item $rank))
    }
}

function Add-SelfCheckRow {
    param([string]$Name, [string]$Status, [string]$Detail)
    $color = if ($Status -eq 'PASS') { '#4FD19A' } elseif ($Status -eq 'WARN') { '#FBBF24' } else { '#F87171' }
    $border = New-Object System.Windows.Controls.Border
    $border.Background = Get-PetBrush '#151B27'
    $border.CornerRadius = [System.Windows.CornerRadius]::new(9)
    $border.Padding = [System.Windows.Thickness]::new(10,7,10,7)
    $border.Margin = [System.Windows.Thickness]::new(0,0,0,5)
    $grid = New-Object System.Windows.Controls.Grid
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(115) }))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(55) }))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    $nameText = New-Object System.Windows.Controls.TextBlock
    $nameText.Text = $Name
    $nameText.Foreground = Get-PetBrush '#DDE7F7'
    [void]$grid.Children.Add($nameText)
    $statusTextBlock = New-Object System.Windows.Controls.TextBlock
    $statusTextBlock.Text = if ($Status -eq 'PASS') { '正常' } elseif ($Status -eq 'WARN') { '提示' } else { '异常' }
    $statusTextBlock.Foreground = Get-PetBrush $color
    $statusTextBlock.FontWeight = 'Bold'
    [System.Windows.Controls.Grid]::SetColumn($statusTextBlock, 1)
    [void]$grid.Children.Add($statusTextBlock)
    $detailText = New-Object System.Windows.Controls.TextBlock
    $detailText.Text = $Detail
    $detailText.Foreground = Get-PetBrush '#8794AA'
    $detailText.TextWrapping = 'Wrap'
    [System.Windows.Controls.Grid]::SetColumn($detailText, 2)
    [void]$grid.Children.Add($detailText)
    $border.Child = $grid
    [void]$script:selfCheckPanel.Children.Add($border)
}

function Invoke-PetSelfCheck {
    $script:selfCheckPanel.Children.Clear()
    $pass = 0; $warn = 0; $fail = 0
    function Add-CheckResult([string]$Name, [string]$Status, [string]$Detail) {
        if ($Status -eq 'PASS') { $script:checkPass++ } elseif ($Status -eq 'WARN') { $script:checkWarn++ } else { $script:checkFail++ }
        Add-SelfCheckRow $Name $Status $Detail
    }
    $script:checkPass = 0; $script:checkWarn = 0; $script:checkFail = 0
    Add-CheckResult '会话日志' $(if (Test-Path -LiteralPath $script:sessionsRoot) { 'PASS' } else { 'FAIL' }) $script:sessionsRoot
    try {
        $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:codexGlobalStatePath | ConvertFrom-Json
        $count = @($state.'local-projects'.PSObject.Properties).Count
        Add-CheckResult '项目名称映射' 'PASS' "$count 个 Codex 项目"
    } catch { Add-CheckResult '项目名称映射' 'FAIL' $_.Exception.Message }
    Add-CheckResult 'Codex 跳转协议' $(if (Test-Path 'Registry::HKEY_CURRENT_USER\Software\Classes\codex') { 'PASS' } else { 'FAIL' }) 'codex://threads/{id}'
    $updateConnection = Get-PetUpdateConnectionStatus
    Add-CheckResult '自动更新连接' $updateConnection.status $updateConnection.detail
    Add-CheckResult 'Codex 桌面进程' $(if (Test-CodexDesktopRunning) { 'PASS' } else { 'WARN' }) $(if ($script:codexProcessRunning) { '正在运行' } else { '当前未运行' })
    if ($null -ne $script:accountRefreshProcess) {
        Add-CheckResult '跨设备额度同步' 'WARN' '正在读取账户额度'
    } elseif ($script:accountRefreshLastSucceeded) {
        Add-CheckResult '跨设备额度同步' 'PASS' ("已同步于 {0}" -f $script:accountRateLimitAt.ToString('MM-dd HH:mm:ss'))
    } elseif (-not [string]::IsNullOrWhiteSpace($script:accountRefreshLastError)) {
        Add-CheckResult '跨设备额度同步' 'WARN' $script:accountRefreshLastError
    } else {
        Add-CheckResult '跨设备额度同步' 'WARN' '等待首次账户同步'
    }
    try {
        if (Test-Path -LiteralPath $script:projectLifetimeCachePath) {
            $cache = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:projectLifetimeCachePath | ConvertFrom-Json
            Add-CheckResult '项目累计缓存' 'PASS' "$(@($cache.files).Count) 个会话记录"
        } else { Add-CheckResult '项目累计缓存' 'WARN' '尚未建立，刷新后会自动生成' }
    } catch { Add-CheckResult '项目累计缓存' 'FAIL' $_.Exception.Message }
    $assetCount = @(Get-ChildItem -LiteralPath $catAssetRoot -Filter 'cat-*.png' -File -ErrorAction SilentlyContinue).Count
    Add-CheckResult '小猫动画资源' $(if ($assetCount -ge 8) { 'PASS' } else { 'FAIL' }) "$assetCount / 8 帧"
    Add-CheckResult '开机启动' $(if (Test-Path -LiteralPath $script:autoStartShortcutPath) { 'PASS' } else { 'WARN' }) $(if (Test-Path -LiteralPath $script:autoStartShortcutPath) { '已启用' } else { '未启用，可在设置中打开' })
    $metrics = if ($null -ne $script:lastMetrics) { $script:lastMetrics } else { Get-CodexMetrics }
    Add-CheckResult '用量数据' $(if ($metrics.available) { 'PASS' } else { 'FAIL' }) $(if ($metrics.available) { "更新于 $($metrics.updated_at)" } else { $metrics.message })
    if (Test-Path -LiteralPath $script:runtimeLogPath) {
        $log = Get-Item -LiteralPath $script:runtimeLogPath
        $status = if ($log.LastWriteTime -gt (Get-Date).AddHours(-1)) { 'WARN' } else { 'PASS' }
        Add-CheckResult '错误日志' $status "$($log.Length) 字节 · 最后写入 $($log.LastWriteTime.ToString('MM-dd HH:mm'))"
    } else { Add-CheckResult '错误日志' 'PASS' '无错误日志' }
    $script:selfCheckSummary.Text = "版本 $script:appVersion · 正常 $script:checkPass · 提示 $script:checkWarn · 异常 $script:checkFail"
    $script:selfCheckSummary.Foreground = Get-PetBrush $(if ($script:checkFail -gt 0) { '#F87171' } elseif ($script:checkWarn -gt 0) { '#FBBF24' } else { '#4FD19A' })
}

function Get-AllMigrationTasks {
    Sync-ProjectLifetimeCache
    $taskByKey = @{}
    foreach ($entry in @($script:projectLifetimeEntries.Values)) {
        $sessionPath = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($sessionPath) -or -not (Test-Path -LiteralPath $sessionPath)) { continue }
        $sessionId = [string]$entry.session_id
        if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = Get-SessionIdFromPath $sessionPath }
        $taskKey = if (-not [string]::IsNullOrWhiteSpace($sessionId)) { 'thread:' + $sessionId.ToLowerInvariant() } else { 'file:' + $sessionPath.ToLowerInvariant() }
        $file = Get-Item -LiteralPath $sessionPath -ErrorAction SilentlyContinue
        if ($null -eq $file) { continue }
        $modifiedAt = $file.LastWriteTime
        $projectName = if ([string]::IsNullOrWhiteSpace([string]$entry.project_name)) { '未识别项目' } else { [string]$entry.project_name }
        $taskTitle = if (-not [string]::IsNullOrWhiteSpace($sessionId) -and $script:threadDescriptions.ContainsKey($sessionId)) {
            [string]$script:threadDescriptions[$sessionId]
        } else {
            $projectName + ' · ' + $modifiedAt.ToString('yyyy-MM-dd HH:mm')
        }
        $state = if ($script:sessionStates.ContainsKey($sessionPath)) { $script:sessionStates[$sessionPath] } else { $null }
        $active = $null -ne $state -and [bool]$state.TaskActive
        $unread = -not $active -and -not [string]::IsNullOrWhiteSpace($sessionId) -and $script:codexUnreadThreadIds.ContainsKey($sessionId)
        $candidate = [pscustomobject]@{
            migration_key = $taskKey
            task_title = $taskTitle
            project_key = [string]$entry.project_key
            project_name = $projectName
            project_path = [string]$entry.project_path
            session_id = $sessionId
            session_path = $sessionPath
            active = [bool]$active
            unread = [bool]$unread
            last_event_at = $modifiedAt.ToString('o')
            modified_ticks = [int64]$file.LastWriteTimeUtc.Ticks
            session = [pscustomobject](Copy-UsageBucket $entry.usage)
            search_text = ($taskTitle + "`n" + $projectName + "`n" + [string]$entry.project_path + "`n" + $sessionId).ToLowerInvariant()
        }
        if (-not $taskByKey.ContainsKey($taskKey) -or [int64]$candidate.modified_ticks -gt [int64]$taskByKey[$taskKey].modified_ticks) {
            $taskByKey[$taskKey] = $candidate
        }
    }
    return @($taskByKey.Values | Sort-Object -Property @{ Expression = { [int64]$_.modified_ticks }; Descending = $true })
}

function Get-MigrationTaskByKey {
    param([string]$TaskKey)
    return @($script:migrationTasks | Where-Object { [string]$_.migration_key -eq $TaskKey } | Select-Object -First 1)[0]
}

function Sync-MigrationControls {
    param([switch]$RefreshCatalog)
    if ($null -eq $script:migrationProjectCombo) { return }
    $selectedKey = if ($null -ne $script:migrationProjectCombo.SelectedItem) { [string]$script:migrationProjectCombo.SelectedItem.Tag } else { '' }
    if ($RefreshCatalog -or $null -eq $script:migrationTasks -or $script:migrationTasks.Count -eq 0) {
        $script:migrationTasks = @(Get-AllMigrationTasks)
    }
    $query = if ($null -ne $script:migrationSearchBox) { [string]$script:migrationSearchBox.Text } else { '' }
    $query = $query.Trim().ToLowerInvariant()
    $filteredTasks = if ([string]::IsNullOrWhiteSpace($query)) {
        @($script:migrationTasks)
    } else {
        $terms = @($query -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        @($script:migrationTasks | Where-Object {
            $haystack = [string]$_.search_text
            $matched = $true
            foreach ($term in $terms) { if (-not $haystack.Contains($term)) { $matched = $false; break } }
            $matched
        })
    }
    $filteredTasks = @($filteredTasks)
    $script:migrationProjectCombo.Items.Clear()
    foreach ($task in $filteredTasks) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $stateText = if ([bool]$task.active) { '工作中' } elseif ([bool]$task.unread) { '完成未读' } else { '已完成' }
        $dateText = ([DateTimeOffset]::Parse([string]$task.last_event_at)).ToLocalTime().ToString('yyyy-MM-dd')
        $item.Content = ([string]$task.task_title) + ' · ' + ([string]$task.project_name) + ' · ' + $dateText + ' · ' + $stateText
        $item.ToolTip = ([string]$task.project_path) + "`n会话 ID：" + ([string]$task.session_id)
        $item.Tag = [string]$task.migration_key
        [void]$script:migrationProjectCombo.Items.Add($item)
        if ([string]$task.migration_key -eq $selectedKey) { $script:migrationProjectCombo.SelectedItem = $item }
    }
    if ($null -eq $script:migrationProjectCombo.SelectedItem -and $script:migrationProjectCombo.Items.Count -gt 0) {
        $script:migrationProjectCombo.SelectedIndex = 0
    }
    $hasTask = $script:migrationProjectCombo.Items.Count -gt 0
    $script:exportMigrationButton.IsEnabled = $hasTask
    $script:exportMigrationButton.Opacity = if ($hasTask) { 1.0 } else { 0.5 }
    if ($null -ne $script:migrationResultCount) {
        $script:migrationResultCount.Text = "显示 $($filteredTasks.Count) / 共 $($script:migrationTasks.Count) 条本地任务"
        $script:migrationResultCount.Foreground = Get-PetBrush $(if ($hasTask) { '#7F8CA5' } else { '#FBBF24' })
    }
}

function Get-SafeMigrationName {
    param([string]$Name)
    $safe = if ([string]::IsNullOrWhiteSpace($Name)) { 'Codex任务' } else { $Name }
    foreach ($character in [System.IO.Path]::GetInvalidFileNameChars()) { $safe = $safe.Replace([string]$character, '_') }
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'Codex任务' }
    if ($safe.Length -gt 48) { $safe = $safe.Substring(0,48) }
    return $safe
}

function Get-SafeGitRemoteUrl {
    param([string]$RemoteUrl)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return '' }
    return ($RemoteUrl -replace '^(https?://)[^/@]+@', '$1')
}

function Get-FileSha256 {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Export-CodexTaskMigration {
    if ($null -eq $script:migrationProjectCombo.SelectedItem) { return }
    $taskKey = [string]$script:migrationProjectCombo.SelectedItem.Tag
    $project = Get-MigrationTaskByKey $taskKey
    if ($null -eq $project) {
        $script:migrationStatus.Text = '找不到所选任务，请先刷新后再试'
        $script:migrationStatus.Foreground = Get-PetBrush '#F87171'
        return
    }
    $sessionPath = [string]$project.session_path
    if ([string]::IsNullOrWhiteSpace($sessionPath) -or -not (Test-Path -LiteralPath $sessionPath)) {
        $script:migrationStatus.Text = '所选任务的完整对话日志不存在，无法导出'
        $script:migrationStatus.Foreground = Get-PetBrush '#F87171'
        return
    }

    $script:exportMigrationButton.IsEnabled = $false
    $script:migrationStatus.Text = '正在整理完整对话和项目状态…'
    $script:migrationStatus.Foreground = Get-PetBrush '#79AFFF'
    $script:controlCenterWindow.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    $migrationTempRoot = Join-Path (Join-Path $env:TEMP 'CodexUsagePet\migration-export') ([guid]::NewGuid().ToString('N'))
    try {
        $conversationDirectory = Join-Path $migrationTempRoot 'conversation'
        $gitDirectory = Join-Path $migrationTempRoot 'git'
        New-Item -ItemType Directory -Path $conversationDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $gitDirectory -Force | Out-Null

        $conversationCopy = Join-Path $conversationDirectory 'session.jsonl'
        Copy-Item -LiteralPath $sessionPath -Destination $conversationCopy -Force
        $conversationHash = Get-FileSha256 $conversationCopy

        $projectPath = [string]$project.project_path
        $gitAvailable = $false
        $gitBranch = ''
        $gitCommit = ''
        $gitRemote = ''
        $gitStatus = ''
        $bundleIncluded = $false
        $patchIncluded = $false
        $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        $previousGitErrorPreference = $ErrorActionPreference
        try {
            # Git uses a non-zero exit code for ordinary cases such as a non-repository
            # project or a repository without origin. Treat those as optional metadata,
            # not as a failed task migration.
            $ErrorActionPreference = 'Continue'
            if ($null -ne $gitCommand -and -not [string]::IsNullOrWhiteSpace($projectPath) -and (Test-Path -LiteralPath $projectPath -PathType Container)) {
                $insideWorkTree = (& $gitCommand.Source -C $projectPath rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
                if ($LASTEXITCODE -eq 0 -and $insideWorkTree -eq 'true') {
                    $gitAvailable = $true
                    $gitBranch = (& $gitCommand.Source -C $projectPath branch --show-current 2>$null | Out-String).Trim()
                    $gitCommit = (& $gitCommand.Source -C $projectPath rev-parse HEAD 2>$null | Out-String).Trim()
                    $gitRemote = Get-SafeGitRemoteUrl ((& $gitCommand.Source -C $projectPath remote get-url origin 2>$null | Out-String).Trim())
                    $gitStatus = (& $gitCommand.Source -C $projectPath status --short --branch 2>$null | Out-String).TrimEnd()
                    Set-Content -LiteralPath (Join-Path $gitDirectory 'status.txt') -Value $gitStatus -Encoding UTF8

                    $bundlePath = Join-Path $gitDirectory 'repository.bundle'
                    & $gitCommand.Source -C $projectPath bundle create $bundlePath HEAD 2>$null | Out-Null
                    $bundleIncluded = $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $bundlePath)
                    if (-not $bundleIncluded -and (Test-Path -LiteralPath $bundlePath)) { Remove-Item -LiteralPath $bundlePath -Force }

                    $patchPath = Join-Path $gitDirectory 'working-tree.patch'
                    & $gitCommand.Source -C $projectPath diff --binary HEAD ("--output=$patchPath") 2>$null | Out-Null
                    $patchIncluded = $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $patchPath) -and (Get-Item -LiteralPath $patchPath).Length -gt 0
                    if (-not $patchIncluded -and (Test-Path -LiteralPath $patchPath)) { Remove-Item -LiteralPath $patchPath -Force }

                    $untracked = (& $gitCommand.Source -C $projectPath ls-files --others --exclude-standard 2>$null | Out-String).TrimEnd()
                    Set-Content -LiteralPath (Join-Path $gitDirectory 'untracked-files.txt') -Value $untracked -Encoding UTF8
                }
            }
        } finally {
            $ErrorActionPreference = $previousGitErrorPreference
        }

        $exportedAt = [DateTimeOffset]::Now
        $handoffLines = @(
            '# Codex 任务迁移说明',
            '',
            ('- 任务：' + [string]$project.task_title),
            ('- 项目：' + [string]$project.project_name),
            ('- 原电脑项目路径：' + $projectPath),
            ('- 会话 ID：' + [string]$project.session_id),
            ('- 最后活动：' + [string]$project.last_event_at),
            ('- 导出时间：' + $exportedAt.ToString('yyyy-MM-dd HH:mm:ss zzz')),
            ('- Git 分支：' + $(if ([string]::IsNullOrWhiteSpace($gitBranch)) { '未识别' } else { $gitBranch })),
            ('- Git 提交：' + $(if ([string]::IsNullOrWhiteSpace($gitCommit)) { '未识别' } else { $gitCommit })),
            ('- Git 远端：' + $(if ([string]::IsNullOrWhiteSpace($gitRemote)) { '未配置或未识别' } else { $gitRemote })),
            '',
            '## 在另一台电脑继续',
            '',
            '1. 安装 Codex 并登录自己的同一账号。',
            '2. 优先从上述 Git 远端克隆项目；没有远端时，可用 `git/repository.bundle` 克隆当前已提交内容。',
            '3. 若存在 `git/working-tree.patch`，在目标仓库中执行 `git apply --binary working-tree.patch` 恢复已跟踪但未提交的修改。',
            '4. 查看 `git/untracked-files.txt`；未跟踪文件仅列出名称，不会自动打包，需自行确认后迁移。',
            '5. 在新电脑的 Codex 中打开项目并创建新任务，让 Codex 先读取本文件和 `conversation/session.jsonl`，然后继续。',
            '',
            '## 重要说明',
            '',
            '- `conversation/session.jsonl` 是完整原始对话记录，可能包含提示词、命令输出、本地路径和其他隐私。',
            '- 迁移包不包含 Codex 登录令牌、账户授权文件或桌面宠物设置。',
            '- 当前没有使用未经官方保证的方式把日志强行写回 Codex 会话目录；导入后会以新任务安全接续。'
        )
        Set-Content -LiteralPath (Join-Path $migrationTempRoot 'HANDOFF.md') -Value ($handoffLines -join "`r`n") -Encoding UTF8
        $continuePrompt = @(
            '这是从另一台电脑迁移来的 Codex 任务。',
            '请先完整读取迁移包中的 HANDOFF.md 与 conversation/session.jsonl，理解原对话目标、已经完成的工作、关键决定和剩余事项。',
            '然后检查当前项目的 Git 分支、提交和工作区是否与 HANDOFF.md 一致；不要重复已经完成的工作。',
            '先用简短中文告诉我你已恢复了哪些上下文，再从原任务最后未完成的位置继续。'
        ) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $migrationTempRoot 'CONTINUE-PROMPT.txt') -Value $continuePrompt -Encoding UTF8

        $manifest = [pscustomobject]@{
            format = 'codex-usage-pet-task-migration'
            format_version = 1
            app_version = $script:appVersion
            exported_at = $exportedAt.ToString('o')
            project_key = [string]$project.project_key
            project_name = [string]$project.project_name
            task_title = [string]$project.task_title
            original_project_path = $projectPath
            session_id = [string]$project.session_id
            session_file_sha256 = $conversationHash
            git = [pscustomobject]@{
                available = $gitAvailable
                branch = $gitBranch
                commit = $gitCommit
                remote = $gitRemote
                repository_bundle_included = $bundleIncluded
                working_tree_patch_included = $patchIncluded
            }
            contains_complete_conversation = $true
            contains_credentials = $false
            untracked_files_included = $false
        }
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $migrationTempRoot 'manifest.json') -Encoding UTF8

        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $desktop = [Environment]::GetFolderPath('Desktop')
        $outputDirectory = Join-Path $desktop 'Codex任务迁移'
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        $safeName = Get-SafeMigrationName ([string]$project.task_title)
        $zipPath = Join-Path $outputDirectory ("$safeName-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
        [System.IO.Compression.ZipFile]::CreateFromDirectory($migrationTempRoot, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        $script:migrationStatus.Text = '迁移包已导出到桌面：' + [System.IO.Path]::GetFileName($zipPath)
        $script:migrationStatus.Foreground = Get-PetBrush '#4FD19A'
        Start-Process -FilePath explorer.exe -ArgumentList ('/select,"{0}"' -f $zipPath)
    } catch {
        $script:migrationStatus.Text = '导出失败：' + $_.Exception.Message
        $script:migrationStatus.Foreground = Get-PetBrush '#F87171'
    } finally {
        $script:exportMigrationButton.IsEnabled = $true
        if (-not [string]::IsNullOrWhiteSpace($migrationTempRoot) -and
            $migrationTempRoot.StartsWith((Join-Path $env:TEMP 'CodexUsagePet\migration-export'), [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $migrationTempRoot)) {
            Remove-Item -LiteralPath $migrationTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Import-CodexTaskMigration {
    try {
        $script:migrationStatus.Text = '请选择从另一台电脑带来的迁移包…'
        $script:migrationStatus.Foreground = Get-PetBrush '#79AFFF'
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = '选择 Codex 任务迁移包'
        $dialog.Filter = 'Codex 任务迁移包 (*.zip)|*.zip'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($script:controlCenterWindow) -ne $true) {
            $script:migrationStatus.Text = '已取消导入'
            $script:migrationStatus.Foreground = Get-PetBrush '#7F8CA5'
            return
        }
        $zipPath = [string]$dialog.FileName
        $script:migrationStatus.Text = '正在校验并展开迁移包…'
        $script:migrationStatus.Foreground = Get-PetBrush '#79AFFF'
        $script:controlCenterWindow.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $desktop = [Environment]::GetFolderPath('Desktop')
        $importRoot = Join-Path (Join-Path $desktop 'Codex任务迁移') ('已导入-' + (Get-SafeMigrationName ([System.IO.Path]::GetFileNameWithoutExtension($zipPath))) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $importRoot -Force | Out-Null
        $destinationRoot = [System.IO.Path]::GetFullPath($importRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $archive.Entries) {
                $targetPath = [System.IO.Path]::GetFullPath((Join-Path $importRoot $entry.FullName))
                if (-not $targetPath.StartsWith($destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw '迁移包包含不安全路径，已停止导入。' }
                if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                    continue
                }
                $targetDirectory = Split-Path -Parent $targetPath
                New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
                $inputStream = $entry.Open()
                $outputStream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
            }
        } finally {
            $archive.Dispose()
        }
        $manifestPath = Join-Path $importRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw '这不是有效的 Codex 任务迁移包：缺少 manifest.json。' }
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
        if ([string]$manifest.format -ne 'codex-usage-pet-task-migration') { throw '迁移包格式无法识别。' }
        $conversationPath = Join-Path $importRoot 'conversation\session.jsonl'
        if (-not (Test-Path -LiteralPath $conversationPath)) { throw '迁移包缺少完整对话日志。' }
        $actualHash = Get-FileSha256 $conversationPath
        if ($actualHash -ne [string]$manifest.session_file_sha256) { throw '对话日志校验失败，迁移包可能不完整。' }
        $script:migrationStatus.Text = '已安全导入并校验；请按 HANDOFF.md 在 Codex 新任务中继续'
        $script:migrationStatus.Foreground = Get-PetBrush '#4FD19A'
        $handoffPath = Join-Path $importRoot 'HANDOFF.md'
        Start-Process explorer.exe $importRoot
        if (Test-Path -LiteralPath $handoffPath) { Start-Process $handoffPath }
    } catch {
        $script:migrationStatus.Text = '导入失败：' + $_.Exception.Message
        $script:migrationStatus.Foreground = Get-PetBrush '#F87171'
    }
}

function Initialize-ControlCenter {
    if ($null -ne $script:controlCenterWindow) { return }
    [xml]$controlXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex 助手控制中心" Width="520" Height="610" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" Topmost="False" ShowInTaskbar="False" WindowStartupLocation="CenterScreen">
  <Border x:Name="ControlRoot" CornerRadius="22" Background="#F5202634" BorderBrush="#4D78B8" BorderThickness="1.5" Padding="18">
    <Border.Effect><DropShadowEffect Color="#90000000" BlurRadius="25" ShadowDepth="6" Opacity="0.7"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition/><RowDefinition Height="34"/></Grid.RowDefinitions>
      <Grid x:Name="ControlHeader">
        <StackPanel><TextBlock Text="Codex 助手控制中心" Foreground="White" FontSize="18" FontWeight="SemiBold"/><TextBlock Text="排行·设置·迁移·诊断" Foreground="#7F8CA5" FontSize="10" Margin="0,3,0,0"/></StackPanel>
        <Button x:Name="ControlClose" Content="×" HorizontalAlignment="Right" VerticalAlignment="Top" Width="28" Height="28" Foreground="#AAB6CC" Background="Transparent" BorderThickness="0" FontSize="18" Cursor="Hand"/>
      </Grid>
      <TabControl x:Name="ControlTabs" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="#DDE7F7">
        <TabItem Header="用量排行">
          <Grid Margin="0,10,0,0"><Grid.RowDefinitions><RowDefinition Height="30"/><RowDefinition/></Grid.RowDefinitions><TextBlock x:Name="RankingSummary" Foreground="#93A4BD" FontSize="11"/><ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="RankingPanel"/></ScrollViewer></Grid>
        </TabItem>
        <TabItem Header="常规设置">
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="8,14,8,0">
            <TextBlock Text="显示与刷新" Foreground="#79AFFF" FontWeight="SemiBold" FontSize="13"/>
            <Grid Margin="0,10,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text="刷新间隔" Foreground="#CBD5E8" VerticalAlignment="Center"/><ComboBox x:Name="RefreshCombo" Grid.Column="1" Height="27"/></Grid>
            <Grid Margin="0,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text="项目排序" Foreground="#CBD5E8" VerticalAlignment="Center"/><ComboBox x:Name="SortCombo" Grid.Column="1" Height="27"/></Grid>
            <Grid Margin="0,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text="小猫动画速度" Foreground="#CBD5E8" VerticalAlignment="Center"/><ComboBox x:Name="AnimationCombo" Grid.Column="1" Height="27"/></Grid>
            <Grid Margin="0,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text="窗口透明度" Foreground="#CBD5E8" VerticalAlignment="Center"/><Grid Grid.Column="1"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><Slider x:Name="OpacitySlider" Minimum="40" Maximum="100" Value="100" TickFrequency="5" IsSnapToTickEnabled="True" VerticalAlignment="Center" ToolTip="调整主助手窗口透明度"/><TextBlock x:Name="OpacityValue" Grid.Column="1" Text="100%" Foreground="#93A4BD" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid></Grid>
            <TextBlock Text="通知与系统" Foreground="#79AFFF" FontWeight="SemiBold" FontSize="13" Margin="0,18,0,0"/>
            <CheckBox x:Name="CompletionCheck" Content="项目任务完成时通知" Foreground="#CBD5E8" Margin="0,10,0,0"/>
            <Grid Margin="22,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="148"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBlock Text="完成气泡停留时间" Foreground="#AEBBD0" VerticalAlignment="Center"/><ComboBox x:Name="CompletionDurationCombo" Grid.Column="1" Height="27"/></Grid>
            <CheckBox x:Name="QuotaCheck" Content="80% / 90% 额度通知" Foreground="#CBD5E8" Margin="0,8,0,0"/>
            <CheckBox x:Name="HealthCheck" Content="主窗口显示数据健康状态" Foreground="#CBD5E8" Margin="0,8,0,0"/>
            <CheckBox x:Name="TopmostCheck" Content="仅主助手窗口始终置顶" Foreground="#CBD5E8" Margin="0,8,0,0"/>
            <CheckBox x:Name="AutoStartCheck" Content="登录 Windows 后自动启动" Foreground="#CBD5E8" Margin="0,8,0,0"/>
            <CheckBox x:Name="AutoUpdateCheck" Content="每次启动时自动检查更新" Foreground="#CBD5E8" Margin="0,8,0,0"/>
            <StackPanel Orientation="Horizontal" Margin="0,14,0,0"><Button x:Name="SettingsSave" Content="保存并应用" Width="110" Height="32" Background="#3B82F6" Foreground="White" BorderThickness="0" Cursor="Hand"/><Button x:Name="SettingsDefaults" Content="恢复推荐值" Width="100" Height="32" Margin="10,0,0,0" Background="#252E3F" Foreground="#CBD5E8" BorderThickness="0" Cursor="Hand"/><Button x:Name="CheckUpdateButton" Content="检查更新" Width="85" Height="32" Margin="10,0,0,0" Background="#315D91" Foreground="White" BorderThickness="0" Cursor="Hand"/></StackPanel>
            <TextBlock x:Name="SettingsStatus" Foreground="#7F8CA5" FontSize="11" Margin="0,10,0,0"/>
            <TextBlock x:Name="UpdateStatus" Text="更新功能需要连接独立 GitHub 仓库" Foreground="#7F8CA5" FontSize="10" Margin="0,5,0,0" TextWrapping="Wrap"/>
          </StackPanel></ScrollViewer>
        </TabItem>
        <TabItem Header="任务迁移">
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="8,16,8,0">
            <TextBlock Text="一键迁移到另一台电脑" Foreground="#79AFFF" FontWeight="SemiBold" FontSize="14"/>
            <TextBlock Text="导出完整对话、Git 提交、当前分支和已跟踪文件的工作区补丁。不会导出登录令牌或账户授权。" Foreground="#AEBBD0" FontSize="11" TextWrapping="Wrap" Margin="0,7,0,0"/>
            <TextBlock Text="搜索全部本地任务" Foreground="#CBD5E8" Margin="0,16,0,6"/>
            <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="62"/></Grid.ColumnDefinitions><TextBox x:Name="MigrationSearchBox" Height="30" Padding="8,4" ToolTip="可搜索任务名、项目名、路径或会话 ID"/><Button x:Name="MigrationSearchClear" Grid.Column="1" Content="清空" Height="30" Margin="7,0,0,0" Background="#252E3F" Foreground="#CBD5E8" BorderThickness="0" Cursor="Hand"/></Grid>
            <TextBlock x:Name="MigrationResultCount" Text="正在读取全部本地任务…" Foreground="#7F8CA5" FontSize="10" Margin="0,6,0,0"/>
            <TextBlock Text="选择要迁移的任务" Foreground="#CBD5E8" Margin="0,10,0,6"/>
            <ComboBox x:Name="MigrationProjectCombo" Height="30" MaxDropDownHeight="280" IsTextSearchEnabled="False"/>
            <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
              <Button x:Name="ExportMigrationButton" Content="一键导出到桌面" Width="132" Height="34" Background="#2E8B68" Foreground="White" BorderThickness="0" Cursor="Hand"/>
              <Button x:Name="ImportMigrationButton" Content="导入迁移包" Width="106" Height="34" Margin="10,0,0,0" Background="#315D91" Foreground="White" BorderThickness="0" Cursor="Hand"/>
            </StackPanel>
            <Border Background="#182130" BorderBrush="#2D3A4D" BorderThickness="1" CornerRadius="10" Padding="12" Margin="0,18,0,0">
              <StackPanel>
                <TextBlock Text="迁移包会包含" Foreground="#DDE7F7" FontWeight="SemiBold"/>
                <TextBlock Text="• 完整原始对话日志（JSONL）&#x0a;• 项目、会话、分支、提交和远端信息&#x0a;• Git 仓库 bundle 与已跟踪文件补丁&#x0a;• HANDOFF 接续说明和可直接使用的继续提示词" Foreground="#93A4BD" FontSize="11" TextWrapping="Wrap" Margin="0,7,0,0"/>
              </StackPanel>
            </Border>
            <Border Background="#30291A" BorderBrush="#6B5524" BorderThickness="1" CornerRadius="10" Padding="12" Margin="0,12,0,0">
              <TextBlock Text="隐私提醒：完整对话可能含本地路径、命令输出和敏感内容。仅通过可信方式传给自己的另一台电脑。未跟踪文件只列清单，不会自动打包。" Foreground="#E7C77B" FontSize="10.5" TextWrapping="Wrap"/>
            </Border>
            <TextBlock x:Name="MigrationStatus" Foreground="#7F8CA5" FontSize="11" Margin="0,14,0,0" TextWrapping="Wrap"/>
          </StackPanel></ScrollViewer>
        </TabItem>
        <TabItem Header="版本与自检">
          <Grid Margin="0,12,0,0"><Grid.RowDefinitions><RowDefinition Height="34"/><RowDefinition Height="38"/><RowDefinition/></Grid.RowDefinitions><TextBlock x:Name="SelfCheckSummary" Foreground="#AAB6CC" FontSize="12"/><Button x:Name="RunSelfCheck" Grid.Row="1" Content="立即重新检查" Width="125" Height="28" HorizontalAlignment="Left" Background="#315D91" Foreground="White" BorderThickness="0" Cursor="Hand"/><ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="SelfCheckPanel"/></ScrollViewer></Grid>
        </TabItem>
      </TabControl>
      <TextBlock Grid.Row="2" Text="项目行和排行榜均需双击跳转 Codex 任务" Foreground="#657188" FontSize="10" VerticalAlignment="Bottom"/>
    </Grid>
  </Border>
</Window>
'@
    $controlReader = New-Object System.Xml.XmlNodeReader $controlXaml
    $script:controlCenterWindow = [Windows.Markup.XamlReader]::Load($controlReader)
    $script:controlCenterWindow.Topmost = $false
    $root = $script:controlCenterWindow.FindName('ControlRoot')
    $controlHeader = $script:controlCenterWindow.FindName('ControlHeader')
    $close = $script:controlCenterWindow.FindName('ControlClose')
    $script:controlTabs = $script:controlCenterWindow.FindName('ControlTabs')
    $script:rankingSummary = $script:controlCenterWindow.FindName('RankingSummary')
    $script:rankingPanel = $script:controlCenterWindow.FindName('RankingPanel')
    $script:refreshCombo = $script:controlCenterWindow.FindName('RefreshCombo')
    $script:sortCombo = $script:controlCenterWindow.FindName('SortCombo')
    $script:animationCombo = $script:controlCenterWindow.FindName('AnimationCombo')
    $script:opacitySlider = $script:controlCenterWindow.FindName('OpacitySlider')
    $script:opacityValue = $script:controlCenterWindow.FindName('OpacityValue')
    $script:completionCheck = $script:controlCenterWindow.FindName('CompletionCheck')
    $script:completionDurationCombo = $script:controlCenterWindow.FindName('CompletionDurationCombo')
    $script:quotaCheck = $script:controlCenterWindow.FindName('QuotaCheck')
    $script:healthCheck = $script:controlCenterWindow.FindName('HealthCheck')
    $script:topmostCheck = $script:controlCenterWindow.FindName('TopmostCheck')
    $script:autoStartCheck = $script:controlCenterWindow.FindName('AutoStartCheck')
    $script:autoUpdateCheck = $script:controlCenterWindow.FindName('AutoUpdateCheck')
    $script:settingsStatus = $script:controlCenterWindow.FindName('SettingsStatus')
    $script:updateStatus = $script:controlCenterWindow.FindName('UpdateStatus')
    $script:migrationSearchBox = $script:controlCenterWindow.FindName('MigrationSearchBox')
    $script:migrationSearchClear = $script:controlCenterWindow.FindName('MigrationSearchClear')
    $script:migrationResultCount = $script:controlCenterWindow.FindName('MigrationResultCount')
    $script:migrationProjectCombo = $script:controlCenterWindow.FindName('MigrationProjectCombo')
    $script:exportMigrationButton = $script:controlCenterWindow.FindName('ExportMigrationButton')
    $script:importMigrationButton = $script:controlCenterWindow.FindName('ImportMigrationButton')
    $script:migrationStatus = $script:controlCenterWindow.FindName('MigrationStatus')
    $script:selfCheckSummary = $script:controlCenterWindow.FindName('SelfCheckSummary')
    $script:selfCheckPanel = $script:controlCenterWindow.FindName('SelfCheckPanel')
    foreach ($seconds in @(2,5,10,30)) { Add-ComboChoice $script:refreshCombo "$seconds 秒" ([string]$seconds) }
    Add-ComboChoice $script:completionDurationCombo '5 秒' '5'
    Add-ComboChoice $script:completionDurationCombo '10 秒' '10'
    Add-ComboChoice $script:completionDurationCombo '30 秒' '30'
    Add-ComboChoice $script:completionDurationCombo '永久存在' '0'
    Add-ComboChoice $script:sortCombo '累计消耗从高到低' 'lifetime'
    Add-ComboChoice $script:sortCombo '最近活动优先' 'recent'
    Add-ComboChoice $script:animationCombo '安静' 'quiet'
    Add-ComboChoice $script:animationCombo '标准' 'normal'
    Add-ComboChoice $script:animationCombo '活泼' 'fast'
    $script:opacitySlider.Add_ValueChanged({
        $opacityPreview = [Math]::Max(40, [Math]::Min(100, [int][Math]::Round($script:opacitySlider.Value)))
        $script:opacityValue.Text = "$opacityPreview%"
    })
    $script:completionCheck.Add_Checked({ $script:completionDurationCombo.IsEnabled = $true })
    $script:completionCheck.Add_Unchecked({ $script:completionDurationCombo.IsEnabled = $false })
    $controlHeader.Add_MouseLeftButtonDown({ try { $script:controlCenterWindow.DragMove() } catch {} })
    $close.Add_Click({ $script:controlCenterWindow.Hide() })
    $script:controlCenterWindow.Add_Closing({ param($sender,$eventArgs); if (-not $script:isExiting) { $eventArgs.Cancel = $true; $script:controlCenterWindow.Hide() } })
    $script:controlCenterWindow.FindName('SettingsSave').Add_Click({ Save-ControlCenterSettings })
    $script:controlCenterWindow.FindName('SettingsDefaults').Add_Click({
        Select-ComboChoice $script:refreshCombo '2'; Select-ComboChoice $script:sortCombo 'lifetime'; Select-ComboChoice $script:animationCombo 'normal'; Select-ComboChoice $script:completionDurationCombo '10'; $script:opacitySlider.Value = 100
        $script:completionCheck.IsChecked = $true; $script:quotaCheck.IsChecked = $true; $script:healthCheck.IsChecked = $true; $script:topmostCheck.IsChecked = $true; $script:autoUpdateCheck.IsChecked = $true
        $script:settingsStatus.Text = '已填入推荐值，点击“保存并应用”生效'
    })
    $script:controlCenterWindow.FindName('CheckUpdateButton').Add_Click({ Start-PetUpdateCheck })
    $script:migrationSearchBox.Add_TextChanged({ Sync-MigrationControls })
    $script:migrationSearchClear.Add_Click({ $script:migrationSearchBox.Clear(); $script:migrationSearchBox.Focus() })
    $script:exportMigrationButton.Add_Click({ Export-CodexTaskMigration })
    $script:importMigrationButton.Add_Click({ Import-CodexTaskMigration })
    $script:controlCenterWindow.FindName('RunSelfCheck').Add_Click({ Invoke-PetSelfCheck })
    $script:controlTabs.Add_SelectionChanged({
        param($sender, $eventArgs)
        if (-not $script:controlCenterLoaded) { return }
        if ($eventArgs.OriginalSource -ne $script:controlTabs) { return }
        if ($script:controlTabs.SelectedIndex -eq 0) { Render-ControlCenter }
        elseif ($script:controlTabs.SelectedIndex -eq 1) { Sync-SettingsControls }
        elseif ($script:controlTabs.SelectedIndex -eq 2) { Sync-MigrationControls -RefreshCatalog }
        elseif ($script:controlTabs.SelectedIndex -eq 3) { Invoke-PetSelfCheck }
    })
    $script:controlCenterLoaded = $true
}

function Show-ControlCenter {
    param([int]$TabIndex = 0)
    Initialize-ControlCenter
    $script:controlTabs.SelectedIndex = [Math]::Max(0, [Math]::Min(3, $TabIndex))
    if (-not $script:controlCenterWindow.IsVisible) { $script:controlCenterWindow.Show() }
    $script:controlCenterWindow.Activate()
    if ($TabIndex -eq 0) { Render-ControlCenter }
    elseif ($TabIndex -eq 1) { Sync-SettingsControls }
    elseif ($TabIndex -eq 2) { Sync-MigrationControls -RefreshCatalog }
    else { Invoke-PetSelfCheck }
}

function Check-UsageAlerts {
    param($Metrics)
    if (-not $script:quotaAlertsEnabled -or $null -eq $Metrics.used_percent -or $null -eq $Metrics.resets_at -or $null -eq $notifyIcon) { return }
    $resetAt = [int64]$Metrics.resets_at
    if ($script:alertResetAt -ne $resetAt) {
        $script:alertResetAt = $resetAt
        $script:alerted80 = $false
        $script:alerted90 = $false
    }
    $used = [double]$Metrics.used_percent
    if ($used -ge 90 -and -not $script:alerted90) {
        $notifyIcon.BalloonTipTitle = 'Codex 额度提醒 · 已使用 90%'
        $notifyIcon.BalloonTipText = '当前额度仅剩 ' + ('{0:0.##}%' -f $Metrics.remaining_percent) + '，' + $Metrics.reset_label
        $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $notifyIcon.ShowBalloonTip(10000)
        $script:alerted80 = $true
        $script:alerted90 = $true
        Save-PetPosition
    } elseif ($used -ge 80 -and -not $script:alerted80) {
        $notifyIcon.BalloonTipTitle = 'Codex 额度提醒 · 已使用 80%'
        $notifyIcon.BalloonTipText = '当前额度剩余 ' + ('{0:0.##}%' -f $Metrics.remaining_percent) + '，请留意后续用量。'
        $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notifyIcon.ShowBalloonTip(10000)
        $script:alerted80 = $true
        Save-PetPosition
    }
}

function Update-PetUi {
    param([switch]$ForceAccountSync)

    $metrics = Get-CodexMetrics -ForceAccountSync:$ForceAccountSync
    $script:lastMetrics = $metrics
    if (-not $metrics.available) {
        $statusText.Text = $metrics.message
        if ($script:idleCatFrames.Count -gt 0) { $petSprite.Source = $script:idleCatFrames[0] }
        $remainingText.Text = '--%'
        Update-DataHealthStatus $metrics
        return
    }

    Check-ProjectCompletionNotifications $metrics
    $todayTokensText.Text = Format-TokenCount $metrics.today.total_tokens
    $outputText.Text = Format-TokenCount $metrics.today.output_tokens
    $cacheText.Text = ('{0:0.0}%' -f $metrics.cache_ratio)
    $modelText.Text = if ([string]::IsNullOrWhiteSpace($metrics.model)) { 'Codex · 本地日志模式' } else { $metrics.model + ' · 本地日志模式' }
    Render-ProjectRows $metrics

    if ($null -ne $metrics.remaining_percent) {
        $remaining = [double]$metrics.remaining_percent
        $remainingText.Text = ('{0:0.##}%' -f $remaining)
        $remainingText.ToolTip = if ([string]$metrics.quota_source -eq 'account_live') {
            "来自 Codex 账户实时额度（包含其他电脑）`n同步时间：$($metrics.account_synced_at)`n账户接口按整数百分比返回，不补零伪装精度。"
        } elseif ([string]$metrics.quota_source -eq 'account_cached') {
            "显示最近一次 Codex 账户额度快照（包含其他电脑）`n快照时间：$($metrics.account_synced_at)`n当前正在同步或最近一次同步失败。"
        } else {
            '账户同步暂不可用，当前采用本机日志额度；日志返回整数时不会补零伪装成小数精度。'
        }
        $limitTitle.Text = '额度剩余 · ' + (Get-WindowLabel $metrics.window_minutes)
        $resetText.Text = $metrics.reset_label
        $availableWidth = [Math]::Max(0, $progressHost.ActualWidth)
        if ($availableWidth -le 0) { $availableWidth = 194 }
        $progressFill.Width = $availableWidth * $remaining / 100.0

        if ($remaining -le 20) {
            $progressFill.Background = '#F87171'
            $remainingText.Foreground = '#FCA5A5'
            $rootCard.BorderBrush = '#EF4444'
        } elseif ($remaining -le 45) {
            $progressFill.Background = '#FBBF24'
            $remainingText.Foreground = '#FCD34D'
            $rootCard.BorderBrush = '#F59E0B'
        } else {
            $progressFill.Background = '#4FD19A'
            $remainingText.Foreground = '#70D6A3'
            $rootCard.BorderBrush = '#3B82F6'
        }
    } else {
        $remainingText.Text = '--%'
        $resetText.Text = '等待下一条 Codex 用量记录'
    }
    Update-DataHealthStatus $metrics
    Check-UsageAlerts $metrics
    if ([DateTimeOffset]::Now -lt $script:statusOverrideUntil -and -not [string]::IsNullOrWhiteSpace($script:statusOverrideText)) {
        $statusText.Text = $script:statusOverrideText
    }
    if ($null -ne $script:historyWindow -and $script:historyWindow.IsVisible) { Render-HistoryWindow }
    if ($null -ne $script:controlCenterWindow -and $script:controlCenterWindow.IsVisible) { Render-ControlCenter }
}

function Invoke-ManualPetRefresh {
    $refreshButton.IsEnabled = $false
    if ($null -ne $refreshItem) {
        $refreshItem.Enabled = $false
        $refreshItem.Text = '正在同步账户额度…'
    }
    try {
        $script:manualAccountRefreshPending = $true
        Update-PetUi -ForceAccountSync
        $script:statusOverrideText = '本机日志已刷新 · 正在同步账户额度…'
        $script:statusOverrideUntil = [DateTimeOffset]::Now.AddSeconds(6)
        $statusText.Text = $script:statusOverrideText
    } catch {
        $script:manualAccountRefreshPending = $false
        $script:statusOverrideText = '刷新失败 · 将自动重试'
        $script:statusOverrideUntil = [DateTimeOffset]::Now.AddSeconds(6)
        $statusText.Text = $script:statusOverrideText
    } finally {
        $refreshButton.IsEnabled = $true
        if ($null -ne $refreshItem) {
            $refreshItem.Text = '立即刷新（账户 + 本机）'
            $refreshItem.Enabled = $true
        }
    }
}

$petStage.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $cursor = [System.Windows.Forms.Cursor]::Position
    $script:isPetDragPending = $true
    $script:petDragMoved = $false
    $script:petDragStartCursor = $cursor
    $script:petDragStartLeft = [double]$window.Left
    $script:petDragStartTop = [double]$window.Top
    [void]$petStage.CaptureMouse()
    $eventArgs.Handled = $true
})
$petStage.Add_MouseMove({
    param($sender, $eventArgs)
    if (-not $script:isPetDragPending -or $eventArgs.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
    $cursor = [System.Windows.Forms.Cursor]::Position
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $deltaX = ([double]$cursor.X - [double]$script:petDragStartCursor.X) / [double]$dpi.DpiScaleX
    $deltaY = ([double]$cursor.Y - [double]$script:petDragStartCursor.Y) / [double]$dpi.DpiScaleY
    if (-not $script:petDragMoved -and ([Math]::Abs($deltaX) -ge 3 -or [Math]::Abs($deltaY) -ge 3)) {
        $script:petDragMoved = $true
    }
    if ($script:petDragMoved) {
        $window.Left = $script:petDragStartLeft + $deltaX
        $window.Top = $script:petDragStartTop + $deltaY
    }
    $eventArgs.Handled = $true
})
$petStage.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    if ($script:isPetDragPending) {
        $script:isPetDragPending = $false
        $petStage.ReleaseMouseCapture()
        if ($script:petDragMoved) {
            $script:lastPetClickAt = [DateTime]::MinValue
            $script:lastPetClickCursor = $null
            Keep-PetWindowOnScreen
            Save-PetPosition
        } else {
            $cursor = [System.Windows.Forms.Cursor]::Position
            $elapsed = ((Get-Date).ToUniversalTime() - $script:lastPetClickAt).TotalMilliseconds
            $nearPreviousClick = $false
            if ($null -ne $script:lastPetClickCursor) {
                $nearPreviousClick = ([Math]::Abs($cursor.X - $script:lastPetClickCursor.X) -le 10 -and [Math]::Abs($cursor.Y - $script:lastPetClickCursor.Y) -le 10)
            }
            if ($elapsed -ge 0 -and $elapsed -le 500 -and $nearPreviousClick) {
                $script:lastPetClickAt = [DateTime]::MinValue
                $script:lastPetClickCursor = $null
                Set-PetOnlyMode (-not $script:isPetOnly)
            } else {
                $script:lastPetClickAt = (Get-Date).ToUniversalTime()
                $script:lastPetClickCursor = $cursor
            }
        }
    }
    $eventArgs.Handled = $true
})

$rootCard.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $source = $eventArgs.OriginalSource
    while ($null -ne $source -and $source -ne $sender) {
        if ($source -is [System.Windows.Controls.Button] -or $source -eq $projectsPanel) { return }
        try { $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source) } catch { break }
    }
    try { $window.DragMove() } catch {}
})
$window.Add_LocationChanged({ Update-CompletionBubblePosition })
$window.Add_SizeChanged({ Update-CompletionBubblePosition })
$window.Add_StateChanged({
    if ($window.WindowState -eq 'Minimized') {
        Suspend-CompletionBubble
    } elseif ($window.IsVisible) {
        Show-NextCompletionBubble
    }
})
$hideButton.Add_Click({
    Save-PetPosition
    Suspend-CompletionBubble
    $window.Hide()
})
$minimizeButton.Add_Click({
    Save-PetPosition
    Suspend-CompletionBubble
    $window.WindowState = 'Minimized'
})
$historyButton.Add_Click({ Show-HistoryWindow })
$refreshButton.Add_Click({ Invoke-ManualPetRefresh })
$showAllProjectsButton.Add_Click({ Restore-AllProjectRows })
$detailToggleButton.Add_Click({ Toggle-PetCompact })
$settingsButton.Add_Click({ Show-ControlCenter 1 })
$projectsScrollViewer.Add_PreviewMouseWheel({
    param($sender, $eventArgs)
    if ($projectsScrollViewer.ScrollableHeight -le 0) { return }
    $step = if ($eventArgs.Delta -gt 0) { -48 } else { 48 }
    $projectsScrollViewer.ScrollToVerticalOffset($projectsScrollViewer.VerticalOffset + $step)
    $eventArgs.Handled = $true
})

function Register-PetResizeThumb {
    param($Thumb, [bool]$Left, [bool]$Right, [bool]$Top, [bool]$Bottom)
    $Thumb.Tag = [pscustomobject]@{ left = $Left; right = $Right; top = $Top; bottom = $Bottom }
    $Thumb.Add_DragStarted({
        $script:isUserSizing = $true
        if (-not $script:isPetOnly) { $script:userResized = $true }
    })
    $Thumb.Add_DragDelta({
        param($sender, $eventArgs)
        $edge = $sender.Tag
        $oldWidth = [double]$window.Width
        $oldHeight = [double]$window.Height
        if ($script:isPetOnly) {
            $sizeDelta = [double]0
            $candidates = @()
            if ($edge.right) { $candidates += [double]$eventArgs.HorizontalChange }
            if ($edge.left) { $candidates += -[double]$eventArgs.HorizontalChange }
            if ($edge.bottom) { $candidates += [double]$eventArgs.VerticalChange }
            if ($edge.top) { $candidates += -[double]$eventArgs.VerticalChange }
            foreach ($candidate in $candidates) {
                if ([Math]::Abs($candidate) -gt [Math]::Abs($sizeDelta)) { $sizeDelta = $candidate }
            }
            $newSize = [Math]::Max($script:petOnlyMinSize, [Math]::Min($script:petOnlyMaxSize, $oldWidth + $sizeDelta))
            $appliedDelta = $newSize - $oldWidth
            if ($edge.left) { $window.Left -= $appliedDelta }
            if ($edge.top) { $window.Top -= $appliedDelta }
            $window.Width = $newSize
            $window.Height = $newSize
            Update-PetOnlyVisualSize
            return
        }
        if ($edge.right) {
            $window.Width = [Math]::Max($window.MinWidth, $oldWidth + [double]$eventArgs.HorizontalChange)
        }
        if ($edge.bottom) {
            $window.Height = [Math]::Max($window.MinHeight, $oldHeight + [double]$eventArgs.VerticalChange)
        }
        if ($edge.left) {
            $newWidth = [Math]::Max($window.MinWidth, $oldWidth - [double]$eventArgs.HorizontalChange)
            $window.Left += $oldWidth - $newWidth
            $window.Width = $newWidth
        }
        if ($edge.top) {
            $newHeight = [Math]::Max($window.MinHeight, $oldHeight - [double]$eventArgs.VerticalChange)
            $window.Top += $oldHeight - $newHeight
            $window.Height = $newHeight
        }
        $statusText.Text = ('调整窗口 · {0:0} × {1:0}' -f $window.Width, $window.Height)
    })
    $Thumb.Add_DragCompleted({
        $script:isUserSizing = $false
        if ($script:isPetOnly) {
            $script:petOnlySize = [double]$window.Width
            Keep-PetWindowOnScreen
            Save-PetPosition
            return
        }
        $script:savedWindowWidth = $window.Width
        $script:savedWindowHeight = $window.Height
        $script:layoutProjectCount = [int]$script:visibleProjectCount
        Save-PetPosition
        $statusText.Text = ('窗口大小已保存 · {0:0} × {1:0}' -f $window.Width, $window.Height)
    })
}

Register-PetResizeThumb $resizeLeft $true $false $false $false
Register-PetResizeThumb $resizeRight $false $true $false $false
Register-PetResizeThumb $resizeTop $false $false $true $false
Register-PetResizeThumb $resizeBottom $false $false $false $true
Register-PetResizeThumb $resizeTopLeft $true $false $true $false
Register-PetResizeThumb $resizeTopRight $false $true $true $false
Register-PetResizeThumb $resizeBottomLeft $true $false $false $true
Register-PetResizeThumb $resizeBottomRight $false $true $false $true
$resizeBottomRight.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($script:isPetOnly) { return }
    if ($eventArgs.ClickCount -ge 2) {
        $script:userResized = $false
        Apply-PetWindowSize -FitContent
        Save-PetPosition
        $statusText.Text = '窗口已恢复为自动大小'
        $eventArgs.Handled = $true
    }
})

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Text = 'Codex 用量宠物'
$notifyIcon.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $trayMenu.Items.Add('显示 / 隐藏')
$historyItem = $trayMenu.Items.Add('用量历史')
$rankingItem = $trayMenu.Items.Add('项目用量排行')
$settingsItem = $trayMenu.Items.Add('设置')
$migrationItem = $trayMenu.Items.Add('一键迁移任务')
$selfCheckItem = $trayMenu.Items.Add('版本与自检')
$showAllProjectsItem = $trayMenu.Items.Add('恢复隐藏项目')
$refreshItem = $trayMenu.Items.Add('立即刷新（账户 + 本机）')
$trayMenu.Items.Add('-') | Out-Null
$exitItem = $trayMenu.Items.Add('退出')
$notifyIcon.ContextMenuStrip = $trayMenu
$trayMenu.Add_Opening({
    $showAllProjectsItem.Text = "恢复隐藏项目（$($script:hiddenProjects.Count)）"
    $showAllProjectsItem.Enabled = $script:hiddenProjects.Count -gt 0
})

$showAction = {
    if ($window.WindowState -eq 'Minimized') {
        $window.WindowState = 'Normal'
        if (-not $window.IsVisible) { $window.Show() }
        Update-PetUi
        Apply-PetWindowSize -FitContent
        $window.Activate()
        Show-NextCompletionBubble
    } elseif ($window.IsVisible) {
        Save-PetPosition
        Suspend-CompletionBubble
        $window.Hide()
    } else {
        $window.WindowState = 'Normal'
        $window.Show()
        Update-PetUi
        Apply-PetWindowSize -FitContent
        $window.Activate()
        Show-NextCompletionBubble
    }
}
$showItem.Add_Click($showAction)
$notifyIcon.Add_DoubleClick($showAction)
$historyItem.Add_Click({ Show-HistoryWindow })
$rankingItem.Add_Click({ Show-ControlCenter 0 })
$settingsItem.Add_Click({ Show-ControlCenter 1 })
$migrationItem.Add_Click({ Show-ControlCenter 2 })
$selfCheckItem.Add_Click({ Show-ControlCenter 3 })
$showAllProjectsItem.Add_Click({ Restore-AllProjectRows })
$refreshItem.Add_Click({ Invoke-ManualPetRefresh })
$exitItem.Add_Click({
    $script:isExiting = $true
    Save-PetPosition
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($null -ne $script:controlCenterWindow) { $script:controlCenterWindow.Close() }
    if ($null -ne $script:historyWindow) { $script:historyWindow.Close() }
    if ($null -ne $script:completionBubbleWindow) { $script:completionBubbleWindow.Close() }
    $window.Close()
    $window.Dispatcher.InvokeShutdown()
})

$window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:isExiting) {
        $eventArgs.Cancel = $true
        Save-PetPosition
        Suspend-CompletionBubble
        $window.Hide()
    }
})

$refreshTimer = New-Object Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds($script:refreshSeconds)
$refreshTimer.Add_Tick({
    try { Update-PetUi } catch {
        $statusText.Text = '刷新失败，将自动重试'
        Update-DataHealthStatus $script:lastMetrics $_.Exception.Message
        try { Add-Content -LiteralPath $script:runtimeLogPath -Value ("[{0}] 刷新失败：{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 } catch {}
    }
})

$wakeTimer = New-Object Windows.Threading.DispatcherTimer
$wakeTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$wakeTimer.Add_Tick({
    if ($script:showExistingEvent.WaitOne(0)) {
        if (-not $window.IsVisible) { $window.Show() }
        $window.WindowState = 'Normal'
        Update-PetUi
        Apply-PetWindowSize -FitContent
        $window.Activate()
        $window.Topmost = $false
        $window.Topmost = $true
        Show-NextCompletionBubble
    }
})

$script:petAnimationFrame = 0
function Get-PetAnimationMilliseconds {
    param([int]$BaseMilliseconds)
    switch ($script:animationSpeed) {
        'quiet' { return [int]($BaseMilliseconds * 1.45) }
        'fast' { return [int][Math]::Max(80, $BaseMilliseconds * 0.70) }
        default { return $BaseMilliseconds }
    }
}

function Update-PetAnimation {
    $script:petAnimationFrame++
    if ($null -eq $script:lastMetrics -or -not $script:lastMetrics.available) {
        if ($script:idleCatFrames.Count -gt 0) { $petSprite.Source = $script:idleCatFrames[0] }
        $petBounce.X = 0
        $petBounce.Y = 0
        return
    }

    if ($script:lastMetrics.active) {
        $petAnimationTimer.Interval = [TimeSpan]::FromMilliseconds((Get-PetAnimationMilliseconds 160))
        $index = $script:petAnimationFrame % $script:busyCatFrames.Count
        $petSprite.Source = $script:busyCatFrames[$index]
        $petBounce.X = 0
        $petBounce.Y = 0
    } else {
        $petAnimationTimer.Interval = [TimeSpan]::FromMilliseconds((Get-PetAnimationMilliseconds 620))
        $index = $script:petAnimationFrame % $script:idleCatFrames.Count
        $petSprite.Source = $script:idleCatFrames[$index]
        $petBounce.X = 0
        $petBounce.Y = 0
    }
}

$petAnimationTimer = New-Object Windows.Threading.DispatcherTimer
$petAnimationTimer.Interval = [TimeSpan]::FromMilliseconds((Get-PetAnimationMilliseconds 320))
$petAnimationTimer.Add_Tick({ Update-PetAnimation })

$window.Add_Loaded({
    Initialize-ControlCenter
    Update-PetUi
    Apply-PetWindowSize -FitContent
    Update-PetAnimation
    if ($script:startPetOnly) { Set-PetOnlyMode $true $false }
    $refreshTimer.Start()
    $wakeTimer.Start()
    $petAnimationTimer.Start()
})

try {
    $window.Show()
    [System.Windows.Threading.Dispatcher]::Run()
} finally {
    $refreshTimer.Stop()
    $wakeTimer.Stop()
    $petAnimationTimer.Stop()
    if ($null -ne $script:updateCheckTimer) { $script:updateCheckTimer.Stop() }
    Stop-CompletionBubbleTimer
    if ($null -ne $script:historyWindow) {
        $script:isExiting = $true
        $script:historyWindow.Close()
    }
    if ($null -ne $script:controlCenterWindow) {
        $script:isExiting = $true
        $script:controlCenterWindow.Close()
    }
    if ($null -ne $script:completionBubbleWindow) {
        $script:isExiting = $true
        $script:completionBubbleWindow.Close()
    }
    if ($null -ne $notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    if ($null -ne $script:singleInstanceMutex) {
        try { $script:singleInstanceMutex.ReleaseMutex() } catch {}
        $script:singleInstanceMutex.Dispose()
    }
    if ($null -ne $script:showExistingEvent) { $script:showExistingEvent.Dispose() }
}
