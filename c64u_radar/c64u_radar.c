/* ==========================================================================
 * C64U RADAR -- public ADS-B scope for the Commodore 64 Ultimate
 *
 * Companion to the standalone C64 Ultimate Radar Python server. The server
 * TLS, JSON, trig and projection; this program opens one TCP socket per
 * poll through the Ultimate Command Interface network target, reads a
 * <=232-byte fixed-width blob, and moves sprites.
 *
 *   feed:   connect FEED_HOST:6464, optionally send MR2 location request,
 *           then read until remote close
 *   blob:   8-byte header "LD",ver,flags,count,total,age,0
 *           + count * 28-byte records (see ldv_c64_feed.py docstring)
 *   text fields arrive as C64 screen codes -- blitted straight to bitmap
 *
 * Display: hires bitmap 320x200, VIC bank 1
 *   $5A00-$5BFF eight independent 64-byte sprite patterns
 *   $5C00 screen matrix (color cells, $D0 = light green on black)
 *   $6000 bitmap
 *   sprite pointers $68-$6F at $5FF8
 *   scope = left 200x200 px, center (100,100), 15nm ring r=95
 *   table = char columns 26..39
 *
 * NOTE: VIC banks 0 and 2 hard-wire the character generator ROM into the
 * VIC's view of memory at bank-offset $1000-$1FFF (this is independent of
 * the CPU's $01 register and cannot be disabled). Bitmap/screen data placed
 * in that window is invisible to the VIC -- it always shows chargen ROM
 * there instead. Bank 1 ($4000-$7FFF) and bank 3 ($C000-$FFFF) have no such
 * shadow, so graphics must stay in one of those two banks.
 *
 * Build:  make            (cl65 -t c64, vendored ultimateii-dos-lib, GPL-3)
 * Run:    select the PRG in the Ultimate file browser and run it
 * Needs:  "Command Interface" enabled in the Ultimate menu, and the C64U
 *         on the same LAN as the server computer. The startup menu can
 *         replace the initial FEED_HOST value without rebuilding.
 *
 * Known v1 limits: no sweep animation, no dead reckoning between polls
 * (track/gs bytes are already in the record for it), blips are all one
 * color until the feed starts banding altitudes.
 * ========================================================================== */

#include <string.h>
#include <stdio.h>
#include <time.h>
#include <peekpoke.h>
#ifndef HOST_TEST
#include <conio.h>
#include <c64.h>
#include <cbm.h>
#endif
#include "ultimate_lib.h"

/* ---- configuration ------------------------------------------------------ */
#define FEED_HOST   "0.0.0.0"         /* public build requires menu setup   */
#define FEED_PORT   6464
#define POLL_JIF    300               /* 5 s between polls (jiffies)        */
#define REPLY_JIF   1200              /* 20 s: first new location may fetch */
#define VERSION_STRING "V0.3"         /* main menu only; scope title has no
                                          room for it (14-char column)      */

/* ---- video map ----------------------------------------------------------- */
#define MATRIX      0x5C00
#define BITMAP      0x6000
#define SPR_DATA    0x5A00
#define SPR_PTRVAL  0x68              /* ($5A00-$4000)/64                   */
#define COL_GREEN_BLACK 0xD0
#define COL_GREY_BLACK  0xF0
#define COL_RED_BLACK   0x20
#define SPR_GREEN   13
#define SPR_GREY    15

/* Two spare character-code slots in the software charset buffer (see
 * `charset` below) are repurposed as a climb/descend indicator: the ROM
 * uppercase/graphics set is loaded into all 256 8-byte slots, but codes
 * $7E/$7F ('~'/DEL) never appear in any string this program draws, so
 * overwriting them with custom glyphs cannot collide with real text. This
 * costs zero extra memory -- charset is a fixed 2KB buffer regardless of
 * how many of its 256 slots hold custom vs. ROM glyphs.                    */
#define SC_DOWN_ARROW 0x7E
#define SC_UP_ARROW   0x7F

#define SCOPE_C     100               /* scope center px                    */
#define RING_PX     95                /* max range ring                     */
#define DEFAULT_SCOPE_RANGE_NM 15
#define TBL_COL     26                /* table starts at char column 26    */
#define TBL_W       14

#define MAGIC0      0x4C              /* 'L' */
#define MAGIC1      0x44              /* 'D' */
#define REC_SZ      28
#define MAX_AC      8
#define FEED_REQ_SZ 48
#define BLOB_SZ     (8 + MAX_AC * REC_SZ)

/* link states */
enum { ST_OK, ST_STALE, ST_DOWN, ST_BAD, ST_WAIT, ST_LOCATION, ST_EXIT };

/* main-menu server-address label: where the current feed_host came from */
enum { SERVER_UNSET, SERVER_AUTO, SERVER_MANUAL };

/* Host-test hook: build with -DHOST_TEST (see host_test/) to compile the
 * drawing/parsing logic natively against a fake 64K RAM and render a
 * pixel-true preview PNG. The C64 build is the #else path, unchanged.   */
#ifdef HOST_TEST
unsigned char host_ram[65536];
#  define MEM(a) (host_ram + (a))
#else
#  define MEM(a) ((unsigned char*)(unsigned int)(a))
#endif

static unsigned char* const bmp = MEM(BITMAP);
static unsigned char* const mtx = MEM(MATRIX);

/* Upper RAM workspace, placed in $C000-$CFFF: this 4KB window is always
 * plain RAM on a stock C64 regardless of the CPU port ($01) banking state
 * (only $A000-$BFFF, $D000-$DFFF and $E000-$FFFF are bankable), so no BASIC
 * ROM switching is required. Keeping these buffers out of the loaded
 * program leaves the fixed $5A00 sprite block untouched as menu/network
 * features grow.                                                          */
static unsigned char* const charset = MEM(0xC000);
static const unsigned char bmask[8] =
    { 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 };

static unsigned char* const blob = MEM(0xC900);
/* Small scalar runtime state, kept in this fixed $C000-$CFFF window instead
 * of the compiler's own BSS segment: BSS shares its address range with the
 * transient ONCE segment (constructor tables, dead after startup) and the
 * space available to it is capped by __STACKSIZE__ in
 * cfg/c64u_radar_safe.cfg -- BSS grows up from __ONCE_RUN__, the runtime
 * stack grows down from __HIMEM__, and the two must not meet. A real-
 * hardware crash was traced to exactly that collision: adding the small
 * climb/descend status-bit RODATA table nudged __ONCE_RUN__ up by a few
 * bytes, and __STACKSIZE__ had already been trimmed to the bare minimum
 * the linker's BSS-area formula would accept, leaving only a handful of
 * bytes of real margin between the stack and these variables. Moving them
 * here removes that pressure entirely -- they no longer compete with the
 * stack margin no matter how much RODATA/CODE this program grows to.      */
#define STATE_ADDR 0xCA90              /* free gap before MAILBOX_ADDR ($CAC0) */
#define sock                (*(unsigned char*)MEM(STATE_ADDR))
#define link_down_displayed (*(unsigned char*)MEM(STATE_ADDR + 1))
#define server_source       (*(unsigned char*)MEM(STATE_ADDR + 2))
#define cs_hotkey           (*(unsigned char*)MEM(STATE_ADDR + 3))
#define location_mode       (*(unsigned char*)MEM(STATE_ADDR + 4))
static char* const feed_request = (char*)MEM(0xCA00);
static char* const feed_host = (char*)MEM(0xCA30);
static char* const scope_label1 = (char*)MEM(0xCA40);
static char* const scope_label2 = (char*)MEM(0xCA50);
static unsigned char scope_range_nm = DEFAULT_SCOPE_RANGE_NM;

/* Server-address mailbox shared with the radar Python server through the
 * Ultimate REST API (machine:readmem / machine:writemem). The server only
 * writes offsets +5..+22 and only after verifying the magic, so it can never
 * touch a machine that is not running this program. The block also survives
 * reset/relaunch, which restores the last IP without the server.
 *   +0..3 magic "MR2M" (ASCII bytes, kept numeric: cc65 letter literals are
 *   PETSCII)  +4 version  +5 ip length  +6..21 ip text  +22 checksum        */
#define MAILBOX_ADDR 0xCAC0
static unsigned char* const mailbox = MEM(MAILBOX_ADDR);
/* server_source (SERVER_UNSET/AUTO/MANUAL) and cs_hotkey (raw byte for
 * Commodore+S, or 0) are defined above with sock/link_down_displayed.     */

/* The currently active custom location (if any), kept across repeated
 * visits to setup_location() so that changing ONLY the range (menu option
 * 3) rebuilds the exact same request with the new range instead of
 * silently reverting to the server's default center. feed_request embeds
 * the range as part of the wire text the server filters by, so a local-
 * only scope_range_nm change is not enough -- the whole request has to be
 * regenerated. Stored at full entered precision (unlike scope_label1/2,
 * which are truncated to 14 characters for on-screen display only).
 * LOC_DEFAULT means no custom location has been chosen yet; feed_request
 * stays empty and the server falls back to its own configured default
 * center -- there is no wire command for "default center, custom range",
 * so a range-only change before ever picking a location only affects the
 * local ring labels.                                                      */
enum { LOC_DEFAULT, LOC_POSITION, LOC_ICAO };
/* location_mode is defined above with sock/link_down_displayed.           */
#define LOC_TEXT_ADDR 0xCA60          /* free gap before MAILBOX_ADDR ($CAC0) */
static char* const saved_latitude  = (char*)MEM(LOC_TEXT_ADDR);       /* 17B */
static char* const saved_longitude = (char*)MEM(LOC_TEXT_ADDR + 17);  /* 17B */
static char* const saved_icao      = (char*)MEM(LOC_TEXT_ADDR + 34);  /*  5B */

static unsigned char set_feed_host(const char* text);
static unsigned char find_commodore_key(unsigned char unshifted_code);

/* Right-justified, space-padded unsigned decimal, minimum field width
 * `width` (0 = no padding) -- a tiny stand-in for sprintf's "%Nu". All
 * call sites in this file only ever format values 0..255, so a 3-digit
 * buffer is enough. Replacing every sprintf() call with this plus plain
 * strcpy() lets the linker drop the entire cc65 sprintf/vfprintf runtime
 * (format-string parser, conversion tables, etc.) which was by far the
 * largest remaining consumer of the budget below the fixed $5A00 VIC
 * bank 1 ceiling -- far more than any further string trimming could
 * recover. Returns a pointer to just past the digits written. */
static char* put_udec(char* dst, unsigned int value, unsigned char width)
{
    char digits[3];
    unsigned char n = 0;
    do {
        digits[n++] = (char)('0' + value % 10);
        value /= 10;
    } while (value && n < 3);
    while (width > n) { *dst++ = ' '; --width; }
    while (n) *dst++ = digits[--n];
    return dst;
}

static unsigned char set_scope_range_from_text(const char* text)
{
    unsigned int value = 0;
    unsigned char digits = 0;
    const char* p = text;
    while (*p >= '0' && *p <= '9') {
        if (++digits > 3) return 0;
        value = value * 10 + (unsigned int)(*p++ - '0');
    }
    if (!digits || *p) return 0;
    if (value < 3 || value > 99) return 0;
    if ((value % 3) != 0) return 0;
    scope_range_nm = (unsigned char)value;
    return 1;
}

static unsigned char mailbox_checksum(void)
{
    unsigned char sum = 0xA5, i, len = mailbox[5];
    sum ^= len;
    for (i = 0; i < len && i < 15; ++i) sum ^= mailbox[6 + i];
    return sum;
}

static unsigned char mailbox_magic_ok(void)
{
    return mailbox[0] == 0x4D && mailbox[1] == 0x52 &&
           mailbox[2] == 0x32 && mailbox[3] == 0x4D && mailbox[4] == 1;
}

/* Mirror the active server IP so the server sees the radar running and the
 * address survives reset.                                                   */
static void mailbox_store(const char* ip)
{
    unsigned char i, len = (unsigned char)strlen(ip);
    mailbox[0] = 0x4D; mailbox[1] = 0x52;
    mailbox[2] = 0x32; mailbox[3] = 0x4D;
    mailbox[4] = 1;
    mailbox[5] = len;
    for (i = 0; i < 16; ++i)
        mailbox[6 + i] = i < len ? (unsigned char)ip[i] : 0;
    mailbox[22] = mailbox_checksum();
}

/* Adopt a valid mailbox IP that differs from the active one. Returns 1 when
 * feed_host changed. Torn server writes fail the checksum and are skipped.
 * A manually entered address is sticky for the rest of this run: the server
 * would otherwise re-push its own address over the user's deliberate choice
 * every poll cycle.                                                        */
static unsigned char mailbox_poll(void)
{
    char ip[16];
    unsigned char i, len = mailbox[5];
    if (server_source == SERVER_MANUAL) return 0;
    if (!mailbox_magic_ok()) return 0;
    if (len < 7 || len > 15) return 0;
    if (mailbox[22] != mailbox_checksum()) return 0;
    for (i = 0; i < len; ++i) ip[i] = (char)mailbox[6 + i];
    ip[len] = 0;
    if (!strcmp(ip, feed_host)) return 0;
    if (!set_feed_host(ip)) return 0;
    server_source = SERVER_AUTO;
    return 1;
}

static void init_config(void)
{
    server_source = location_mode = SERVER_UNSET;
    strcpy(feed_host, FEED_HOST);
    feed_request[0] = 0;
    scope_label1[0] = 0;
    scope_label2[0] = 0;
    /* A mailbox that survived reset restores the last server IP (mailbox_poll
       sets server_source = SERVER_AUTO on success); otherwise plant a fresh
       mailbox so the server knows the radar is running.                    */
    if (!mailbox_poll())
        mailbox_store(feed_host);
    /* 0x53 is the numeric low-PETSCII code the KERNAL reports for the
       unshifted S key -- NOT the char literal 'S', which cc65 compiles to
       high PETSCII for on-screen display and would never match here. */
    cs_hotkey = find_commodore_key(0x53);
    POKE(0x0291, 128);   /* disable the SHIFT+Commodore charset toggle:    */
                         /* C=+S is now an app hotkey, not a display switch */
}

/* ==========================================================================
 * startup location request
 * ========================================================================== */


/* Validate a decimal coordinate without linking the C64 floating-point
 * library. Values at the exact pole/date-line limit may only have zeroes
 * after the decimal point.                                                  */
static unsigned char valid_coordinate(const char* text, unsigned int limit)
{
    unsigned int whole = 0;
    unsigned char digits = 0, frac_digits = 0, frac_nonzero = 0;
    const char* p = text;
    if (*p == '+' || *p == '-') ++p;
    while (*p >= '0' && *p <= '9') {
        if (digits == 3) return 0;
        whole = whole * 10 + (unsigned int)(*p - '0');
        ++digits; ++p;
    }
    if (!digits) return 0;
    if (*p == '.') {
        ++p;
        while (*p >= '0' && *p <= '9') {
            if (*p != '0') frac_nonzero = 1;
            ++frac_digits; ++p;
        }
        if (!frac_digits) return 0;
    }
    if (*p) return 0;
    return whole < limit || (whole == limit && !frac_nonzero);
}

static unsigned char set_position_request(const char* latitude,
                                          const char* longitude)
{
    char* d;
    if (!valid_coordinate(latitude, 90) || !valid_coordinate(longitude, 180))
        return 0;
    if (strlen(latitude) + strlen(longitude) + 13 > FEED_REQ_SZ)
        return 0;
    /* Lowercase source letters compile to the ASCII-compatible PETSCII
       bytes required by the network protocol. */
    d = feed_request;
    strcpy(d, "mr2 pos "); d += 8;
    strcpy(d, latitude); d += strlen(latitude);
    *d++ = ' ';
    strcpy(d, longitude); d += strlen(longitude);
    *d++ = ' ';
    d = put_udec(d, (unsigned int)scope_range_nm, 0);
    *d++ = '\n'; *d = 0;
    strncpy(scope_label1, latitude, 14); scope_label1[14] = 0;
    strncpy(scope_label2, longitude, 14); scope_label2[14] = 0;
    return 1;
}

static unsigned char set_icao_request(const char* code)
{
    unsigned char i;
    char* d;
    if (strlen(code) != 4) return 0;
    for (i = 0; i < 4; ++i)
        if (code[i] < 'A' || code[i] > 'Z') return 0;
    d = feed_request;
    strcpy(d, "mr2 icao "); d += 9;
    *d++ = (char)(code[0] & 0x7F);
    *d++ = (char)(code[1] & 0x7F);
    *d++ = (char)(code[2] & 0x7F);
    *d++ = (char)(code[3] & 0x7F);
    *d++ = ' ';
    d = put_udec(d, (unsigned int)scope_range_nm, 0);
    *d++ = '\n'; *d = 0;
    strcpy(scope_label1, code);
    scope_label2[0] = 0;
    return 1;
}

/* Regenerate feed_request (and scope_label1/2) for the currently active
 * location using the *current* scope_range_nm, without requiring the user
 * to re-enter the position/ICAO code. Called after a range-only change
 * (menu option 3) so a previously chosen custom location survives. The
 * saved text was already validated once by set_position_request()/
 * set_icao_request(), and range never affects that validation, so this
 * cannot fail. */
static void rebuild_location_request(void)
{
    switch (location_mode) {
        case LOC_POSITION:
            set_position_request(saved_latitude, saved_longitude);
            break;
        case LOC_ICAO:
            set_icao_request(saved_icao);
            break;
        default:
            break;
    }
}

static unsigned char set_feed_host(const char* text)
{
    unsigned char groups = 0, digits = 0;
    unsigned int value = 0;
    const char* p = text;
    for (;;) {
        if (*p >= '0' && *p <= '9') {
            if (++digits > 3) return 0;
            value = value * 10 + (unsigned int)(*p++ - '0');
            if (value > 255) return 0;
        } else if (*p == '.' || !*p) {
            if (!digits || ++groups > 4) return 0;
            if (!*p) break;
            digits = 0; value = 0; ++p;
        } else return 0;
    }
    if (groups != 4 || strlen(text) > 15) return 0;
    strcpy(feed_host, text);
    return 1;
}

static unsigned char key_to_petscii(unsigned char c)
{
    /* KERNAL keyboard input uses low PETSCII for unshifted letters, while
       cc65 uppercase C literals use high PETSCII. Normalize to the latter. */
    if (c >= 0x41 && c <= 0x5A) c |= 0x80;
    else if (c >= 0x61 && c <= 0x7A)
        c = (unsigned char)((c - 0x20) | 0x80);
    return c;
}

/* KERNAL ROM is banked in at $E000-$FFFF by default (this program never
 * hides it, unlike the brief CHAREN toggle in copy_charset()), so its fixed
 * keyboard decode tables can be read directly instead of guessing a byte
 * value for a modified key. Locate the physical key whose *unshifted* code
 * is `unshifted_code` in the $EB81 table, then return the same key's entry
 * in the $EC03 Commodore-key table. This works across KERNAL ROM revisions.
 * The lookup is a plain PEEK scan, so it also runs correctly against the
 * harness's fake RAM when a test plants matching bytes there.               */
#define KEYTAB_UNSHIFT   0xEB81
#define KEYTAB_COMMODORE 0xEC03
#define KEYTAB_KEYS      64
static unsigned char find_commodore_key(unsigned char unshifted_code)
{
    unsigned char i;
    for (i = 0; i < KEYTAB_KEYS; ++i)
        if (PEEK(KEYTAB_UNSHIFT + i) == unshifted_code)
            return PEEK(KEYTAB_COMMODORE + i);
    return 0;
}

#ifndef HOST_TEST
/* The menu uses the lowercase/uppercase character set. cc65's high-PETSCII
 * uppercase and low-PETSCII lowercase literals therefore display directly. */
static void menu_putsxy(unsigned char x, unsigned char y, const char* text)
{
    unsigned char c;
    gotoxy(x, y);
    while (*text) {
        c = (unsigned char)*text++;
        cputc((char)c);
    }
}

static unsigned char read_input(char* result, unsigned char maximum)
{
    unsigned char length = 0, c;
    unsigned char start_x = wherex(), start_y = wherey();
    cursor(1);
    for (;;) {
        c = (unsigned char)cgetc();
        if (c == CH_ENTER) break;
        if (c == CH_DEL || c == 8) {
            if (length) {
                --length;
                gotoxy((unsigned char)(start_x + length), start_y);
                cputc(' ');
                gotoxy((unsigned char)(start_x + length), start_y);
            }
            continue;
        }
        c = key_to_petscii(c);
        if (((c >= 0x20 && c <= 0x7E) || (c >= 0xC1 && c <= 0xDA))
                && length < maximum) {
            result[length++] = (char)c;
            cputc((char)c);
        }
    }
    cursor(0);
    result[length] = 0;
    return length;
}

/* Draw whichever of the three server-address states currently applies.
 * Label and value sit on separate rows because "AUTO DISCOVERED SERVER AT:"
 * plus a worst-case 15-character IP would overflow the 40-column screen and
 * wrap onto the next line if crammed onto one.                             */
static void draw_server_status(void)
{
    switch (server_source) {
        case SERVER_MANUAL:
            menu_putsxy(4, 12, "USER SERVER IP:");
            menu_putsxy(4, 13, feed_host);
            break;
        case SERVER_AUTO:
            menu_putsxy(4, 12, "Auto-discovered server:");
            menu_putsxy(4, 13, feed_host);
            break;
        default:
            menu_putsxy(4, 12, "SEARCHING FOR SERVER..");
            break;
    }
}

static void setup_location(void)
{
    char latitude[17], longitude[17], icao[5], address[16], range_text[4];
    char range_line[19];
    unsigned char choice, raw;
    textcolor(COLOR_LIGHTGREEN);
    bgcolor(COLOR_BLACK);
    bordercolor(COLOR_BLACK);

    for (;;) {
        clrscr();
        menu_putsxy(13, 2, "C64U RADAR " VERSION_STRING);
        menu_putsxy(1, 4, "Choose an option to center your scope:");
        menu_putsxy(4, 6, "1. CENTER ON LAT/LONG");
        menu_putsxy(4, 8, "2. CENTER ON ICAO AIRPORT CODE");
        {
            char* d = range_line;
            strcpy(d, "3. RANGE: "); d += 10;
            d = put_udec(d, (unsigned int)scope_range_nm, 2);
            strcpy(d, " NM");
        }
        menu_putsxy(4, 10, range_line);
        draw_server_status();
        menu_putsxy(4, 15, "C= + S CHANGES SERVER ADDRESS");
        menu_putsxy(6, 20, "Data: adsb.fi");
        menu_putsxy(13, 23, "levimaaia.com");
        menu_putsxy(9, 24, "youtube.com/@levimaaia");
        /* Wait for a key while watching the mailbox: the server pushes its
           IP through the Ultimate REST API while this menu idles. The raw
           byte is checked against the Commodore+S hotkey before any PETSCII
           normalization, since normalizing could shift it into a different
           code and hide the match.                                         */
        raw = 0;
        for (;;) {
            if (kbhit()) { raw = (unsigned char)cgetc(); break; }
            if (mailbox_poll()) break;    /* redraw with the new server line */
        }
        if (!raw) continue;

        if (cs_hotkey && raw == cs_hotkey) {
            clrscr();
            menu_putsxy(6, 4, "ENTER SERVER IP ADDRESS");
            menu_putsxy(4, 8, "IP: ");
            read_input(address, 15);
            if (set_feed_host(address)) {
                server_source = SERVER_MANUAL;
                mailbox_store(feed_host);
            } else {
                menu_putsxy(8, 12, "INVALID IP ADDRESS");
                menu_putsxy(8, 14, "PRESS A KEY");
                cgetc();
            }
            continue;
        }

        choice = key_to_petscii(raw);
        if (choice == '1' || choice == 'P') {
            clrscr();
            menu_putsxy(7, 1, "ENTER LAT / LONG");
            menu_putsxy(5, 3, "FORMAT: SIGNED DECIMAL DEGREES");
            menu_putsxy(5, 4, "LATITUDE:  -90 TO 90");
            menu_putsxy(5, 5, "LONGITUDE: -180 TO 180");
            menu_putsxy(6, 6, "EX: 39.117210  -94.635600");
            menu_putsxy(3, 9, "LATITUDE : ");
            read_input(latitude, 15);
            menu_putsxy(3, 12, "LONGITUDE: ");
            read_input(longitude, 16);
            if (set_position_request(latitude, longitude)) {
                strcpy(saved_latitude, latitude);
                strcpy(saved_longitude, longitude);
                location_mode = LOC_POSITION;
                return;
            }
            menu_putsxy(3, 16, "INVALID POSITION");
            menu_putsxy(3, 18, "PRESS A KEY TO RETRY");
            cgetc();
            continue;
        }
        if (choice == '2' || choice == 'I') {
            clrscr();
            menu_putsxy(7, 4, "ENTER ICAO CODE");
            menu_putsxy(12, 8, "CODE: ");
            read_input(icao, 4);
            if (set_icao_request(icao)) {
                strcpy(saved_icao, icao);
                location_mode = LOC_ICAO;
                return;
            }
            menu_putsxy(8, 12, "INVALID ICAO CODE");
            menu_putsxy(8, 14, "PRESS A KEY");
            cgetc();
            continue;
        }
        if (choice == '3') {
            clrscr();
            menu_putsxy(8, 4, "SET RANGE (NM)");
            menu_putsxy(3, 7, "MULTIPLE OF 3, 3..99");
            {
                char* d = range_line;
                strcpy(d, "CURRENT: "); d += 9;
                d = put_udec(d, (unsigned int)scope_range_nm, 2);
                *d = 0;
            }
            menu_putsxy(10, 9, range_line);
            menu_putsxy(9, 12, "RANGE: ");
            read_input(range_text, 3);
            if (set_scope_range_from_text(range_text)) {
                rebuild_location_request();
                return;
            }
            menu_putsxy(6, 16, "INVALID RANGE VALUE");
            menu_putsxy(6, 18, "PRESS A KEY");
            cgetc();
            continue;
        }
    }
}
#endif

/* 3x5 digit masks for 1..8. The bits are cut out of a solid diamond.      */
static const unsigned char digit_rows[8][5] = {
    { 2, 6, 2, 2, 7 },
    { 7, 1, 7, 4, 7 },
    { 7, 1, 7, 1, 7 },
    { 5, 5, 7, 1, 1 },
    { 7, 4, 7, 1, 7 },
    { 7, 4, 7, 5, 7 },
    { 7, 1, 2, 2, 2 },
    { 7, 5, 7, 5, 7 }
};

/* Stem endpoints for N, NE, E, SE, S, SW, W, NW. Each direction exposes
 * five pixels beyond the radius-five diamond.                              */
static const unsigned char dir_x[8] = { 11, 18, 21, 18, 11, 4, 1, 4 };
static const unsigned char dir_y[8] = {  0,  3, 10, 17, 20,17,10, 3 };

/* Climb/descend indicator glyphs patched into the software charset at
 * SC_DOWN_ARROW/SC_UP_ARROW (see copy_charset). $7E/$7F are consecutive
 * codes, so their 8-byte patterns are one contiguous 16-byte block --
 * a single memcpy covers both.                                            */
static const unsigned char arrow_glyphs[16] =
    { 0x00, 0x00, 0x7F, 0x3E, 0x1C, 0x08, 0x00, 0x00,   /* down, $7E */
      0x00, 0x00, 0x08, 0x1C, 0x3E, 0x7F, 0x00, 0x00 }; /* up,   $7F */

static unsigned int bmp_row_offset(unsigned char row)
{
    return ((unsigned int)row << 8) + ((unsigned int)row << 6);
}

/* ==========================================================================
 * low-level drawing
 * ========================================================================== */

static void plot(int x, int y)
{
    if ((unsigned)x > 199 || (unsigned)y > 199) return;
    bmp[bmp_row_offset((unsigned char)(y >> 3)) + (y & 7) + (x & 0xF8)] |= bmask[x & 7];
}

static void hline(int x0, int x1, int y)
{
    int x;
    for (x = x0; x <= x1; ++x) plot(x, y);
}

static void vline(int y0, int y1, int x)
{
    int y;
    for (y = y0; y <= y1; ++y) plot(x, y);
}


/* Sprite-local drawing. A pattern is 3 bytes x 21 rows plus byte 63.      */
static void spr_plot(unsigned char* p, unsigned char x, unsigned char y)
{
    if (x < 24 && y < 21)
        p[(unsigned int)y * 3 + (x >> 3)] |= bmask[x & 7];
}

static void spr_unplot(unsigned char* p, unsigned char x, unsigned char y)
{
    if (x < 24 && y < 21)
        p[(unsigned int)y * 3 + (x >> 3)] &= (unsigned char)~bmask[x & 7];
}

static void spr_line(unsigned char* p, int x0, int y0, int x1, int y1)
{
    int dx = x1 > x0 ? x1 - x0 : x0 - x1;
    int dy = y1 > y0 ? y1 - y0 : y0 - y1;
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = dx - dy, e2;
    for (;;) {
        spr_plot(p, (unsigned char)x0, (unsigned char)y0);
        if (x0 == x1 && y0 == y1) break;
        e2 = err << 1;
        if (e2 > -dy) { err -= dy; x0 += sx; }
        if (e2 <  dx) { err += dx; y0 += sy; }
    }
}

/* Build one numbered marker. Track-byte sectors are 32 units (45 degrees),
 * rounded to the nearest of the eight compass directions.                 */
static void build_sprite(unsigned char slot, unsigned char track,
                         unsigned char track_unknown)
{
    unsigned char* p = MEM(SPR_DATA + (unsigned int)slot * 64);
    unsigned char sector, x, y, half, row;
    memset(p, 0, 64);

    if (!track_unknown) {
        sector = (unsigned char)((((unsigned int)track + 16) >> 5) & 7);
        spr_line(p, 11, 10, dir_x[sector], dir_y[sector]);
    }

    /* Solid radius-five diamond centered at the target position. */
    for (y = 5; y <= 15; ++y) {
        half = (unsigned char)(5 - (y > 10 ? y - 10 : 10 - y));
        for (x = (unsigned char)(11 - half); x <= (unsigned char)(11 + half); ++x)
            spr_plot(p, x, y);
    }

    /* Cut the target number out in black for CRT-readable contrast. */
    for (y = 0; y < 5; ++y) {
        row = digit_rows[slot][y];
        for (x = 0; x < 3; ++x)
            if (row & (4 >> x))
                spr_unplot(p, (unsigned char)(10 + x), (unsigned char)(8 + y));
    }
}

static void circle(int cx, int cy, int r)
{
    int x = r, y = 0, err = 1 - r;
    while (x >= y) {
        plot(cx + x, cy + y); plot(cx - x, cy + y);
        plot(cx + x, cy - y); plot(cx - x, cy - y);
        plot(cx + y, cy + x); plot(cx - y, cy + x);
        plot(cx + y, cy - x); plot(cx - y, cy - x);
        ++y;
        if (err < 0) err += (y << 1) + 1;
        else { --x; err += ((y - x) << 1) + 1; }
    }
}

/* blit screen-code glyphs into the bitmap at char cell (col,row)           */
static void draw_sc(unsigned char col, unsigned char row,
                    const unsigned char* sc, unsigned char len)
{
    unsigned char i, k;
    unsigned char* dst = bmp + bmp_row_offset(row) + (col << 3);
    const unsigned char* g;
    for (i = 0; i < len; ++i) {
        g = charset + ((unsigned int)sc[i] << 3);
        for (k = 0; k < 8; ++k) dst[k] = g[k];
        dst += 8;
    }
}

/* One reverse-video screen-code cell in bitmap mode: green field, black
 * glyph. There is no VIC reverse flag in hires bitmap mode.                */
static void draw_sc_reverse(unsigned char col, unsigned char row,
                            unsigned char sc)
{
    unsigned char k;
    unsigned char* dst = bmp + bmp_row_offset(row) + (col << 3);
    const unsigned char* g = charset + ((unsigned int)sc << 3);
    for (k = 0; k < 8; ++k) dst[k] = (unsigned char)~g[k];
}

static unsigned char asc2sc(char c)
{
    unsigned char o = (unsigned char)c;
    if (o >= 0xC1 && o <= 0xDA) return o & 0x1F;
    if (o >= 0x41 && o <= 0x5A) return o - 0x40;
    if (o >= 0x61 && o <= 0x7A) return o - 0x60;
    if (o >= 0x20 && o <= 0x3F) return o;
    return 46;                                    /* '.' */
}

/* draw PETSCII/ASCII text, space-padded to `width` screen-code cells       */
static void draw_ascii(unsigned char col, unsigned char row,
                       const char* s, unsigned char width)
{
    unsigned char buf[40];
    unsigned char i = 0;
    while (*s && i < width) buf[i++] = asc2sc(*s++);
    while (i < width) buf[i++] = 0x20;
    draw_sc(col, row, buf, width);
}

static void draw_centered(unsigned char col, unsigned char row,
                          const char* s, unsigned char width)
{
    char buf[15];
    unsigned char n = (unsigned char)strlen(s), left;
    if (n > width) n = width;
    left = (unsigned char)((width - n) >> 1);
    memset(buf, ' ', width);
    memcpy(buf + left, s, n);
    buf[width] = 0;
    draw_ascii(col, row, buf, width);
}

static void draw_reverse_ascii(unsigned char col, unsigned char row,
                               const char* s, unsigned char width)
{
    unsigned char i;
    memset(mtx + (unsigned int)row * 40 + col, COL_RED_BLACK, width);
    for (i = 0; i < width; ++i)
        draw_sc_reverse((unsigned char)(col + i), row,
                        asc2sc(s[i] ? s[i] : ' '));
}

/* ==========================================================================
 * display setup
 * ========================================================================== */

#ifndef HOST_TEST   /* host harness loads the chargen ROM file instead */
static void copy_charset(void)
{
    unsigned char p;
    __asm__("sei");
    p = PEEK(0x0001);
    POKE(0x0001, p & 0xFB);                       /* char ROM in at $D000  */
    memcpy(charset, (void*)0xD000, 2048);         /* uppercase/gfx set     */
    POKE(0x0001, p);
    __asm__("cli");
    memcpy(charset + (SC_DOWN_ARROW * 8), arrow_glyphs, 16);
}
#endif

static void init_video(void)
{
    POKE(0xD011, 0x0B);                           /* display off during mode switch */
    POKE(0xDD02, PEEK(0xDD02) | 0x03);            /* CIA2 PA0/PA1 outputs  */
    POKE(0xDD00, (PEEK(0xDD00) & 0xFC) | 0x02);   /* VIC bank 1 ($4000)    */
    POKE(0xD018, 0x78);                           /* matrix $5C00, bmp $6000 */
    memset(bmp, 0, 8000);
    memset(mtx, COL_GREEN_BLACK, 1000);
    POKE(0xD011, 0x3B);                           /* hires bitmap on       */
    POKE(0xD016, 0xC8);
    POKE(0xD020, 0); POKE(0xD021, 0);
}

static void init_sprites(void)
{
    unsigned char i;
    memset(MEM(SPR_DATA), 0, 512);
    for (i = 0; i < 8; ++i) {
        build_sprite(i, 0, 1);
        POKE(MATRIX + 0x3F8 + i, SPR_PTRVAL + i);
        POKE(0xD027 + i, SPR_GREEN);
    }
    POKE(0xD015, 0);                              /* all off until data    */
    POKE(0xD010, 0); POKE(0xD017, 0); POKE(0xD01D, 0);
    POKE(0xD01B, 0); POKE(0xD01C, 0);
}

static void draw_static_scope(void)
{
    char ring_label[3];

    /* bezel + rings (3/6/9 nm) + center cross */
    hline(0, 199, 0);  hline(0, 199, 199);
    vline(0, 199, 0);  vline(0, 199, 199);
    circle(SCOPE_C, SCOPE_C, 32);
    circle(SCOPE_C, SCOPE_C, 63);
    circle(SCOPE_C, SCOPE_C, RING_PX);
    hline(98, 102, 100); vline(98, 102, 100);

    /* ring labels just right of 12 o'clock, like the panel */
    *put_udec(ring_label, (unsigned int)(scope_range_nm / 3), 2) = 0;
    draw_ascii(12, 8, ring_label, 2);
    *put_udec(ring_label, (unsigned int)((scope_range_nm * 2) / 3), 2) = 0;
    draw_ascii(12, 4, ring_label, 2);
    *put_udec(ring_label, (unsigned int)scope_range_nm, 2) = 0;
    draw_ascii(12, 0, ring_label, 2);

    /* right column chrome */
    draw_centered(TBL_COL, 0, "C64U RADAR", TBL_W);
    memset(bmp + bmp_row_offset(1) + (TBL_COL << 3), 0, TBL_W * 8);
    {
        unsigned char bar[TBL_W];
        memset(bar, 0x40, TBL_W);                 /* horizontal line char  */
        draw_sc(TBL_COL, 1, bar, TBL_W);
        draw_sc(TBL_COL, 20, bar, TBL_W);
    }
    draw_ascii(TBL_COL, 23, "MAIN MENU: F1", TBL_W);
}

/* ==========================================================================
 * table + sprites from a parsed blob
 * ========================================================================== */

static void show_status(unsigned char st)
{
    static const char* const txt[] =
        { "LINK OK", "LINK STALE", "LINK DOWN", "BAD DATA", "CONNECTING",
          "BAD LOCATION" };
    memset(mtx + 21 * 40 + TBL_COL,
           (st == ST_STALE || st == ST_DOWN || st == ST_BAD || st == ST_LOCATION)
               ? COL_RED_BLACK : COL_GREEN_BLACK,
           TBL_W);
    draw_ascii(TBL_COL, 21, txt[st], TBL_W);
}

static void show_link_down(void)
{
    unsigned char row;
    POKE(0xD015, 0);
    for (row = 2; row <= 19; ++row)
        draw_ascii(TBL_COL, row, "", TBL_W);
    draw_ascii(TBL_COL, 21, "", TBL_W);
    draw_ascii(TBL_COL, 22, "", TBL_W);
    draw_reverse_ascii(6, 12, "  LINK DOWN  ", 13);
    link_down_displayed = 1;
}

static void render_targets(void)
{
    unsigned char count = blob[4];
    unsigned char total = blob[5];
    unsigned char age   = blob[6];
    unsigned char i, x, y;
    unsigned char row_color;
    const unsigned char* r;
    unsigned char lineA[TBL_W], lineB[TBL_W];
    char tmp[16];

    if (count > MAX_AC) count = MAX_AC;

    draw_centered(TBL_COL, 2, scope_label1, TBL_W);
    draw_centered(TBL_COL, 3, scope_label2, TBL_W);
    if (blob[3] & 0x01) {
        char* d = tmp;
        strcpy(d, "AGE "); d += 4;
        d = put_udec(d, age, 3);
        strcpy(d, " RNG "); d += 5;
        d = put_udec(d, total, 3);
        *d = 0;
    } else {
        char* d = tmp;
        strcpy(d, "IN "); d += 3;
        d = put_udec(d, (unsigned int)scope_range_nm, 2);
        strcpy(d, "NM "); d += 3;
        d = put_udec(d, total, 3);
        *d = 0;
    }
    draw_ascii(TBL_COL, 22, tmp, TBL_W);

    /* Keep the previous frame visible while positions/patterns are updated. */
    for (i = 0; i < count; ++i) {
        r = blob + 8 + (unsigned int)i * REC_SZ;
        x = r[0]; y = r[1];
        {
            /* status bit 0x01 = alt unknown/None = aircraft is on ground   */
            unsigned char grounded = r[3] & 0x01;
            build_sprite(i, r[4], r[3] & 0x04);
            POKE(0xD027 + i, grounded ? SPR_GREY : SPR_GREEN);
        }
        POKE(0xD000 + (i << 1), 24 + x - 11);     /* center local 11,10    */
        POKE(0xD001 + (i << 1), 50 + y - 10);
    }
    POKE(0xD015, count ? (unsigned char)((1 << count) - 1) : 0);

    /* table rows: two per target */
    for (i = 0; i < MAX_AC; ++i) {
        memset(lineA, 0x20, TBL_W);
        memset(lineB, 0x20, TBL_W);
        row_color = COL_GREEN_BLACK;
        if (i < count) {
            r = blob + 8 + (unsigned int)i * REC_SZ;
            if (r[3] & 0x01) row_color = COL_GREY_BLACK;
            lineA[0] = (unsigned char)('1' + i);  /* sprite/list number    */
            memcpy(lineA + 1,  r + 6, 8);         /* callsign              */
            memcpy(lineA + 10, r + 14, 4);        /* type, col 9 is space  */
            memcpy(lineB + 1,  r + 18, 5);        /* alt                   */
            memcpy(lineB + 7,  r + 23, 4);        /* gs                    */
            lineB[11] = 0x0B;                     /* K                     */
            lineB[12] = 0x14;                     /* T                     */
            /* status bits 0x08/0x10 = climbing/descending (see server's
             * pack_record, which sets at most one of the two); neither set
             * means level, on ground, or the rate is unknown -- leave the
             * trailing column blank. Masked into one local byte and
             * compared by equality (rather than two independent bitwise
             * branches) so only the exact expected bit patterns match.    */
            {
                unsigned char vstatus = (unsigned char)(r[3] & 0x18);
                if (vstatus == 0x08) lineB[6] = SC_UP_ARROW;
                else if (vstatus == 0x10) lineB[6] = SC_DOWN_ARROW;
            }
        } else if (i == 0) {
            memset(mtx + 4 * 40 + TBL_COL, COL_GREEN_BLACK, TBL_W);
            memset(mtx + 5 * 40 + TBL_COL, COL_GREEN_BLACK, TBL_W);
            draw_ascii(TBL_COL, 4, "NO TRAFFIC", TBL_W);
            draw_sc(TBL_COL, 5, lineB, TBL_W);
            continue;
        }
        memset(mtx + (unsigned int)(4 + (i << 1)) * 40 + TBL_COL, row_color, TBL_W);
        memset(mtx + (unsigned int)(5 + (i << 1)) * 40 + TBL_COL, row_color, TBL_W);
        draw_sc(TBL_COL, 4 + (i << 1), lineA, TBL_W);
        if (i < count)
            draw_sc_reverse(TBL_COL, 4 + (i << 1), lineA[0]);
        draw_sc(TBL_COL, 5 + (i << 1), lineB, TBL_W);
    }
}

/* ==========================================================================
 * network
 * ========================================================================== */

/* read until the server closes (return 0) or we have the whole blob.
 * uii_socketread: 0 = closed, -1 = nothing yet, >0 = bytes at uii_data[2] */
static int read_blob(void)
{
    unsigned int total = 0, needed = 8;
    int n;
    clock_t t0 = clock();

    while (total < needed) {
#ifndef HOST_TEST
        if (kbhit() && (unsigned char)cgetc() == CH_F1) return -3;
#endif
        n = uii_socketread(sock, 512);
        if (n == 0) break;
        if (n > 0) {
            if (total + n > BLOB_SZ) n = BLOB_SZ - total;
            if (n > 0) {
                memcpy(blob + total, uii_data + 2, (size_t)n);
                total += n;
            }
            if (total >= 8) {
                if (blob[0] != MAGIC0 || blob[1] != MAGIC1 || blob[4] > MAX_AC)
                    return -2;
                needed = 8 + (unsigned int)blob[4] * REC_SZ;
            }
        }
        if ((unsigned int)(clock() - t0) > REPLY_JIF) return -1;
    }
    return (total >= needed) ? (int)total : -1;
}

static unsigned char fetch(void)
{
    int r;
    uii_abort();
    sock = uii_tcpconnect(feed_host, FEED_PORT);
    if (!uii_success()) return ST_DOWN;
    if (feed_request[0]) {
        uii_socketwrite(sock, feed_request);
        if (!uii_success()) {
            uii_socketclose(sock);
            return ST_DOWN;
        }
    }
    r = read_blob();
    uii_socketclose(sock);
    if (r == -3) return ST_EXIT;
    if (r == -2) return ST_BAD;
    if (r < 0)  return ST_DOWN;
    if (blob[3] & 0x04) return ST_LOCATION;
    if (!link_down_displayed) render_targets();
    return (blob[3] & 0x01) ? ST_STALE : ST_OK;
}

#ifndef HOST_TEST
static unsigned char wait_jiffies(unsigned int j)
{
    clock_t t0 = clock();
    while ((unsigned int)(clock() - t0) < j) {
        if (kbhit() && (unsigned char)cgetc() == CH_F1) return 1;
    }
    return 0;
}

static void init_text_video(void)
{
    POKE(0xD015, 0);
    POKE(0xD011, 0x1B);
    POKE(0xD016, 0xC8);
    POKE(0xDD02, PEEK(0xDD02) | 0x03);
    POKE(0xDD00, (PEEK(0xDD00) & 0xFC) | 0x03);
    POKE(0xD018, 0x17);                           /* lowercase/uppercase ROM */
    POKE(0xD020, 0); POKE(0xD021, 0);
}

/* ========================================================================== */

int main(void)
{
    init_config();
    copy_charset();
    for (;;) {
        unsigned char status;
        init_text_video();
        setup_location();
        init_video();
        init_sprites();
        draw_static_scope();
        link_down_displayed = 0;
        show_status(ST_WAIT);
        for (;;) {
            status = fetch();
            if (status == ST_EXIT) break;
            if (status == ST_DOWN) {
                if (!link_down_displayed) show_link_down();
            } else {
                if (link_down_displayed) {
                    init_video();
                    init_sprites();
                    draw_static_scope();
                    render_targets();
                    link_down_displayed = 0;
                }
                show_status(status);
            }
            if (wait_jiffies(POLL_JIF)) break;
        }
    }
    return 0;
}
#endif /* !HOST_TEST */