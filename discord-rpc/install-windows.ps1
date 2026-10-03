# Sets up the Lumisound Discord Rich Presence daemon to run at login on Windows.
#
# Requires Python 3 (https://www.python.org/downloads/ — check "Add python.exe
# to PATH" during install).
#
# Usage (in PowerShell):
#   .\install-windows.ps1                              # sign in with email/username + password
#   .\install-windows.ps1 -Token "<rpc_token>"          # or paste a token
#   .\install-windows.ps1 -BridgeUrl "https://..."      # self-hosted bridge
#
# Signing in is the default: the Rich Presence token is 248 characters and
# pasting it into a PowerShell window — which wraps and can mangle long lines —
# was the most error-prone step of setup. Your password is exchanged for a
# 365-day token and is never written to disk (see rpc_login.py).

param(
    [string]$Token = "",
    [string]$BridgeUrl = "",
    [string]$Identifier = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $ScriptDir "lumisound_discord_rpc.py"
$LoginPath = Join-Path $ScriptDir "rpc_login.py"

$Python = (Get-Command python -ErrorAction SilentlyContinue).Path
if (-not $Python) {
    $Python = (Get-Command python3 -ErrorAction SilentlyContinue).Path
}
if (-not $Python) {
    Write-Error "Python 3 not found. Install it from https://www.python.org/downloads/ and re-run this script."
    exit 1
}

# Config writing is delegated to rpc_login.py rather than done here in
# PowerShell. This script used to write %APPDATA%\lumisound-discord-rpc\config.json
# directly, but the daemon only ever read ~\.config\lumisound-discord-rpc\config.json
# and nothing set LUMISOUND_RPC_CONFIG — so the config landed where the daemon
# never looked and every Windows install failed with "No config found".
# rpc_login.py imports the daemon's own default_config_path(), so the two
# cannot disagree again.
$LoginArgs = @($LoginPath)
if ($Token) { $LoginArgs += @("--token", $Token) }
if ($BridgeUrl) { $LoginArgs += @("--bridge-url", $BridgeUrl) }
if ($Identifier) { $LoginArgs += @("--identifier", $Identifier) }

& $Python @LoginArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Sign-in failed; the scheduled task was not registered."
    exit $LASTEXITCODE
}

# Register a logon task that restarts the daemon if it ever exits.
$Action = New-ScheduledTaskAction -Execute $Python -Argument "`"$ScriptPath`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -Hidden -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 0)
Register-ScheduledTask -TaskName "LumisoundDiscordRPC" -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null

Write-Host "Registered scheduled task 'LumisoundDiscordRPC' (runs at login)."
Write-Host "Starting it now..."
Start-ScheduledTask -TaskName "LumisoundDiscordRPC"

Write-Host ""
Write-Host "Check status with:"
Write-Host "  Get-ScheduledTask -TaskName LumisoundDiscordRPC"
Write-Host "Stop it with:"
Write-Host "  Stop-ScheduledTask -TaskName LumisoundDiscordRPC; Unregister-ScheduledTask -TaskName LumisoundDiscordRPC -Confirm:`$false"
