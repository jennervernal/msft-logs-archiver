# Contributing

Use PowerShell 7, keep strict mode and terminating-error behavior, and preserve collector boundaries: service retrieval belongs in `M365Archive.Collectors.psm1`, adaptive service behavior in `M365Archive.RateLimit.psm1`, and archive/checkpoint primitives in `M365Archive.Core.psm1`.

Changes must:

- preserve explicit complete/partial/skipped/failed semantics and never turn unavailable data into success;
- retain half-open window behavior, deterministic resume, atomic finalization, bounded resources, and source-record fidelity;
- avoid fixed claims about Microsoft quotas or licenses;
- use fabricated IDs, paths, and records in tests/docs;
- avoid credentials, tokens, tenant data, runtime archives, checkpoints, or generated output;
- update collector/configuration/security/operations documentation when behavior changes.

Run parser checks and all Pester tests:

```powershell
$files = Get-ChildItem -Recurse -File -Include *.ps1,*.psm1,*.psd1
foreach ($file in $files) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) { $errors | Format-List; throw "Parser failure: $($file.FullName)" }
}
Invoke-Pester -Path .\tests -Output Detailed
```

Add deterministic Pester coverage for new pure behavior. Mock remote calls; automated tests must not require a tenant or interactive authentication. Keep commits focused and use a conventional subject such as `feat:`, `fix:`, `docs:`, or `test:`.
