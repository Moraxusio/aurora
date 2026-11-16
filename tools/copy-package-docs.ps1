# Preserve document paths, then validate links against the actual bundle.
param([Parameter(Mandatory)][string]$Destination, [string]$NotesFile = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$docs = Join-Path $repo 'docs'
$notesRelative = ''
if ($NotesFile) {
    if (-not [IO.Path]::IsPathRooted($NotesFile)) { $NotesFile = Join-Path $repo $NotesFile }
    $NotesFile = (Resolve-Path -LiteralPath $NotesFile).Path
    if (-not $NotesFile.StartsWith("$docs\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Package notes must be a document inside docs/'
    }
    $notesRelative = $NotesFile.Substring($repo.Length + 1).Replace('\', '/')
}
Copy-Item (Join-Path $repo 'LICENSE'), (Join-Path $repo 'NOTICE'), (Join-Path $repo 'README.md') $Destination
Copy-Item -LiteralPath $docs -Destination $Destination -Recurse
# Archived attribution links retain their original source-relative target.
$attribution = Join-Path $Destination 'agent\internal\ai'
New-Item -ItemType Directory -Path $attribution -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'agent\internal\ai\THIRD_PARTY_OPENCODE_LICENSE') -Destination $attribution
if ($notesRelative) {
    @"
# Version notes

[Read the bundled version notes]($notesRelative).

[Documentation](docs/README.md).
"@ | Set-Content -LiteralPath (Join-Path $Destination 'CHANGES.md') -Encoding utf8
}
& (Join-Path $PSScriptRoot 'check-docs.ps1') -Root $Destination -Package
