# PreToolUse (Bash) hook, native Windows port of agentic-push-gate.sh/.py (no python, no bash needed).
# Blocks `git push` unless the pipeline green marker matches HEAD. Fails CLOSED (exit 2) on any doubt.
$ErrorActionPreference = 'Stop'

function Block($msg) { [Console]::Error.WriteLine($msg); exit 2 }

try {
    # PS 5.1 decodes stdin in the legacy code page; a non-ASCII repo path would arrive mangled.
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'hook input missing/empty' }
    $data = $raw | ConvertFrom-Json
    $cmd = $data.tool_input.command
    if ($cmd -isnot [string]) { throw 'tool_input.command is not a string' }
} catch {
    Block "PUSH BLOCKED: malformed hook input ($($_.Exception.Message)) - failing closed."
}

# git ... push at a command position (line start or after ; & |), not inside a quoted string
$m = [regex]::Match($cmd, '(?:^|[;&|\n]\s*)(git\b[^;&|\n]*?(?<![\w./-])push(?![\w./-])[^;&|\n]*)')
if (-not $m.Success) { exit 0 }

$seg = $m.Groups[1].Value
$quotedOrBare = '("([^"]+)"|''([^'']+)''|(\S+))'
$dir = ''
$mc = [regex]::Match($seg, '-C\s+' + $quotedOrBare)
if ($mc.Success) {
    $dir = ($mc.Groups[2].Value, $mc.Groups[3].Value, $mc.Groups[4].Value | Where-Object { $_ } | Select-Object -First 1)
} else {
    # last `cd <path>` at a command position before the push segment
    $before = $cmd.Substring(0, $m.Groups[1].Index)
    foreach ($c in [regex]::Matches($before, '(?:^|[;&|\n]\s*)cd\s+("([^"]+)"|''([^'']+)''|([^\s;&|]+))')) {
        $dir = ($c.Groups[2].Value, $c.Groups[3].Value, $c.Groups[4].Value | Where-Object { $_ } | Select-Object -First 1)
    }
}

if ($dir) {
    if ($dir -eq '~' -or $dir.StartsWith('~/')) { $dir = $HOME + $dir.Substring(1) }
    $dir = $dir -replace '^\$HOME', $HOME
    $dir = $dir -replace '^/([a-zA-Z])(/|$)', '$1:$2'   # Git Bash /c/Users/x -> c:/Users/x
    $dir = [Environment]::ExpandEnvironmentVariables($dir)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Block "PUSH BLOCKED: cannot resolve target repo dir '$dir' from the command - failing closed. Use a plain 'cd <dir> && git push' form."
    }
    Set-Location -LiteralPath $dir
}

$ErrorActionPreference = 'Continue'   # PS 5.1 turns native stderr into a terminating error under Stop
$gitdir = & git rev-parse --git-dir 2>$null
if ($LASTEXITCODE -ne 0) { exit 0 }
$head = & git rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0) { exit 0 }
$marker = Join-Path $gitdir 'AGENTIC_GREEN'
if ((Test-Path -LiteralPath $marker) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $head.Trim())) { exit 0 }

# tripwire, not a vault: pushes buried in scripts are beyond text parsing; writing the marker is the documented override
Block "PUSH BLOCKED: no green pipeline gate for HEAD ($head). Run the tester + functional gates; on PASS write the marker and push:  git rev-parse HEAD > `"$gitdir/AGENTIC_GREEN`". Non-pipeline repos: write the marker after your own verification - deliberate override, log it if it skips a real gate."
