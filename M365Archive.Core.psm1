Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SchemaVersion = '1.0'
$script:LogFile = $null

function Initialize-ArchiveLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $script:LogFile = $Path
}

function Write-ArchiveLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data
    )

    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level        = $Level
        message      = $Message
    }
    if ($Data) { $entry.data = $Data }
    $line = $entry | ConvertTo-Json -Compress -Depth 20
    Write-Host "[$Level] $Message"
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
    }
}

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)
    try {
        $parsed = [DateTimeOffset]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        )
        return $parsed.UtcDateTime
    }
    catch {
        throw "$Name must be an ISO 8601 date/time value. Received '$Value'."
    }
}

function Assert-ArchiveConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    foreach ($name in @('TenantId', 'OutputRoot', 'ArchiveMode', 'Collectors', 'RequiredCollectors', 'WindowHours', 'ScaleProfile', 'ResourceControls')) {
        if (-not $Config.ContainsKey($name)) { throw "Configuration is missing required key '$name'." }
    }
    if (-not [Guid]::TryParse([string]$Config.TenantId, [ref]([Guid]::Empty))) {
        throw 'TenantId must be a GUID.'
    }
    if ($Config.ArchiveMode -notin @('Fixed', 'Incremental')) { throw "ArchiveMode must be 'Fixed' or 'Incremental'." }
    if ($Config.ArchiveMode -eq 'Fixed') {
        foreach ($name in @('StartUtc', 'EndUtc')) {
            if (-not $Config.ContainsKey($name)) { throw "Fixed mode requires '$name'." }
        }
        $start = ConvertTo-UtcDateTime $Config.StartUtc 'StartUtc'
        $end = ConvertTo-UtcDateTime $Config.EndUtc 'EndUtc'
        if ($start -ge $end) { throw 'StartUtc must be earlier than EndUtc.' }
        if ($end -gt [DateTime]::UtcNow.AddMinutes(5)) { throw 'EndUtc cannot be in the future.' }
    }
    else {
        foreach ($name in @('IncrementalInitialLookbackHours', 'IncrementalOverlapMinutes', 'IngestionDelayMinutes')) {
            if (-not $Config.ContainsKey($name) -or [double]$Config[$name] -lt 0) {
                throw "Incremental mode requires non-negative '$name'."
            }
        }
        if ([double]$Config.IncrementalInitialLookbackHours -le 0) {
            throw 'IncrementalInitialLookbackHours must be greater than zero.'
        }
        if ($Config.ContainsKey('IncrementalInitialStartUtc')) {
            $initialStart = ConvertTo-UtcDateTime $Config.IncrementalInitialStartUtc 'IncrementalInitialStartUtc'
            if ($initialStart -ge [DateTime]::UtcNow.AddMinutes(5)) {
                throw 'IncrementalInitialStartUtc must be earlier than the current time.'
            }
        }
        if ($Config.ContainsKey('IncrementalStateKey') -and
            [string]$Config.IncrementalStateKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
            throw 'IncrementalStateKey must contain only letters, numbers, dot, underscore, or hyphen and be at most 80 characters.'
        }
    }
    $windowHours = 0.0
    if (-not [double]::TryParse([string]$Config.WindowHours, [ref]$windowHours) -or $windowHours -le 0 -or $windowHours -gt 168) {
        throw 'WindowHours must be greater than 0 and no more than 168.'
    }
    $allowed = @('EntraAudit', 'EntraSignIns', 'EntraRiskySignIns', 'UnifiedAudit', 'IntuneAudit', 'AzureActivity', 'DefenderXdr')
    foreach ($collector in @($Config.Collectors)) {
        if ($collector -notin $allowed) { throw "Unknown collector '$collector'." }
    }
    if (@($Config.Collectors).Count -eq 0) { throw 'At least one collector must be selected.' }
    if ([string]::IsNullOrWhiteSpace([string]$Config.OutputRoot)) { throw 'OutputRoot cannot be empty.' }
    if ($Config.ContainsKey('RequiredCollectors')) {
        foreach ($required in @($Config.RequiredCollectors)) {
            if ($required -notin @($Config.Collectors)) { throw "Required collector '$required' is not selected." }
        }
    }
    if (@($Config.Collectors) -contains 'AzureActivity' -and -not $Config.ContainsKey('AzureSubscriptionIds')) {
        throw 'AzureActivity requires AzureSubscriptionIds (use an empty array to select all visible subscriptions).'
    }
    if (@($Config.Collectors) -contains 'UnifiedAudit' -and -not $Config.ContainsKey('UnifiedAuditRecordTypes')) {
        throw 'UnifiedAudit requires UnifiedAuditRecordTypes (use an empty array for all record types).'
    }
    if (@($Config.Collectors) -contains 'DefenderXdr' -and (
        -not $Config.ContainsKey('DefenderXdrTables') -or @($Config.DefenderXdrTables).Count -eq 0
    )) {
        throw 'DefenderXdr requires at least one DefenderXdrTables value.'
    }
    if ($Config.ScaleProfile -notin @('Small', 'Medium', 'Large')) { throw 'ScaleProfile must be Small, Medium, or Large.' }
    foreach ($name in @('MaximumTotalWorkers', 'MinimumFreeDiskGB', 'MaximumProcessMemoryMB', 'MaximumDeduplicationKeysPerPartition', 'MaximumQueueRecords')) {
        if (-not $Config.ResourceControls.ContainsKey($name) -or [double]$Config.ResourceControls[$name] -le 0) {
            throw "ResourceControls requires positive '$name'."
        }
        if ([int]$Config.ResourceControls.MaximumTotalWorkers -gt 16) {
            throw 'ResourceControls.MaximumTotalWorkers cannot exceed 16.'
        }
    }
    return $true
}

function Assert-ResourceCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][double]$MinimumFreeDiskGB,
        [Parameter(Mandatory)][double]$MaximumProcessMemoryMB
    )
    $fullPath = [IO.Path]::GetFullPath($OutputRoot)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady) { throw "Archive drive '$root' is not ready." }
    $freeGB = $drive.AvailableFreeSpace / 1GB
    if ($freeGB -lt $MinimumFreeDiskGB) {
        throw "Insufficient free disk space: $([Math]::Round($freeGB, 2)) GB available; $MinimumFreeDiskGB GB required."
    }
    $memoryMB = [Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB
    if ($memoryMB -gt $MaximumProcessMemoryMB) {
        throw "Process memory is $([Math]::Round($memoryMB, 1)) MB, exceeding the configured $MaximumProcessMemoryMB MB."
    }
    return [pscustomobject]@{ FreeDiskGB = $freeGB; ProcessMemoryMB = $memoryMB }
}

function Resolve-ArchiveDateRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$StatePath,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    if ($Config.ArchiveMode -eq 'Fixed') {
        return [pscustomobject]@{
            StartUtc = ConvertTo-UtcDateTime $Config.StartUtc 'StartUtc'
            EndUtc = ConvertTo-UtcDateTime $Config.EndUtc 'EndUtc'
        }
    }
    $end = $NowUtc.ToUniversalTime().AddMinutes(-[double]$Config.IngestionDelayMinutes)
    $start = if ($Config.ContainsKey('IncrementalInitialStartUtc')) {
        ConvertTo-UtcDateTime $Config.IncrementalInitialStartUtc 'IncrementalInitialStartUtc'
    }
    else {
        $end.AddHours(-[double]$Config.IncrementalInitialLookbackHours)
    }
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            if ($state.ContainsKey('pendingStartUtc') -and $state.ContainsKey('pendingEndUtc')) {
                $start = ConvertTo-UtcDateTime $state.pendingStartUtc 'pendingStartUtc'
                $end = ConvertTo-UtcDateTime $state.pendingEndUtc 'pendingEndUtc'
            }
            elseif ($state.ContainsKey('lastSuccessfulEndUtc')) {
                $lastEnd = ConvertTo-UtcDateTime $state.lastSuccessfulEndUtc 'lastSuccessfulEndUtc'
                $start = $lastEnd.AddMinutes(-[double]$Config.IncrementalOverlapMinutes)
            }
            else {
                throw 'missing pending range and lastSuccessfulEndUtc'
            }
        }
        catch {
            throw "Incremental state '$StatePath' is invalid: $($_.Exception.Message)"
        }
    }
    if ($start -ge $end) { throw 'Resolved incremental start must precede end; check delay and state settings.' }
    return [pscustomobject]@{ StartUtc = $start; EndUtc = $end }
}

function Test-RequiredCollectorsComplete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Statuses,
        [Parameter(Mandatory)][string[]]$RequiredCollectors
    )

    foreach ($required in $RequiredCollectors) {
        $status = @($Statuses | Where-Object source -eq $required)
        if ($status.Count -ne 1 -or $status[0].status -ne 'success') {
            return $false
        }
    }
    return $true
}

function New-TimeWindows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc,
        [Parameter(Mandatory)][TimeSpan]$Window
    )

    if ($StartUtc -ge $EndUtc) { throw 'StartUtc must precede EndUtc.' }
    if ($Window -le [TimeSpan]::Zero) { throw 'Window must be positive.' }
    $cursor = $StartUtc.ToUniversalTime()
    $end = $EndUtc.ToUniversalTime()
    while ($cursor -lt $end) {
        $next = $cursor.Add($Window)
        if ($next -gt $end) { $next = $end }
        [pscustomobject]@{ StartUtc = $cursor; EndUtc = $next }
        $cursor = $next
    }
}

function Split-TimeWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc,
        [Parameter(Mandatory)][TimeSpan]$MinimumWindow
    )
    $duration = $EndUtc - $StartUtc
    if ($duration -le $MinimumWindow) { throw 'Time window cannot be split without violating MinimumWindow.' }
    $midpoint = $StartUtc.AddTicks([long]($duration.Ticks / 2))
    return @(
        [pscustomobject]@{ StartUtc = $StartUtc; EndUtc = $midpoint }
        [pscustomobject]@{ StartUtc = $midpoint; EndUtc = $EndUtc }
    )
}

function Get-StableHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-RecordValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Name)

    if ($Record -is [Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $null
    }
    $property = $Record.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temp = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Value | ConvertTo-Json -Depth 40
        [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Read-Checkpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ schemaVersion = $script:SchemaVersion; completedPartitions = @{} }
    }
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        if (-not $value.ContainsKey('completedPartitions')) { throw 'missing completedPartitions' }
        return $value
    }
    catch {
        throw "Checkpoint '$Path' is invalid: $($_.Exception.Message)"
    }
}

function Save-Checkpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Checkpoint)
    $Checkpoint['updatedUtc'] = [DateTime]::UtcNow.ToString('o')
    Write-JsonAtomic -Path $Path -Value $Checkpoint
}

function Add-UniqueRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Records,
        [Parameter(Mandatory)][scriptblock]$KeySelector,
        [System.Collections.Generic.HashSet[string]]$Seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    )

    $result = [Collections.Generic.List[object]]::new()
    foreach ($record in $Records) {
        $key = [string](& $KeySelector $record)
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = Get-StableHash ($record | ConvertTo-Json -Compress -Depth 50)
        }
        if ($Seen.Add($key)) { $result.Add($record) }
    }
    return $result.ToArray()
}

function Enter-ArchiveLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputRoot)

    if (-not (Test-Path -LiteralPath $OutputRoot)) {
        New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    }
    $path = Join-Path $OutputRoot '.archive.lock'
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $payload = [Text.Encoding]::UTF8.GetBytes("pid=$PID`nstartedUtc=$([DateTime]::UtcNow.ToString('o'))")
        $stream.SetLength(0)
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush($true)
        return [pscustomobject]@{ Path = $path; Stream = $stream }
    }
    catch {
        throw "Another archive run appears to be active (lock '$path'): $($_.Exception.Message)"
    }
}

function Exit-ArchiveLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lock)
    if ($Lock.Stream) { $Lock.Stream.Dispose() }
    if (Test-Path -LiteralPath $Lock.Path) { Remove-Item -LiteralPath $Lock.Path -Force }
}

function Get-PartitionPaths {
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc
    )
    $datePath = Join-Path $OutputRoot (Join-Path $Source (Join-Path $StartUtc.ToString('yyyy') (Join-Path $StartUtc.ToString('MM') (Join-Path $StartUtc.ToString('dd') $RunId))))
    $baseName = '{0}_{1}' -f $StartUtc.ToString('yyyyMMddTHHmmssZ'), $EndUtc.ToString('yyyyMMddTHHmmssZ')
    return [pscustomobject]@{
        Directory = $datePath
        Archive   = Join-Path $datePath "$baseName.jsonl.gz"
        Manifest  = Join-Path $datePath "$baseName.manifest.json"
    }
}

function Test-PartitionManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $false }
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $archive = Join-Path (Split-Path -Parent $ManifestPath) $manifest.archiveFile
        return (
            $manifest.status -eq 'success' -and
            (Test-Path -LiteralPath $archive) -and
            (Get-FileSha256 $archive) -eq $manifest.sha256
        )
    }
    catch { return $false }
}

function Write-ArchivePartition {
    [CmdletBinding(DefaultParameterSetName = 'Records')]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc,
        [Parameter(Mandatory, ParameterSetName = 'Records')][System.Collections.IEnumerable]$Records,
        [Parameter(Mandatory, ParameterSetName = 'Producer')][scriptblock]$RecordProducer,
        [Parameter(Mandatory)][scriptblock]$DeduplicationKey,
        [hashtable]$Continuation = @{},
        [int]$MaximumDeduplicationKeys = 1000000,
        [double]$MaximumProcessMemoryMB = 2048,
        [double]$MinimumFreeDiskGB = 1
    )

    $paths = Get-PartitionPaths -OutputRoot $OutputRoot -Source $Source -RunId $RunId -StartUtc $StartUtc -EndUtc $EndUtc
    if (Test-PartitionManifest $paths.Manifest) {
        return Get-Content -LiteralPath $paths.Manifest -Raw -Encoding utf8 | ConvertFrom-Json
    }
    if (Test-Path -LiteralPath $paths.Manifest) {
        $existing = Get-Content -LiteralPath $paths.Manifest -Raw -Encoding utf8 | ConvertFrom-Json
        if ($existing.status -eq 'success') {
            throw "Existing successful partition manifest failed validation: '$($paths.Manifest)'."
        }
        Remove-Item -LiteralPath $paths.Manifest -Force
    }
    New-Item -ItemType Directory -Path $paths.Directory -Force | Out-Null
    $jsonlTemp = Join-Path $paths.Directory ".$([Guid]::NewGuid().ToString('N')).jsonl.tmp"
    $gzipTemp = "$($paths.Archive).$([Guid]::NewGuid().ToString('N')).tmp"
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $writeState = @{ RecordsWritten = 0 }
    try {
        $writer = [IO.StreamWriter]::new($jsonlTemp, $false, [Text.UTF8Encoding]::new($false))
        try {
            $writeRecord = {
                $record = $_
                $key = [string](& $DeduplicationKey $record)
                if ([string]::IsNullOrWhiteSpace($key)) {
                    $key = Get-StableHash ($record | ConvertTo-Json -Compress -Depth 50)
                }
                if ($seen.Add($key)) {
                    if ($seen.Count -gt $MaximumDeduplicationKeys) {
                        throw "Partition exceeded MaximumDeduplicationKeys ($MaximumDeduplicationKeys); reduce service window size."
                    }
                    $writer.WriteLine(($record | ConvertTo-Json -Compress -Depth 50))
                    $writeState.RecordsWritten++
                    if (($writeState.RecordsWritten % 1000) -eq 0) {
                        Assert-ResourceCapacity -OutputRoot $OutputRoot -MinimumFreeDiskGB $MinimumFreeDiskGB `
                            -MaximumProcessMemoryMB $MaximumProcessMemoryMB | Out-Null
                    }
                }
            }
            if ($PSCmdlet.ParameterSetName -eq 'Producer') {
                & $RecordProducer | ForEach-Object -Process $writeRecord
            }
            else {
                $Records | ForEach-Object -Process $writeRecord
            }
        }
        finally { $writer.Dispose() }

        Assert-ResourceCapacity -OutputRoot $OutputRoot -MinimumFreeDiskGB $MinimumFreeDiskGB `
            -MaximumProcessMemoryMB $MaximumProcessMemoryMB | Out-Null
        $input = [IO.File]::OpenRead($jsonlTemp)
        $output = [IO.File]::Create($gzipTemp)
        $gzip = [IO.Compression.GZipStream]::new($output, [IO.Compression.CompressionLevel]::Optimal)
        try { $input.CopyTo($gzip) }
        finally {
            $gzip.Dispose()
            $output.Dispose()
            $input.Dispose()
        }
        Move-Item -LiteralPath $gzipTemp -Destination $paths.Archive
        $manifest = [ordered]@{
            schemaVersion      = $script:SchemaVersion
            source             = $Source
            runId              = $RunId
            queryStartUtc      = $StartUtc.ToUniversalTime().ToString('o')
            queryEndUtc        = $EndUtc.ToUniversalTime().ToString('o')
            collectedUtc       = [DateTime]::UtcNow.ToString('o')
            recordCount        = $writeState.RecordsWritten
            archiveFile        = Split-Path -Leaf $paths.Archive
            compression        = 'gzip'
            format             = 'jsonl'
            encoding           = 'utf-8'
            sha256             = Get-FileSha256 $paths.Archive
            status             = 'success'
            continuation       = $Continuation
        }
        Write-JsonAtomic -Path $paths.Manifest -Value $manifest
        return [pscustomobject]$manifest
    }
    finally {
        foreach ($temp in @($jsonlTemp, $gzipTemp)) {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }
}

function Write-FailedPartitionManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc,
        [Parameter(Mandatory)][string]$ErrorMessage,
        [hashtable]$Continuation = @{}
    )

    $paths = Get-PartitionPaths -OutputRoot $OutputRoot -Source $Source -RunId $RunId -StartUtc $StartUtc -EndUtc $EndUtc
    if (Test-PartitionManifest $paths.Manifest) { return }
    $manifest = [ordered]@{
        schemaVersion = $script:SchemaVersion
        source = $Source
        runId = $RunId
        queryStartUtc = $StartUtc.ToUniversalTime().ToString('o')
        queryEndUtc = $EndUtc.ToUniversalTime().ToString('o')
        collectedUtc = [DateTime]::UtcNow.ToString('o')
        recordCount = 0
        archiveFile = $null
        compression = 'gzip'
        format = 'jsonl'
        encoding = 'utf-8'
        sha256 = $null
        status = 'failed'
        error = $ErrorMessage
        continuation = $Continuation
    }
    Write-JsonAtomic -Path $paths.Manifest -Value $manifest
}

function Test-ArchiveManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return [pscustomobject]@{ Valid = $false; Error = 'Manifest not found'; ManifestPath = $ManifestPath }
    }
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $archive = Join-Path (Split-Path -Parent $ManifestPath) $manifest.archiveFile
        if (-not (Test-Path -LiteralPath $archive)) { throw "Archive '$archive' not found." }
        $actual = Get-FileSha256 $archive
        if ($actual -ne $manifest.sha256) { throw "SHA-256 mismatch (expected $($manifest.sha256), actual $actual)." }
        [pscustomobject]@{ Valid = $true; Error = $null; ManifestPath = $ManifestPath; ArchivePath = $archive; RecordCount = $manifest.recordCount }
    }
    catch {
        [pscustomobject]@{ Valid = $false; Error = $_.Exception.Message; ManifestPath = $ManifestPath }
    }
}

Export-ModuleMember -Function @(
    'Initialize-ArchiveLog', 'Write-ArchiveLog', 'Assert-ArchiveConfig', 'ConvertTo-UtcDateTime',
    'New-TimeWindows', 'Split-TimeWindow', 'Resolve-ArchiveDateRange', 'Test-RequiredCollectorsComplete',
    'Assert-ResourceCapacity', 'Get-StableHash', 'Get-RecordValue', 'Get-FileSha256', 'Write-JsonAtomic',
    'Read-Checkpoint', 'Save-Checkpoint', 'Add-UniqueRecords',
    'Enter-ArchiveLock', 'Exit-ArchiveLock', 'Get-PartitionPaths', 'Test-PartitionManifest',
    'Write-ArchivePartition', 'Write-FailedPartitionManifest', 'Test-ArchiveManifest'
)
