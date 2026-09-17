BeforeAll {
    function global:Search-UnifiedAuditLog { }
    Import-Module (Join-Path $PSScriptRoot '..\M365Archive.RateLimit.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\M365Archive.Collectors.psm1') -Force
    $script:testPolicies = (Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\ScaleProfiles.psd1')).Small
}

AfterAll {
    Remove-Item Function:\Search-UnifiedAuditLog -ErrorAction SilentlyContinue
}

Describe 'Test-IntuneAuditCapability' {
    BeforeEach {
        Mock Connect-ArchiveGraph -ModuleName M365Archive.Collectors
    }

    It 'reports an unavailable endpoint only for HTTP 404' {
        Mock Invoke-ServiceOperation -ModuleName M365Archive.Collectors {
            $exception = [Exception]::new('Not Found')
            $exception | Add-Member -NotePropertyName StatusCode -NotePropertyValue 404
            throw $exception
        }
        $result = Test-IntuneAuditCapability -TenantId '11111111-2222-3333-4444-555555555555'
        $result.Available | Should -BeFalse
        $result.Reason | Should -Match 'unavailable'
    }

    It 'does not hide an authorization failure as service absence' {
        Mock Invoke-ServiceOperation -ModuleName M365Archive.Collectors {
            $exception = [Exception]::new('Forbidden')
            $exception | Add-Member -NotePropertyName StatusCode -NotePropertyValue 403
            throw $exception
        }
        {
            Test-IntuneAuditCapability -TenantId '11111111-2222-3333-4444-555555555555'
        } | Should -Throw
    }
}

Describe 'collector request contracts' {
    BeforeEach {
        Initialize-ApiRuntime -Policies $script:testPolicies -StatePath (Join-Path $TestDrive 'collector-runtime.json')
        Mock Connect-ArchiveGraph -ModuleName M365Archive.Collectors
        Mock Invoke-ServiceOperation -ModuleName M365Archive.Collectors { & $Operation }
    }

    It 'pages Graph responses through @odata.nextLink' {
        $script:graphUris = [Collections.Generic.List[string]]::new()
        Mock Invoke-MgGraphRequest -ModuleName M365Archive.Collectors {
            $script:graphUris.Add($Uri)
            if ($script:graphUris.Count -eq 1) {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'first' })
                    '@odata.nextLink' = 'https://graph.microsoft.com/next'
                }
            }
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'second' }) }
        }

        $records = @(Invoke-GraphPagedRequest 'https://graph.microsoft.com/first')

        $records.id | Should -Be @('first', 'second')
        $script:graphUris | Should -Be @('https://graph.microsoft.com/first', 'https://graph.microsoft.com/next')
    }

    It 'uses an inclusive Intune end one tick below the archive boundary' {
        $script:intuneUri = $null
        Mock Invoke-GraphPagedRequest -ModuleName M365Archive.Collectors {
            $script:intuneUri = [Uri]::UnescapeDataString($Uri)
        }
        $start = [DateTime]::Parse('2026-09-17T10:00:00Z').ToUniversalTime()
        $end = [DateTime]::Parse('2026-09-17T11:00:00Z').ToUniversalTime()

        Get-IntuneAuditRecords -TenantId '11111111-2222-3333-4444-555555555555' -StartUtc $start -EndUtc $end

        $script:intuneUri | Should -Match ([regex]::Escape("activityDateTime ge $($start.ToString('o')) and activityDateTime le $($end.AddTicks(-1).ToString('o'))"))
        $script:intuneUri | Should -Not -Match 'activityDateTime lt'
    }

    It 'skips Intune windows outside the moving two-year retention boundary' {
        Mock Invoke-GraphPagedRequest -ModuleName M365Archive.Collectors

        Get-IntuneAuditRecords -TenantId '11111111-2222-3333-4444-555555555555' `
            -StartUtc ([DateTime]::UtcNow.AddYears(-2).AddHours(-2)) `
            -EndUtc ([DateTime]::UtcNow.AddYears(-2).AddHours(-1))

        Should -Invoke Invoke-GraphPagedRequest -ModuleName M365Archive.Collectors -Times 0
    }

    It 'parses raw Unified AuditData without requesting formatted output' {
        $script:ualCalls = 0
        $script:ualParameters = $null
        Mock Search-UnifiedAuditLog -ModuleName M365Archive.Collectors {
            $script:ualCalls++
            $script:ualParameters = $PSBoundParameters
            if ($script:ualCalls -eq 1) {
                [pscustomobject]@{ Identity = 'ual-1'; AuditData = '{"Id":"ual-1","Operation":"FileAccessed"}' }
            }
        }

        $records = @(Get-UnifiedAuditRecords `
            -StartUtc ([DateTime]::Parse('2026-09-17T10:00:00Z').ToUniversalTime()) `
            -EndUtc ([DateTime]::Parse('2026-09-17T11:00:00Z').ToUniversalTime()))

        $records.Id | Should -Be 'ual-1'
        $script:ualParameters.ContainsKey('Formatted') | Should -BeFalse
    }

    It 'connects to Exchange without WAM or the fragile format-data bypass' {
        $script:exchangeParameters = $null
        Mock Connect-ExchangeOnline -ModuleName M365Archive.Collectors {
            param($UserPrincipalName, $ShowBanner, $DisableWAM, $SkipLoadingFormatData)
            $script:exchangeParameters = $PSBoundParameters
        }

        Connect-ArchiveExchange -UserPrincipalName 'operator@contoso.com'

        $script:exchangeParameters.UserPrincipalName | Should -Be 'operator@contoso.com'
        $script:exchangeParameters.ShowBanner | Should -BeFalse
        $script:exchangeParameters.DisableWAM | Should -BeTrue
        $script:exchangeParameters.ContainsKey('SkipLoadingFormatData') | Should -BeFalse
    }

    It 'uses an inclusive Azure end and follows an absolute nextLink' {
        $script:azureRequests = [Collections.Generic.List[string]]::new()
        Mock Set-AzContext -ModuleName M365Archive.Collectors
        Mock Invoke-AzRestMethod -ModuleName M365Archive.Collectors {
            param($Method, $Path, $Uri)
            $requestUri = if ($PSBoundParameters.ContainsKey('Uri')) { $Uri } else { $Path }
            $script:azureRequests.Add([Uri]::UnescapeDataString($requestUri))
            if ($script:azureRequests.Count -eq 1) {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '{"value":[{"eventDataId":"first"}],"nextLink":"https://management.azure.com/next"}'
                }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"eventDataId":"second"}]}' }
        }
        $start = [DateTime]::Parse('2026-09-17T10:00:00Z').ToUniversalTime()
        $end = [DateTime]::Parse('2026-09-17T11:00:00Z').ToUniversalTime()

        $records = @(Get-AzureActivityRecords `
            -SubscriptionId '11111111-2222-3333-4444-555555555555' -StartUtc $start -EndUtc $end)

        $records.eventDataId | Should -Be @('first', 'second')
        $script:azureRequests[0] | Should -Match ([regex]::Escape("eventTimestamp ge '$($start.ToString('o'))' and eventTimestamp le '$($end.AddTicks(-1).ToString('o'))'"))
        $script:azureRequests[0] | Should -Not -Match 'eventTimestamp lt'
        $script:azureRequests[1] | Should -Be 'https://management.azure.com/next'
    }
}
