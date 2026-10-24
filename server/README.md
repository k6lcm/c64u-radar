# C64 Ultimate Radar Server

A standalone, cross-platform traffic server for C64U Radar. It talks directly
to adsb.fi over HTTPS and converts the response to the compact binary feed
consumed by the C64U program.

## Requirements

- Python 3.9 or newer
- An internet connection
- The computer and C64U on the same LAN
- The C64U Command Interface enabled

There are no third-party Python packages.

## Start it

macOS: double-click `start_server_mac.command` in Finder. This is a plain
shell script, not a signed/notarized `.app`, so the first launch will show a
Gatekeeper prompt — right-click the file and choose **Open** (or System
Settings > Privacy & Security > **Open Anyway**) once. A `.command` script
gets a lighter prompt than an unsigned `.app` would, since Terminal (an
already-trusted, signed app) is what actually runs it.

Linux: run `start_server_mac_linux.sh`.

Windows: run `start_server_windows.bat`.

Or directly with Python 3.9+:

```text
python3 ultimate_radar_server.py      # macOS/Linux
py -3 ultimate_radar_server.py        # Windows
```

The server reports every LAN IPv4 address it can identify:

```text
Server address: 192.168.1.100:6464
Status page:    http://192.168.1.100:6464/
```

Allow incoming Python connections if the operating system firewall asks. The
C64U Radar menu normally fills in this address itself — see below — but you
can also enter it manually with `C= + S` on the C64 if needed.

## Automatic C64U server-address push

If the C64 Ultimate's web interface (REST API on port 80) is enabled, typing
the IP is usually unnecessary. The server locates Ultimates on the LAN — a
threaded port-80 sweep of each local /24, identified with `GET /v1/version` —
and checks C64 memory at `$8AC0` through `machine:readmem` for the radar's
`MR2M` mailbox magic. The magic exists only while the radar PRG is running;
without it the server never writes to the machine. When the magic is present
and the mailbox does not already hold the server's address, the server writes
its LAN IP and a checksum into the mailbox with `machine:writemem`. The radar
menu polls the mailbox and updates its `SERVER:` line within a second or two.

Configuration keys and flags:

- `ultimate_discovery` (default `true`) or `--no-ultimate` to disable.
- `ultimate_hosts`, or repeatable `--ultimate-host 192.168.4.64`, to name the
  C64U directly and skip the LAN sweep.
- `ultimate_interval_seconds` (default 10) between mailbox checks.

Found machines and push times appear in `/status.json` under `ultimates`.

## Configuration

Edit `ultimate_radar_server.json` to set the fallback center, range, and port.
Command line values override the file. The C64U Radar PRG always requires an
ICAO code or latitude/longitude before opening the scope, so this fallback is
only used by the legacy requestless wire format described below.

```text
python3 ultimate_radar_server.py --lat 51.470748 --lon -0.459909 --range 9
```

Use `--help` for all command-line options.

## Check it from a browser

- `/` — addresses and basic status
- `/traffic.txt` — human-readable aircraft table
- `/traffic` — exact C64 binary response
- `/status.json` — server, cache, and upstream status

For example:

```text
http://192.168.1.100:6464/traffic.txt
```

The server warms and refreshes the default cache in the background. This lets
the current C64U program receive a response promptly even when adsb.fi is slow.
If an upstream request briefly fails, the last successful data remains visible
without an immediate warning. The wire-format stale flag is set only after the
cached data reaches `stale_after_seconds` (30 seconds by default).

## C64 request protocol

C64U Radar always sends an explicit center once the user picks a lat/long or
ICAO code. A requestless legacy client (or any other TCP client that connects
and sends nothing) receives the configured fallback center instead:

```text
MR2 POS 51.470748 -0.459909 9
MR2 ICAO EGLL 9
```

`POS` can use any valid latitude and longitude. `ICAO` currently resolves codes
from a cached copy of the public-domain OurAirports dataset. The server refreshes
that cache every 30 days; entries under `airports` in the JSON file remain local
overrides and work even if the database download is temporarily unavailable.
An unrecognized code now returns `BAD LOCATION` on the C64 instead of silently
showing traffic from the default center.

The database is worldwide, not US-only. The server tries both the OurAirports
GitHub Pages download and GitHub's raw-file host, with a 60-second download
allowance. A successful startup reports thousands of available airports. If it
reports `ICAO WARNING` and only a few fallback airports, check the following
download error or local firewall/proxy settings. Locally configured entries
remain available as fallbacks.

Airport coordinates: <https://ourairports.com/data/> (public domain).

HTTP debugging can request another center as well:

```text
/traffic.txt?lat=51.470748&lon=-0.459909&range=9
/traffic.txt?icao=EGLL&range=9
```

## Loading traffic as a PRG over HTTP

Clients that can `LOAD` a URL, such as NES 64 with its Wi-Fi adapter, can
fetch the same traffic as a C64 program file:

```text
LOAD"HTTP://192.168.1.100:6464/KSFO.PRG",10,1
LOAD"HTTP://192.168.1.100:6464/KSFO-25.PRG",10,1
```

The path is the ICAO code, upper or lower case, with an optional `-` and a
range in nm (1 to 100, the configured default otherwise). The file is a
2-byte load address, `$A000`, then the wire blob below padded with zeros to
232 bytes, so every reply is 234 bytes long. An unknown code or a bad range
still returns a 234-byte file, with the location error flag set. HTTP
`Range` and `HEAD` requests are answered.

## Wire compatibility

Responses use the existing version-1 radar format:

- 8-byte `LD` header
- Zero to eight 28-byte aircraft records
- Maximum response size of 232 bytes
- Nearest aircraft first
- Truncated and stale flags preserved
