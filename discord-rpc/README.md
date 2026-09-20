# Lumisound Discord Rich Presence

A small daemon that mirrors your Lumisound "now playing" state to your
Discord profile via Rich Presence.

## Why this can't be fully server-side

Discord's Rich Presence (the "Playing/Listening to..." card on a profile) is
only settable over Discord's **local IPC** — a Unix socket (or, on Windows, a
named pipe) that the Discord desktop client opens on the machine it's running
on. There is no Discord API that lets a remote server set another account's
Rich Presence directly; the only first-party way is this local connection.

So **something has to run next to your Discord desktop client** — there's no
way around that part. What Lumisound *does* centralize is everything else:
your Discord Application Client ID, Rich Presence art, and the on/off toggle
all live on the Lumisound server (`/user/discord-rpc-config`, set from
**Account → Discord Rich Presence**) and the daemon fetches them
automatically. The only thing you need locally is **one token** and **one
command/script** — see below.

## 1. Get your Rich Presence token

In the app, go to **Account → Discord Rich Presence** and:

1. Tap **Generate Rich Presence Token** — this only allows reading your own
   playback state, not your password, and can be revoked any time from
   **Account → Active Sessions** ("Discord RPC Bridge") without changing your
   password.
2. Enter a **Discord Application Client ID** (create one for free at
   https://discord.com/developers/applications — only the name/icon matter)
   and optionally a Rich Presence art asset name, then save. This is stored
   server-side, so the daemon picks it up automatically — nothing to copy
   into a config file.

## 2. Run the daemon

Pick your platform. Each script needs **just the token from step 1** —
everything else has a sensible default (the hosted Lumisound bridge) or comes
from your server-side registration.

### Linux (systemd --user service)

```sh
./install.sh <rpc_token>
```

Manage it with:

```sh
systemctl --user status lumisound-discord-rpc.service
journalctl --user -u lumisound-discord-rpc.service -f
```

### macOS (LaunchAgent, starts at login)

```sh
./install-macos.sh <rpc_token>
```

Manage it with:

```sh
launchctl list | grep lumisound
tail -f ~/.config/lumisound-discord-rpc/daemon.log
```

### Windows (Scheduled Task, starts at login)

Requires Python 3 from https://www.python.org/downloads/ (check "Add
python.exe to PATH"). In PowerShell:

```powershell
.\install-windows.ps1 -Token "<rpc_token>"
```

Manage it with:

```powershell
Get-ScheduledTask -TaskName LumisoundDiscordRPC
```

### Manual / any platform

```sh
mkdir -p ~/.config/lumisound-discord-rpc
echo '{"access_token": "<rpc_token>"}' > ~/.config/lumisound-discord-rpc/config.json
python3 lumisound_discord_rpc.py
```

If you're self-hosting the ios-bridge instead of using the hosted one, add
`"bridge_url": "https://your-bridge-host.example.com"` to `config.json` (or
pass it as the second argument to the install scripts).

## How it works

The daemon polls `GET /user/playback-state` on the bridge. Whenever
Lumisound's iOS app reports a track via the existing playback-state sync,
this daemon picks it up and calls `SET_ACTIVITY` over Discord's local IPC,
showing:

- **Details**: track title
- **State**: `by <artist>`
- **Timestamps**: elapsed/remaining bar based on `position_seconds` /
  `duration_seconds`

If playback is paused or the last update is older than 2 minutes (app
backgrounded/closed), the Rich Presence is cleared.

If you would rather keep a paused track on screen (without the elapsed timer),
set `"show_when_paused": true` in your config.
