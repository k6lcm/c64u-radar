# C64U Radar public build
# Requires cc65/cl65 on PATH.

PRG  = c64u_radar.prg
MAP  = c64u_radar.map
SRC  = c64u_radar.c ultimateii/ultimate_lib.c

PRG2 = c64u_radar2.prg
MAP2 = c64u_radar2.map
SRC2 = c64u_radar2.asm ultimateii/ultimate_lib.c

# Both targets build with cc65's stock c64 config and stay under the fixed
# $5A00 VIC bank 1 ceiling (C: $5803, asm: $4E2A), so no custom linker config
# is required. A custom cfg to relocate ultimate_lib.c's 2KB uii_status/
# uii_data queues out of low RAM is worthwhile future work for headroom, but
# needs a correctly sized UII_BSS area, a matching #pragma bss-name in
# ultimate_lib.c, and a placement that does not run into I/O space at $D000.

all: $(PRG) $(PRG2)

$(PRG): $(SRC)
	cl65 -t c64 -O -Iultimateii --mapfile $(MAP) -o $@ $(SRC)
	@python3 check_map.py $(MAP)

$(PRG2): $(SRC2)
	cl65 -t c64 -O -Iultimateii --mapfile $(MAP2) -o $@ $(SRC2)
	@python3 check_map.py $(MAP2)

clean:
	rm -f $(PRG) $(MAP) $(PRG2) $(MAP2) *.o ultimateii/*.o
