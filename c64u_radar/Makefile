# C64U Radar public build
# Requires cc65/cl65 on PATH.

# Primary build: 6502 assembly (contributed by @buck5125). Smaller and lower
# per-frame overhead than the legacy cc65 C build; this is the .prg shipped
# as an asset on each GitHub release.
PRG  = c64u_radar.prg
MAP  = c64u_radar.map
SRC  = c64u_radar.asm ultimateii/ultimate_lib.c

# Legacy cc65 C build, retained as a reference implementation of the same
# design (the host_test/ harness compiles against it). Not part of `make all`;
# build explicitly with `make c64u_radar_c.prg`.
PRG_C = c64u_radar_c.prg
MAP_C = c64u_radar_c.map
SRC_C = c64u_radar.c ultimateii/ultimate_lib.c

# Both targets build with cc65's stock c64 config and stay under the fixed
# $5A00 VIC bank 1 ceiling (asm: $4E2A, C: $5803), so no custom linker config
# is required.

all: $(PRG)

$(PRG): $(SRC)
	cl65 -t c64 -O -Iultimateii --mapfile $(MAP) -o $@ $(SRC)
	@python3 check_map.py $(MAP)

$(PRG_C): $(SRC_C)
	cl65 -t c64 -O -Iultimateii --mapfile $(MAP_C) -o $@ $(SRC_C)
	@python3 check_map.py $(MAP_C)

clean:
	rm -f $(PRG) $(MAP) $(PRG_C) $(MAP_C) *.o ultimateii/*.o
