# C64U Radar public build
# Requires cc65/cl65 on PATH.

PRG  = c64u_radar.prg
MAP  = c64u_radar.map
SRC  = c64u_radar.c ultimateii/ultimate_lib.c

PRG2 = 64u_radar2.prg
MAP2 = 64u_radar2.map
SRC2 = 64u_radar2.asm ultimateii/ultimate_lib.c

all: $(PRG) $(PRG2)

$(PRG): $(SRC)
	cl65 -t c64 -O -Iultimateii -C cfg/c64u_radar_safe.cfg --mapfile $(MAP) -o $@ $(SRC)
	@python3 check_map.py $(MAP)

$(PRG2): $(SRC2)
	cl65 -t c64 -O -Iultimateii -C cfg/c64u_radar_safe.cfg --mapfile $(MAP2) -o $@ $(SRC2)
	@python3 check_map.py $(MAP2)

clean:
	rm -f $(PRG) $(MAP) $(PRG2) $(MAP2) *.o ultimateii/*.o
