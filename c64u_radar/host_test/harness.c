/* Builds c64u_radar.c natively against fake RAM + a mocked UCI, drives
 * one init + fetch cycle with a real captured feed blob, and dumps the
 * bitmap, sprite block and VIC registers for render_preview.py.
 *
 *   cc -DHOST_TEST -I. -I.. -o harness harness.c   (from host_test/)
 */
#include <stdio.h>
#include <stdlib.h>

#include "../c64u_radar.c"

/* ---- fake RAM + registers ---- */
void host_poke(unsigned addr, unsigned char v) { host_ram[addr & 0xFFFF] = v; }
unsigned char host_peek(unsigned addr)         { return host_ram[addr & 0xFFFF]; }

/* ---- fake jiffies ---- */
static long jiffies = 0;
clock_t host_clock(void) { return (clock_t)jiffies++; }

/* ---- mocked UCI serving the captured blob ---- */
char uii_status[256];
char uii_data[1794];
static unsigned char feed[512];
static int feed_len = 0, feed_pos = 0, first_read = 1;
static char sent_request[FEED_REQ_SZ];

static int sprite_pixel(unsigned char slot, unsigned char x, unsigned char y)
{
    unsigned int off = SPR_DATA + (unsigned int)slot * 64
                     + (unsigned int)y * 3 + (x >> 3);
    return (host_ram[off] & (0x80 >> (x & 7))) != 0;
}

static unsigned long sprite_hash(unsigned char slot)
{
    unsigned int i;
    unsigned long h = 2166136261UL;
    for (i = 0; i < 64; ++i) {
        h ^= host_ram[SPR_DATA + (unsigned int)slot * 64 + i];
        h *= 16777619UL;
    }
    return h;
}

unsigned char uii_tcpconnect(char* host, unsigned short port)
{
    (void)host; (void)port;
    uii_status[0] = '0'; uii_status[1] = '0';
    feed_pos = 0; first_read = 1;
    sent_request[0] = 0;
    return 1;
}

void uii_socketwrite(unsigned char socketid, char* data)
{
    (void)socketid;
    strncpy(sent_request, data, sizeof(sent_request) - 1);
    sent_request[sizeof(sent_request) - 1] = 0;
    uii_status[0] = '0'; uii_status[1] = '0';
}

int uii_socketread(unsigned char socketid, unsigned short length)
{
    int n;
    (void)socketid;
    if (first_read) { first_read = 0; return -1; }     /* "nothing yet"   */
    n = feed_len - feed_pos;
    if (n <= 0) return 0;                              /* remote closed   */
    if (n > 100) n = 100;                              /* force chunking  */
    if (n > (int)length) n = length;
    memcpy(uii_data + 2, feed + feed_pos, n);
    feed_pos += n;
    return n;
}

void uii_socketclose(unsigned char socketid) { (void)socketid; }
void uii_abort(void) { }        /* UCI timeout guard: no-op on the host */

/* ---- mailbox helper: emulate the server's REST writemem push ---- */
static void push_mailbox(const char* ip)
{
    unsigned char i, len = (unsigned char)strlen(ip);
    unsigned char sum = 0xA5 ^ len;
    host_ram[MAILBOX_ADDR + 5] = len;
    for (i = 0; i < 16; ++i)
        host_ram[MAILBOX_ADDR + 6 + i] = i < len ? (unsigned char)ip[i] : 0;
    for (i = 0; i < len; ++i) sum ^= (unsigned char)ip[i];
    host_ram[MAILBOX_ADDR + 22] = sum;
}

/* ---- host copy_charset: load the real 901225-01 ROM, uppercase set ---- */
static void copy_charset(void)
{
    unsigned char p, y;
    FILE* f = fopen("../chargen.bin", "rb");
    if (!f) {
        memset(charset, 0, 2048);
        for (p = 0; p < 8; ++p) {
            for (y = 0; y < 5; ++y)
                charset[((unsigned int)('1' + p) << 3) + 1 + y]
                    = (unsigned char)(digit_rows[p][y] << 3);
        }
        fprintf(stderr, "chargen.bin missing; using synthetic digit glyphs\n");
        return;
    }
    if (fread(charset, 1, 2048, f) != 2048) {
        fprintf(stderr, "chargen.bin truncated\n"); exit(1);
    }
    fclose(f);
}

int main(void)
{
    unsigned char st, i, d, other, k, px, py;
    unsigned int stem_pixels;
    int mdx, mdy;
    unsigned char* cell;
    unsigned char* glyph;
    unsigned long digit_hash[8];
    FILE* f = fopen("../preview_blob.bin", "rb");
    if (!f) { fprintf(stderr, "preview_blob.bin missing\n"); return 1; }
    feed_len = (int)fread(feed, 1, sizeof(feed), f);
    fclose(f);

    /* Plant a synthetic KERNAL keyboard decode table before init_config()
       runs its find_commodore_key(0x53) lookup, mirroring the real ROM's
       $EB81 (unshifted) / $EC03 (commodore) layout at a made-up index.     */
    host_ram[0xEB81 + 20] = 0x53;          /* unshifted 'S' key            */
    host_ram[0xEC03 + 20] = 0xB3;          /* its Commodore-key byte       */
    init_config();
    if (find_commodore_key(0x53) != 0xB3) {
        fprintf(stderr, "commodore-key keytab scan failed\n"); return 1;
    }
    if (find_commodore_key(0xFF) != 0) {
        fprintf(stderr, "commodore-key scan should miss an absent key\n"); return 1;
    }
    if (key_to_petscii(0x4B) != 0xCB || key_to_petscii(0x53) != 0xD3 ||
        key_to_petscii(0x42) != 0xC2 || key_to_petscii(0x41) != 0xC1 ||
        asc2sc((char)0xC1) != 1 || asc2sc((char)0xDA) != 26) {
        fprintf(stderr, "PETSCII keyboard normalization failed\n"); return 1;
    }
    if (!set_feed_host("10.20.30.40") || set_feed_host("256.1.1.1") ||
        set_feed_host("192.168.1") || set_feed_host("1.2.3.4.5")) {
        fprintf(stderr, "server IP validation failed\n"); return 1;
    }
    /* init_config must plant a fresh mailbox: magic + FEED_HOST + checksum */
    if (host_ram[MAILBOX_ADDR] != 0x4D || host_ram[MAILBOX_ADDR + 1] != 0x52 ||
        host_ram[MAILBOX_ADDR + 2] != 0x32 || host_ram[MAILBOX_ADDR + 3] != 0x4D ||
        host_ram[MAILBOX_ADDR + 4] != 1 ||
        host_ram[MAILBOX_ADDR + 5] != strlen(FEED_HOST) ||
        memcmp(host_ram + MAILBOX_ADDR + 6, FEED_HOST, strlen(FEED_HOST))) {
        fprintf(stderr, "mailbox was not planted at startup\n"); return 1;
    }
    /* server push adopts a valid, different IP */
    push_mailbox("192.168.4.99");
    if (!mailbox_poll() || strcmp(feed_host, "192.168.4.99")) {
        fprintf(stderr, "mailbox push was not adopted\n"); return 1;
    }
    if (server_source != SERVER_AUTO) {
        fprintf(stderr, "adopted push did not mark SERVER_AUTO\n"); return 1;
    }
    if (mailbox_poll()) {                 /* unchanged value: no re-adopt   */
        fprintf(stderr, "mailbox re-adopted an unchanged IP\n"); return 1;
    }
    /* torn write: checksum mismatch must be ignored */
    push_mailbox("192.168.4.50");
    host_ram[MAILBOX_ADDR + 22] ^= 0xFF;
    if (mailbox_poll() || strcmp(feed_host, "192.168.4.99")) {
        fprintf(stderr, "corrupt mailbox was adopted\n"); return 1;
    }
    /* checksum-valid junk that is not a dotted quad must be rejected */
    push_mailbox("999.1.1.1");
    if (mailbox_poll() || strcmp(feed_host, "192.168.4.99")) {
        fprintf(stderr, "non-IP mailbox content was adopted\n"); return 1;
    }
    /* manual entry mirrors into the mailbox and locks out further auto-adopt,
       matching what setup_location() does on a successful C=+S entry.      */
    if (!set_feed_host("10.20.30.40")) return 1;
    server_source = SERVER_MANUAL;
    mailbox_store(feed_host);
    if (host_ram[MAILBOX_ADDR + 5] != 11 ||
        memcmp(host_ram + MAILBOX_ADDR + 6, "10.20.30.40", 11)) {
        fprintf(stderr, "manual IP was not mirrored to the mailbox\n"); return 1;
    }
    push_mailbox("192.168.4.55");             /* a server push arrives...  */
    if (mailbox_poll() || strcmp(feed_host, "10.20.30.40")) {
        fprintf(stderr, "manual server entry was overridden by a push\n"); return 1;
    }
    /* reset survival: a real relaunch zeroes .bss (server_source included)
       before running init_config again; simulate that here.               */
    server_source = SERVER_UNSET;
    push_mailbox("192.168.4.99");
    init_config();
    if (strcmp(feed_host, "192.168.4.99") || server_source != SERVER_AUTO) {
        fprintf(stderr, "mailbox IP did not survive simulated reset\n"); return 1;
    }
    if (!set_feed_host("10.20.30.40")) return 1;
    if (!set_position_request("39.117210", "-94.635600")) {
        fprintf(stderr, "initial public position rejected\n"); return 1;
    }
    copy_charset();
    init_video();
    init_sprites();
    draw_static_scope();
    show_status(ST_WAIT);
    st = fetch();
    show_status(st);

    printf("fetch status=%u (0=OK)  count=%u total=%u age=%u flags=%02x\n",
           st, blob[4], blob[5], blob[6], blob[3]);
    if (st != ST_OK) return 1;
    if (strcmp(sent_request, "mr2 pos 39.117210 -94.635600 15\n")) {
        fprintf(stderr, "public position request mismatch: %s\n", sent_request); return 1;
    }
    feed[3] |= 0x04;
    if (fetch() != ST_LOCATION) {
        fprintf(stderr, "location-error wire flag was ignored\n"); return 1;
    }
    show_status(ST_LOCATION);
    if (host_ram[MATRIX + 21 * 40 + TBL_COL] != COL_RED_BLACK) {
        fprintf(stderr, "bad-location status was not red\n"); return 1;
    }
    feed[3] &= (unsigned char)~0x04;
    if (fetch() != ST_OK) return 1;
    show_status(ST_OK);

    if (!set_position_request("40.6413", "-73.7781")) {
        fprintf(stderr, "valid position rejected\n"); return 1;
    }
    if (strcmp(scope_label1, "40.6413") || strcmp(scope_label2, "-73.7781")) {
        fprintf(stderr, "position labels mismatch\n"); return 1;
    }
    if (fetch() != ST_OK || strcmp(sent_request, "mr2 pos 40.6413 -73.7781 15\n")) {
        fprintf(stderr, "position request mismatch: %s\n", sent_request); return 1;
    }
    if (!set_icao_request("KJFK")) {
        fprintf(stderr, "valid ICAO rejected\n"); return 1;
    }
    if (strcmp(scope_label1, "KJFK") || scope_label2[0]) {
        fprintf(stderr, "ICAO label mismatch\n"); return 1;
    }
    if (fetch() != ST_OK || strcmp(sent_request, "mr2 icao KJFK 15\n")) {
        fprintf(stderr, "ICAO request mismatch: %s\n", sent_request); return 1;
    }
    if (set_position_request("90.1", "0") ||
        set_position_request("0", "-180.01") ||
        set_position_request("999999999999999", "0") ||
        set_position_request("N34", "-119") ||
        set_icao_request("JFK")) {
        fprintf(stderr, "invalid location accepted\n"); return 1;
    }
    /* Every displayed list number must be the reverse of its digit glyph. */
    for (i = 0; i < blob[4]; ++i) {
        cell = host_ram + BITMAP + bmp_row_offset((unsigned char)(4 + (i << 1))) + (TBL_COL << 3);
        glyph = charset + ((unsigned int)('1' + i) << 3);
        for (k = 0; k < 8; ++k) {
            if (cell[k] != (unsigned char)~glyph[k]) {
                fprintf(stderr, "bad reverse table number %u row %u\n", i + 1, k);
                return 1;
            }
        }
    }

    f = fopen("bitmap.bin", "wb");
    fwrite(host_ram + BITMAP, 1, 8000, f); fclose(f);
    f = fopen("sprblock.bin", "wb");
    fwrite(host_ram + SPR_DATA, 1, 512, f); fclose(f);
    f = fopen("sprites.txt", "w");
    fprintf(f, "%u\n", host_ram[0xD015]);
    for (i = 0; i < 8; ++i)
        fprintf(f, "%u %u %u\n", host_ram[0xD000 + (i << 1)],
                host_ram[0xD001 + (i << 1)], host_ram[0xD027 + i] & 15);
    fclose(f);
    for (i = 0; i < 8; ++i) {
        if (host_ram[MATRIX + 0x3F8 + i] != SPR_PTRVAL + i) {
            fprintf(stderr, "bad sprite pointer %u\n", i); return 1;
        }
        if (host_ram[SPR_DATA + (unsigned int)i * 64 + 63] != 0) {
            fprintf(stderr, "bad sprite pad byte %u\n", i); return 1;
        }
    }
    /* Exercise every number and all eight exact compass sectors. */
    for (i = 0; i < 8; ++i) {
        build_sprite(i, 0, 1);
        digit_hash[i] = sprite_hash(i);
        for (other = 0; other < i; ++other) {
            if (digit_hash[i] == digit_hash[other]) {
                fprintf(stderr, "duplicate digit patterns %u/%u\n", other + 1, i + 1);
                return 1;
            }
        }
        for (d = 0; d < 8; ++d) {
            build_sprite(i, (unsigned char)(d << 5), 0);
            if (!sprite_pixel(i, dir_x[d], dir_y[d])) {
                fprintf(stderr, "missing direction endpoint digit=%u dir=%u\n", i + 1, d);
                return 1;
            }
            stem_pixels = 0;
            for (py = 0; py < 21; ++py) {
                for (px = 0; px < 24; ++px) {
                    mdx = px > 11 ? px - 11 : 11 - px;
                    mdy = py > 10 ? py - 10 : 10 - py;
                    if (mdx + mdy > 5 && sprite_pixel(i, px, py))
                        ++stem_pixels;
                }
            }
            if (stem_pixels != 5) {
                fprintf(stderr, "nonuniform stem digit=%u dir=%u pixels=%u\n",
                        i + 1, d, stem_pixels);
                return 1;
            }
        }
        build_sprite(i, 91, 1);
        stem_pixels = 0;
        for (py = 0; py < 21; ++py) {
            for (px = 0; px < 24; ++px) {
                mdx = px > 11 ? px - 11 : 11 - px;
                mdy = py > 10 ? py - 10 : 10 - py;
                if (mdx + mdy > 5 && sprite_pixel(i, px, py))
                    ++stem_pixels;
            }
        }
        if (stem_pixels != 0) {
            fprintf(stderr, "unknown track drew %u outside pixels for digit=%u\n",
                    stem_pixels, i + 1);
            return 1;
        }
        for (d = 0; d < 8; ++d) {
            if (sprite_pixel(i, dir_x[d], dir_y[d])) {
                fprintf(stderr, "unknown track drew arrow digit=%u dir=%u\n", i + 1, d);
                return 1;
            }
        }
    }
    for (i = 0; i < 8; ++i)
        build_sprite(i, (unsigned char)(i << 5), 0);
    f = fopen("sprite_sheet.bin", "wb");
    fwrite(host_ram + SPR_DATA, 1, 512, f); fclose(f);

    show_link_down();
    if (host_ram[0xD015] || !link_down_displayed ||
        host_ram[MATRIX + 12 * 40 + 6] != COL_RED_BLACK ||
        host_ram[BITMAP + bmp_row_offset(12) + (6 << 3)] != 0xFF) {
        fprintf(stderr, "link-down banner/clearing failed\n"); return 1;
    }

    puts("verified public POS and ICAO location request modes");
    puts("verified $8AC0 mailbox plant/push/adopt, torn-write and junk rejection, reset survival");
    puts("verified commodore-key keytab scan and manual-entry push lockout");
    puts("verified location headers and reverse-red link-down clearing");
    puts("verified bad-location wire flag and red status");
    puts("verified 8 pointers, 8 unique digits, 64 uniform five-pixel stems, and unknown track");
    puts("dumped bitmap.bin sprblock.bin sprites.txt sprite_sheet.bin");
    return 0;
}
