[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$ArchivePath,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$writer = if ($OutputPath) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.StreamWriter]::new($OutputPath, $false, [Text.UTF8Encoding]::new($false))
}
else { $null }

try {
    foreach ($path in $ArchivePath) {
        foreach ($resolvedPath in @(Resolve-Path -Path $path)) {
            $input = [IO.File]::OpenRead($resolvedPath.Path)
            $gzip = [IO.Compression.GZipStream]::new($input, [IO.Compression.CompressionMode]::Decompress)
            $reader = [IO.StreamReader]::new($gzip, [Text.Encoding]::UTF8)
            try {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if ($writer) { $writer.WriteLine($line) } else { $line | ConvertFrom-Json }
                }
            }
            finally {
                $reader.Dispose()
                $gzip.Dispose()
                $input.Dispose()
            }
        }
    }
}
finally {
    if ($writer) { $writer.Dispose() }
}
