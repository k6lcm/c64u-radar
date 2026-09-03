# C64U Radar

## Changelog

The 6502 assembly build (`c64u_radar.asm`) is the shipping version and was
contributed by [@buck5125](https://github.com/buck5125).

- **v0.4.1 (2026-09-02)** — fixed `menu_putsxy`'s PETSCII→screen-code
  conversion: the "low-set letters" range check started at `$41` instead of
  `$40`, so `@` ($40) fell through unconverted and rendered as the wrong
  glyph. Broke the YouTube URL on the setup menu (`youtube.com/@levimaaia`).
- **v0.4asm (2026-08-22)** — main build switched to `c64u_radar.asm`
  (buck5125). Invalid ICAO / out-of-range location is caught in the setup
  menu (via a preflight fetch before video init) instead of drawing the
  scope and then overlaying a "BAD LOCATION" message. Sprites are cleared
  alongside the display-off during `init_video` to prevent stale-pointer
  artifacts.
- **v0.3asm (2026-07-31)** — full behavioral parity port from `c64u_radar.c`
  to `c64u_radar.asm` by buck5125. Optimized render path (direct bitmap/
  sprite/table updates), smaller code size (no C runtime), robust `MR2 RNG`
  handling, deterministic numeric formatting, `CLD`-safe helpers, PETSCII
  case alignment.
- **v0.3 (2026-07-24, cc65 C)** — climb/descent glyphs, ground tracks in
  grey, auto QNH/QFE, frame rate. Retained as the reference implementation.
- **v0.2 (cc65 C)** — menu item to adjust display range (multiples of 3, 3..99).

## Overview

C64 Ultimate ADS-B radar scope. This source tree contains no baked-in
coordinates or LAN address — the compiled server address starts at `0.0.0.0`
and the user always picks a real center on the C64.

The visible menu is:

```text
C64U RADAR V0.4.1
Choose an option to center your scope:
1. CENTER ON LAT/LONG
2. CENTER ON ICAO AIRPORT CODE
3. SET RANGE
```

The version string is on the main menu title only — the bitmap scope
screen's own title has no room for it (14-character column). Bump `str_title`
in `c64u_radar.asm` for future releases (and `VERSION_STRING` in
`c64u_radar.c` if you also rebuild the legacy C reference).

Users choose a latitude/longitude or four-letter ICAO airport center. There is
no numbered menu option for the server IP; the address normally fills itself
in. While the menu idles, the program watches a mailbox at `$CAC0` that the
Python server fills over the C64 Ultimate REST API (see
`../server/README.md`), and the menu shows one of three states:

- `SEARCHING FOR SERVER...` — no mailbox value adopted yet.
- `AUTO DISCOVERED SERVER AT:` — the server found and pushed its address.
- `USER ENTERED SERVER IP:` — the user overrode it manually (below).

Pressing Commodore+S (`C= + S`) opens manual IP entry. A manually entered
address is sticky for the rest of the run: it is mirrored into the mailbox,
but the program stops auto-adopting further server pushes until the next
relaunch/reset, so a background server on a different address can't silently
overwrite a deliberate manual choice. Either way — pushed or manually
entered — the address survives reset/relaunch, because the mailbox lives in
RAM outside the loaded program and is only lost on power-off.

Mailbox layout at `$CAC0` (23 bytes): `MR2M` magic, version 1, IP length,
16-byte IP text field, XOR checksum (seed `$A5`). The program only adopts a
mailbox IP whose checksum validates and which parses as dotted IPv4.

The Commodore+S hotkey is detected by scanning the KERNAL's own keyboard
decode tables at `$EB81` (unshifted) and `$EC03` (Commodore) at startup for
the physical S key, rather than hardcoding a PETSCII byte for the
Commodore-modified key. `POKE 657,128` disables the KERNAL's automatic
SHIFT+Commodore charset toggle, since Commodore is now an application hotkey
modifier and the program owns a fixed lowercase/uppercase charset choice.

## Build

Requires [cc65](https://cc65.github.io/) on `PATH` (cc65 ships `ca65`/`ld65`,
which the asm build uses via `cl65`).

```sh
make clean all
```

Output: `c64u_radar.prg`, built from `c64u_radar.asm`. The build fails if
program/data reaches the fixed sprite block at `$5A00`.

For a release, `make release` copies that output into `release/` under a
version-stamped name taken from `../server/VERSION`:

```text
c64u_radar.prg                     build output, always this name
release/c64u_radar_0_4_1.prg       the copy attached to the GitHub release
```

Keeping the stamped copy in its own directory means the build output and
the release artifact are never mistaken for each other. `release/` is
gitignored; the artifact is uploaded to the GitHub release, not committed.

The legacy cc65 C reference build is not part of `make all`. Build it
explicitly if you want to compare:

```sh
make c64u_radar_c.prg
```

Output: `c64u_radar_c.prg` (same design, larger, higher per-frame overhead).

Run the native harness (compiles the C reference against a fake 64K RAM and
a mocked Ultimate network API, using the system's C compiler — not a
substitute for hardware testing, but useful for logic regressions):

```sh
cd host_test
cc -DHOST_TEST -I. -I.. -o harness harness.c
./harness
```

The companion Python server lives in this repo's `server/` folder.
