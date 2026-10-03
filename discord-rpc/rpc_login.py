#!/usr/bin/env python3
"""Interactive sign-in for the Lumisound Discord Rich Presence daemon.

Writes ~/.config/lumisound-discord-rpc/config.json containing a long-lived
Rich Presence token. Shared by install.sh, install-macos.sh and
install-windows.ps1 so the login flow exists once rather than three times --
python3 is already a hard requirement of the daemon itself, so every platform
that can run the daemon can run this.

Why this asks for email/username + password instead of a token: the Rich
Presence token is 248 characters, and pasting it into a terminal (especially
cmd.exe/PowerShell, which wrap and mangle long lines) was the single most
error-prone step of setup.

The password is never written to disk. It is exchanged here for a 365-day
Rich Presence token -- a regular revocable session, visible in
Lumisound -> Account -> Sessions -- and only that token is stored.

Usage:
  rpc_login.py [--bridge-url URL] [--token TOKEN] [--identifier EMAIL_OR_USERNAME]

  --token        skip the interactive login and store this token as-is
                 (the old "Generate Rich Presence Token" path; also the only
                 option for accounts whose 2FA code is unavailable)
  --identifier   pre-fill the email/username prompt (password is still asked for)
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import NoReturn

DEFAULT_BRIDGE_URL = "https://lumisound-bridge.xenusanimations.studio"


def device_name() -> str:
    """Hostname-qualified, e.g. "Discord RPC Bridge (desmond-laptop)".

    The bridge supersedes a previous RPC session by exact device_name match,
    so this has to identify the machine: a bare "Discord RPC Bridge" would
    make a desktop and a laptop look like the same device and each setup would
    revoke the other's token. It also makes Account -> Sessions readable when
    you do run it in more than one place.
    """
    host = ""
    try:
        host = socket.gethostname().split(".")[0].strip()
    except OSError:
        pass
    return f"Discord RPC Bridge ({host})" if host else "Discord RPC Bridge"


# /auth/login creates a session of its own, which becomes dead weight the
# moment its token is traded for the RPC one. It is logged out below, but it is
# labelled distinctly so that if the logout ever fails the leftover is
# identifiable in Account -> Sessions rather than looking like a second daemon
# -- and so the bridge can sweep abandoned ones (it matches "%(setup)").
# The suffix must stay exactly "(setup)" for that sweep to find it.
SETUP_DEVICE_NAME = "Discord RPC Bridge (setup)"

# Imported from the daemon rather than re-derived, so the installer can never
# write the config somewhere the daemon does not read it -- exactly the bug
# that made every Windows install fail (installer wrote %APPDATA%, daemon read
# ~/.config). Both now agree by construction.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lumisound_discord_rpc import default_config_path  # noqa: E402

CONFIG_FILE = default_config_path()
CONFIG_DIR = CONFIG_FILE.parent


def _post(base_url: str, path: str, body: dict, token: str | None = None) -> dict:
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "lumisound-rpc-login/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}{path}",
        data=json.dumps(body).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else {}


def _fail(msg: str) -> NoReturn:
    print(f"\nError: {msg}", file=sys.stderr)
    sys.exit(1)


def _describe_http_error(exc: urllib.error.HTTPError) -> str:
    """Surfaces the bridge's own `detail` string rather than a bare 401."""
    try:
        detail = json.loads(exc.read()).get("detail")
    except Exception:
        detail = None
    if detail:
        return str(detail)
    if exc.code == 401:
        return "Invalid email/username or password."
    if exc.code == 429:
        return "Too many attempts -- wait a minute and try again."
    return f"HTTP {exc.code} from the Lumisound bridge."


def interactive_login(base_url: str, identifier: str | None) -> str:
    """Returns a 365-day Rich Presence token. Password never leaves memory."""
    if not identifier:
        identifier = input("Lumisound email or username: ").strip()
    if not identifier:
        _fail("No email/username entered.")

    password = getpass.getpass("Lumisound password (not shown): ")
    if not password:
        _fail("No password entered.")

    print("Signing in...")
    try:
        result = _post(
            base_url, "/auth/login",
            {"username": identifier, "password": password, "device_name": SETUP_DEVICE_NAME},
        )
    except urllib.error.HTTPError as exc:
        _fail(_describe_http_error(exc))
    except urllib.error.URLError as exc:
        _fail(f"Could not reach the Lumisound bridge at {base_url} ({exc.reason}).")

    # A 2FA account gets {"requires_2fa": true, "pending_token": ...} with no
    # "token". The daemon itself cannot prompt for a code, which is why it
    # tells 2FA users to paste a token -- but an installer runs interactively,
    # so it can finish the challenge properly.
    if result.get("requires_2fa"):
        pending = result.get("pending_token")
        if not pending:
            _fail("The bridge asked for 2FA but returned no pending token.")
        code = input("Two-factor code (6 digits from your authenticator app): ").strip().replace(" ", "")
        if not code:
            _fail("No two-factor code entered.")
        try:
            # device_name is passed here too: /auth/2fa/login records the
            # session with whatever it is given, so omitting it would leave a
            # 2FA user's temporary session unlabeled in Account -> Sessions.
            result = _post(
                base_url, "/auth/2fa/login",
                {"pending_token": pending, "code": code, "device_name": SETUP_DEVICE_NAME},
            )
        except urllib.error.HTTPError as exc:
            _fail(_describe_http_error(exc))
        except urllib.error.URLError as exc:
            _fail(f"Could not reach the Lumisound bridge at {base_url} ({exc.reason}).")

    session_token = result.get("token")
    if not session_token:
        _fail("Login succeeded but the bridge returned no token.")

    # Exchange the session token for the long-lived scoped one, so the stored
    # credential is purpose-built for this daemon and separately revocable.
    print("Creating a Rich Presence token for this device...")
    try:
        rpc = _post(
            base_url, "/user/rpc-token",
            {"device_name": device_name()}, token=session_token,
        )
    except urllib.error.HTTPError as exc:
        _fail(f"Signed in, but could not create a Rich Presence token: {_describe_http_error(exc)}")
    except urllib.error.URLError as exc:
        _fail(f"Signed in, but could not reach the bridge to create a token ({exc.reason}).")

    token = rpc.get("token")
    if not token:
        _fail("The bridge returned no Rich Presence token.")
    expires = rpc.get("expires_at")
    print(f"Token created for {rpc.get('device_name', device_name())}"
          f"{f' (expires {expires})' if expires else ''}.")

    # The bridge reports what its housekeeping reclaimed; worth echoing so a
    # re-run visibly supersedes the old token rather than looking like it
    # silently added yet another session.
    cleaned = rpc.get("cleaned_up") or {}
    bits = [
        f"{cleaned.get('superseded', 0)} previous token(s) for this device",
        f"{cleaned.get('expired', 0)} expired",
        f"{cleaned.get('stale_setup', 0)} abandoned setup",
    ]
    if any(cleaned.get(k) for k in ("superseded", "expired", "stale_setup")):
        print("Revoked " + ", ".join(bits) + ".")

    # Retire the sign-in session now that the RPC token has replaced it.
    # /auth/logout deletes the session matching the bearer token's jti, so this
    # must be called with session_token, not the new one. Without it each run
    # left a second live session behind, so Account -> Sessions filled up with
    # one dead entry per setup. Best-effort: a failed logout leaves a stale
    # (but revocable, and distinctly labelled) session rather than failing a
    # setup that has otherwise completed.
    try:
        _post(base_url, "/auth/logout", {}, token=session_token)
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, ValueError):
        print("Note: could not close the temporary sign-in session; "
              "you can revoke \"" + SETUP_DEVICE_NAME + "\" from Account -> Sessions.")

    return token


def write_config(token: str, bridge_url: str | None) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    # Preserve any settings the user already tuned (poll interval, paused
    # behaviour, custom bridge) instead of flattening the file on re-run.
    config: dict = {}
    if CONFIG_FILE.exists():
        try:
            config = json.loads(CONFIG_FILE.read_text())
            if not isinstance(config, dict):
                config = {}
        except (OSError, ValueError):
            config = {}

    config["access_token"] = token
    config.setdefault("poll_interval_seconds", 5)
    if bridge_url:
        config["bridge_url"] = bridge_url
    # Credentials left by an older setup (or by the daemon's own
    # username/password fallback) are redundant once a token is stored, and a
    # password is strictly worse to keep than the token it was exchanged for.
    # Both are dropped; the token alone is what the daemon needs.
    had_password = config.pop("password", None) is not None
    config.pop("username", None)
    if had_password:
        print("Removed the password left in config.json by a previous setup.")

    # 0600 before writing, so the token is never briefly world-readable.
    fd = os.open(CONFIG_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.chmod(CONFIG_FILE, 0o600)
    print(f"Wrote {CONFIG_FILE}")


def main() -> None:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--bridge-url", default=None)
    ap.add_argument("--token", default=None)
    ap.add_argument("--identifier", default=None)
    args = ap.parse_args()

    base_url = args.bridge_url or DEFAULT_BRIDGE_URL
    token = args.token.strip() if args.token else interactive_login(base_url, args.identifier)
    write_config(token, args.bridge_url)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        sys.exit(130)
