<#
.SYNOPSIS
  Native Windows installer for the agentic system. No python, no bash, no WSL required.
.DESCRIPTION
  Installs agents, commands, rules and PowerShell hooks into ~/.claude, registers the hooks in
  settings.json, and appends/updates the marked agentic block in ~/.claude/CLAUDE.md.
  Idempotent. Existing files are backed up as *.bak.<timestamp>.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
#>
param(
    [switch]$Yes,
    [string]$ClaudeDir = (Join-Path $HOME '.claude')
)
$ErrorActionPreference = 'Stop'
$Repo  = Split-Path -Parent $PSScriptRoot
$Start = '<!-- agentic-system:start -->'
$End   = '<!-- agentic-system:end -->'
$Ts    = Get-Date -Format 'yyyyMMddHHmmss'
$Utf8  = New-Object System.Text.UTF8Encoding($false)
$Fwd   = { param($p) $p.Replace('\', '/') }

# Preflight - fail before mutating anything.
foreach ($need in 'claude/agents/*.md', 'claude/commands/*.md', 'hooks/agentic-*.ps1', 'claude/CLAUDE.agentic.md') {
    if (-not (Test-Path (Join-Path $Repo $need))) { throw "repo incomplete - $need missing." }
}

if (-not $Yes) {
    Write-Host 'This will modify:'
    Write-Host "  - $ClaudeDir\agents, commands, hooks, rules  (overwritten; existing ones backed up to *.bak.<ts>)"
    Write-Host "  - $ClaudeDir\settings.json                   (hook registrations merged; settings.json.bak written)"
    Write-Host "  - $ClaudeDir\CLAUDE.md                       (agentic block appended/replaced; backed up)"
    if ((Read-Host 'Continue? [y/N]') -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; exit 1 }
}

function Copy-WithBackup($srcGlob, $destDir) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    foreach ($f in Get-ChildItem -Path $srcGlob -File) {
        $dest = Join-Path $destDir $f.Name
        if (Test-Path $dest) { Copy-Item $dest "$dest.bak.$Ts" }
        Copy-Item $f.FullName $dest -Force
    }
}

New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeDir 'decisions') | Out-Null
Copy-WithBackup (Join-Path $Repo 'claude/agents/*.md')   (Join-Path $ClaudeDir 'agents')
Copy-WithBackup (Join-Path $Repo 'claude/commands/*.md') (Join-Path $ClaudeDir 'commands')
Copy-WithBackup (Join-Path $Repo 'hooks/agentic-*.ps1')  (Join-Path $ClaudeDir 'hooks')
if (Test-Path (Join-Path $Repo 'claude/rules')) {
    Copy-WithBackup (Join-Path $Repo 'claude/rules/*.md') (Join-Path $ClaudeDir 'rules')
}

# Merge hook registrations into settings.json (idempotent, backed up).
$settingsPath = Join-Path $ClaudeDir 'settings.json'
$settings = if (Test-Path $settingsPath) { [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }

function Register-Hook($event, $matcher, $scriptName) {
    $script = & $Fwd (Join-Path (Join-Path $ClaudeDir 'hooks') $scriptName)
    $command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if (-not $settings.hooks.PSObject.Properties[$event]) {
        $settings.hooks | Add-Member -NotePropertyName $event -NotePropertyValue @()
    }
    foreach ($e in @($settings.hooks.$event)) {
        foreach ($h in @($e.hooks)) { if ($h.type -eq 'command' -and $h.command -eq $command) { return } }
    }
    $entry = [ordered]@{ hooks = @([ordered]@{ type = 'command'; command = $command }) }
    if ($matcher) { $entry = [ordered]@{ matcher = $matcher; hooks = $entry.hooks } }
    $settings.hooks.$event = @(@($settings.hooks.$event) + [pscustomobject]$entry)
}
Register-Hook 'SessionStart' $null  'agentic-pending-decisions.ps1'
Register-Hook 'PreToolUse'   'Bash' 'agentic-push-gate.ps1'

if (Test-Path $settingsPath) { Copy-Item $settingsPath "$settingsPath.bak" -Force }
[IO.File]::WriteAllText($settingsPath, (ConvertTo-Json -InputObject $settings -Depth 20), $Utf8)
Write-Host 'Hooks registered in settings.json (backup: settings.json.bak)'

# CLAUDE.md marked block.
$target = Join-Path $ClaudeDir 'CLAUDE.md'
$block  = [IO.File]::ReadAllText((Join-Path $Repo 'claude/CLAUDE.agentic.md')).TrimEnd("`r", "`n")
if (-not (Test-Path $target)) { New-Item -ItemType File -Path $target | Out-Null }
Copy-Item $target "$target.bak.$Ts"
$text = [IO.File]::ReadAllText($target)
if ($text.Contains($Start)) {
    if (-not $text.Contains($End)) { throw "$target has a start marker but no end marker. Nothing was changed. Fix the markers and re-run." }
    $pattern = '(?s)' + [regex]::Escape($Start) + '.*?' + [regex]::Escape($End)
    $text = [regex]::Replace($text, $pattern, { param($mm) "$Start`n$block`n$End" })
    Write-Host "Updated agentic block in $target"
} else {
    $text = $text + "`n$Start`n$block`n$End`n"
    Write-Host "Appended agentic block to $target"
}
[IO.File]::WriteAllText($target, $text, $Utf8)

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning 'claude CLI not found on PATH - config installed, but nothing will run it.'
}
Write-Host 'Done. Restart Claude Code.'
