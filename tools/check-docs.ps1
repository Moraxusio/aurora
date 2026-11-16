# Checks owned Markdown structure, metadata, navigation and local links.
param([string]$Root = (Split-Path -Parent $PSScriptRoot), [switch]$Package)
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
$docs = Join-Path $Root 'docs'
$index = [IO.File]::ReadAllText((Join-Path $docs 'README.md'))
$errors = New-Object 'System.Collections.Generic.List[string]'
$files = @(Get-ChildItem -LiteralPath $docs -Filter *.md -File -Recurse)
$rootFiles = @(if ($Package) { 'README.md' } else { 'README.md', 'AGENTS.md', 'app/AGENTS.md' })
if ($Package -and (Test-Path -LiteralPath (Join-Path $Root 'CHANGES.md'))) { $rootFiles += 'CHANGES.md' }
foreach ($name in $rootFiles) {
    $files += Get-Item -LiteralPath (Join-Path $Root $name)
}
$current = 0
foreach ($file in $files) {
    $relative = $file.FullName.Substring($Root.Length + 1).Replace('\', '/')
    $text = [IO.File]::ReadAllText($file.FullName)
    # Examples inside fenced/inline code are not navigable Markdown links.
    $body = [regex]::Replace($text, '(?ms)^```[^\r\n]*\r?\n.*?^```[^\r\n]*', '')
    $body = [regex]::Replace($body, '`[^`\r\n]+`', '')
    foreach ($match in [regex]::Matches($body, '\]\(([^)\r\n]+)\)')) {
        $target = $match.Groups[1].Value.Trim()
        if ($target -match '^(https?://|mailto:|#)') { continue }
        $target = ($target -split '#', 2)[0]
        if (-not $target) { continue }
        $target = [Uri]::UnescapeDataString($target.Trim('<', '>'))
        if (-not (Test-Path -LiteralPath (Join-Path $file.DirectoryName $target))) {
            $errors.Add("$relative -> missing link: $target")
        }
    }
    if (-not $relative.StartsWith('docs/')) { continue }
    $name = $relative.Substring(5)
    if ($name.StartsWith('performance/')) { continue }
    if ($name.StartsWith('archive/') -and $name -ne 'archive/README.md') {
        if ($text -notmatch '> 已归档：\d{4}-\d{2}-\d{2}') {
            $errors.Add("$relative -> missing archive notice")
        }
        continue
    }
    $current++
    if ($name -notmatch '/' -and $name -ne 'README.md') {
        $errors.Add("$relative -> docs root is reserved for README.md")
    }
    if ($file.Name -ne 'README.md' -and $file.Name -cnotmatch '^[a-z0-9]+(?:[.-][a-z0-9]+)*\.md$') {
        $errors.Add("$relative -> use lowercase kebab-case filenames")
    }
    if ([regex]::Matches($body, '(?m)^# [^\r\n]+').Count -ne 1) {
        $errors.Add("$relative -> expected exactly one H1")
    }
    if ($text -notmatch '(?m)^> 类型：[^|\r\n]+\| 状态：(生效|候选|已记录|模板|已替代) \| 维护：[^|\r\n]+\| 更新：\d{4}-\d{2}-\d{2}\s*$' -or
        $text -notmatch '(?m)^> 适用：\S.+$') {
        $errors.Add("$relative -> incomplete document metadata")
    }
    if ($name -ne 'README.md' -and -not $index.Contains("]($name)")) {
        $errors.Add("$relative -> not listed in docs/README.md")
    }
}

# Old absolute doc entry paths in owned code/scripts/current docs must migrate too.
$owned = @()
if (-not $Package) {
    $owned = & git -C $Root ls-files --cached --others --exclude-standard -- '*.md' '*.go' '*.dart' '*.ps1' '*.yaml'
    if ($LASTEXITCODE) { throw 'Cannot enumerate owned documentation references' }
}
$legacy = 'docs[/\\](?:DESIGN|PLAN|AI|AI_HARNESS|AI_REDESIGN|AURORA_GUI|DEVELOPMENT_TOOLS|GUI_FOUNDATION|GUI_AUDIT|UI_SYSTEM|TABS|LOCAL_AGENT|GPU_MONITOR|IMPLEMENTATION_ROADMAP_20261116|IMPLEMENTATION_VALIDATION_20261116|PROJECT_AUDIT_20261116)\.md'
foreach ($name in ($owned | Sort-Object -Unique)) {
    if ($name -match '^docs/(archive|performance)/|/third_party/') { continue }
    $path = Join-Path $Root $name
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and [IO.File]::ReadAllText($path) -match $legacy) {
        $errors.Add("$name -> references a retired docs root entry")
    }
}
if ($errors.Count) {
    $errors | Write-Output
    throw "Documentation contract failed: $($errors.Count) problem(s)"
}
Write-Output "Documentation contract passed: $current current documents, $($files.Count) Markdown files, local links and owned references."
