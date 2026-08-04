# C64U Radar

## ASM Port Changelog (2026-07-31)

- Completed full behavioral parity port from `c64u_radar.c` to `64u_radar2.asm`.
- Optimized render path for lower per-frame overhead (direct bitmap/sprite/table updates).
- Reduced code size by removing C runtime overhead and unused high-level abstractions.
- Added robust range handling (`MR2 RNG`) and deterministic numeric formatting for menu/status text.
- Hardened arithmetic helpers for reliable decimal formatting (`CLD`-safe helpers where needed).
- Aligned menu text rendering with PETSCII case semantics so displayed case matches source strings.

## C Changelog (2026-07-24)

- v0.2 - Added menu item to adjust display range. Must be multipe of 3..99
- v0.3 - Added climb/descent glyphs, revealed ground tracks in grey, 'auto' QNH/QFE, frame rate

## Overview

C64 Ultimate ADS-B radar scope. This source tree contains no baked-in
coordinates or LAN address — the compiled server address starts at `0.0.0.0`
and the user always picks a real center on the C64.

The visible menu is:

```text
C64U RADAR V0.3 / V0.3asm
Choose an option to center your scope:
1. CENTER ON LAT/LONG
2. CENTER ON ICAO AIRPORT CODE
3. SET RANGE
```

The version string is on the main menu title only — the bitmap scope
screen's own title has no room for it (14-character column). Bump
`VERSION_STRING` in `c64u_radar.c` for future releases.

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

## Build cc65 and 6502 versions

see makefile..

Build with cc65 on `PATH`:

```sh
make clean all
```

Output: `c64u_radar.prg`. The build fails if program/data reaches the fixed
sprite block at `$5A00`.

Run the native harness from `host_test/` with:

```sh
cc -DHOST_TEST -I. -I.. -o harness harness.c
./harness
```

The companion Python server lives in this repo's `server/` folder.
