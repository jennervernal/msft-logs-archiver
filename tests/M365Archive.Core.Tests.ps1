BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\M365Archive.Core.psm1') -Force
}

Describe 'New-TimeWindows' {
    It 'creates contiguous bounded windows including a short final window' {
        $start = [DateTime]'2026-01-01T00:00:00Z'
        $end = [DateTime]'2026-01-01T02:30:00Z'
        $windows = @(New-TimeWindows -StartUtc $start -EndUtc $end -Window ([TimeSpan]::FromHours(1)))
        $windows.Count | Should -Be 3
        $windows[0].StartUtc | Should -Be $start.ToUniversalTime()
        $windows[1].StartUtc | Should -Be $windows[0].EndUtc
        $windows[-1].EndUtc | Should -Be $end.ToUniversalTime()
    }

    It 'rejects a non-positive window' {
        { New-TimeWindows -StartUtc ([DateTime]'2026-01-01Z') -EndUtc ([DateTime]'2026-01-02Z') -Window ([TimeSpan]::Zero) } |
            Should -Throw
    }
}

Describe 'checkpoint persistence' {
    It 'round-trips completed partitions atomically' {
        $path = Join-Path $TestDrive 'checkpoint.json'
        $checkpoint = Read-Checkpoint $path
        $checkpoint.completedPartitions['source|window'] = @{ sha256 = 'abc'; recordCount = 2 }
        Save-Checkpoint -Path $path -Checkpoint $checkpoint
        $loaded = Read-Checkpoint $path
        $loaded.completedPartitions['source|window'].recordCount | Should -Be 2
        @(Get-ChildItem $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }

    It 'rejects malformed checkpoint JSON' {
        $path = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $path -Value '{bad' -Encoding utf8
        { Read-Checkpoint $path } | Should -Throw
    }
}

Describe 'Add-UniqueRecords' {
    It 'keeps the first record for each key and hashes keyless records' {
        $records = @(
            [pscustomobject]@{ id = 'a'; value = 1 }
            [pscustomobject]@{ id = 'a'; value = 2 }
            [pscustomobject]@{ id = 'b'; value = 3 }
        )
        $actual = @(Add-UniqueRecords -Records $records -KeySelector { param($record) $record.id })
        $actual.Count | Should -Be 2
        $actual[0].value | Should -Be 1
    }
}

Describe 'Test-RequiredCollectorsComplete' {
    It 'requires every required collector to have exactly one successful status' {
        $statuses = @(
            [pscustomobject]@{ source = 'EntraAudit'; status = 'success' }
            [pscustomobject]@{ source = 'AzureActivity'; status = 'skipped-unavailable' }
            [pscustomobject]@{ source = 'OptionalSource'; status = 'optional-failed' }
        )
        Test-RequiredCollectorsComplete -Statuses $statuses -RequiredCollectors @('EntraAudit') |
            Should -BeTrue
        Test-RequiredCollectorsComplete -Statuses $statuses -RequiredCollectors @('EntraAudit', 'AzureActivity') |
            Should -BeFalse
        Test-RequiredCollectorsComplete -Statuses @(
            [pscustomobject]@{ source = 'EntraAudit'; status = 'partial' }
        ) -RequiredCollectors @('EntraAudit') | Should -BeFalse
    }
}

Describe 'archive hashing and manifest validation' {
    It 'writes gzip JSONL and validates its SHA-256' {
        $records = @([pscustomobject]@{ id = '1'; value = 'alpha' }, [pscustomobject]@{ id = '2'; value = 'beta' })
        $manifest = Write-ArchivePartition -OutputRoot $TestDrive -Source 'TestSource' -RunId 'run-1' `
            -StartUtc ([DateTime]'2026-01-01T00:00:00Z') -EndUtc ([DateTime]'2026-01-01T01:00:00Z') `
            -Records $records -DeduplicationKey { param($record) $record.id }
        $manifest.recordCount | Should -Be 2
        $manifestPath = Get-ChildItem $TestDrive -Filter '*.manifest.json' -Recurse | Select-Object -First 1
        (Test-ArchiveManifest $manifestPath.FullName).Valid | Should -BeTrue
    }

    It 'detects archive tampering' {
        $records = @([pscustomobject]@{ id = '1' })
        $manifest = Write-ArchivePartition -OutputRoot $TestDrive -Source 'TamperSource' -RunId 'run-2' `
            -StartUtc ([DateTime]'2026-01-02T00:00:00Z') -EndUtc ([DateTime]'2026-01-02T01:00:00Z') `
            -Records $records -DeduplicationKey { param($record) $record.id }
        $manifestPath = Get-ChildItem $TestDrive -Filter '*.manifest.json' -Recurse |
            Where-Object FullName -Like '*TamperSource*' | Select-Object -First 1
        $archivePath = Join-Path $manifestPath.DirectoryName $manifest.archiveFile
        Add-Content -LiteralPath $archivePath -Value 'tamper'
        (Test-ArchiveManifest $manifestPath.FullName).Valid | Should -BeFalse
    }

    It 'writes and validates an empty successful partition' {
        $manifest = Write-ArchivePartition -OutputRoot $TestDrive -Source 'EmptySource' -RunId 'run-3' `
            -StartUtc ([DateTime]'2026-01-03T00:00:00Z') -EndUtc ([DateTime]'2026-01-03T01:00:00Z') `
            -Records @() -DeduplicationKey { param($record) Get-RecordValue $record 'id' }
        $manifest.recordCount | Should -Be 0
        $manifestPath = Get-ChildItem $TestDrive -Filter '*.manifest.json' -Recurse |
            Where-Object FullName -Like '*EmptySource*' | Select-Object -First 1
        (Test-ArchiveManifest $manifestPath.FullName).Valid | Should -BeTrue
    }
}

Describe 'Assert-ArchiveConfig' {
    BeforeEach {
        $script:validConfig = @{
            TenantId = '11111111-1111-1111-1111-111111111111'
            OutputRoot = (Join-Path $TestDrive 'archive')
            ArchiveMode = 'Fixed'
            StartUtc = '2026-01-01T00:00:00Z'
            EndUtc = '2026-01-02T00:00:00Z'
            WindowHours = 1
            Collectors = @('EntraAudit')
            RequiredCollectors = @('EntraAudit')
            ScaleProfile = 'Small'
            ResourceControls = @{
                MaximumTotalWorkers = 2
                MinimumFreeDiskGB = 1
                MaximumProcessMemoryMB = 1024
                MaximumDeduplicationKeysPerPartition = 10000
                MaximumQueueRecords = 1000
            }
        }

    }

    Describe 'Resolve-ArchiveDateRange' {
        It 'uses durable incremental state with the configured overlap' {
            $statePath = Join-Path $TestDrive 'incremental.json'
            Write-JsonAtomic $statePath @{ lastSuccessfulEndUtc = '2026-01-02T00:00:00Z' }
            $config = @{
                ArchiveMode = 'Incremental'
                IncrementalInitialLookbackHours = 24
                IncrementalOverlapMinutes = 15
                IngestionDelayMinutes = 120
            }
            $range = Resolve-ArchiveDateRange -Config $config -StatePath $statePath -NowUtc ([DateTime]'2026-01-02T04:00:00Z')
            $range.StartUtc | Should -Be ([DateTimeOffset]'2026-01-01T23:45:00Z').UtcDateTime
            $range.EndUtc | Should -Be ([DateTimeOffset]'2026-01-02T02:00:00Z').UtcDateTime
        }
    }

    Describe 'Split-TimeWindow' {
        It 'creates two contiguous halves without gaps' {
            $start = ([DateTimeOffset]'2026-01-01T00:00:00Z').UtcDateTime
            $end = ([DateTimeOffset]'2026-01-01T01:00:00Z').UtcDateTime
            $halves = @(Split-TimeWindow -StartUtc $start -EndUtc $end -MinimumWindow ([TimeSpan]::FromMinutes(5)))
            $halves.Count | Should -Be 2
            $halves[0].StartUtc | Should -Be $start
            $halves[0].EndUtc | Should -Be $halves[1].StartUtc
            $halves[1].EndUtc | Should -Be $end
        }

        It 'refuses to split at the minimum window' {
            { Split-TimeWindow -StartUtc ([DateTime]'2026-01-01T00:00:00Z') -EndUtc ([DateTime]'2026-01-01T00:05:00Z') `
                -MinimumWindow ([TimeSpan]::FromMinutes(5)) } | Should -Throw
        }
    }

    It 'accepts a valid configuration' {
        Assert-ArchiveConfig $validConfig | Should -BeTrue
    }

    It 'rejects reversed dates' {
        $validConfig.StartUtc = '2026-01-03T00:00:00Z'
        { Assert-ArchiveConfig $validConfig } | Should -Throw
    }

    It 'rejects unknown collectors' {
        $validConfig.Collectors = @('ImaginaryLog')
        { Assert-ArchiveConfig $validConfig } | Should -Throw
    }

    It 'requires required collectors to be selected' {
        $validConfig.RequiredCollectors = @('UnifiedAudit')
        { Assert-ArchiveConfig $validConfig } | Should -Throw
    }
}
