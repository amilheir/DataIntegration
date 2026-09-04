# Windows entry point for the demo scripts (IMPROVEMENTS_SPEC PR-2, RR-1).
#
#   powershell -ExecutionPolicy Bypass -File scripts\demo.ps1 verify
#   powershell -ExecutionPolicy Bypass -File scripts\demo.ps1 reset
#   powershell -ExecutionPolicy Bypass -File scripts\demo.ps1 newday
#
# The checks themselves live in the .sh scripts and are NOT duplicated here: two
# implementations of a readiness check drift, and the one that drifts is the one
# nobody ran that morning. This finds the Git Bash that ships with Git for
# Windows and runs the single implementation through it.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("verify", "reset", "newday")]
    [string]$Command
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$candidates = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)
# Git Bash first, and only then whatever is on PATH. The bash on PATH is often
# C:\Windows\System32\bash.exe - the WSL launcher, which cannot see C:/... paths
# and fails with "No such file or directory" on a perfectly good script.
$bash = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) {
    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue |
              Where-Object { $_.Source -notlike "*\System32\*" -and $_.Source -notlike "*\SysWOW64\*" } |
              Select-Object -First 1
    if ($onPath) { $bash = $onPath.Source }
}

if (-not $bash) {
    Write-Output "!! No bash.exe found. Install Git for Windows, or run the script from any"
    Write-Output "   POSIX shell:  sh scripts/demo-$Command.sh"
    exit 2
}

# bash treats a Windows path's backslashes as escapes ("C:InterSystems..."), so
# hand it forward slashes - which it accepts on Windows.
$script = ($here -replace '\\', '/') + "/demo-$Command.sh"
& $bash $script
exit $LASTEXITCODE
