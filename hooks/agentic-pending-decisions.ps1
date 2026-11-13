# SessionStart hook, native Windows port of agentic-pending-decisions.sh: inject pending owner-decisions
# and the last-2-days work log into session context. A digest, not a dump - see the .sh for why the caps exist.

# Windows PowerShell 5.1 reads BOM-less files and writes stdout in the legacy code page, which turns
# every em dash in a decision log into mojibake. Read and emit UTF-8 explicitly.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$MaxRows  = 5     # newest rows shown per project and section
$MaxChars = 400   # per-row truncation

$today = (Get-Date).ToString('yyyy-MM-dd')
$yday  = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')

function Get-Section($lines, $heading) {
    $on = $false
    foreach ($l in $lines) {
        if ($l -match '^## ') { $on = ($l -match ('^## ' + [regex]::Escape($heading))); continue }
        if ($on) { $l }
    }
}

function Write-Digest($rows, $label) {
    $rows | Sort-Object -Descending | Select-Object -First $MaxRows | ForEach-Object {
        if ($_.Length -gt $MaxChars) { $_.Substring(0, $MaxChars) + ' ...' } else { $_ + ' ...' }
    }
    if ($rows.Count -gt $MaxRows) {
        "  (+$($rows.Count - $MaxRows) older $label rows not shown - full queue in the file above)"
    }
}

$dir = Join-Path $HOME '.claude/decisions'
if (-not (Test-Path -LiteralPath $dir)) { exit 0 }
foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.md' -File) {
    $proj  = $f.BaseName
    $lines = [IO.File]::ReadAllLines($f.FullName)
    # Struck-through rows (~~P-x~~ (resolved by D-y)) are the audit trail, not the queue.
    $pending = @(Get-Section $lines 'Pending Decisions' | Where-Object { $_ -match '^\| \d{4}' -and $_ -notmatch '~~' })
    if ($pending.Count) {
        "PENDING DECISIONS for the owner ($proj) - if the owner is present, surface these FIRST (numbered, with recommendations) before other work. Source: $($f.FullName)"
        Write-Digest $pending 'pending'
    }
    $work = @(Get-Section $lines 'Work Log' | Where-Object { $_ -match "^\| ($today|$yday)" })
    if ($work.Count) {
        "RECENT WORK ($proj, last 2 days) - include in the check-in digest:"
        Write-Digest $work 'work-log'
    }
}
exit 0
