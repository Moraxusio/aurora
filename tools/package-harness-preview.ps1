# Compatibility entry point; new callers use package-preview.ps1.
param(
    [string]$Version = '3.22.0',
    [string]$Suffix = 'ide-preview1',
    [Parameter(Mandatory)][string]$Out,
    [string]$Key = $env:AURORA_RELEASE_KEY,
    [string]$NotesFile = ''
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'package-preview.ps1') -Version $Version -Suffix $Suffix -Out $Out -Key $Key -NotesFile $NotesFile
