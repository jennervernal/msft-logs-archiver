BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\M365Archive.Collectors.psm1') -Force
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
