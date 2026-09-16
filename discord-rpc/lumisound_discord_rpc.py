#!/usr/bin/env python3
"""
Lumisound Discord Rich Presence bridge.

Runs locally (as a systemd --user service) alongside the Discord desktop
client. It polls the Lumisound ios-bridge server for the signed-in user's
current playback state (GET /user/playback-state) and mirrors it to Discord
via the local Rich Presence IPC socket, so other people on Discord can see
"Playing Lumisound - <title> / by <artist>" on your profile.

This only works because Discord's Rich Presence IPC is a local Unix socket
that the desktop client exposes to apps running on the same machine — it
cannot be driven remotely from the iOS app itself.

Setup:
  1. Create a Discord application at https://discord.com/developers/applications
     (only its name and optional icon matter for Rich Presence) and copy its
     Client ID.
  2. Copy config.example.json to ~/.config/lumisound-discord-rpc/config.json
     and fill in discord_client_id, bridge_url, and either access_token or
     username/password.
  3. Run this script directly, or install the provided systemd user service.
"""

from __future__ import annotations

import json
import os
import platform
import socket
import struct
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Optional

IS_WINDOWS = platform.system() == "Windows"

OP_HANDSHAKE = 0
OP_FRAME = 1
OP_CLOSE = 2
OP_PING = 3
OP_PONG = 4

DEFAULT_CONFIG_PATH = Path.home() / ".config" / "lumisound-discord-rpc" / "config.json"

# The hosted Lumisound bridge. Almost everyone uses this — `bridge_url` only
# needs to be set in config.json for people running their own ios-bridge
# instance, so the bare minimum config is just `{"access_token": "..."}`.
DEFAULT_BRIDGE_URL = "https://lumisound-bridge.xenusanimations.studio"


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{ts}  {msg}", flush=True)


# ---------------------------------------------------------------------------
# Discord IPC client
# ---------------------------------------------------------------------------


def _candidate_ipc_paths() -> list[str]:
    """Discord's RPC endpoint is named discord-ipc-{0..9} — a Unix socket on
    Linux/macOS, or a named pipe (`\\\\.\\pipe\\discord-ipc-{0..9}`) on
    Windows, placed in one of several possible locations depending on how
    Discord was installed (native package, Flatpak, Snap)."""
    if IS_WINDOWS:
        return [rf"\\.\pipe\discord-ipc-{i}" for i in range(10)]

    bases = []
    for var in ("XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"):
        val = os.environ.get(var)
        if val:
            bases.append(val)
    bases.append("/tmp")

    paths = []
    for base in bases:
        paths.append(base)
        paths.append(os.path.join(base, "app", "com.discordapp.Discord"))  # Flatpak
        paths.append(os.path.join(base, "snap.discord"))  # Snap

    sockets = []
    for base in paths:
        for i in range(10):
            sockets.append(os.path.join(base, f"discord-ipc-{i}"))
    return sockets


class DiscordIPCError(Exception):
    pass


class DiscordIPC:
    """Minimal client for Discord's local Rich Presence IPC protocol.

    On Linux/macOS this is a Unix domain socket; on Windows it's a named
    pipe opened as a regular file handle (`\\\\.\\pipe\\discord-ipc-N`),
    which supports the same read/write framing.
    """

    def __init__(self, client_id: str):
        self.client_id = client_id
        self.sock: Optional[socket.socket] = None
        self.pipe = None  # Windows named-pipe file handle

    def connect(self) -> None:
        if IS_WINDOWS:
            for path in _candidate_ipc_paths():
                try:
                    pipe = open(path, "r+b", buffering=0)
                except OSError:
                    continue
                self.pipe = pipe
                self._handshake()
                log(f"Connected to Discord IPC at {path}")
                return
            raise DiscordIPCError("No Discord IPC pipe found — is Discord running?")

        for path in _candidate_ipc_paths():
            if not os.path.exists(path):
                continue
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(path)
            except OSError:
                sock.close()
                continue
            self.sock = sock
            self._handshake()
            log(f"Connected to Discord IPC at {path}")
            return
        raise DiscordIPCError("No Discord IPC socket found — is Discord running?")

    def _write(self, data: bytes) -> None:
        if self.pipe:
            self.pipe.write(data)
        elif self.sock:
            self.sock.sendall(data)
        else:
            raise DiscordIPCError("Not connected")

    def _read(self, n: int) -> bytes:
        if self.pipe:
            return self.pipe.read(n)
        if self.sock:
            return self.sock.recv(n)
        raise DiscordIPCError("Not connected")

    def _send(self, opcode: int, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self._write(struct.pack("<II", opcode, len(data)) + data)

    def _recv(self) -> tuple[int, dict]:
        header = self._recv_exact(8)
        opcode, length = struct.unpack("<II", header)
        body = self._recv_exact(length)
        try:
            return opcode, json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            return opcode, {}

    def _recv_exact(self, n: int) -> bytes:
        chunks = []
        remaining = n
        while remaining > 0:
            chunk = self._read(remaining)
            if not chunk:
                raise DiscordIPCError("Discord IPC connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    @property
    def connected(self) -> bool:
        return self.sock is not None or self.pipe is not None

    def _handshake(self) -> None:
        self._send(OP_HANDSHAKE, {"v": 1, "client_id": self.client_id})
        opcode, payload = self._recv()
        if payload.get("evt") != "READY":
            raise DiscordIPCError(f"Unexpected handshake response: {payload}")

    def set_activity(self, activity: Optional[dict]) -> None:
        self._send(
            OP_FRAME,
            {
                "cmd": "SET_ACTIVITY",
                "args": {"pid": os.getpid(), "activity": activity},
                "nonce": str(uuid.uuid4()),
            },
        )
        # Drain the response so it doesn't pile up in the socket buffer.
        self._recv()

    def clear_activity(self) -> None:
        self.set_activity(None)

    def close(self) -> None:
        if self.sock:
            try:
                self._send(OP_CLOSE, {})
            except OSError:
                pass
            self.sock.close()
            self.sock = None
        if self.pipe:
            try:
                self._send(OP_CLOSE, {})
            except OSError:
                pass
            self.pipe.close()
            self.pipe = None


# ---------------------------------------------------------------------------
# Lumisound bridge client
# ---------------------------------------------------------------------------


class BridgeClient:
    def __init__(self, base_url: str, config_path: Path, config: dict):
        self.base_url = base_url.rstrip("/")
        self.config_path = config_path
        self.config = config
        self.access_token: Optional[str] = config.get("access_token")

    def _request(self, method: str, path: str, body: Optional[dict] = None, auth: bool = True) -> dict:
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {
            "Content-Type": "application/json",
            "User-Agent": "lumisound-discord-rpc/1.0",
        }
        if auth and self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}

    def login(self) -> None:
        username = self.config.get("username")
        password = self.config.get("password")
        if not username or not password:
            raise DiscordIPCError(
                "No access_token and no username/password configured — cannot authenticate"
            )
        result = self._request(
            "POST", "/auth/login",
            {"username": username, "password": password, "device_name": "Discord RPC Bridge"},
            auth=False,
        )
        if result.get("requires_2fa"):
            # /auth/login returns {"requires_2fa": True, "pending_token": ...}
            # (no "token") for a 2FA-enabled account — this daemon has no way
            # to prompt for a TOTP code, so username/password login can never
            # complete for one. Without this check, `result["token"]` below
            # raised an uncaught KeyError, crashing the daemon outright. The
            # /user/rpc-token flow (Lumisound -> Account -> Discord Rich
            # Presence -> Generate Rich Presence Token) sidesteps this
            # entirely since it's generated from inside the already-logged-in
            # app — that's the recommended setup for exactly this reason.
            raise DiscordIPCError(
                "This account has two-factor authentication enabled — username/password "
                "login can't complete a TOTP challenge here. Generate a Rich Presence "
                "token instead: Lumisound -> Account -> Discord Rich Presence -> "
                "\"Generate Rich Presence Token\", then set it as access_token in config.json."
            )
        self.access_token = result["token"]
        log("Logged in to Lumisound bridge")

        # Persist the fresh token so future restarts don't need to re-login
        # (and so a password doesn't need to stay in the config forever).
        try:
            self.config["access_token"] = self.access_token
            self.config_path.write_text(json.dumps(self.config, indent=2))
        except OSError as exc:
            log(f"Warning: could not persist refreshed token: {exc}")

    def get_playback_state(self) -> Optional[dict]:
        if not self.access_token:
            self.login()
        try:
            return self._request("GET", "/user/playback-state")
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                log("Access token expired/invalid, re-authenticating")
                self.login()
                return self._request("GET", "/user/playback-state")
            raise

    def get_rpc_config(self) -> Optional[dict]:
        """Fetches this user's registered Discord Rich Presence settings
        (discord_client_id, large_image, enabled) from the bridge, set via
        Lumisound -> Account -> Discord Rich Presence. Returns None if the
        user hasn't registered one (configured == False)."""
        if not self.access_token:
            self.login()
        try:
            result = self._request("GET", "/user/discord-rpc-config")
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                log("Access token expired/invalid, re-authenticating")
                self.login()
                result = self._request("GET", "/user/discord-rpc-config")
            else:
                raise
        return result if result.get("configured") else None


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


_BUTTON_LABELS = {
    "youtube": "Listen on YouTube",
    "soundcloud": "Listen on SoundCloud",
}


def build_activity(
    state: dict,
    large_image: Optional[str],
    small_image: Optional[str] = None,
    show_buttons: bool = True,
) -> Optional[dict]:
    """Translates a /user/playback-state response into a Discord SET_ACTIVITY
    payload, or None if nothing should be shown (stale/no track)."""
    if not state or not state.get("title"):
        return None

    updated_at = state.get("updated_at")
    if updated_at:
        try:
            from datetime import datetime, timezone
            updated = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
            if updated.tzinfo is None:
                # The bridge returns naive timestamps in the server's local
                # time zone (not UTC), so compare against local "now".
                age = (datetime.now() - updated).total_seconds()
            else:
                age = (datetime.now(timezone.utc) - updated).total_seconds()
            if age > 120:
                return None  # client hasn't reported in — likely backgrounded/closed
        except ValueError:
            pass

    is_playing = state.get("is_playing", True)

    activity: dict = {
        # ActivityType 2 = "Listening to ..." instead of the default 0
        # ("Playing ..."), which made Lumisound show up like a game.
        "type": 2,
        "details": (state.get("title") or "")[:128],
    }
    if state.get("artist"):
        activity["state"] = f"by {state['artist']}"[:128]

    if is_playing:
        # Only set "start" — if "end" is also set, Discord renders a countdown
        # to "end" (counting DOWN from the track's remaining time) instead of
        # an elapsed-time counter counting UP from 0:00.
        position = state.get("position_seconds") or 0
        now = time.time()
        activity["timestamps"] = {"start": int(now - position)}
    # When paused, omit timestamps entirely rather than showing a frozen
    # elapsed counter that keeps ticking — the small_text/small_image (if
    # configured) is the only indicator of paused state.

    assets: dict = {}
    if large_image:
        assets["large_image"] = large_image
        assets["large_text"] = "Lumisound"
    if small_image:
        assets["small_image"] = small_image
        assets["small_text"] = "Playing" if is_playing else "Paused"
    if assets:
        activity["assets"] = assets

    if show_buttons and state.get("track_url"):
        label = _BUTTON_LABELS.get(state.get("source"), "Open Track")
        activity["buttons"] = [{"label": label, "url": state["track_url"]}]

    return activity


def load_config(config_path: Path) -> dict:
    if not config_path.exists():
        log(f"No config found at {config_path}")
        log("Copy config.example.json there and fill in your details, or run install.sh with your Rich Presence token.")
        sys.exit(1)
    config = json.loads(config_path.read_text())
    if not config.get("access_token") and not (config.get("username") and config.get("password")):
        log(f"{config_path} needs an \"access_token\" (Lumisound -> Account -> Generate Rich Presence Token).")
        sys.exit(1)
    return config


def main() -> None:
    config_path = Path(os.environ.get("LUMISOUND_RPC_CONFIG", DEFAULT_CONFIG_PATH))
    config = load_config(config_path)

    bridge_url = config.get("bridge_url") or DEFAULT_BRIDGE_URL
    poll_interval = config.get("poll_interval_seconds", 5)
    bridge = BridgeClient(bridge_url, config_path, config)

    # client_id/large_image can be set locally, but normally come from the
    # server-side registration made in Lumisound -> Account -> Discord Rich
    # Presence (GET /user/discord-rpc-config) — that's the "general server"
    # bit: the local daemon only needs bridge_url + access_token.
    client_id = config.get("discord_client_id")
    large_image = config.get("large_image")
    small_image = config.get("small_image")
    show_buttons = config.get("show_buttons", True)

    if not client_id:
        log("No discord_client_id in local config — fetching registration from bridge")
        # Waits for a usable token rather than exiting.
        #
        # An RPC token's session is revoked whenever the account password
        # changes (the bridge deletes every OTHER session on a password change,
        # which is correct). The daemon then 401s, and because this used to
        # raise straight out of main(), systemd restarted it into the same
        # failure every few seconds — a crash loop that produced no working
        # presence and no clear statement of why. It stayed that way silently
        # for days.
        #
        # The IPC-socket path below already waits patiently for Discord to
        # start; a missing credential deserves the same treatment, so that
        # dropping a fresh token into config.json is picked up without anyone
        # having to notice the service is dead and restart it by hand.
        rpc_config = None
        while rpc_config is None:
            try:
                rpc_config = bridge.get_rpc_config()
                break
            except DiscordIPCError as exc:
                log(f"Cannot authenticate with the bridge: {exc}")
                log("Generate a new token in Lumisound -> Account -> Discord Rich Presence "
                    "and set it as access_token in config.json. Retrying in 60s.")
                time.sleep(60)
            except urllib.error.HTTPError as exc:
                if exc.code in (401, 403):
                    log(f"Bridge rejected the RPC token (HTTP {exc.code}) — it has most likely "
                        "been revoked by a password change.")
                    log("Generate a new token in Lumisound -> Account -> Discord Rich Presence "
                        "and set it as access_token in config.json. Retrying in 60s.")
                    time.sleep(60)
                else:
                    raise
        if not rpc_config:
            log("No Discord Rich Presence config registered for this account.")
            log("Open Lumisound -> Account -> Discord Rich Presence to register a Discord Application Client ID, or set discord_client_id in config.json.")
            sys.exit(1)
        if not rpc_config.get("enabled", True):
            log("Discord Rich Presence is disabled for this account (Lumisound -> Account -> Discord Rich Presence).")
            sys.exit(0)
        client_id = rpc_config["discord_client_id"]
        large_image = large_image or rpc_config.get("large_image")
        small_image = small_image or rpc_config.get("small_image")
        if "show_buttons" not in config:
            show_buttons = rpc_config.get("show_buttons", True)
        log(f"Using registered Discord Application Client ID {client_id}")

    ipc = DiscordIPC(client_id)

    last_activity_signature: Optional[tuple] = None

    while True:
        # --- Discord IPC connection -----------------------------------
        # Handled separately from the bridge request below: urllib's
        # URLError/HTTPError (e.g. a 502 or read timeout from the bridge)
        # are themselves OSError subclasses, so they must not be confused
        # with a dead Discord IPC socket — doing so used to force a
        # spurious IPC reconnect (and a "Cleared"/"Now playing" flicker)
        # every time the bridge had an unrelated network hiccup.
        try:
            if not ipc.connected:
                ipc.connect()
        except (DiscordIPCError, OSError) as exc:
            log(f"Discord IPC error: {exc}")
            if ipc.connected:
                ipc.close()
            last_activity_signature = None
            time.sleep(poll_interval)
            continue

        # --- Lumisound bridge request -----------------------------------
        try:
            state = bridge.get_playback_state()
        except urllib.error.URLError as exc:
            log(f"Bridge request failed: {exc}")
            time.sleep(poll_interval)
            continue
        except Exception as exc:  # noqa: BLE001 — keep the daemon alive
            log(f"Unexpected error: {exc}")
            time.sleep(poll_interval)
            continue

        # --- Update Rich Presence ---------------------------------------
        activity = build_activity(state, large_image, small_image, show_buttons)
        try:
            # Discord's rate limit (5 SET_ACTIVITY calls per 20s) is well
            # above our poll interval, so we re-send every poll (timestamps
            # need refreshing anyway) but only log when the track changes.
            signature = (activity.get("details"), activity.get("state"), "timestamps" in activity) if activity else None
            ipc.set_activity(activity)
            if signature != last_activity_signature:
                if activity:
                    status = "Now playing" if "timestamps" in activity else "Paused"
                    log(f"{status}: {activity.get('details')} {activity.get('state', '')}")
                else:
                    log("Cleared Rich Presence (idle)")
                last_activity_signature = signature
        except (DiscordIPCError, OSError) as exc:
            # The IPC socket died under us — usually because Discord was
            # restarted and replaced its socket file. Drop our handle so
            # the next loop iteration reconnects.
            log(f"Discord IPC error: {exc}")
            if ipc.connected:
                ipc.close()
            last_activity_signature = None

        time.sleep(poll_interval)


if __name__ == "__main__":
    main()
