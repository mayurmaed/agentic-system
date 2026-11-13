# SessionStart hook, native Windows port of agentic-pending-decisions.sh: inject pending owner-decisions
# and the last-2-days work log into session context.
$today = (Get-Date).ToString('yyyy-MM-dd')
$yday  = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')

function Get-Section($lines, $heading) {
    $on = $false
    foreach ($l in $lines) {
        if ($l -match '^## ') { $on = ($l -match ('^## ' + [regex]::Escape($heading))); continue }
        if ($on) { $l }
    }
}

$dir = Join-Path $HOME '.claude/decisions'
if (-not (Test-Path -LiteralPath $dir)) { exit 0 }
foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.md' -File) {
    $proj  = $f.BaseName
    $lines = Get-Content -LiteralPath $f.FullName
    $pending = @(Get-Section $lines 'Pending Decisions' | Where-Object { $_ -match '^\| \d{4}' })
    if ($pending.Count) {
        "PENDING DECISIONS for the owner ($proj) - if the owner is present, surface these FIRST (numbered, with recommendations) before other work:"
        $pending
    }
    $work = @(Get-Section $lines 'Work Log' | Where-Object { $_ -match "^\| ($today|$yday)" })
    if ($work.Count) {
        "RECENT WORK ($proj, last 2 days) - include in the check-in digest:"
        $work
    }
}
exit 0
