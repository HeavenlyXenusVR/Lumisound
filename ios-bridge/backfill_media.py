#!/usr/bin/env python3
"""Backfill artwork and tempo for cloud-library tracks, including locked ones.

Both columns were effectively unpopulated for anything backed up as a locked
(`.lms`) file, and for the same underlying reason: the server could not read
inside the lock, so artwork had to arrive as a separate upload from the phone and
`bpm` could only ever be filled in by on-device analysis on the iPhone. A library
filled from tvOS or from cloud backup therefore had artwork for some tracks and
tempo for essentially none — which is what left Smart Playlists with nothing to
build from.

`locked_media` removes that limitation. This walks a user's library and fills in
what is missing.

Safety: stored files are opened read-only and never rewritten. Extraction works
from a temporary unmasked copy which is deleted immediately — see
`locked_media.readable_copy` for why that is preferred over unmasking in place
and re-masking afterwards.

Usage:
    python3 backfill_media.py --user <id> [--artwork] [--bpm] [--limit N] [--apply]

Dry-run unless --apply is passed.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import locked_media  # noqa: E402

try:
    import psycopg2
except ImportError:
    print("psycopg2 required", file=sys.stderr)
    raise


def artwork_cache_path(music_dir: pathlib.Path, metadata_id: str) -> pathlib.Path:
    """Mirrors main.py's `_locked_artwork_path` — keyed by metadata id, not path,
    so a thumbnail survives the track being renamed or re-foldered."""
    safe = "".join(c for c in metadata_id if c.isalnum())
    return music_dir / ".artwork" / f"{safe}.jpg"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", required=True)
    ap.add_argument("--root", default="/mnt/fastssd/lumisound-user-music")
    ap.add_argument("--dsn", default="dbname=discord_music_gws user=postgres")
    ap.add_argument("--artwork", action="store_true")
    ap.add_argument("--bpm", action="store_true")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    if not args.artwork and not args.bpm:
        args.artwork = args.bpm = True

    music_dir = pathlib.Path(args.root) / args.user
    if not music_dir.is_dir():
        print(f"no such library: {music_dir}", file=sys.stderr)
        return 1

    conn = psycopg2.connect(args.dsn)
    cur = conn.cursor()
    cur.execute(
        "SELECT id, COALESCE(relative_path, filename), has_artwork, bpm "
        "FROM ios_user_music_metadata WHERE user_id = %s ORDER BY filename",
        (args.user,),
    )
    rows = cur.fetchall()
    print(f"library rows: {len(rows)}")

    todo = []
    for mid, rel, has_art, bpm in rows:
        need_art = args.artwork and not artwork_cache_path(music_dir, mid).exists()
        need_bpm = args.bpm and (bpm is None or bpm <= 0)
        if need_art or need_bpm:
            todo.append((mid, rel, need_art, need_bpm))
    if args.limit:
        todo = todo[: args.limit]

    print(f"tracks needing work: {len(todo)}"
          f"  (artwork {sum(1 for t in todo if t[2])}, bpm {sum(1 for t in todo if t[3])})")
    if not args.apply:
        print("\nDRY RUN — pass --apply to write\n")

    art_ok = art_none = bpm_ok = bpm_none = missing = 0
    art_sources: dict[str, int] = {}
    started = time.time()

    for i, (mid, rel, need_art, need_bpm) in enumerate(todo, 1):
        path = music_dir / rel
        if not path.exists():
            missing += 1
            continue

        note = []
        if need_art:
            data, source = locked_media.extract_artwork(path)
            if data:
                art_ok += 1
                art_sources[source] = art_sources.get(source, 0) + 1
                note.append(f"art:{source}")
                if args.apply:
                    dest = artwork_cache_path(music_dir, mid)
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(data)
                    cur.execute(
                        "UPDATE ios_user_music_metadata SET has_artwork = TRUE "
                        "WHERE user_id = %s AND id = %s", (args.user, mid))
            else:
                art_none += 1
                note.append("art:none")
                # A row claiming artwork the server cannot produce 404s on every
                # single view; clearing it turns a repeating error into a clean
                # placeholder.
                if args.apply:
                    cur.execute(
                        "UPDATE ios_user_music_metadata SET has_artwork = FALSE "
                        "WHERE user_id = %s AND id = %s", (args.user, mid))

        if need_bpm:
            value = locked_media.estimate_bpm(path)
            if value:
                bpm_ok += 1
                note.append(f"bpm:{value}")
                if args.apply:
                    cur.execute(
                        "UPDATE ios_user_music_metadata SET bpm = %s "
                        "WHERE user_id = %s AND id = %s", (value, args.user, mid))
            else:
                bpm_none += 1
                note.append("bpm:-")

        if args.apply and i % 25 == 0:
            conn.commit()
        if i % 10 == 0 or i == len(todo):
            rate = i / max(0.001, time.time() - started)
            print(f"[{i}/{len(todo)}] {rate:.1f}/s  {path.name[:44]:44s} {' '.join(note)}",
                  flush=True)

    if args.apply:
        conn.commit()
    cur.close()
    conn.close()

    elapsed = time.time() - started
    print(f"\nprocessed {len(todo)} in {elapsed:.0f}s")
    print(f"  artwork found:   {art_ok}   {art_sources}")
    print(f"  artwork absent:  {art_none}")
    print(f"  bpm estimated:   {bpm_ok}")
    print(f"  bpm indecisive:  {bpm_none}")
    print(f"  file missing:    {missing}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
