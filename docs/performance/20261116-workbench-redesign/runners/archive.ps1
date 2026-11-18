param([ValidateSet('source','package')][string]$Stage = 'source')
$ErrorActionPreference = 'Stop'
$tmp = 'C:\Users\finwe\AppData\Local\Temp\opencode'
$out = 'C:\build\aurora\docs\performance\20261116-workbench-redesign'
function CopyEvidence([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Missing evidence: $Source" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Target) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Target -Force
}
if ($Stage -eq 'source') {
    foreach ($name in @('go-all','go-vet','go-build','go-race','go-race-ai2','systemd-linux2','gui-targeted1','repair-targeted1','docs-final')) {
        CopyEvidence "$tmp\aurora-workbench-$name.log" "$out\checks\$name.log"
    }
    foreach ($name in @('repair-repro','repair-repro2','gui-targeted2','gui-targeted3','analyze-gui1','analyze-gui2','systemd-linux','go-targeted','ui-contract')) {
        CopyEvidence "$tmp\aurora-workbench-$name.log" "$out\failures\$name.log"
    }
    foreach ($file in Get-ChildItem "$tmp\aurora-workbench-client" -File -Filter *.log) {
        CopyEvidence $file.FullName "$out\checks\client\$($file.Name)"
    }
    foreach ($file in Get-ChildItem "$tmp\aurora-workbench-client\shots-final4" -File -Filter *.png) {
        CopyEvidence $file.FullName "$out\screenshots\$($file.Name)"
    }
    foreach ($file in Get-ChildItem "$tmp\aurora-workbench-client\shots-extra4" -File -Filter *.png) {
        CopyEvidence $file.FullName "$out\screenshots\extra\$($file.Name)"
    }
    foreach ($file in Get-ChildItem "$tmp\aurora-workbench-linux" -File | Where-Object Extension -in '.log','.json') {
        CopyEvidence $file.FullName "$out\linux\$($file.Name)"
    }
    foreach ($audit in @('interaction','foundation','foundation2','foundation3')) {
        foreach ($file in Get-ChildItem "$tmp\aurora-workbench-native-$audit" -File) {
            CopyEvidence $file.FullName "$out\native-$audit\$($file.Name)"
        }
    }
    foreach ($file in @('baseline.json','hashes.json')) {
        CopyEvidence "$tmp\aurora-workbench-repair-baseline\$file" "$out\baseline\$file"
    }
    CopyEvidence "$tmp\aurora-workbench-ai-preservation.json" "$out\baseline\ai-preservation.json"
    CopyEvidence "$tmp\aurora-workbench-audit-source-consistency.json" "$out\baseline\audit-source-consistency.json"
    CopyEvidence "$tmp\aurora-workbench-environment.json" "$out\environment.json"
    foreach ($file in @('flutter.out','agent.log','node.log')) {
        CopyEvidence "$tmp\aurora-workbench-proxy-e2e2\$file" "$out\proxy-e2e\$file"
    }
    CopyEvidence "$tmp\aurora-workbench-proxy-e2e\flutter.out" "$out\failures\proxy-e2e-first.log"
    CopyEvidence "$tmp\aurora-workbench-proxy-e2e.ps1" "$out\proxy-e2e\run.ps1"
    foreach ($file in @('aurora-workbench-build-fixtures.ps1','aurora-workbench-upgrade-keygen.go')) {
        CopyEvidence "$tmp\$file" "$out\checks\client\$file"
    }
    foreach ($name in @('client-final4','packages-final','native','archive')) {
        CopyEvidence "$tmp\aurora-workbench-$name.ps1" "$out\runners\$name.ps1"
    }
    foreach ($set in @('final4','extra4')) {
        foreach ($file in Get-ChildItem "$tmp\aurora-workbench-package\contact-sheets-$set" -File -Filter *.png) {
            CopyEvidence $file.FullName "$out\contact-sheets\$set\$($file.Name)"
        }
    }
} else {
    foreach ($file in Get-ChildItem "$tmp\aurora-workbench-package" -File | Where-Object Extension -in '.log','.txt','.json','.ps1','.dart') {
        CopyEvidence $file.FullName "$out\package\$($file.Name)"
    }
    foreach ($file in @('BUILD-INFO.json','SOURCE-HASHES.json')) {
        CopyEvidence "C:\dev\VPS\preview5\Aurora-3.24.0-workbench-preview1\$file" "$out\package\$file"
    }
}
Write-Output "Evidence archived: $Stage -> $out"
