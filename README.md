# C64U Radar

**v0.1 — first public beta.** A live ADS-B air traffic scope for the
Commodore 64 Ultimate (C64U/Ultimate 64).

**v0.2 - range set via menu.** added new menu item to set range (3..99) multiples of 3

**v0.3 - track table enhancements.** climb/descent glyphs, ground tracks in grey, auto QNH

![C64U Radar scope screen](assets/v0.3asm radar.png)!

The C64 can't do HTTPS, JSON, or geodesic math, so a small companion program
does that on a Mac, Windows, Linux, or Raspberry Pi computer and streams a
compact binary feed to the C64U over the LAN:

```text
adsb.fi HTTPS API
        |
        v
Python server: fetch, cache, filter, sort, project, encode
        |
        | plain TCP port 6464, MR2 request + LD binary response
        v
C64 Ultimate: validate feed, draw bitmap scope/table, move 8 sprites
```

The server uses only the Python standard library — no API key, no
third-party package, no account.

## Features

- Hires bitmap scope, customisable nautical mile range 3..99nm range rings.
- Up to 8 simultaneous targets (VIC-II hardware sprite limit), shown as
  numbered diamonds with a directional stem for track/heading.
- Callsign, aircraft type, altitude, climb/descent indicator and groundspeed for each target.
- Center on any latitude/longitude, or a four-letter ICAO airport code
  (worldwide, via a cached OurAirports lookup).
- The server finds the C64U on the LAN and pushes its own address into a
  small mailbox in C64 memory over the C64 Ultimate's REST API — the server
  address usually just fills itself in, with manual entry (`C= + S`) as a
  fallback. See [`server/README.md`](server/README.md) for how this works.

## Quick start

1. On a computer on the same LAN as the C64U, run the server:
   - **macOS**: double-click `executables/server_bundle/start_server_mac.command`
     (first launch needs a right-click → Open, since the script isn't
     Apple-signed — see [`server/README.md`](server/README.md) for why).
   - **Windows**: run `executables/server_bundle/start_server_windows.bat`.
   - **Linux**: run `executables/server_bundle/start_server_mac_linux.sh`.
   - Or directly: `python3 executables/server_bundle/ultimate_radar_server.py`
     (Python 3.9+).
2. On the C64U: enable `Command Interface`, then run `executables/c64u_radar.prg`
   for the .c based version and /C64u_radar2.prg for the .6502 version. 
   Look under **Main Menu > MEMORY & ROMS** on the Commodore-branded C64
   Ultimate, or **Configure > C64 and Cartridge Settings** on other
   Ultimate 64 / 1541 Ultimate-II+ firmware. Menu location can vary by
   firmware version; if you don't see it in one place, check the other.
3. Pick a center (latitude/longitude or ICAO code). The server address should
   already be filled in; if not, press `C= + S` to enter it manually.

## Building from source

**C64 program** (needs [cc65](https://cc65.github.io/)):

```sh
cd c64u_radar
make clean all
```

Fails the build if the program/data exceeds the fixed `$5A00` sprite memory
block — this is checked automatically by `check_map.py`.

**Native logic harness** (no C64 emulator; compiles the real radar source
against a fake 64K RAM and a mocked Ultimate network API, using your system's
C compiler):

```sh
cd c64u_radar/host_test
cc -DHOST_TEST -I. -I.. -o harness harness.c
./harness
```

This is not a substitute for testing on real hardware, but it does catch
regressions in request generation, PETSCII handling, the server-address
mailbox, sprite drawing, and link-down behavior.

**Server tests**:

```sh
cd server
python3 -m unittest test_ultimate_radar_server.py
```

## Repository layout

```text
c64u_radar/          C64 program source (cc65), Makefile, native test harness
server/              Python server source and tests
executables/          Prebuilt PRG and a ready-to-run server bundle
assets/              Screenshots
```

## Protocol summary

The C64 opens one TCP connection to the server on port 6464 per poll cycle
(~10s), optionally sends an `MR2 POS <lat> <lon> <range>` or
`MR2 ICAO <code> <range>` request line, reads an 8-byte header plus up to
eight 28-byte aircraft records, then disconnects. See
[`server/README.md`](server/README.md) for the full wire format and the HTTP
debug endpoints (`/traffic.txt`, `/status.json`, etc.).

## Credits

- Traffic data: [adsb.fi](https://adsb.fi/).
- Airport coordinates: [OurAirports](https://ourairports.com/data/) (public domain).
- C64 Ultimate command interface: the `ultimateii` library in
  `c64u_radar/ultimateii/`, by Scott Hutter and Francesco Sblendorio
  ([1541ultimate2](https://github.com/markusC64/1541ultimate2)), GPL-3.

## License

GPL-3. See [`LICENSE`](LICENSE). The C64 program links the GPL-3 `ultimateii`
library directly, so the whole repository is distributed under those terms.
