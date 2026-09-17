BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\M365Archive.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\M365Archive.QuickStart.psm1') -Force
}

Describe 'Get-M365TenantIdFromGraphContext' {
    It 'discovers and normalizes a tenant ID from a mocked Graph context' {
        $context = [pscustomobject]@{ TenantId = '11111111-2222-3333-4444-555555555555' }
        Get-M365TenantIdFromGraphContext -Context $context |
            Should -Be '11111111-2222-3333-4444-555555555555'
    }

    It 'rejects a missing or invalid tenant ID' {
        { Get-M365TenantIdFromGraphContext -Context ([pscustomobject]@{}) } | Should -Throw
        { Get-M365TenantIdFromGraphContext -Context @{ TenantId = 'not-a-guid' } } | Should -Throw
        { Get-M365TenantIdFromGraphContext -Context @{ TenantId = [Guid]::Empty } } | Should -Throw
    }
}

Describe 'Get-M365QuickStartPlan' {
    BeforeAll {
        $script:now = ([DateTimeOffset]'2026-09-17T12:00:00Z').UtcDateTime
        $script:plan = @(Get-M365QuickStartPlan -NowUtc $now)
    }

    It 'uses exactly the A3 quick-start collectors' {
        $plan.Collector | Should -Be @(
            'EntraAudit', 'EntraSignIns', 'UnifiedAudit', 'IntuneAudit', 'AzureActivity'
        )
        $plan.Collector | Should -Not -Contain 'EntraRiskySignIns'
        $plan.Collector | Should -Not -Contain 'DefenderXdr'
    }

    It 'uses service-specific maximum-history targets and ingestion delays' {
        ($plan | Where-Object Collector -eq 'EntraAudit').InitialStartUtc |
            Should -Be $now.AddMinutes(-15).AddDays(-30)
        ($plan | Where-Object Collector -eq 'EntraSignIns').InitialStartUtc |
            Should -Be $now.AddMinutes(-15).AddDays(-30)
        ($plan | Where-Object Collector -eq 'UnifiedAudit').InitialStartUtc |
            Should -Be $now.AddMinutes(-120).AddDays(-180)
        ($plan | Where-Object Collector -eq 'IntuneAudit').InitialStartUtc |
            Should -Be $now.AddMinutes(-60).AddYears(-2)
        ($plan | Where-Object Collector -eq 'AzureActivity').InitialStartUtc |
            Should -Be $now.AddMinutes(-15).AddDays(-90)
    }

    It 'creates independent durable state keys and conservative configs' {
        $configs = @($plan | ForEach-Object {
            New-M365QuickStartConfig -PlanItem $_ `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -OutputRoot (Join-Path $TestDrive 'archive')
        })
        @($configs.IncrementalStateKey | Select-Object -Unique).Count | Should -Be 5
        $configs.ScaleProfile | Should -Be @('Small', 'Small', 'Small', 'Small', 'Small')
        $configs.Collectors | ForEach-Object { @($_).Count | Should -Be 1 }
        $configs.AzureSubscriptionIds.Count | Should -Be 0
        foreach ($config in $configs) { Assert-ArchiveConfig $config | Should -BeTrue }
    }
}

Describe 'quick-start incremental state' {
    It 'uses the service-specific first-run start and later resumes with overlap' {
        $now = ([DateTimeOffset]'2026-09-17T12:00:00Z').UtcDateTime
        $item = Get-M365QuickStartPlan -NowUtc $now | Where-Object Collector -eq 'UnifiedAudit'
        $config = New-M365QuickStartConfig -PlanItem $item `
            -TenantId '11111111-2222-3333-4444-555555555555' `
            -OutputRoot (Join-Path $TestDrive 'archive')
        $statePath = Join-Path $TestDrive 'incremental-ual.json'

        $first = Resolve-ArchiveDateRange -Config $config -StatePath $statePath -NowUtc $now
        $first.StartUtc | Should -Be $item.InitialStartUtc
        $first.EndUtc | Should -Be $item.InitialEndUtc

        Write-JsonAtomic -Path $statePath -Value @{
            lastSuccessfulEndUtc = '2026-09-17T08:00:00Z'
        }
        $later = Resolve-ArchiveDateRange -Config $config -StatePath $statePath `
            -NowUtc ([DateTimeOffset]'2026-09-18T12:00:00Z').UtcDateTime
        $later.StartUtc | Should -Be ([DateTimeOffset]'2026-09-17T06:00:00Z').UtcDateTime
        $later.EndUtc | Should -Be ([DateTimeOffset]'2026-09-18T10:00:00Z').UtcDateTime
    }

    It 'reuses an exact pending range after interruption instead of restarting the backfill' {
        $now = ([DateTimeOffset]'2026-09-17T12:00:00Z').UtcDateTime
        $item = Get-M365QuickStartPlan -NowUtc $now | Where-Object Collector -eq 'IntuneAudit'
        $config = New-M365QuickStartConfig -PlanItem $item `
            -TenantId '11111111-2222-3333-4444-555555555555' `
            -OutputRoot (Join-Path $TestDrive 'archive')
        $statePath = Join-Path $TestDrive 'incremental-intune-pending.json'
        Write-JsonAtomic -Path $statePath -Value @{
            pendingStartUtc = '2024-09-17T11:00:00Z'
            pendingEndUtc = '2026-09-17T11:00:00Z'
        }

        $resumed = Resolve-ArchiveDateRange -Config $config -StatePath $statePath `
            -NowUtc ([DateTimeOffset]'2026-09-20T12:00:00Z').UtcDateTime
        $resumed.StartUtc | Should -Be ([DateTimeOffset]'2024-09-17T11:00:00Z').UtcDateTime
        $resumed.EndUtc | Should -Be ([DateTimeOffset]'2026-09-17T11:00:00Z').UtcDateTime
    }
}

Describe 'advanced configuration compatibility' {
    It 'keeps ConfigPath mandatory in the default path parameter set' {
        $command = Get-Command (Join-Path $PSScriptRoot '..\Archive-M365Logs.ps1')
        $pathAttribute = $command.Parameters.ConfigPath.Attributes |
            Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.ParameterSetName -eq 'Path' }
        $pathAttribute.Mandatory | Should -BeTrue
        ($command.ParameterSets | Where-Object IsDefault).Name | Should -Be 'Path'
        $command.Parameters.Keys | Should -Contain 'ConfigData'
    }
}
