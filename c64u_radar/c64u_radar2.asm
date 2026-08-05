; =============================================================================
; C64U RADAR -- complete 6502 / ca65 translation of c64u_radar.c
;
; Companion to the C64 Ultimate Radar Python server.  Connects via the
; Ultimate Command Interface (UCI) network target, reads a <=232-byte
; fixed-width ADS-B blob, and drives sprites + a hires-bitmap scope.
;
; Display layout:  hires 320x200, VIC bank 1
;   $5A00-$5BFF  eight 64-byte sprite patterns
;   $5C00        screen matrix
;   $6000        bitmap
;   scope        left 200x200 px, centre (100,100), outer ring r=95
;   table        char columns 26-39
;
; Build: assemble with ca65 / link with ld65 alongside ultimate_lib.s.
;        The linker config (cfg/c64u_radar_safe.cfg) and project-config.json
;        are unchanged from the C build -- only this file replaces c64u_radar.c.
;
; ca65 calling convention for imported cc65 C functions:
;   All args but the rightmost are pushed left-to-right with pushax/pusha0;
;   the rightmost arg is passed in A (lo) / X (hi).  The callee cleans the
;   software stack.  The software stack pointer lives at $FD/$FE (sp).
;   8-bit returns → A;  16-bit returns → A (lo) / X (hi).
; =============================================================================

    .setcpu  "6502"
    .smart   on
    .feature string_escapes

; ---------------------------------------------------------------------------
; PRG header: 2-byte load address + 13-byte BASIC SYS stub
; These segments are required by the linker config (type = import).
; The cfg places HEADER at $0801 (size $0D = 13 bytes), so code (MAIN)
; starts at $080E.  SYS 2062 = $080E.
; ---------------------------------------------------------------------------
.export __LOADADDR__
.export __EXEHDR__

.segment "LOADADDR"
__LOADADDR__:
    .word $0801                     ; PRG load address in file header

.segment "EXEHDR"
__EXEHDR__:
    .byte $0B, $08                  ; ptr to next BASIC line  ($080B)
    .byte $0A, $00                  ; BASIC line number 10
    .byte $9E                       ; SYS token
    .byte $20                       ; space (required by BASIC parser)
    .byte '2', '0', '6', '2'       ; "2062" = $080E (first byte of MAIN)
    .byte $00                       ; end of BASIC line
    .byte $00, $00                  ; end of BASIC program

; ---------------------------------------------------------------------------
; cc65 zero-page runtime variables (importzp so the linker knows)
; ---------------------------------------------------------------------------
    .importzp  sp                     ; $FD/$FE  software stack pointer
    .importzp  ptr1, ptr2, ptr3, ptr4 ; $02/$03 $04/$05 $06/$07 $08/$09
    .importzp  tmp1, tmp2, tmp3, tmp4 ; $0A $0B $0C $0D

; ---------------------------------------------------------------------------
; cc65 runtime helpers (pushax etc.)
; ---------------------------------------------------------------------------
    .import  pushax                   ; push A/X onto soft stack
    .import  pusha                    ; push A onto soft stack
    .import  pusha0                   ; push A (X=0) onto soft stack
    .import  incsp2                   ; pop 2 bytes from soft stack (no result)

; ---------------------------------------------------------------------------
; Ultimate library (compiled from ultimate_lib.c with cc65)
; ---------------------------------------------------------------------------
    .import  _uii_abort
    .import  _uii_tcpconnect
    .import  _uii_socketread
    .import  _uii_socketwrite
    .import  _uii_socketclose
    .import  _uii_status                ; uii_success() is a macro: status[0]=='0'&&status[1]=='0'
    .import  _uii_data                ; global: unsigned char uii_data[640+2]

; ---------------------------------------------------------------------------
; KERNAL entry points
; ---------------------------------------------------------------------------
GETIN       = $FFE4                   ; get key from buffer (A=0 if empty)
CHROUT      = $FFD2                   ; output PETSCII char in A
PLOT        = $FFF0                   ; C=0 set cursor Y=row X=col
                                      ; C=1 get cursor Y=row X=col

; ---------------------------------------------------------------------------
; Video & hardware equates
; ---------------------------------------------------------------------------
MATRIX      = $5C00
BITMAP      = $6000
SPR_DATA    = $5A00
SPR_PTRVAL  = $68                     ; ($5A00-$4000)/64
COL_GREEN_BLACK = $D0
COL_GREY_BLACK  = $F0
COL_RED_BLACK   = $20
SPR_GREEN   = 13
SPR_GREY    = 15

; Scope / display geometry
SCOPE_C     = 100
RING_PX     = 95
DEFAULT_SCOPE_RANGE_NM = 15
TBL_COL     = 26
TBL_W       = 14

; Blob protocol
MAGIC0      = $4C                     ; 'L'
MAGIC1      = $44                     ; 'D'
REC_SZ      = 28
MAX_AC      = 8
FEED_REQ_SZ = 48
BLOB_SZ     = 8 + MAX_AC * REC_SZ    ; 232

FEED_PORT   = 6464
POLL_JIF    = 120                     ; ~2 s
REPLY_JIF   = 1200                    ; ~20 s

; Link-state constants (match enum in C source)
ST_OK       = 0
ST_STALE    = 1
ST_DOWN     = 2
ST_BAD      = 3
ST_WAIT     = 4
ST_LOCATION = 5
ST_EXIT     = 6

; Server-source constants
SERVER_UNSET  = 0
SERVER_AUTO   = 1
SERVER_MANUAL = 2

; Location-mode constants
LOC_DEFAULT  = 0
LOC_POSITION = 1
LOC_ICAO     = 2

; Custom charset glyph codes (repurposing ROM codes $7E/$7F)
SC_DOWN_ARROW = $7E
SC_UP_ARROW   = $7F

; Fixed upper-RAM addresses
CHARSET_ADDR  = $C000
BLOB_ADDR     = $C900
STATE_ADDR    = $CA90
MAILBOX_ADDR  = $CAC0
FEED_REQ_ADDR = $CA00
FEED_HOST_ADDR= $CA30
SCOPE_LBL1    = $CA40
SCOPE_LBL2    = $CA50
LOC_TEXT_ADDR = $CA60

; STATE_ADDR byte offsets (matches C #defines)
;   +0  sock
;   +1  link_down_displayed
;   +2  server_source
;   +3  cs_hotkey
;   +4  location_mode

; Keyboard decode tables (KERNAL ROM)
KEYTAB_UNSHIFT   = $EB81
KEYTAB_COMMODORE = $EC03
KEYTAB_KEYS      = 64

; C64 CIA2
CIA2_DDRA   = $DD02
CIA2_PA     = $DD00

; VIC-II
VIC_SPR_EN   = $D015
VIC_SPR_MSBX = $D010
VIC_SPR_X0   = $D000
VIC_SPR_Y0   = $D001
VIC_SPR_COL0 = $D027
VIC_SPR_XEX  = $D01D
VIC_SPR_YEX  = $D017
VIC_SPR_BG   = $D01B
VIC_SPR_MC   = $D01C
VIC_CTRL1    = $D011
VIC_CTRL2    = $D016
VIC_MEMCTRL  = $D018
VIC_BORDER   = $D020
VIC_BGCOL    = $D021
CPU_PORT     = $0001

; Jiffy clock (set by KERNAL IRQ handler)
JIFFY_HI     = $A1
JIFFY_LO     = $A2

; cc65 keyboard buffer count
KBD_BUF_CNT  = $C6

; =============================================================================
; DATA SEGMENT
; =============================================================================
.segment "RODATA"

; String table for show_status  (each exactly 14 chars, space-padded)
status_txt_0: .byte "LINK OK       "
status_txt_1: .byte "LINK STALE    "
status_txt_2: .byte "LINK DOWN     "
status_txt_3: .byte "BAD DATA      "
status_txt_4: .byte "CONNECTING    "
status_txt_5: .byte "BAD LOCATION  "

status_txt_lo:
    .byte <status_txt_0, <status_txt_1, <status_txt_2
    .byte <status_txt_3, <status_txt_4, <status_txt_5
status_txt_hi:
    .byte >status_txt_0, >status_txt_1, >status_txt_2
    .byte >status_txt_3, >status_txt_4, >status_txt_5

; Feed host initial value (used in init_config)
feed_host_default: .byte "0.0.0.0",0

; Mailbox magic "MR2M" as numeric bytes
MAILBOX_MAGIC0 = $4D  ; 'M'
MAILBOX_MAGIC1 = $52  ; 'R'
MAILBOX_MAGIC2 = $32  ; '2'
MAILBOX_MAGIC3 = $4D  ; 'M'

; 3x5 digit masks for slots 0-7 (match C digit_rows[8][5])
digit_rows:
    .byte 2,6,2,2,7    ; 1
    .byte 7,1,7,4,7    ; 2
    .byte 7,1,7,1,7    ; 3
    .byte 5,5,7,1,1    ; 4
    .byte 7,4,7,1,7    ; 5
    .byte 7,4,7,5,7    ; 6
    .byte 7,1,2,2,2    ; 7
    .byte 7,5,7,5,7    ; 8

; Stem endpoints for 8 compass sectors (dir_x, dir_y)
dir_x: .byte 11,18,21,18,11, 4, 1, 4
dir_y: .byte  0, 3,10,17,20,17,10, 3

; Climb/descend arrow glyphs (16 bytes: $7E=down, $7F=up)
arrow_glyphs:
    .byte $00,$00,$7F,$3E,$1C,$08,$00,$00   ; down  $7E
    .byte $00,$00,$08,$1C,$3E,$7F,$00,$00   ; up    $7F

; Pixel bitmask table  bmask[8] = {$80,$40,$20,$10,$08,$04,$02,$01}
bmask: .byte $80,$40,$20,$10,$08,$04,$02,$01

; Menu strings (PETSCII, null-terminated)
; Drawn by menu_putsxy via direct screen/color RAM writes.
str_title:    .byte "C64U RADAR V0.3asm",0
str_opt_hdr:  .byte "Choose an option to center your scope:",0
str_opt1:     .byte "1. CENTER ON LAT/LONG",0
str_opt2:     .byte "2. CENTER ON ICAO AIRPORT CODE",0
str_opt3_pre: .byte "3. RANGE: ",0
str_opt3_suf: .byte " NM",0
str_csks:     .byte "C= + S CHANGES SERVER ADDRESS",0
str_data:     .byte "Data: adsb.fi",0
str_leviurl:  .byte "levimaaia.com",0
str_yturl:    .byte "youtube.com/@levimaaia",0
str_srv_man:  .byte "USER SERVER IP:",0
str_srv_auto: .byte "Auto-discovered server:",0
str_srv_srch: .byte "SEARCHING FOR SERVER..",0
str_enter_ip: .byte "ENTER SERVER IP ADDRESS",0
str_ip_lbl:   .byte "IP: ",0
str_invalid_ip:.byte "INVALID IP ADDRESS",0
str_press_key:.byte "PRESS A KEY",0
str_lat_hdr:  .byte "ENTER LAT / LONG",0
str_fmt:      .byte "FORMAT: SIGNED DECIMAL DEGREES",0
str_lat_rng:  .byte "LATITUDE:  -90 TO 90",0
str_lon_rng:  .byte "LONGITUDE: -180 TO 180",0
str_ex:       .byte "EX: 39.117210  -94.635600",0
str_lat_lbl:  .byte "LATITUDE : ",0
str_lon_lbl:  .byte "LONGITUDE: ",0
str_inv_pos:  .byte "INVALID POSITION",0
str_retry:    .byte "PRESS A KEY TO RETRY",0
str_icao_hdr: .byte "ENTER ICAO CODE",0
str_icao_lbl: .byte "CODE: ",0
str_inv_icao: .byte "INVALID ICAO CODE",0
str_range_hdr:.byte "SET RANGE (NM)",0
str_mult3:    .byte "MULTIPLE OF 3, 3..99",0
str_cur_pre:  .byte "CURRENT: ",0
str_range_lbl:.byte "RANGE: ",0
str_inv_rng:  .byte "INVALID RANGE VALUE",0
str_scope_ttl:.byte "C64U RADAR",0
str_main_menu:.byte "MAIN MENU: F1",0
str_no_traf:  .byte "NO TRAFFIC",0
str_age_pre:  .byte "AGE ",0
str_rng_pre:  .byte " RNG ",0
str_in_pre:   .byte "IN ",0
str_nm_post:  .byte "NM ",0
str_mr2_pos:  .byte "mr2 pos ",0
str_mr2_icao: .byte "mr2 icao ",0
str_mr2_rng:  .byte "mr2 rng ",0
str_kernal_s: .byte $53,0             ; unshifted PETSCII 'S' for hotkey search

; =============================================================================
; BSS / zero-initialised working variables
; (Live in fixed upper-RAM; see STATE_ADDR block above.)
; Nothing declared here -- all working state lives in the $CA90 fixed block.
; =============================================================================

; Macro: 16-bit store of immediate value to address
.macro  STW  val, addr
    lda  #<(val)
    sta  addr
    lda  #>(val)
    sta  addr+1
.endmacro

; Macro: load 16-bit pointer
.macro  LDA16  addr
    lda  addr
    ldx  addr+1
.endmacro

; Macro: store 16-bit AX to zp pair
.macro  STAX  zp
    sta  zp
    stx  zp+1
.endmacro

; =============================================================================
; CODE SEGMENT
; =============================================================================
.segment "CODE"

; Entry point: SYS from the BASIC stub lands here ($080E = start of MAIN).
; Jump past all the utility routines to the real main entry point.
    jmp  start

; =============================================================================
; Utility: memset
;   ptr1 = dest, Y = fill byte, X:A = count (16-bit, A=lo X=hi)
; =============================================================================
.proc memset_fn
    ; ptr3 = count
    sta  ptr3
    stx  ptr3+1
    ; fill byte in tmp1
    sty  tmp1
    ldy  #0
    ; outer loop: process 256-byte pages
@page:
    lda  ptr3+1
    beq  @tail              ; no full pages left
    ; fill 256 bytes
    ldx  #0
    lda  tmp1
@loop256:
    sta  (ptr1),y
    iny
    bne  @loop256
    inc  ptr1+1             ; advance dest page
    dec  ptr3+1
    bne  @page
@tail:
    ldx  ptr3
    beq  @done
    lda  tmp1
@looptail:
    sta  (ptr1),y
    iny
    dex
    bne  @looptail
@done:
    rts
.endproc

; =============================================================================
; Utility: memcpy
;   ptr1 = dest, ptr2 = src, A = count (8-bit, <=255)
; Clobbers: A, X, Y, tmp1
; =============================================================================
.proc memcpy_fn
    sta  tmp1
    beq  @done
    ldy  #0
@loop:
    lda  (ptr2),y
    sta  (ptr1),y
    iny
    cpy  tmp1
    bne  @loop
@done:
    rts
.endproc

; =============================================================================
; Utility: strcpy  src=ptr2 -> dst=ptr1
;   Copies until and including NUL.  Returns length (not including NUL) in A.
; =============================================================================
.proc strcpy_fn
    ldy  #0
@loop:
    lda  (ptr2),y
    sta  (ptr1),y
    beq  @done
    iny
    bne  @loop
@done:
    tya
    rts
.endproc

; =============================================================================
; Utility: strlen  src=ptr1  -> A = length (capped at 255)
; =============================================================================
.proc strlen_fn
    ldy  #0
@loop:
    lda  (ptr1),y
    beq  @done
    iny
    bne  @loop
@done:
    tya
    rts
.endproc

; =============================================================================
; Utility: strcmp  ptr1 vs ptr2 -> Z=1 equal, Z=0 not-equal
; =============================================================================
.proc strcmp_fn
    ldy  #0
@loop:
    lda  (ptr1),y
    cmp  (ptr2),y
    bne  @done              ; mismatch: Z=0
    beq  @null_check
@null_check:
    lda  (ptr1),y
    beq  @done              ; both NUL, equal: Z=1
    iny
    bne  @loop
    ; overflow (>255): treat as not-equal
    lda  #1
    ora  #0                 ; clear Z
@done:
    rts
.endproc

; =============================================================================
; Utility: strncpy  ptr1=dst, ptr2=src, tmp1=n
;   Copies at most tmp1 bytes; NUL-pads to exactly tmp1.
; =============================================================================
.proc strncpy_fn
    ldy  #0
    ldx  tmp1
    beq  @done
@copy:
    lda  (ptr2),y
    sta  (ptr1),y
    beq  @pad
    iny
    dex
    bne  @copy
    rts
@pad:
    iny
    dex
    beq  @done
    lda  #0
    sta  (ptr1),y
    bne  @pad               ; always
@done:
    rts
.endproc

; =============================================================================
; put_udec  -- right-justified unsigned decimal, minimum width
;   In:  ptr1 = dst buffer pointer
;        tmp1 = value (0-255)
;        tmp2 = width (0 = no pad)
;   Out: ptr1 advanced past digits written
;   Clobbers A, X, Y
; =============================================================================
.proc put_udec
    lda  tmp1
    sta  pu_work
    lda  tmp2
    sta  pu_width
    ldx  #0                 ; digit count
@digitloop:
    ; divide current value by 10, remainder is next digit
    lda  pu_work
    jsr  div10              ; A = quotient, tmp_rem = remainder
    pha                     ; save quotient
    lda  rem_byte
    clc
    adc  #'0'
    sta  digit_buf,x
    inx
    pla
    sta  pu_work
    bne  @digitloop         ; continue while quotient != 0
    stx  pu_digits          ; digit count

    ; pad with spaces to width
    ldy  #0
@padloop:
    cpx  pu_width
    bcs  @nopad             ; x >= width, no more padding
    lda  #' '
    sta  (ptr1),y
    iny
    inx
    bne  @padloop
@nopad:
    ; write digits in reverse
    ldx  pu_digits
@writeloop:
    dex
    bmi  @wdone
    lda  digit_buf,x
    sta  (ptr1),y
    iny
    bne  @writeloop         ; always (y<255 for small values)
@wdone:
    ; advance ptr1 by y
    tya
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   rts
.endproc

; Scratch for put_udec
pu_work:   .res 1
pu_width:  .res 1
pu_digits: .res 1
rem_byte: .res 1
digit_buf: .res 3

; 8-bit divide by 10: A in, quotient in A, remainder in rem_byte
.proc div10
    cld
    sta  d10_work
    lda  #0
    ldx  #8
@loop:
    asl  d10_work
    rol  a
    cmp  #10
    bcc  :+
    sbc  #10            ; C=1 after cmp means no underflow; stays 1 after sbc
    inc  d10_work       ; set quotient bit (bit 0 was cleared by asl above)
:   dex
    bne  @loop
    sta  rem_byte
    lda  d10_work       ; quotient
    rts
.endproc
d10_work: .res 1

; =============================================================================
; bmp_row_offset  -- compute byte offset of bitmap character row
;   In:  A = row (0-24)
;   Out: A (lo) / X (hi) = row * 320 = row*256 + row*64
;   Clobbers: A, X only -- uses a private scratch byte (bro_row), NOT tmp1,
;   because callers (plot/draw_sc/draw_sc_reverse) keep their x/col argument
;   in tmp1 across this call and must see it unchanged on return.
; =============================================================================
.proc bmp_row_offset
    sta  bro_row
    ; row * 256 = shift left 8 → (0, row)
    ; row * 64  = shift left 6 → (row>>2, row<<6)
    ; total = (row + row>>2, (row<<6)&$FF)
    lsr  a                  ; A = row>>1
    lsr  a                  ; A = row>>2
    clc
    adc  bro_row            ; A = row + row>>2  (hi byte)
    tax
    lda  bro_row
    asl  a                  ; ×2
    asl  a                  ; ×4
    asl  a                  ; ×8
    asl  a                  ; ×16
    asl  a                  ; ×32
    asl  a                  ; ×64  (A = (row*64)&$FF; carry holds overflow)
    ; Do NOT propagate carry into X here: high byte already includes row>>2
    ; from the decomposition row*320 = row*256 + row*64.
    rts
.endproc
bro_row: .res 1

; =============================================================================
; plot  -- set one pixel in hires bitmap
;   In: tmp1 = x (0-199), tmp2 = y (0-199)
;   Clobbers A, X, Y, ptr3
; =============================================================================
.proc plot
    ; bounds check: x and y must be 0-199
    lda  tmp1
    cmp  #200
    bcs  @out
    lda  tmp2
    cmp  #200
    bcs  @out
    ; compute byte address = BITMAP + bmp_row_offset(y>>3) + (y&7) + (x&0xF8)
    ; ptr3 = offset
    lda  tmp2
    lsr  a
    lsr  a
    lsr  a                  ; y >> 3
    jsr  bmp_row_offset     ; AX = row_offset
    STAX ptr3
    ; add (y&7)
    lda  tmp2
    and  #7
    clc
    adc  ptr3
    sta  ptr3
    bcc  :+
    inc  ptr3+1
:   ; add (x & 0xF8)
    lda  tmp1
    and  #$F8
    clc
    adc  ptr3
    sta  ptr3
    bcc  :+
    inc  ptr3+1
:   ; add BITMAP base
    lda  ptr3
    clc
    adc  #<BITMAP
    sta  ptr3
    lda  ptr3+1
    adc  #>BITMAP
    sta  ptr3+1
    ; bitmask = bmask[x & 7]
    lda  tmp1
    and  #7
    tay
    lda  bmask,y
    ; OR into bitmap byte
    ldy  #0
    ora  (ptr3),y
    sta  (ptr3),y
@out:
    rts
.endproc

; =============================================================================
; hline  -- horizontal line  x0=tmp1, x1=tmp2, y=tmp3  (all 0-199)
; =============================================================================
; The first procedure was a bit tangled due to register reuse.
; Let's use a cleaner version with local saved values.
x1_save: .res 1
y_save:  .res 1

.proc hline
    lda  tmp2
    sta  x1_save
    lda  tmp3
    sta  y_save
    lda  tmp1
@hloop:
    sta  tmp1
    sta  tmp_hx
    lda  y_save
    sta  tmp2
    jsr  plot
    lda  tmp_hx
    clc
    adc  #1
    sta  tmp_hx
    cmp  x1_save
    beq  @hlast
    bcc  @hloop
    rts
@hlast:
    sta  tmp1
    lda  y_save
    sta  tmp2
    jmp  plot
.endproc
tmp_hx: .res 1

; =============================================================================
; vline  -- vertical line  y0=tmp1, y1=tmp2, x=tmp3  (all 0-199)
; =============================================================================
.proc vline
    lda  tmp2
    sta  y1_save
    lda  tmp3
    sta  x_save
    lda  tmp1
@vloop:
    sta  tmp_vy
    lda  x_save
    sta  tmp1
    lda  tmp_vy
    sta  tmp2
    jsr  plot
    lda  tmp_vy
    clc
    adc  #1
    sta  tmp_vy
    cmp  y1_save
    beq  @vlast
    bcc  @vloop
    rts
@vlast:
    lda  x_save
    sta  tmp1
    lda  y1_save
    sta  tmp2
    jmp  plot
.endproc
y1_save: .res 1
x_save:  .res 1
tmp_vy:  .res 1

; =============================================================================
; spr_plot / spr_unplot / spr_line
;   ptr1 = sprite pattern base (64-byte block)
;   For spr_plot/spr_unplot: tmp1=x (0-23), tmp2=y (0-20)
; =============================================================================
.proc spr_plot
    lda  tmp1
    cmp  #24
    bcs  @out
    lda  tmp2
    cmp  #21
    bcs  @out
    ; byte offset = y*3 + (x>>3)
    lda  tmp2
    asl  a
    clc
    adc  tmp2               ; y*3
    lsr  tmp1               ; x>>1
    lsr  tmp1               ; x>>2
    lsr  tmp1               ; x>>3
    clc
    adc  tmp1               ; + (x>>3)
    tay
    ; bitmask: bmask[original_x & 7]
    ; We need original x -- but we modified tmp1. Use saved value.
    lda  x_spr_save
    and  #7
    tax
    lda  bmask,x
    ora  (ptr1),y
    sta  (ptr1),y
@out:
    rts
.endproc

.proc spr_unplot
    lda  tmp1
    cmp  #24
    bcs  @out
    lda  tmp2
    cmp  #21
    bcs  @out
    lda  tmp2
    asl  a
    clc
    adc  tmp2
    lsr  tmp1
    lsr  tmp1
    lsr  tmp1
    clc
    adc  tmp1
    tay
    lda  x_spr_save
    and  #7
    tax
    lda  bmask,x
    eor  #$FF
    and  (ptr1),y
    sta  (ptr1),y
@out:
    rts
.endproc

x_spr_save: .res 1

; spr_line -- Bresenham line in sprite space
; ptr1=pattern, tmp1=x0, tmp2=y0, tmp3=x1, tmp4=y1
; Uses signed arithmetic via 16-bit scratch in ptr2/ptr3/ptr4
.proc spr_line
    ; We need signed values. Store as bytes (they're 0-23, 0-20 max so OK)
    ; Variables: x0,y0,x1,y1 already in tmp1-tmp4
    ; dx = |x1-x0|, dy = |y1-y0|, sx, sy, err
    lda  tmp3               ; x1
    sec
    sbc  tmp1               ; x1-x0
    bpl  @dx_pos
    eor  #$FF
    clc
    adc  #1
@dx_pos:
    sta  sl_dx
    lda  tmp4               ; y1
    sec
    sbc  tmp2               ; y1-y0
    bpl  @dy_pos
    eor  #$FF
    clc
    adc  #1
@dy_pos:
    sta  sl_dy

    ; sx = (x0<x1) ? 1 : -1
    lda  tmp1
    cmp  tmp3
    bcc  @sx1
    lda  #$FF               ; -1 as signed byte
    bne  @sx_done
@sx1:
    lda  #1
@sx_done:
    sta  sl_sx

    ; sy = (y0<y1) ? 1 : -1
    lda  tmp2
    cmp  tmp4
    bcc  @sy1
    lda  #$FF
    bne  @sy_done
@sy1:
    lda  #1
@sy_done:
    sta  sl_sy

    ; err = dx - dy
    lda  sl_dx
    sec
    sbc  sl_dy
    sta  sl_err             ; signed, fits in byte for sprite coords

    ; current position in sl_cx, sl_cy
    lda  tmp1
    sta  sl_cx
    lda  tmp2
    sta  sl_cy

@mainloop:
    ; plot current point
    lda  sl_cx
    sta  x_spr_save
    sta  tmp1
    lda  sl_cy
    sta  tmp2
    jsr  spr_plot
    ; check done: cx==x1 && cy==y1
    lda  sl_cx
    cmp  tmp3
    bne  @notdone
    lda  sl_cy
    cmp  tmp4
    beq  @done
@notdone:
    ; e2 = err*2 (signed byte -- fits for sprite coords 0-23/0-20)
    lda  sl_err
    asl  a
    sta  sl_e2
    ; if e2 > -dy: err -= dy; cx += sx
    ; e2 > -dy  ↔  e2 + dy > 0
    lda  sl_e2
    clc
    adc  sl_dy
    bmi  @skip_x            ; result <= 0, skip
    ; err -= dy
    lda  sl_err
    sec
    sbc  sl_dy
    sta  sl_err
    ; cx += sx
    lda  sl_cx
    clc
    adc  sl_sx
    sta  sl_cx
@skip_x:
    ; if e2 < dx: err += dx; cy += sy
    ; e2 < dx  ↔  dx - e2 > 0
    lda  sl_dx
    sec
    sbc  sl_e2
    bmi  @skip_y
    beq  @skip_y
    ; err += dx
    lda  sl_err
    clc
    adc  sl_dx
    sta  sl_err
    ; cy += sy
    lda  sl_cy
    clc
    adc  sl_sy
    sta  sl_cy
@skip_y:
    jmp  @mainloop
@done:
    rts
.endproc

sl_dx:  .res 1
sl_dy:  .res 1
sl_sx:  .res 1
sl_sy:  .res 1
sl_err: .res 1
sl_e2:  .res 1
sl_cx:  .res 1
sl_cy:  .res 1

; =============================================================================
; build_sprite -- build one numbered sprite pattern
;   A = slot (0-7), tmp1 = track byte, tmp2 = track_unknown flag
; =============================================================================
.proc build_sprite
    ; ptr1 = SPR_DATA + slot*64 (full 16-bit)
    and  #7
    sta  bs_slot
    lda  bs_slot
    asl  a
    asl  a
    asl  a
    asl  a
    asl  a
    asl  a                  ; low byte of slot*64
    sta  ptr1
    lda  bs_slot
    lsr  a
    lsr  a                  ; high byte contribution of slot*64 = slot>>2
    clc
    adc  #>SPR_DATA
    sta  ptr1+1

    ; memset(p, 0, 64)
    ldy  #0
    lda  #0
    ldx  #64
@clr:
    sta  (ptr1),y
    iny
    dex
    bne  @clr

    ; direction stem (if track known)
    lda  tmp2               ; track_unknown
    bne  @skip_stem
    ; sector = ((track + 16) >> 5) & 7
    lda  tmp1
    clc
    adc  #16
    lsr  a
    lsr  a
    lsr  a
    lsr  a
    lsr  a                  ; >> 5
    and  #7
    sta  bs_sector
    ; spr_line(p, 11, 10, dir_x[sector], dir_y[sector])
    tax
    lda  #11
    sta  tmp1
    lda  #10
    sta  tmp2
    lda  dir_x,x
    sta  tmp3
    lda  dir_y,x
    sta  tmp4
    jsr  spr_line
@skip_stem:

    ; Solid radius-5 diamond centred at (11,10)
    ; for y=5..15: half=5-(|y-10|); for x=(11-half)..(11+half): spr_plot
    lda  #5
    sta  bs_y
@diamond_y:
    lda  bs_y
    cmp  #16                ; y > 15?
    bcs  @diamond_done
    ; half = 5 - |y-10|
    sec
    sbc  #10                ; A = y-10 (signed)
    bpl  :+
    eor  #$FF               ; abs
    clc
    adc  #1
:   sta  bs_abs
    lda  #5
    sec
    sbc  bs_abs
    sta  bs_half
    ; x = 11-half .. 11+half
    lda  #11
    sec
    sbc  bs_half
    sta  bs_x
@diamond_x:
    lda  bs_x
    cmp  #12
    clc
    adc  bs_half
    ; x <= 11+half
    lda  bs_x
    sta  x_spr_save
    sta  tmp1
    lda  bs_y
    sta  tmp2
    jsr  spr_plot
    inc  bs_x
    lda  bs_x
    lda  #11
    clc
    adc  bs_half
    cmp  bs_x
    bcs  @diamond_x
    ; final pixel at x = 11+half
    lda  #11
    clc
    adc  bs_half
    sta  x_spr_save
    sta  tmp1
    lda  bs_y
    sta  tmp2
    jsr  spr_plot
    inc  bs_y
    jmp  @diamond_y
@diamond_done:

    ; Cut slot number out (unplot)
    ; digit_rows[slot][y] for y=0..4, x=0..2
    ; source row base: digit_rows + slot*5
    lda  #0
    sta  bs_rowy
    lda  bs_slot
    asl  a
    asl  a
    clc
    adc  bs_slot            ; slot*5
    sta  bs_dig_idx
@dig_row:
    lda  bs_rowy
    cmp  #5
    beq  @dig_done
    ldy  bs_dig_idx
    lda  digit_rows,y
    sta  bs_row
    ; col 0..2: if bit (4>>col) set, unplot (10+col, 8+row)
    lda  #0
    sta  bs_col
@dig_col:
    lda  bs_col
    cmp  #3
    beq  @dig_col_done
    ; bit = (4 >> col): col0=bit2, col1=bit1, col2=bit0
    lda  #4
    ldy  bs_col
    beq  @shift_done
@shift:
    lsr  a
    dey
    bne  @shift
@shift_done:
    bit  bs_row
    beq  @skip_unplot
    ; unplot (10+col, 8+row)
    lda  #10
    clc
    adc  bs_col
    sta  x_spr_save
    sta  tmp1
    lda  #8
    clc
    adc  bs_rowy
    sta  tmp2
    jsr  spr_unplot
@skip_unplot:
    inc  bs_col
    jmp  @dig_col
@dig_col_done:
    inc  bs_rowy
    inc  bs_dig_idx
    jmp  @dig_row
@dig_done:
    rts
.endproc

bs_slot:    .res 1
bs_sector:  .res 1
bs_y:       .res 1
bs_x:       .res 1
bs_half:    .res 1
bs_abs:     .res 1
bs_row:     .res 1
bs_col:     .res 1
bs_rowy:    .res 1
bs_dig_idx: .res 1

; =============================================================================
; circle -- Midpoint circle algorithm
;   cx=tmp1, cy=tmp2, r=tmp3  (all unsigned 0-199)
; =============================================================================
.proc circle
    ; x=r, y=0, err=1-r (16-bit signed to avoid 8-bit overflow artifacts)
    lda  tmp3               ; r
    sta  ci_x
    lda  #0
    sta  ci_y
    lda  #1
    sec
    sbc  tmp3               ; err = 1-r
    sta  ci_err_lo
    lda  #0
    sbc  #0
    sta  ci_err_hi

@loop:
    ; while (x >= y)
    lda  ci_x
    cmp  ci_y
    bcc  @done

    ; plot 8 symmetric points: (cx±x, cy±y), (cx±y, cy±x)
    ; We call plot with tmp1=px, tmp2=py
    lda  tmp1               ; cx
    clc
    adc  ci_x
    sta  ci_px
    lda  tmp2               ; cy
    clc
    adc  ci_y
    sta  ci_py
    jsr  ci_plot8

    ; if x >= y: advance
    lda  ci_y
    clc
    adc  #1
    sta  ci_y

    ; if (err < 0) err += 2*y+1; else { --x; err += (2*y+1) - 2*x; }
    lda  ci_err_hi
    bmi  @err_neg

    ; err >= 0 branch: --x first (matches C)
    dec  ci_x

    ; err += 2*y+1
    lda  ci_y
    asl  a
    clc
    adc  #1
    sta  ci_tmp
    lda  ci_err_lo
    clc
    adc  ci_tmp
    sta  ci_err_lo
    lda  ci_err_hi
    adc  #0
    sta  ci_err_hi

    ; err -= 2*x
    lda  ci_x
    asl  a
    sta  ci_tmp
    lda  ci_err_lo
    sec
    sbc  ci_tmp
    sta  ci_err_lo
    lda  ci_err_hi
    sbc  #0
    sta  ci_err_hi
    jmp  @loop

@err_neg:
    ; err += 2*y+1
    lda  ci_y
    asl  a
    clc
    adc  #1
    sta  ci_tmp
    lda  ci_err_lo
    clc
    adc  ci_tmp
    sta  ci_err_lo
    lda  ci_err_hi
    adc  #0
    sta  ci_err_hi
    jmp  @loop

@done:
    rts
.endproc

; Helper: plot the 8 symmetric circle points given base (ci_px, ci_py)
; Actually recalculate from cx/cy/ci_x/ci_y
.proc ci_plot8
    ; Save center so each octant point is computed from a stable base.
    lda  tmp1
    sta  ci_cx
    lda  tmp2
    sta  ci_cy

    ; (cx + x, cy + y)
    lda  ci_cx
    clc
    adc  ci_x
    sta  tmp1
    lda  ci_cy
    clc
    adc  ci_y
    sta  tmp2
    jsr  plot

    ; (cx - x, cy + y)
    lda  ci_cx
    sec
    sbc  ci_x
    sta  tmp1
    lda  ci_cy
    clc
    adc  ci_y
    sta  tmp2
    jsr  plot

    ; (cx + x, cy - y)
    lda  ci_cx
    clc
    adc  ci_x
    sta  tmp1
    lda  ci_cy
    sec
    sbc  ci_y
    sta  tmp2
    jsr  plot

    ; (cx - x, cy - y)
    lda  ci_cx
    sec
    sbc  ci_x
    sta  tmp1
    lda  ci_cy
    sec
    sbc  ci_y
    sta  tmp2
    jsr  plot

    ; (cx + y, cy + x)
    lda  ci_cx
    clc
    adc  ci_y
    sta  tmp1
    lda  ci_cy
    clc
    adc  ci_x
    sta  tmp2
    jsr  plot

    ; (cx - y, cy + x)
    lda  ci_cx
    sec
    sbc  ci_y
    sta  tmp1
    lda  ci_cy
    clc
    adc  ci_x
    sta  tmp2
    jsr  plot

    ; (cx + y, cy - x)
    lda  ci_cx
    clc
    adc  ci_y
    sta  tmp1
    lda  ci_cy
    sec
    sbc  ci_x
    sta  tmp2
    jsr  plot

    ; (cx - y, cy - x)
    lda  ci_cx
    sec
    sbc  ci_y
    sta  tmp1
    lda  ci_cy
    sec
    sbc  ci_x
    sta  tmp2
    jsr  plot

    ; restore center in tmp1/tmp2 for caller
    lda  ci_cx
    sta  tmp1
    lda  ci_cy
    sta  tmp2
    rts
.endproc

ci_x:   .res 1
ci_y:   .res 1
ci_err_lo: .res 1
ci_err_hi: .res 1
ci_tmp: .res 1
ci_px:  .res 1
ci_py:  .res 1
ci_cx:  .res 1
ci_cy:  .res 1

; =============================================================================
; draw_sc -- blit screen-code glyphs into bitmap
;   col=tmp1, row=tmp2, sc ptr=ptr2, len=tmp3
;   Uses charset at CHARSET_ADDR.
; =============================================================================
.proc draw_sc
    ; dst = BITMAP + bmp_row_offset(row) + (col<<3)
    lda  tmp2               ; row
    jsr  bmp_row_offset     ; AX = offset
    clc
    adc  #<BITMAP
    sta  ptr1
    txa
    adc  #>BITMAP
    sta  ptr1+1
    ; add col*8 (16-bit-safe: col can be up to ~39, so col*8 can be up to
    ; ~312 and overflow a byte -- capture the high contribution (col>>5)
    ; before the destructive left-shifts, then add both bytes properly).
    lda  tmp1
    lsr  a
    lsr  a
    lsr  a
    lsr  a
    lsr  a                  ; col>>5 = high byte of col*8
    sta  ds_colhi
    lda  tmp1
    asl  a
    asl  a
    asl  a                  ; (col*8) & $FF
    clc
    adc  ptr1
    sta  ptr1
    lda  ptr1+1
    adc  ds_colhi
    sta  ptr1+1
    ; ptr1 = dst
    lda  #0
    sta  ds_i               ; i=0
@outer:
    lda  ds_i
    cmp  tmp3
    beq  @done
    ; g = charset + sc[i]*8
    ldy  ds_i
    lda  (ptr2),y           ; sc[i]
    asl  a
    asl  a
    asl  a                  ; *8  (low byte of charset offset)
    clc
    adc  #<CHARSET_ADDR
    sta  ptr3
    lda  #>CHARSET_ADDR
    ; hi: sc[i] >> 5 (since sc*8 may overflow 8 bits)
    ; Actually sc is 0-127: sc*8 = 0..1016, fits in 10 bits
    ; ptr3 = CHARSET_ADDR + sc[i]*8
    ldy  ds_i
    lda  (ptr2),y
    sta  ds_sc
    ; sc*8 hi byte = sc >> 5
    lda  #0
    lda  ds_sc
    lsr  a
    lsr  a
    lsr  a
    lsr  a
    lsr  a                  ; sc >> 5
    clc
    adc  #>CHARSET_ADDR
    sta  ptr3+1
    lda  ds_sc
    asl  a
    asl  a
    asl  a                  ; sc*8 lo (may wrap, that's the low byte)
    clc
    adc  #<CHARSET_ADDR
    sta  ptr3
    bcc  :+
    inc  ptr3+1
:   ; copy 8 bytes from (ptr3) to (ptr1)
    ldy  #0
@inner:
    lda  (ptr3),y
    sta  (ptr1),y
    iny
    cpy  #8
    bne  @inner
    ; advance ptr1 by 8
    lda  ptr1
    clc
    adc  #8
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   inc  ds_i
    jmp  @outer
@done:
    rts
.endproc
ds_i:  .res 1
ds_sc: .res 1
ds_colhi: .res 1

; =============================================================================
; draw_sc_reverse -- one reverse-video cell
;   col=tmp1, row=tmp2, sc=A
; =============================================================================
.proc draw_sc_reverse
    sta  dsr_sc
    ; compute glyph ptr = CHARSET_ADDR + sc*8
    lsr  a
    lsr  a
    lsr  a
    lsr  a
    lsr  a                  ; sc>>5
    clc
    adc  #>CHARSET_ADDR
    sta  ptr3+1
    lda  dsr_sc
    asl  a
    asl  a
    asl  a
    clc
    adc  #<CHARSET_ADDR
    sta  ptr3
    bcc  :+
    inc  ptr3+1
:   ; compute dst = BITMAP + bmp_row_offset(row) + col*8
    lda  tmp2
    jsr  bmp_row_offset
    clc
    adc  #<BITMAP
    sta  ptr1
    txa
    adc  #>BITMAP
    sta  ptr1+1
    ; add col*8 (16-bit-safe -- see draw_sc for why this can't just be
    ; three asl's followed by clc/adc: col*8 overflows a byte for col>=32)
    lda  tmp1
    lsr  a
    lsr  a
    lsr  a
    lsr  a
    lsr  a                  ; col>>5 = high byte of col*8
    sta  dsr_colhi
    lda  tmp1
    asl  a
    asl  a
    asl  a
    clc
    adc  ptr1
    sta  ptr1
    lda  ptr1+1
    adc  dsr_colhi
    sta  ptr1+1
    ldy  #0
@loop:
    lda  (ptr3),y
    eor  #$FF
    sta  (ptr1),y
    iny
    cpy  #8
    bne  @loop
    rts
.endproc
dsr_sc: .res 1
dsr_colhi: .res 1

; =============================================================================
; asc2sc -- PETSCII/ASCII byte to screen code
;   In: A = char    Out: A = screen code
; =============================================================================
.proc asc2sc
    ; $C1-$DA → &$1F (uppercase PETSCII → screen codes 1-26)
    cmp  #$C1
    bcc  @not_hi_upper
    cmp  #$DB
    bcs  @not_hi_upper
    and  #$1F
    rts
@not_hi_upper:
    ; $41-$5A → subtract $40
    cmp  #$41
    bcc  @not_lo_upper
    cmp  #$5B
    bcs  @not_lo_upper
    sec
    sbc  #$40
    rts
@not_lo_upper:
    ; $61-$7A → subtract $60
    cmp  #$61
    bcc  @not_lo_lower
    cmp  #$7B
    bcs  @not_lo_lower
    sec
    sbc  #$60
    rts
@not_lo_lower:
    ; $20-$3F → as-is (space, digits, punctuation)
    cmp  #$20
    bcc  @dot
    cmp  #$40
    bcs  @dot
    rts
@dot:
    lda  #46                ; '.'
    rts
.endproc

; =============================================================================
; draw_ascii -- draw PETSCII text space-padded to width cells
;   col=tmp1, row=tmp2, src ptr=ptr2 (C string), width=tmp3
; =============================================================================
.proc draw_ascii
    ; build screen-code buffer on soft stack (reuse da_buf: 40 bytes in BSS)
    lda  #0
    sta  da_i
@conv:
    lda  da_i
    cmp  tmp3
    beq  @pad
    ldy  da_i
    lda  (ptr2),y
    beq  @pad
    jsr  asc2sc
    ldy  da_i
    sta  da_buf,y
    inc  da_i
    jmp  @conv
@pad:
    lda  da_i
    cmp  tmp3
    beq  @draw
    ldy  da_i
    lda  #$20
    sta  da_buf,y
    inc  da_i
    jmp  @pad
@draw:
    ; ptr2 = da_buf
    lda  #<da_buf
    sta  ptr2
    lda  #>da_buf
    sta  ptr2+1
    jmp  draw_sc            ; tail-call (tmp1/tmp2/tmp3 still set, ptr2=buf)
.endproc
da_i:   .res 1
da_buf: .res 40

; =============================================================================
; draw_centered -- centred within width cells
;   col=tmp1, row=tmp2, src ptr=ptr2, width=tmp3
; =============================================================================
.proc draw_centered
    ; measure n=strlen(src), clamp to width
    lda  ptr2
    sta  ptr1
    lda  ptr2+1
    sta  ptr1+1
    jsr  strlen_fn          ; A = len
    cmp  tmp3
    bcc  :+
    lda  tmp3               ; clamp to width
:   sta  dc_n
    ; left = (width - n) >> 1
    lda  tmp3
    sec
    sbc  dc_n
    lsr  a
    sta  dc_left
    ; fill buf with spaces, then overlay n chars centred
    ldy  #0
    lda  tmp3
    sta  tmp4               ; width
@sp:
    lda  #' '
    sta  dc_buf,y
    iny
    cpy  tmp4
    bne  @sp
    ; copy n chars starting at dc_left
    ; Y = source index, X = dest index (dc_left + Y)
    lda  dc_left
    sta  dc_di              ; dest index starts at dc_left
    ldy  #0
@cp:
    cpy  dc_n
    beq  @done
    lda  (ptr2),y           ; (zp),Y is valid; (zp),X is not on 6502
    ldx  dc_di
    sta  dc_buf,x           ; absolute indexed X is valid
    inc  dc_di
    iny
    jmp  @cp
@done:
    lda  #0
    ldx  tmp3
    sta  dc_buf,x           ; C parity: NUL-terminate at buf[width]
    ; draw_ascii with ptr2 = dc_buf
    lda  #<dc_buf
    sta  ptr2
    lda  #>dc_buf
    sta  ptr2+1
    jmp  draw_ascii
.endproc
dc_n:    .res 1
dc_left: .res 1
dc_di:   .res 1             ; running dest index for centred copy
dc_buf:  .res 16

; =============================================================================
; draw_reverse_ascii
;   col=tmp1, row=tmp2, src ptr=ptr2, width=tmp3
; =============================================================================
.proc draw_reverse_ascii
    ; memset(mtx + row*40 + col, COL_RED_BLACK, width)
    ; Compute row*40 as a proper 16-bit multiply: row*8*5.
    ; Uses only asl/rol on ptr3/ptr3+1 so every carry is captured.
    lda  tmp2
    sta  dra_row
    sta  ptr3               ; ptr3 = row
    lda  #0
    sta  ptr3+1
    ; row * 8  (3 x 16-bit left-shift)
    asl  ptr3
    rol  ptr3+1
    asl  ptr3
    rol  ptr3+1
    asl  ptr3
    rol  ptr3+1
    ; save row*8
    lda  ptr3
    sta  dra_tmp
    lda  ptr3+1
    sta  dra_tmp2
    ; row * 32  (2 more 16-bit left-shifts)
    asl  ptr3
    rol  ptr3+1
    asl  ptr3
    rol  ptr3+1
    ; row * 40 = row*32 + row*8
    lda  ptr3
    clc
    adc  dra_tmp
    sta  ptr3
    lda  ptr3+1
    adc  dra_tmp2
    sta  ptr3+1
    ; add col
    lda  tmp1
    clc
    adc  ptr3
    sta  ptr3
    bcc  :+
    inc  ptr3+1
:   ; add MATRIX base
    lda  ptr3
    clc
    adc  #<MATRIX
    sta  ptr3
    lda  ptr3+1
    adc  #>MATRIX
    sta  ptr3+1
    ; memset(ptr3, COL_RED_BLACK, width)
    ldy  #0
    ldx  tmp3
    lda  #COL_RED_BLACK
@mset:
    sta  (ptr3),y
    iny
    dex
    bne  @mset
    ; draw each glyph reversed
    lda  #0
    sta  dra_i
    sta  dra_col
@dloop:
    lda  dra_i
    cmp  tmp3
    beq  @ddone
    ldy  dra_i
    lda  (ptr2),y
    bne  :+
    lda  #' '
:   jsr  asc2sc
    ; draw_sc_reverse(col+i, row, sc)
    ; tmp1 = col+i, tmp2=row already set? No, tmp2 might be clobbered.
    ; Save and restore:
    sta  dra_sc
    lda  dra_orig_col
    clc
    adc  dra_i
    sta  tmp1
    lda  dra_row
    sta  tmp2
    lda  dra_sc
    jsr  draw_sc_reverse
    inc  dra_i
    jmp  @dloop
@ddone:
    rts
.endproc

; Pre-call: save col into dra_orig_col
dra_orig_col: .res 1
dra_col:  .res 1             ; current column index within draw_reverse_ascii
dra_row:  .res 1
dra_tmp:  .res 1
dra_tmp2: .res 1
dra_i:    .res 1
dra_sc:   .res 1

; Wrapper that saves col first
.proc draw_reverse_ascii_w
    lda  tmp1
    sta  dra_orig_col
    jmp  draw_reverse_ascii
.endproc

; =============================================================================
; copy_charset -- copy uppercase/graphics ROM to CHARSET_ADDR, patch arrows
;   Disables interrupts briefly to bank in char ROM at $D000.
; =============================================================================
.proc copy_charset
    sei
    lda  CPU_PORT
    sta  cc_save_p
    and  #$FB               ; bit 2 = 0: char ROM at $D000
    sta  CPU_PORT
    ; memcpy(charset, $D000, 2048)
    lda  #<CHARSET_ADDR
    sta  ptr1
    lda  #>CHARSET_ADDR
    sta  ptr1+1
    lda  #<$D000
    sta  ptr2
    lda  #>$D000
    sta  ptr2+1
    ; 2048 = 8 pages
    ldx  #8
@page:
    ldy  #0
@byte:
    lda  (ptr2),y
    sta  (ptr1),y
    iny
    bne  @byte
    inc  ptr1+1
    inc  ptr2+1
    dex
    bne  @page
    ; restore CPU port
    lda  cc_save_p
    sta  CPU_PORT
    cli
    ; patch arrow glyphs at SC_DOWN_ARROW ($7E) and SC_UP_ARROW ($7F)
    ; dst = CHARSET_ADDR + SC_DOWN_ARROW * 8
    lda  #<(CHARSET_ADDR + SC_DOWN_ARROW * 8)
    sta  ptr1
    lda  #>(CHARSET_ADDR + SC_DOWN_ARROW * 8)
    sta  ptr1+1
    ldy  #0
@arrows:
    lda  arrow_glyphs,y
    sta  (ptr1),y
    iny
    cpy  #16
    bne  @arrows
    rts
.endproc
cc_save_p: .res 1

; =============================================================================
; init_video
; =============================================================================
.proc init_video
    lda  #$0B
    sta  VIC_CTRL1           ; display off during switch
    lda  CIA2_DDRA
    ora  #$03
    sta  CIA2_DDRA           ; PA0/PA1 = outputs
    lda  CIA2_PA
    and  #$FC
    ora  #$02
    sta  CIA2_PA             ; VIC bank 1 ($4000)
    lda  #$78
    sta  VIC_MEMCTRL         ; screen=$5C00, bitmap=$6000
    ; memset(bmp, 0, 8000)
    lda  #<BITMAP
    sta  ptr1
    lda  #>BITMAP
    sta  ptr1+1
    ldy  #0
    lda  #0
    ldx  #>8000              ; 8000 = $1F40: 31 full pages + 64 bytes
@bmpclr_page:
    cpx  #0
    beq  @bmpclr_tail
@bmpclr_inner:
    sta  (ptr1),y
    iny
    bne  @bmpclr_inner
    inc  ptr1+1
    dex
    jmp  @bmpclr_page
@bmpclr_tail:
    ldy  #0
@bmpclr64:
    sta  (ptr1),y
    iny
    cpy  #<8000
    bne  @bmpclr64
    ; memset(mtx, COL_GREEN_BLACK, 1000)
    lda  #<MATRIX
    sta  ptr1
    lda  #>MATRIX
    sta  ptr1+1
    lda  #COL_GREEN_BLACK
    ldy  #0
    ldx  #3                 ; 3 full pages (768) + 232
@mtxclr_page:
    sta  (ptr1),y
    iny
    bne  @mtxclr_page
    inc  ptr1+1
    dex
    bne  @mtxclr_page
    ; remaining 232 bytes
    ldx  #232
@mtxclr_tail:
    sta  (ptr1),y
    iny
    dex
    bne  @mtxclr_tail
    ; enable hires bitmap
    lda  #$3B
    sta  VIC_CTRL1
    lda  #$C8
    sta  VIC_CTRL2
    lda  #0
    sta  VIC_BORDER
    sta  VIC_BGCOL
    rts
.endproc

; =============================================================================
; init_sprites
; =============================================================================
.proc init_sprites
    ; memset(SPR_DATA, 0, 512)
    lda  #<SPR_DATA
    sta  ptr1
    lda  #>SPR_DATA
    sta  ptr1+1
    ldy  #0
    lda  #0
    ldx  #2                 ; 2 pages = 512
@clr:
    sta  (ptr1),y
    iny
    bne  @clr
    inc  ptr1+1
    dex
    bne  @clr
    ; build_sprite(i, track=0, track_unknown=1) for i=0..7
    lda  #0
    sta  is_i               ; use memory counter -- build_sprite clobbers X
@loop:
    lda  is_i
    cmp  #8
    beq  @sprites_done
    lda  #0
    sta  tmp1               ; track = 0
    lda  #1
    sta  tmp2               ; track_unknown = 1
    lda  is_i               ; slot = i
    jsr  build_sprite       ; clobbers X; is_i is safe in memory
    ; sprite pointer: MATRIX[$3F8 + i] = SPR_PTRVAL + i
    lda  is_i
    clc
    adc  #SPR_PTRVAL
    ldx  is_i
    ldy  #0
    sta  MATRIX+$3F8,x      ; absolute indexed -- no ptr needed
    ; sprite color
    lda  #SPR_GREEN
    sta  VIC_SPR_COL0,x
    inc  is_i
    jmp  @loop
@sprites_done:
    ; all off until data
    lda  #0
    sta  VIC_SPR_EN
    sta  VIC_SPR_MSBX
    sta  VIC_SPR_YEX
    sta  VIC_SPR_XEX
    sta  VIC_SPR_BG
    sta  VIC_SPR_MC
    rts
.endproc
is_i: .res 1

; =============================================================================
; draw_static_scope
; =============================================================================
.proc draw_static_scope
    ; bezel top (y=0)
    lda  #0
    sta  tmp1               ; x0=0
    lda  #199
    sta  tmp2               ; x1=199
    lda  #0
    sta  tmp3               ; y=0
    jsr  hline
    ; bezel bottom (y=199) -- hline clobbers tmp1/tmp2 on return,
    ; so we must re-set ALL three arguments before the second call.
    lda  #0
    sta  tmp1               ; x0=0
    lda  #199
    sta  tmp2               ; x1=199
    lda  #199
    sta  tmp3               ; y=199
    jsr  hline
    lda  #0
    sta  tmp1               ; y0=0
    lda  #199
    sta  tmp2               ; y1=199
    lda  #0
    sta  tmp3               ; x=0
    jsr  vline
    lda  #199
    sta  tmp3
    jsr  vline

    ; rings
    lda  #SCOPE_C
    sta  tmp1
    sta  tmp2
    lda  #32
    sta  tmp3
    jsr  circle
    lda  #SCOPE_C
    sta  tmp1
    sta  tmp2
    lda  #63
    sta  tmp3
    jsr  circle
    lda  #SCOPE_C
    sta  tmp1
    sta  tmp2
    lda  #RING_PX
    sta  tmp3
    jsr  circle

    ; centre cross: hline(98,102,100) vline(98,102,100)
    lda  #98
    sta  tmp1
    lda  #102
    sta  tmp2
    lda  #100
    sta  tmp3
    jsr  hline
    lda  #98
    sta  tmp1
    lda  #102
    sta  tmp2
    lda  #100
    sta  tmp3
    jsr  vline

    ; ring labels (just right of 12 o'clock)
    ; scope_range_nm/3 at char (12,8); *2/3 at (12,4); scope_range_nm at (12,0)
    lda  scope_range_nm
    sta  ds_rng_nm
    ; inner: range/3
    jsr  div3_a
    jsr  fmt2d_a
    lda  #12
    sta  tmp1
    lda  #8
    sta  tmp2
    lda  #2
    sta  tmp3
    lda  #<rl_buf
    sta  ptr2
    lda  #>rl_buf
    sta  ptr2+1
    jsr  draw_sc
    ; middle: range*2/3
    lda  ds_rng_nm
    asl  a                  ; *2
    jsr  div3_a
    jsr  fmt2d_a
    lda  #12
    sta  tmp1
    lda  #4
    sta  tmp2
    lda  #2
    sta  tmp3
    lda  #<rl_buf
    sta  ptr2
    lda  #>rl_buf
    sta  ptr2+1
    jsr  draw_sc
    ; outer: full range
    lda  ds_rng_nm
    jsr  fmt2d_a
    lda  #12
    sta  tmp1
    lda  #0
    sta  tmp2
    lda  #2
    sta  tmp3
    lda  #<rl_buf
    sta  ptr2
    lda  #>rl_buf
    sta  ptr2+1
    jsr  draw_sc

    ; right-column chrome: "C64U RADAR" centred
    lda  #TBL_COL
    sta  tmp1
    lda  #0
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<str_scope_ttl
    sta  ptr2
    lda  #>str_scope_ttl
    sta  ptr2+1
    jsr  draw_centered

    ; clear bitmap row 1 at TBL_COL
    lda  #1
    jsr  bmp_row_offset
    clc
    adc  #<BITMAP
    sta  ptr3
    txa
    adc  #>BITMAP
    sta  ptr3+1
    lda  ptr3
    clc
    adc  #(TBL_COL*8)
    sta  ptr3
    bcc  :+
    inc  ptr3+1
:   ldy  #0
    lda  #0
    ldx  #(TBL_W*8)
@clr1:
    sta  (ptr3),y
    iny
    dex
    bne  @clr1

    ; horizontal bar chars ($40 = horizontal line) in rows 1 and 20
    ldx  #TBL_W
@fill_bar1:
    dex
    lda  #$40
    sta  ds_bar,x
    cpx  #0
    bne  @fill_bar1
    lda  #TBL_COL
    sta  tmp1
    lda  #1
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<ds_bar
    sta  ptr2
    lda  #>ds_bar
    sta  ptr2+1
    jsr  draw_sc
    lda  #TBL_COL
    sta  tmp1
    lda  #20
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<ds_bar
    sta  ptr2
    lda  #>ds_bar
    sta  ptr2+1
    jsr  draw_sc

    ; "MAIN MENU: F1"
    lda  #TBL_COL
    sta  tmp1
    lda  #23
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<str_main_menu
    sta  ptr2
    lda  #>str_main_menu
    sta  ptr2+1
    jsr  draw_ascii
    rts
.endproc

; Dedicated range byte (kept out of STATE_ADDR to avoid accidental overwrite).
scope_range_nm: .res 1

ds_rng_nm: .res 1
tmp1_rng:  .res 1
rl_buf:    .res 4            ; ring label buffer (2 screen-code bytes)
ds_bar:    .res TBL_W

; fmt2d_a -- format A (0-99) as 2 right-justified screen codes in rl_buf
;   Screen code for digit d = $30+d.  Space = $20.
;   Input: A = value.  Clobbers A, X (via div10), rem_byte.
.proc fmt2d_a
    cmp  #10
    bcc  @one_digit
    ; two digits: divide by 10
    sta  fmt2d_v
    jsr  div10              ; A = tens digit (quotient), rem_byte = units
    clc
    adc  #$30               ; screen code for tens
    sta  rl_buf+0
    lda  rem_byte
    clc
    adc  #$30               ; screen code for units
    sta  rl_buf+1
    rts
@one_digit:
    sta  fmt2d_v
    lda  #$20               ; space in tens position
    sta  rl_buf+0
    lda  fmt2d_v
    clc
    adc  #$30               ; screen code for units
    sta  rl_buf+1
    rts
.endproc
fmt2d_v: .res 1

; Divide A by 3, return quotient in A
.proc div3_a
    cld
    sta  d3_val
    lda  #0
    ldx  #8
@loop:
    asl  d3_val
    rol  a
    cmp  #3
    bcc  :+
    sbc  #3             ; C=1 from cmp; no underflow; C stays 1 after sbc
    inc  d3_val         ; record quotient bit (bit 0 cleared by asl)
:   dex
    bne  @loop
    lda  d3_val         ; quotient
    rts
.endproc
d3_val: .res 1

; =============================================================================
; show_status  A = status code (ST_OK..ST_LOCATION)
; =============================================================================
.proc show_status
    ; color: red for stale/down/bad/location, green otherwise
    cmp  #ST_STALE
    beq  @red
    cmp  #ST_DOWN
    beq  @red
    cmp  #ST_BAD
    beq  @red
    cmp  #ST_LOCATION
    beq  @red
    lda  #COL_GREEN_BLACK
    bne  @setclr
@red:
    lda  #COL_RED_BLACK
@setclr:
    ; memset(mtx + 21*40 + TBL_COL, color, TBL_W)
    sta  ss_color
    lda  #<(MATRIX + 21*40 + TBL_COL)
    sta  ptr3
    lda  #>(MATRIX + 21*40 + TBL_COL)
    sta  ptr3+1
    ldy  #0
    ldx  #TBL_W
    lda  ss_color
@mset:
    sta  (ptr3),y
    iny
    dex
    bne  @mset
    ; draw text
    lda  ss_status          ; status code (0-5) = direct index into lo/hi tables
    tax
    lda  status_txt_lo,x
    sta  ptr2
    lda  status_txt_hi,x
    sta  ptr2+1
    lda  #TBL_COL
    sta  tmp1
    lda  #21
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    jmp  draw_ascii
.endproc
ss_color:  .res 1
ss_status: .res 1

; Wrapper that saves A to ss_status first
.proc show_status_w
    sta  ss_status
    jmp  show_status
.endproc

; =============================================================================
; show_link_down
; =============================================================================
.proc show_link_down
    lda  #0
    sta  VIC_SPR_EN          ; all sprites off
    ; clear table rows 4-19 (rows 2-3 kept for diagnostics)
    ldx  #4
@row:
    txa
    sta  sld_row
    ; draw_ascii(TBL_COL, row, "", TBL_W)
    lda  #TBL_COL
    sta  tmp1
    lda  sld_row
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<empty_str
    sta  ptr2
    lda  #>empty_str
    sta  ptr2+1
    jsr  draw_ascii
    ldx  sld_row
    inx
    cpx  #20
    bne  @row
    ; clear rows 21 and 22 too
    lda  #TBL_COL
    sta  tmp1
    lda  #21
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<empty_str
    sta  ptr2
    lda  #>empty_str
    sta  ptr2+1
    jsr  draw_ascii
    lda  #21
    sta  tmp2
    jsr  draw_ascii
    lda  #22
    sta  tmp2
    jsr  draw_ascii
    ; draw "  LINK DOWN  " reversed at centre
    lda  #6
    sta  tmp1
    lda  #12
    sta  tmp2
    lda  #13
    sta  tmp3
    lda  #<str_link_down
    sta  ptr2
    lda  #>str_link_down
    sta  ptr2+1
    lda  tmp1
    sta  dra_orig_col
    jsr  draw_reverse_ascii
    ; link_down_displayed = 1
    lda  #1
    sta  STATE_ADDR+1
    rts
.endproc

empty_str:    .byte 0
str_link_down:.byte "  LINK DOWN  ",0
sld_row:      .res 1

; =============================================================================
; mailbox_checksum  -> A = checksum
; =============================================================================
.proc mailbox_checksum
    lda  #$A5
    eor  MAILBOX_ADDR+5
    sta  mc_sum
    lda  MAILBOX_ADDR+5
    cmp  #16
    bcc  :+
    lda  #15
:   sta  mc_n
    ldy  #0
@loop:
    cpy  mc_n
    beq  @done
    lda  MAILBOX_ADDR+6,y
    eor  mc_sum
    sta  mc_sum
    iny
    jmp  @loop
@done:
    lda  mc_sum
    rts
.endproc

mailbox_ptr:  .word MAILBOX_ADDR   ; constant pointer for indirect use
mc_sum: .res 1
mc_len: .res 1
mc_n:   .res 1
mc_loop_i: .res 1

; Simpler direct-access version (mailbox is at fixed address):
.proc mailbox_checksum_direct
    lda  #$A5
    eor  MAILBOX_ADDR+5
    sta  mc_sum
    lda  MAILBOX_ADDR+5
    cmp  #16
    bcc  :+
    lda  #15
:   sta  mc_n
    ldy  #0
@loop:
    cpy  mc_n
    beq  @done
    lda  MAILBOX_ADDR+6,y
    eor  mc_sum
    sta  mc_sum
    iny
    jmp  @loop
@done:
    lda  mc_sum
    rts
.endproc

; =============================================================================
; mailbox_magic_ok -> A = 1 if magic valid, 0 otherwise
; =============================================================================
.proc mailbox_magic_ok
    lda  MAILBOX_ADDR+0
    cmp  #MAILBOX_MAGIC0
    bne  @fail
    lda  MAILBOX_ADDR+1
    cmp  #MAILBOX_MAGIC1
    bne  @fail
    lda  MAILBOX_ADDR+2
    cmp  #MAILBOX_MAGIC2
    bne  @fail
    lda  MAILBOX_ADDR+3
    cmp  #MAILBOX_MAGIC3
    bne  @fail
    lda  MAILBOX_ADDR+4
    cmp  #1
    bne  @fail
    lda  #1
    rts
@fail:
    lda  #0
    rts
.endproc

; =============================================================================
; mailbox_store  ptr1 = ip C-string
; =============================================================================
.proc mailbox_store
    lda  #MAILBOX_MAGIC0
    sta  MAILBOX_ADDR+0
    lda  #MAILBOX_MAGIC1
    sta  MAILBOX_ADDR+1
    lda  #MAILBOX_MAGIC2
    sta  MAILBOX_ADDR+2
    lda  #MAILBOX_MAGIC3
    sta  MAILBOX_ADDR+3
    lda  #1
    sta  MAILBOX_ADDR+4
    ; strlen(ip)
    jsr  strlen_fn          ; ptr1 already set, A = len
    sta  MAILBOX_ADDR+5
    sta  ms_len
    ; copy up to 16 bytes
    ldy  #0
@copy:
    cpy  ms_len
    beq  @pad
    cpy  #16
    beq  @chk
    lda  (ptr1),y
    sta  MAILBOX_ADDR+6,y
    iny
    jmp  @copy
@pad:
    cpy  #16
    beq  @chk
    lda  #0
    sta  MAILBOX_ADDR+6,y
    iny
    jmp  @pad
@chk:
    jsr  mailbox_checksum_direct
    sta  MAILBOX_ADDR+22
    rts
.endproc
ms_len: .res 1

; =============================================================================
; mailbox_poll -> A = 1 if feed_host changed, 0 otherwise
;   (server_source must not be SERVER_MANUAL; checks magic+checksum)
; =============================================================================
.proc mailbox_poll
    lda  STATE_ADDR+2       ; server_source
    cmp  #SERVER_MANUAL
    beq  @no
    jsr  mailbox_magic_ok
    beq  @no
    lda  MAILBOX_ADDR+5
    sta  mp_len
    cmp  #7
    bcc  @no
    cmp  #16
    bcs  @no
    jsr  mailbox_checksum_direct
    cmp  MAILBOX_ADDR+22
    bne  @no
    ; copy to ip buffer
    ldy  #0
@copyip:
    cpy  mp_len
    beq  @null
    lda  MAILBOX_ADDR+6,y
    sta  mp_ip,y
    iny
    jmp  @copyip
@null:
    lda  #0
    sta  mp_ip,y
    ; compare with feed_host
    lda  #<FEED_HOST_ADDR
    sta  ptr1
    lda  #>FEED_HOST_ADDR
    sta  ptr1+1
    lda  #<mp_ip
    sta  ptr2
    lda  #>mp_ip
    sta  ptr2+1
    jsr  strcmp_fn
    beq  @no                ; same, no change
    ; set_feed_host(mp_ip)
    lda  #<mp_ip
    sta  ptr1
    lda  #>mp_ip
    sta  ptr1+1
    jsr  set_feed_host
    beq  @no                ; invalid
    lda  #SERVER_AUTO
    sta  STATE_ADDR+2
    lda  #1
    rts
@no:
    lda  #0
    rts
.endproc
mp_len: .res 1
mp_ip:  .res 16

; =============================================================================
; set_feed_host  ptr1 = text C-string
;   Returns A=1 if valid IPv4 (nnn.nnn.nnn.nnn), 0 otherwise.
;   On success copies to FEED_HOST_ADDR.
; =============================================================================
.proc set_feed_host
    lda  #0
    sta  sfh_groups
    sta  sfh_digits
    sta  sfh_valhi
    sta  sfh_vallo
    ldy  #0
@loop:
    lda  (ptr1),y
    beq  @eol
    cmp  #'.'
    beq  @dot
    cmp  #'0'
    bcs  :+
    jmp  @fail
:   cmp  #'9'+1
    bcc  :+
    jmp  @fail
:   ; digit
    inc  sfh_digits
    lda  sfh_digits
    cmp  #4
    bcc  :+
    jmp  @fail
:   ; value = value*10 + digit
    ; value*10: value*8 + value*2
    lda  sfh_vallo
    asl  a
    sta  sfh_tmp            ; *2 lo
    lda  sfh_valhi
    rol  a
    sta  sfh_tmp2           ; *2 hi
    lda  sfh_vallo
    asl  a
    asl  a
    asl  a                  ; *8 lo
    clc
    adc  sfh_tmp            ; +*2 = *10
    sta  sfh_vallo
    lda  sfh_valhi
    rol  a
    rol  a
    rol  a
    clc
    adc  sfh_tmp2
    sta  sfh_valhi
    lda  (ptr1),y
    sec
    sbc  #'0'
    clc
    adc  sfh_vallo
    sta  sfh_vallo
    bcc  :+
    inc  sfh_valhi
:   ; value > 255?
    lda  sfh_valhi
    bne  @fail              ; already guarantees vallo <= 255
    iny
    jmp  @loop
@dot:
    lda  sfh_digits
    beq  @fail
    inc  sfh_groups
    lda  sfh_groups
    cmp  #5
    bcs  @fail
    lda  #0
    sta  sfh_digits
    sta  sfh_vallo
    sta  sfh_valhi
    iny
    jmp  @loop
@eol:
    lda  sfh_digits
    beq  @fail
    inc  sfh_groups
    lda  sfh_groups
    cmp  #4
    bne  @fail
    ; check strlen <= 15
    jsr  strlen_fn          ; ptr1 still set, A=len
    cmp  #16
    bcs  @fail
    ; strcpy(feed_host, text)
    lda  #<FEED_HOST_ADDR
    sta  ptr2               ; dst
    lda  #>FEED_HOST_ADDR
    sta  ptr2+1
    ; swap: ptr1=src, ptr2=dst for strcpy_fn
    ; but strcpy_fn uses ptr1=dst, ptr2=src
    ; save src
    lda  ptr1
    sta  sfh_src
    lda  ptr1+1
    sta  sfh_src+1
    lda  #<FEED_HOST_ADDR
    sta  ptr1
    lda  #>FEED_HOST_ADDR
    sta  ptr1+1
    lda  sfh_src
    sta  ptr2
    lda  sfh_src+1
    sta  ptr2+1
    jsr  strcpy_fn
    lda  #1
    rts
@fail:
    lda  #0
    rts
.endproc
sfh_groups: .res 1
sfh_digits: .res 1
sfh_vallo:  .res 1
sfh_valhi:  .res 1
sfh_tmp:    .res 1
sfh_tmp2:   .res 1
sfh_src:    .res 2

; =============================================================================
; key_to_petscii  A = raw key -> A = PETSCII
; =============================================================================
.proc key_to_petscii
    ; $41-$5A: set bit 7
    cmp  #$41
    bcc  @not_lo_upper
    cmp  #$5B
    bcs  @not_lo_upper
    ora  #$80
    rts
@not_lo_upper:
    ; $61-$7A: subtract $20, set bit 7
    cmp  #$61
    bcc  @done
    cmp  #$7B
    bcs  @done
    sec
    sbc  #$20
    ora  #$80
@done:
    rts
.endproc

; =============================================================================
; find_commodore_key  A = unshifted_code -> A = commodore-key code (0 if not found)
; =============================================================================
.proc find_commodore_key
    sta  fck_target
    ldx  #0
@loop:
    cpx  #KEYTAB_KEYS
    beq  @notfound
    lda  KEYTAB_UNSHIFT,x
    cmp  fck_target
    beq  @found
    inx
    jmp  @loop
@found:
    lda  KEYTAB_COMMODORE,x
    rts
@notfound:
    lda  #0
    rts
.endproc
fck_target: .res 1

; =============================================================================
; init_config
; =============================================================================
.proc init_config
    ; server_source = location_mode = SERVER_UNSET (=0)
    lda  #SERVER_UNSET
    sta  STATE_ADDR+2
    lda  #LOC_DEFAULT
    sta  STATE_ADDR+4
    ; strcpy(feed_host, FEED_HOST_DEFAULT)
    lda  #<FEED_HOST_ADDR
    sta  ptr1
    lda  #>FEED_HOST_ADDR
    sta  ptr1+1
    lda  #<feed_host_default
    sta  ptr2
    lda  #>feed_host_default
    sta  ptr2+1
    jsr  strcpy_fn
    ; feed_request[0] = 0
    lda  #0
    sta  FEED_REQ_ADDR
    ; scope_label1[0] = scope_label2[0] = 0
    sta  SCOPE_LBL1
    sta  SCOPE_LBL2
    ; scope_range_nm = DEFAULT_SCOPE_RANGE_NM
    lda  #DEFAULT_SCOPE_RANGE_NM
    sta  scope_range_nm
    ; if (!mailbox_poll()) mailbox_store(feed_host)
    jsr  mailbox_poll
    bne  @done
    lda  #<FEED_HOST_ADDR
    sta  ptr1
    lda  #>FEED_HOST_ADDR
    sta  ptr1+1
    jsr  mailbox_store
@done:
    ; cs_hotkey = find_commodore_key($53)
    lda  #$53
    jsr  find_commodore_key
    sta  STATE_ADDR+3
    ; disable SHIFT+Commodore charset toggle
    lda  #128
    sta  $0291
    rts
.endproc

; =============================================================================
; valid_coordinate  ptr1 = text C-string, tmp1 = limit_lo, tmp2 = limit_hi
;   Returns A=1 if valid, A=0 if invalid.
;   (limit is 90 for lat, 180 for lon -- fits in a byte each)
; =============================================================================
.proc valid_coordinate
    ldy  #0
    lda  #0
    sta  vc_digits
    sta  vc_frac_d
    sta  vc_frac_nz
    sta  vc_whole_lo
    sta  vc_whole_hi
    lda  (ptr1),y
    cmp  #'+'
    beq  @skip_sign
    cmp  #'-'
    beq  @skip_sign
    jmp  @digits
@skip_sign:
    iny
@digits:
    lda  (ptr1),y
    cmp  #'0'
    bcc  @after_digits
    cmp  #'9'+1
    bcs  @after_digits
    ; check digit count <= 3
    lda  vc_digits
    cmp  #3
    bne  :+
    jmp  @fail
:   inc  vc_digits
    ; whole = whole*10 + digit
    lda  (ptr1),y
    sec
    sbc  #'0'
    pha
    lda  vc_whole_lo
    asl  a
    sta  vc_tmp
    lda  vc_whole_hi
    rol  a
    sta  vc_tmp2
    lda  vc_whole_lo
    asl  a
    asl  a
    asl  a
    clc
    adc  vc_tmp
    sta  vc_whole_lo
    lda  vc_whole_hi
    rol  a
    rol  a
    rol  a
    clc
    adc  vc_tmp2
    sta  vc_whole_hi
    pla
    clc
    adc  vc_whole_lo
    sta  vc_whole_lo
    bcc  :+
    inc  vc_whole_hi
:   iny
    jmp  @digits
@after_digits:
    lda  vc_digits
    beq  @fail
    lda  (ptr1),y
    cmp  #'.'
    bne  @check_end
    iny
@frac:
    lda  (ptr1),y
    cmp  #'0'
    bcc  @after_frac
    cmp  #'9'+1
    bcs  @after_frac
    cmp  #'0'
    bne  :+
    jmp  @next_frac
:   lda  #1
    sta  vc_frac_nz
@next_frac:
    inc  vc_frac_d
    iny
    jmp  @frac
@after_frac:
    lda  vc_frac_d
    beq  @fail
@check_end:
    lda  (ptr1),y
    bne  @fail
    ; compare whole against limit
    ; whole < limit: valid;  whole == limit && !frac_nonzero: valid;  else fail
    lda  vc_whole_hi
    bne  @check_gt
    lda  vc_whole_lo
    cmp  tmp1               ; limit (lo byte; hi=0 for 90/180)
    bcc  @ok
    beq  @at_limit
@fail2:
@fail:
    lda  #0
    rts
@check_gt:
    ; whole_hi > 0 means >= 256 > any limit
    jmp  @fail
@at_limit:
    lda  vc_frac_nz
    bne  @fail
@ok:
    lda  #1
    rts
.endproc

vc_digits:   .res 1
vc_frac_d:   .res 1
vc_frac_nz:  .res 1
vc_whole_lo: .res 1
vc_whole_hi: .res 1
vc_tmp:      .res 1
vc_tmp2:     .res 1

; =============================================================================
; set_scope_range_from_text  ptr1 = text -> A=1 valid & stored, A=0 invalid
; =============================================================================
.proc set_scope_range_from_text
    ldy  #0
    lda  #0
    sta  sr_vallo
    sta  sr_valhi
    sta  sr_digits
@loop:
    lda  (ptr1),y
    beq  @eol
    cmp  #'0'
    bcs  :+
    jmp  @fail
:   cmp  #'9'+1
    bcc  :+
    jmp  @fail
:   inc  sr_digits
    lda  sr_digits
    cmp  #4
    bcc  :+
    jmp  @fail
:   ; value = value*10 + digit
    lda  (ptr1),y
    sec
    sbc  #'0'
    pha
    lda  sr_vallo
    asl  a
    sta  sr_tmp
    lda  sr_valhi
    rol  a
    sta  sr_tmp2
    lda  sr_vallo
    asl  a
    asl  a
    asl  a
    clc
    adc  sr_tmp
    sta  sr_vallo
    lda  sr_valhi
    rol  a
    rol  a
    rol  a
    clc
    adc  sr_tmp2
    sta  sr_valhi
    pla
    clc
    adc  sr_vallo
    sta  sr_vallo
    bcc  :+
    inc  sr_valhi
:   iny
    jmp  @loop
@eol:
    lda  sr_digits
    beq  @fail
    lda  (ptr1),y
    bne  @fail
    ; value must be 3..99, multiple of 3
    lda  sr_valhi
    bne  @fail
    lda  sr_vallo
    cmp  #3
    bcc  @fail
    cmp  #100
    bcs  @fail
    ; divisible by 3?
    sta  sr_tmp
    jsr  div3_a
    asl  a
    clc
    adc  sr_tmp
    ; Hmm, need mod3. Compute: v - (v/3)*3
    lda  sr_vallo
    sta  sr_tmp
    jsr  div3_a             ; A = v/3
    sta  sr_quot
    ; sr_quot * 3
    asl  a                  ; *2
    clc
    adc  sr_quot            ; *3
    cmp  sr_tmp             ; = original?
    bne  @fail
    ; store
    lda  sr_vallo
    sta  scope_range_nm
    lda  #1
    rts
@fail:
    lda  #0
    rts
.endproc

sr_vallo: .res 1
sr_valhi: .res 1
sr_digits:.res 1
sr_tmp:   .res 1
sr_tmp2:  .res 1
sr_quot:  .res 1

; =============================================================================
; set_position_request  ptr1=latitude, ptr2=longitude -> A=1/0
; =============================================================================
.proc set_position_request
    ; save pointers
    lda  ptr1
    sta  spr_lat
    lda  ptr1+1
    sta  spr_lat+1
    lda  ptr2
    sta  spr_lon
    lda  ptr2+1
    sta  spr_lon+1
    ; valid_coordinate(latitude, 90)
    lda  #90
    sta  tmp1
    lda  #0
    sta  tmp2
    jsr  valid_coordinate
    bne  :+
    jmp  @fail
:   ; valid_coordinate(longitude, 180)
    lda  spr_lon
    sta  ptr1
    lda  spr_lon+1
    sta  ptr1+1
    lda  #180
    sta  tmp1
    jsr  valid_coordinate
    bne  :+
    jmp  @fail
:   ; check total length fits in FEED_REQ_SZ
    lda  spr_lat
    sta  ptr1
    lda  spr_lat+1
    sta  ptr1+1
    jsr  strlen_fn
    sta  spr_lat_len
    lda  spr_lon
    sta  ptr1
    lda  spr_lon+1
    sta  ptr1+1
    jsr  strlen_fn
    clc
    adc  spr_lat_len
    clc
    adc  #13                ; "mr2 pos " (8) + spaces + NL + some overhead
    cmp  #FEED_REQ_SZ+1
    bcc  :+
    jmp  @fail
:
    ; build request at FEED_REQ_ADDR
    lda  #<FEED_REQ_ADDR
    sta  ptr1
    lda  #>FEED_REQ_ADDR
    sta  ptr1+1
    lda  #<str_mr2_pos
    sta  ptr2
    lda  #>str_mr2_pos
    sta  ptr2+1
    jsr  strcpy_fn          ; writes "mr2 pos \0" and returns len
    ; advance ptr1 by 8
    clc
    adc  ptr1               ; A = strlen returned = 8
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   ; strcpy(ptr1, latitude)
    lda  spr_lat
    sta  ptr2
    lda  spr_lat+1
    sta  ptr2+1
    jsr  strcpy_fn
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   ldy  #0
    lda  #' '
    sta  (ptr1),y
    inc  ptr1
    bne  :+
    inc  ptr1+1
:   lda  spr_lon
    sta  ptr2
    lda  spr_lon+1
    sta  ptr2+1
    jsr  strcpy_fn
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   ldy  #0
    lda  #' '
    sta  (ptr1),y
    inc  ptr1
    bne  :+
    inc  ptr1+1
:   ; append range as ASCII decimal
    jsr  append_range_ascii
    ldy  #0
    lda  #$0A               ; '\n'
    sta  (ptr1),y
    iny
    lda  #0
    sta  (ptr1),y
    ; scope_label1 = latitude (strncpy 14)
    lda  #<SCOPE_LBL1
    sta  ptr1
    lda  #>SCOPE_LBL1
    sta  ptr1+1
    lda  spr_lat
    sta  ptr2
    lda  spr_lat+1
    sta  ptr2+1
    lda  #14
    sta  tmp1
    jsr  strncpy_fn
    lda  #0
    ldy  #14
    sta  (ptr1),y           ; NUL terminate at 14
    ; scope_label2 = longitude
    lda  #<SCOPE_LBL2
    sta  ptr1
    lda  #>SCOPE_LBL2
    sta  ptr1+1
    lda  spr_lon
    sta  ptr2
    lda  spr_lon+1
    sta  ptr2+1
    lda  #14
    sta  tmp1
    jsr  strncpy_fn
    lda  #0
    ldy  #14
    sta  (ptr1),y
    lda  #1
    rts
@fail:
    lda  #0
    rts
.endproc

spr_lat:     .res 2
spr_lon:     .res 2
spr_lat_len: .res 1

; =============================================================================
; set_icao_request  ptr1 = code (4 uppercase chars) -> A=1/0
; =============================================================================
.proc set_icao_request
    ; strlen must be 4
    jsr  strlen_fn
    cmp  #4
    beq  :+
    jmp  @fail
:   ; all chars 'A'-'Z'
    ldy  #0
@check:
    cpy  #4
    beq  @ok
    lda  (ptr1),y
    cmp  #'A'
    bcs  :+
    jmp  @fail
:   cmp  #'Z'+1
    bcc  :+
    jmp  @fail
:
    iny
    jmp  @check
@ok:
    ; build: "mr2 icao " + code + " " + range + "\n"
    lda  ptr1
    sta  si_code
    lda  ptr1+1
    sta  si_code+1
    lda  #<FEED_REQ_ADDR
    sta  ptr1
    lda  #>FEED_REQ_ADDR
    sta  ptr1+1
    lda  #<str_mr2_icao
    sta  ptr2
    lda  #>str_mr2_icao
    sta  ptr2+1
    jsr  strcpy_fn          ; "mr2 icao \0", len=9
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   ; copy 4 chars of code (masked &$7F to ensure ASCII)
    lda  si_code
    sta  ptr2
    lda  si_code+1
    sta  ptr2+1
    ldy  #0
    ldx  #4
@cpcode:
    lda  (ptr2),y
    and  #$7F
    sta  (ptr1),y
    iny
    dex
    bne  @cpcode
    ; advance ptr1 by 4
    lda  ptr1
    clc
    adc  #4
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   ldy  #0
    lda  #' '
    sta  (ptr1),y
    inc  ptr1
    bne  :+
    inc  ptr1+1
:   ; append range as ASCII decimal
    jsr  append_range_ascii
    ldy  #0
    lda  #$0A
    sta  (ptr1),y
    iny
    lda  #0
    sta  (ptr1),y
    ; scope_label1 = code (4 chars)
    lda  si_code
    sta  ptr2
    lda  si_code+1
    sta  ptr2+1
    lda  #<SCOPE_LBL1
    sta  ptr1
    lda  #>SCOPE_LBL1
    sta  ptr1+1
    jsr  strcpy_fn
    ; scope_label2[0] = 0
    lda  #0
    sta  SCOPE_LBL2
    lda  #1
    rts
@fail:
    lda  #0
    rts
.endproc

si_code: .res 2

; =============================================================================
; rebuild_location_request
; =============================================================================
.proc rebuild_location_request
    lda  STATE_ADDR+4       ; location_mode
    cmp  #LOC_POSITION
    bne  @not_pos
    lda  #<(LOC_TEXT_ADDR)
    sta  ptr1
    lda  #>(LOC_TEXT_ADDR)
    sta  ptr1+1
    lda  #<(LOC_TEXT_ADDR+17)
    sta  ptr2
    lda  #>(LOC_TEXT_ADDR+17)
    sta  ptr2+1
    jsr  set_position_request
    rts
@not_pos:
    cmp  #LOC_ICAO
    bne  @done
    lda  #<(LOC_TEXT_ADDR+34)
    sta  ptr1
    lda  #>(LOC_TEXT_ADDR+34)
    sta  ptr1+1
    jsr  set_icao_request
    rts
@done:
    jsr  set_range_request
    rts
.endproc

; =============================================================================
; set_range_request -- build "mr2 rng <range>\n" at FEED_REQ_ADDR
; =============================================================================
.proc set_range_request
    lda  #<FEED_REQ_ADDR
    sta  ptr1
    lda  #>FEED_REQ_ADDR
    sta  ptr1+1
    lda  #<str_mr2_rng
    sta  ptr2
    lda  #>str_mr2_rng
    sta  ptr2+1
    jsr  strcpy_fn
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   jsr  append_range_ascii
    ldy  #0
    lda  #$0A
    sta  (ptr1),y
    iny
    lda  #0
    sta  (ptr1),y
    rts
.endproc

; append_range_ascii -- append scope_range_nm as ASCII decimal at ptr1
; In: ptr1=dest, scope_range_nm=3..99 ; Out: ptr1 advanced past digits
.proc append_range_ascii
    lda  scope_range_nm
    jsr  div10              ; A=tens (0..9), rem_byte=ones
    beq  @one_digit
    clc
    adc  #'0'
    ldy  #0
    sta  (ptr1),y
    inc  ptr1
    bne  :+
    inc  ptr1+1
:   lda  rem_byte
    clc
    adc  #'0'
    ldy  #0
    sta  (ptr1),y
    inc  ptr1
    bne  :+
    inc  ptr1+1
:   rts
@one_digit:
    lda  rem_byte
    clc
    adc  #'0'
    ldy  #0
    sta  (ptr1),y
    inc  ptr1
    bne  :+
    inc  ptr1+1
:   rts
.endproc

; append_u8_ascii -- append A (0..255) as ASCII decimal at ptr1
; In: A=value, ptr1=dest ; Out: ptr1 advanced
.proc append_u8_ascii
    sta  au_work
    ldx  #0
@digitloop:
    lda  au_work
    jsr  div10
    pha
    lda  rem_byte
    clc
    adc  #'0'
    sta  au_digits,x
    inx
    pla
    sta  au_work
    bne  @digitloop
    stx  au_count
    ldx  au_count
@writeloop:
    dex
    bmi  @done
    lda  au_digits,x
    ldy  #0
    sta  (ptr1),y
    inc  ptr1
    bne  :+
    inc  ptr1+1
:   jmp  @writeloop
@done:
    rts
.endproc
au_work:   .res 1
au_count:  .res 1
au_digits: .res 3

; append_total_ascii -- append rt_total-style value in A
; For 0..99 use fmt2d_a (same proven display path as ring labels),
; otherwise fall back to full append_u8_ascii for 100..255.
.proc append_total_ascii
    cmp  #100
    bcs  @three_digits
    jsr  fmt2d_a
    ldy  #0
    lda  rl_buf+0
    sta  (ptr1),y
    iny
    lda  rl_buf+1
    sta  (ptr1),y
    lda  ptr1
    clc
    adc  #2
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   rts
@three_digits:
    jmp  append_u8_ascii
.endproc

; =============================================================================
; menu_putsxy -- write string to screen RAM + color RAM at exact x,y
;   tmp1 = col (0-39), tmp2 = row (0-24), ptr2 = NUL-terminated PETSCII string
; Direct writes to both screen RAM (ptr3) and color RAM (ptr4) guarantee correct
; character appearance regardless of whatever CLR or bitmap mode left in $D800.
; PETSCII→screen-code conversion (lc/uc ROM, $D018=$17):
;   $C1-$DA PETSCII uppercase letters → screen uppercase
;   $41-$5A PETSCII low-set letters and $61-$7A ASCII letters → screen lowercase
;   others unchanged
; Updates KERNAL cursor vars ($D6/$D3 + $D1/$D2 via PLOT) so read_input echoes
; at the correct position immediately after the string.
; =============================================================================
.proc menu_putsxy
    ; offset = row*40 + col
    lda  tmp2
    asl  a
    asl  a
    asl  a                  ; row*8
    sta  mps_r8
    asl  a                  ; row*16 lo
    sta  mps_lo
    lda  #0
    rol  a                  ; row*16 hi
    sta  mps_hi
    lda  mps_lo
    asl  a                  ; row*32 lo
    sta  mps_lo
    lda  mps_hi
    rol  a                  ; row*32 hi
    sta  mps_hi
    lda  mps_lo
    clc
    adc  mps_r8             ; row*40 lo
    sta  mps_lo
    lda  mps_hi
    adc  #0
    sta  mps_hi
    lda  tmp1
    clc
    adc  mps_lo
    sta  mps_lo
    bcc  :+
    inc  mps_hi
:   ; ptr3 = $0400 + offset  (screen RAM)
    lda  mps_lo
    clc
    adc  #<$0400
    sta  ptr3
    lda  mps_hi
    adc  #>$0400
    sta  ptr3+1
    ; ptr4 = $D800 + offset  (color RAM)
    lda  mps_lo
    clc
    adc  #<$D800
    sta  ptr4
    lda  mps_hi
    adc  #>$D800
    sta  ptr4+1
    ldy  #0
@loop:
    lda  (ptr2),y
    beq  @done
    ; PETSCII → screen code
    cmp  #$C1
    bcc  @not_hi_upper
    cmp  #$DB
    bcs  @not_hi_upper
    and  #$1F
    ora  #$40             ; PETSCII uppercase -> screen uppercase in lc/uc mode
    jmp  @store
@not_hi_upper:
    ; PETSCII low-set letters ($41-$5A) are lowercase in ca65 string literals
    cmp  #$41
    bcc  @not_lo_alpha
    cmp  #$5B
    bcs  @not_lo_alpha
    and  #$1F             ; -> screen lowercase in lc/uc mode
    jmp  @store
@not_lo_alpha:
    cmp  #$61
    bcc  @not_lower
    cmp  #$7B
    bcs  @not_lower
    and  #$1F             ; ASCII lowercase -> screen lowercase
    jmp  @store
@not_lower:
    ; Other bytes unchanged (digits, punctuation, symbols)
@store:
    sta  (ptr3),y
    lda  #$05               ; green foreground
    sta  (ptr4),y
    iny
    jmp  @loop
@done:
    ; Update KERNAL cursor so read_input CHROUT echo lands at the right place.
    lda  tmp2
    sta  $D6
    tya
    clc
    adc  tmp1
    sta  $D3
    ldy  $D6
    ldx  $D3
    clc
    jsr  PLOT               ; sets $D1/$D2 (screen line ptr) for CHROUT
    rts
.endproc
mps_r8:  .res 1
mps_lo:  .res 1
mps_hi:  .res 1

; =============================================================================
; read_input  ptr1=result_buf, tmp1=maximum -> A=length
;   Reads chars until ENTER or buffer full.  Handles DEL.
; =============================================================================
.proc read_input
    ; cursor on
    lda  #0
    sta  $CC
    lda  #0
    sta  ri_len
    ; menu_putsxy set $D6 (row) and $D3 (col) to the position after
    ; the prompt string.  Call PLOT with C=0 to set $D1/$D2 (screen-line
    ; pointer) so that CHROUT echo lands on the correct row.
    ldy  $D6
    ldx  $D3
    clc
    jsr  PLOT
    stx  ri_start_x
    sty  ri_start_y
@keyloop:
    jsr  GETIN
    beq  @keyloop
    cmp  #$0D               ; ENTER
    beq  @done
    cmp  #$14               ; DEL (C64 PETSCII)
    beq  @del
    cmp  #8                 ; backspace
    beq  @del
    ; normalize to PETSCII
    jsr  key_to_petscii
    ; accept $20-$7E and $C1-$DA
    cmp  #$20
    bcc  @keyloop
    cmp  #$7F
    bcc  @printable
    cmp  #$C1
    bcc  @keyloop
    cmp  #$DB
    bcs  @keyloop
@printable:
    ldy  ri_len
    cpy  tmp1
    beq  @keyloop           ; buffer full
    sta  (ptr1),y
    inc  ri_len
    jsr  CHROUT
    jmp  @keyloop
@del:
    lda  ri_len
    beq  @keyloop
    dec  ri_len
    ; move cursor back one, print space, move back again
    lda  #$14               ; DEL moves cursor left and erases
    jsr  CHROUT
    jmp  @keyloop
@done:
    ; NUL terminate
    ldy  ri_len
    lda  #0
    sta  (ptr1),y
    ; cursor off
    lda  #1
    sta  $CC
    lda  ri_len
    rts
.endproc
ri_len:     .res 1
ri_start_x: .res 1
ri_start_y: .res 1

; =============================================================================
; draw_server_status
; =============================================================================
.proc draw_server_status
    lda  STATE_ADDR+2       ; server_source
    cmp  #SERVER_MANUAL
    bne  @not_manual
    lda  #4
    sta  tmp1
    lda  #12
    sta  tmp2
    lda  #<str_srv_man
    sta  ptr2
    lda  #>str_srv_man
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #4
    sta  tmp1
    lda  #13
    sta  tmp2
    lda  #<FEED_HOST_ADDR
    sta  ptr2
    lda  #>FEED_HOST_ADDR
    sta  ptr2+1
    jmp  menu_putsxy
@not_manual:
    cmp  #SERVER_AUTO
    bne  @searching
    lda  #4
    sta  tmp1
    lda  #12
    sta  tmp2
    lda  #<str_srv_auto
    sta  ptr2
    lda  #>str_srv_auto
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #4
    sta  tmp1
    lda  #13
    sta  tmp2
    lda  #<FEED_HOST_ADDR
    sta  ptr2
    lda  #>FEED_HOST_ADDR
    sta  ptr2+1
    jmp  menu_putsxy
@searching:
    lda  #4
    sta  tmp1
    lda  #12
    sta  tmp2
    lda  #<str_srv_srch
    sta  ptr2
    lda  #>str_srv_srch
    sta  ptr2+1
    jmp  menu_putsxy
.endproc

; =============================================================================
; setup_location -- main setup menu loop (no HOST_TEST path)
; =============================================================================
.proc setup_location
    ; set text colors
    lda  #5                 ; COLOR_LIGHTGREEN in cc65
    sta  $0286
    lda  #0
    sta  $D021              ; bgcolor black
    sta  $D020              ; bordercolor black

@outer:
    ; Set current-color BEFORE CLR so KERNAL fills color RAM from $0286.
    lda  #$05               ; green
    sta  $0286
    lda  #$93               ; PETSCII CLR
    jsr  CHROUT
    ; Also fill color RAM explicitly: CLR may be unreliable after VIC-bank switch.
    ; 25*40 = 1000 = 3 full pages + 232 bytes.
    lda  #$05               ; green
    ldy  #0
@clrcl0: sta  $D800,y
    iny
    bne  @clrcl0
@clrcl1: sta  $D900,y
    iny
    bne  @clrcl1
@clrcl2: sta  $DA00,y
    iny
    bne  @clrcl2
    ldx  #232
@clrcl3: sta  $DB00,y
    iny
    dex
    bne  @clrcl3

    ; draw title
    lda  #13
    sta  tmp1
    lda  #2
    sta  tmp2
    lda  #<str_title
    sta  ptr2
    lda  #>str_title
    sta  ptr2+1
    jsr  menu_putsxy

    lda  #1
    sta  tmp1
    lda  #4
    sta  tmp2
    lda  #<str_opt_hdr
    sta  ptr2
    lda  #>str_opt_hdr
    sta  ptr2+1
    jsr  menu_putsxy

    lda  #4
    sta  tmp1
    lda  #6
    sta  tmp2
    lda  #<str_opt1
    sta  ptr2
    lda  #>str_opt1
    sta  ptr2+1
    jsr  menu_putsxy

    lda  #4
    sta  tmp1
    lda  #8
    sta  tmp2
    lda  #<str_opt2
    sta  ptr2
    lda  #>str_opt2
    sta  ptr2+1
    jsr  menu_putsxy

    ; build "3. RANGE: XX NM" line
    lda  #4
    sta  tmp1
    lda  #10
    sta  tmp2
    lda  #<str_opt3_pre
    sta  ptr2
    lda  #>str_opt3_pre
    sta  ptr2+1
    jsr  menu_putsxy

    ; build range number string in sl_rng_buf using div10 directly,
    ; avoiding tmp1/tmp2 which may be clobbered between load and put_udec call.
    lda  scope_range_nm    ; value (e.g. 15)
    sta  sl_rng_num             ; keep a safe copy
    jsr  div10                  ; A = tens digit value (0..9), rem_byte = ones
    pha                         ; save tens
    lda  rem_byte
    clc
    adc  #'0'
    sta  sl_rng_buf+1           ; ones digit (slot 1)
    pla                         ; restore tens
    beq  @one_dig               ; tens = 0: single digit number
    ; two-digit number: tens at slot 0, ones at slot 1, NUL at slot 2
    clc
    adc  #'0'
    sta  sl_rng_buf+0
    lda  #0
    sta  sl_rng_buf+2
    lda  #14                    ; start at col 14 (right after "3. RANGE: ")
    sta  tmp1
    jmp  @show_num
@one_dig:
    ; one-digit: pad with space at slot 0, digit at slot 1 (matches C width=2)
    lda  #' '
    sta  sl_rng_buf+0
    lda  sl_rng_buf+1           ; ones digit already there
    sta  sl_rng_buf+1
    lda  #0
    sta  sl_rng_buf+2
    lda  #14                    ; same col as two-digit (space+digit fills 2 chars)
    sta  tmp1
@show_num:
    lda  #10
    sta  tmp2
    lda  #<sl_rng_buf
    sta  ptr2
    lda  #>sl_rng_buf
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #<str_opt3_suf
    sta  ptr2
    lda  #>str_opt3_suf
    sta  ptr2+1
    lda  #16                    ; col 14 + 2 digits = col 16
    sta  tmp1
    lda  #10
    sta  tmp2
    jsr  menu_putsxy

    jsr  draw_server_status

    lda  #4
    sta  tmp1
    lda  #15
    sta  tmp2
    lda  #<str_csks
    sta  ptr2
    lda  #>str_csks
    sta  ptr2+1
    jsr  menu_putsxy

    lda  #6
    sta  tmp1
    lda  #20
    sta  tmp2
    lda  #<str_data
    sta  ptr2
    lda  #>str_data
    sta  ptr2+1
    jsr  menu_putsxy

    lda  #13
    sta  tmp1
    lda  #23
    sta  tmp2
    lda  #<str_leviurl
    sta  ptr2
    lda  #>str_leviurl
    sta  ptr2+1
    jsr  menu_putsxy

    lda  #9
    sta  tmp1
    lda  #24
    sta  tmp2
    lda  #<str_yturl
    sta  ptr2
    lda  #>str_yturl
    sta  ptr2+1
    jsr  menu_putsxy

    ; Wait for key, polling mailbox
@waitkey:
    lda  KBD_BUF_CNT
    beq  :+
    jmp  @gotkey
:   jsr  mailbox_poll
    beq  :+
    jmp  @outer             ; redraw with new server line
:   jmp  @waitkey
@gotkey:
    jsr  GETIN
    bne  :+
    jmp  @waitkey
:   sta  sl_raw

    ; check Commodore+S hotkey before PETSCII normalisation
    lda  STATE_ADDR+3       ; cs_hotkey
    bne  :+
    jmp  @not_cs
:
    cmp  sl_raw
    beq  :+
    jmp  @not_cs
:
    ; change server address
    lda  #$93
    jsr  CHROUT
    lda  #6
    sta  tmp1
    lda  #4
    sta  tmp2
    lda  #<str_enter_ip
    sta  ptr2
    lda  #>str_enter_ip
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #4
    sta  tmp1
    lda  #8
    sta  tmp2
    lda  #<str_ip_lbl
    sta  ptr2
    lda  #>str_ip_lbl
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #<sl_addr_buf
    sta  ptr1
    lda  #>sl_addr_buf
    sta  ptr1+1
    lda  #15
    sta  tmp1
    jsr  read_input
    lda  #<sl_addr_buf
    sta  ptr1
    lda  #>sl_addr_buf
    sta  ptr1+1
    jsr  set_feed_host
    beq  @ip_bad
    lda  #SERVER_MANUAL
    sta  STATE_ADDR+2
    lda  #<FEED_HOST_ADDR
    sta  ptr1
    lda  #>FEED_HOST_ADDR
    sta  ptr1+1
    jsr  mailbox_store
    jmp  @outer
@ip_bad:
    lda  #8
    sta  tmp1
    lda  #12
    sta  tmp2
    lda  #<str_invalid_ip
    sta  ptr2
    lda  #>str_invalid_ip
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #8
    sta  tmp1
    lda  #14
    sta  tmp2
    lda  #<str_press_key
    sta  ptr2
    lda  #>str_press_key
    sta  ptr2+1
    jsr  menu_putsxy
@wk2:
    jsr  GETIN
    beq  @wk2
    jmp  @outer

@not_cs:
    lda  sl_raw
    jsr  key_to_petscii
    sta  sl_choice

    ; choice '1' or 'P'
    cmp  #'1'
    bne  :+
    jmp  @do_latlong
:   cmp  #$D0
    bne  :+
    jmp  @do_latlong
:   cmp  #'2'
    bne  :+
    jmp  @do_icao
:   cmp  #$C9
    bne  :+
    jmp  @do_icao
:   cmp  #'3'
    bne  :+
    jmp  @do_range
:   jmp  @outer

@do_latlong:
    lda  #$93
    jsr  CHROUT
    ; prompt lat/long entry
    lda  #7
    sta  tmp1
    lda  #1
    sta  tmp2
    lda  #<str_lat_hdr
    sta  ptr2
    lda  #>str_lat_hdr
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #5
    sta  tmp1
    lda  #3
    sta  tmp2
    lda  #<str_fmt
    sta  ptr2
    lda  #>str_fmt
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #5
    sta  tmp1
    lda  #4
    sta  tmp2
    lda  #<str_lat_rng
    sta  ptr2
    lda  #>str_lat_rng
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #5
    sta  tmp1
    lda  #5
    sta  tmp2
    lda  #<str_lon_rng
    sta  ptr2
    lda  #>str_lon_rng
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #6
    sta  tmp1
    lda  #6
    sta  tmp2
    lda  #<str_ex
    sta  ptr2
    lda  #>str_ex
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #3
    sta  tmp1
    lda  #9
    sta  tmp2
    lda  #<str_lat_lbl
    sta  ptr2
    lda  #>str_lat_lbl
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #<sl_lat_buf
    sta  ptr1
    lda  #>sl_lat_buf
    sta  ptr1+1
    lda  #15
    sta  tmp1
    jsr  read_input
    lda  #3
    sta  tmp1
    lda  #12
    sta  tmp2
    lda  #<str_lon_lbl
    sta  ptr2
    lda  #>str_lon_lbl
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #<sl_lon_buf
    sta  ptr1
    lda  #>sl_lon_buf
    sta  ptr1+1
    lda  #16
    sta  tmp1
    jsr  read_input
    ; set_position_request(latitude, longitude)
    lda  #<sl_lat_buf
    sta  ptr1
    lda  #>sl_lat_buf
    sta  ptr1+1
    lda  #<sl_lon_buf
    sta  ptr2
    lda  #>sl_lon_buf
    sta  ptr2+1
    jsr  set_position_request
    beq  @pos_bad
    ; save to LOC_TEXT_ADDR
    lda  #<(LOC_TEXT_ADDR)
    sta  ptr1
    lda  #>(LOC_TEXT_ADDR)
    sta  ptr1+1
    lda  #<sl_lat_buf
    sta  ptr2
    lda  #>sl_lat_buf
    sta  ptr2+1
    jsr  strcpy_fn
    lda  #<(LOC_TEXT_ADDR+17)
    sta  ptr1
    lda  #>(LOC_TEXT_ADDR+17)
    sta  ptr1+1
    lda  #<sl_lon_buf
    sta  ptr2
    lda  #>sl_lon_buf
    sta  ptr2+1
    jsr  strcpy_fn
    lda  #LOC_POSITION
    sta  STATE_ADDR+4
    rts
@pos_bad:
    lda  #3
    sta  tmp1
    lda  #16
    sta  tmp2
    lda  #<str_inv_pos
    sta  ptr2
    lda  #>str_inv_pos
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #3
    sta  tmp1
    lda  #18
    sta  tmp2
    lda  #<str_retry
    sta  ptr2
    lda  #>str_retry
    sta  ptr2+1
    jsr  menu_putsxy
@wk3:
    jsr  GETIN
    beq  @wk3
    jmp  @outer

@do_icao:
    lda  #$93
    jsr  CHROUT
    lda  #7
    sta  tmp1
    lda  #4
    sta  tmp2
    lda  #<str_icao_hdr
    sta  ptr2
    lda  #>str_icao_hdr
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #12
    sta  tmp1
    lda  #8
    sta  tmp2
    lda  #<str_icao_lbl
    sta  ptr2
    lda  #>str_icao_lbl
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #<sl_icao_buf
    sta  ptr1
    lda  #>sl_icao_buf
    sta  ptr1+1
    lda  #4
    sta  tmp1
    jsr  read_input
    lda  #<sl_icao_buf
    sta  ptr1
    lda  #>sl_icao_buf
    sta  ptr1+1
    jsr  set_icao_request
    beq  @icao_bad
    lda  #<(LOC_TEXT_ADDR+34)
    sta  ptr1
    lda  #>(LOC_TEXT_ADDR+34)
    sta  ptr1+1
    lda  #<sl_icao_buf
    sta  ptr2
    lda  #>sl_icao_buf
    sta  ptr2+1
    jsr  strcpy_fn
    lda  #LOC_ICAO
    sta  STATE_ADDR+4
    rts
@icao_bad:
    lda  #8
    sta  tmp1
    lda  #12
    sta  tmp2
    lda  #<str_inv_icao
    sta  ptr2
    lda  #>str_inv_icao
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #8
    sta  tmp1
    lda  #14
    sta  tmp2
    lda  #<str_press_key
    sta  ptr2
    lda  #>str_press_key
    sta  ptr2+1
    jsr  menu_putsxy
@wk4:
    jsr  GETIN
    beq  @wk4
    jmp  @outer

@do_range:
    lda  #$05               ; green
    sta  $0286
    lda  #$93
    jsr  CHROUT
    lda  #$05
    ldy  #0
@dr_clrcl0: sta  $D800,y
    iny
    bne  @dr_clrcl0
@dr_clrcl1: sta  $D900,y
    iny
    bne  @dr_clrcl1
@dr_clrcl2: sta  $DA00,y
    iny
    bne  @dr_clrcl2
    ldx  #232
@dr_clrcl3: sta  $DB00,y
    iny
    dex
    bne  @dr_clrcl3
    lda  #8
    sta  tmp1
    lda  #4
    sta  tmp2
    lda  #<str_range_hdr
    sta  ptr2
    lda  #>str_range_hdr
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #3
    sta  tmp1
    lda  #7
    sta  tmp2
    lda  #<str_mult3
    sta  ptr2
    lda  #>str_mult3
    sta  ptr2+1
    jsr  menu_putsxy
    ; "CURRENT: XX"
    lda  #10
    sta  tmp1
    lda  #9
    sta  tmp2
    lda  #<str_cur_pre
    sta  ptr2
    lda  #>str_cur_pre
    sta  ptr2+1
    jsr  menu_putsxy
    ; print current range inline using div10 (avoids tmp1 clobber issue)
    lda  scope_range_nm
    jsr  div10              ; A = tens (0..9), rem_byte = ones
    pha
    lda  rem_byte
    clc
    adc  #'0'
    sta  sl_rng_buf+1
    pla
    beq  @cur_one_dig
    clc
    adc  #'0'
    sta  sl_rng_buf+0
    lda  #0
    sta  sl_rng_buf+2
    lda  #19
    sta  tmp1
    jmp  @cur_show
@cur_one_dig:
    lda  sl_rng_buf+1
    sta  sl_rng_buf+0
    lda  #0
    sta  sl_rng_buf+1
    lda  #20
    sta  tmp1
@cur_show:
    lda  #9
    sta  tmp2
    lda  #<sl_rng_buf
    sta  ptr2
    lda  #>sl_rng_buf
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #9
    sta  tmp1
    lda  #12
    sta  tmp2
    lda  #<str_range_lbl
    sta  ptr2
    lda  #>str_range_lbl
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #<sl_rng_in
    sta  ptr1
    lda  #>sl_rng_in
    sta  ptr1+1
    lda  #3
    sta  tmp1
    jsr  read_input
    lda  #<sl_rng_in
    sta  ptr1
    lda  #>sl_rng_in
    sta  ptr1+1
    jsr  set_scope_range_from_text
    beq  @rng_bad
    jsr  rebuild_location_request
    rts
@rng_bad:
    lda  #6
    sta  tmp1
    lda  #16
    sta  tmp2
    lda  #<str_inv_rng
    sta  ptr2
    lda  #>str_inv_rng
    sta  ptr2+1
    jsr  menu_putsxy
    lda  #6
    sta  tmp1
    lda  #18
    sta  tmp2
    lda  #<str_press_key
    sta  ptr2
    lda  #>str_press_key
    sta  ptr2+1
    jsr  menu_putsxy
@wk5:
    jsr  GETIN
    beq  @wk5
    jmp  @outer
.endproc

; local buffers for setup_location
sl_raw:     .res 1
sl_choice:  .res 1
sl_rng_buf: .res 4
sl_rng_num: .res 1
sl_addr_buf:.res 16
sl_lat_buf: .res 17
sl_lon_buf: .res 17
sl_icao_buf:.res 5
sl_rng_in:  .res 4

; =============================================================================
; render_targets -- decode blob and update sprites + table
; =============================================================================
.proc render_targets
    lda  BLOB_ADDR+4
    sta  rt_count
    lda  BLOB_ADDR+5
    sta  rt_total
    lda  BLOB_ADDR+6
    sta  rt_age
    ; clamp count
    lda  rt_count
    cmp  #MAX_AC+1
    bcc  :+
    lda  #MAX_AC
    sta  rt_count
:   ; draw scope labels
    lda  #TBL_COL
    sta  tmp1
    lda  #2
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<SCOPE_LBL1
    sta  ptr2
    lda  #>SCOPE_LBL1
    sta  ptr2+1
    jsr  draw_centered
    lda  #TBL_COL
    sta  tmp1
    lda  #3
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<SCOPE_LBL2
    sta  ptr2
    lda  #>SCOPE_LBL2
    sta  ptr2+1
    jsr  draw_centered

    ; row 22: age/range summary
    lda  BLOB_ADDR+3
    and  #$01
    beq  @in_range_mode
    ; "AGE XXX RNG XXX"
    lda  #<rt_tmp
    sta  ptr1
    lda  #>rt_tmp
    sta  ptr1+1
    lda  #<str_age_pre
    sta  ptr2
    lda  #>str_age_pre
    sta  ptr2+1
    jsr  strcpy_fn
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   lda  rt_age
    jsr  append_u8_ascii
    lda  #<str_rng_pre
    sta  ptr2
    lda  #>str_rng_pre
    sta  ptr2+1
    jsr  strcpy_fn
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   lda  rt_total
    jsr  append_total_ascii
    ldy  #0
    lda  #0
    sta  (ptr1),y
    jmp  @draw22
@in_range_mode:
    ; "IN XXnm XXX"
    lda  #<rt_tmp
    sta  ptr1
    lda  #>rt_tmp
    sta  ptr1+1
    lda  #<str_in_pre
    sta  ptr2
    lda  #>str_in_pre
    sta  ptr2+1
    jsr  strcpy_fn
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   lda  scope_range_nm
    jsr  fmt2d_a
    ldy  #0
    lda  rl_buf+0
    sta  (ptr1),y
    iny
    lda  rl_buf+1
    sta  (ptr1),y
    lda  ptr1
    clc
    adc  #2
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   
    lda  #<str_nm_post
    sta  ptr2
    lda  #>str_nm_post
    sta  ptr2+1
    jsr  strcpy_fn
    clc
    adc  ptr1
    sta  ptr1
    bcc  :+
    inc  ptr1+1
:   lda  rt_total
    jsr  div10              ; A=tens, rem_byte=ones
    sta  ir_tens
    lda  rem_byte
    sta  ir_ones
    lda  ir_tens
    beq  @in_one_digit
    clc
    adc  #'0'
    sta  rt_tmp+8
    lda  ir_ones
    clc
    adc  #'0'
    sta  rt_tmp+9
    lda  #0
    sta  rt_tmp+10
    jmp  @draw22
@in_one_digit:
    lda  ir_ones
    clc
    adc  #'0'
    sta  rt_tmp+8
    lda  #0
    sta  rt_tmp+9
@draw22:
    lda  #TBL_COL
    sta  tmp1
    lda  #22
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<rt_tmp
    sta  ptr2
    lda  #>rt_tmp
    sta  ptr2+1
    jsr  draw_ascii

    ; update sprites for visible targets
    lda  #0
    sta  rt_i
@sprloop:
    lda  rt_i
    cmp  rt_count
    bne  :+
    jmp  @sprdone
:
    ; r = blob + 8 + i*28
    lda  rt_i
    asl  a
    asl  a                  ; i*4
    sta  rt_offset
    lda  rt_i
    asl  a
    asl  a
    asl  a
    asl  a
    asl  a                  ; i*32
    sec
    sbc  rt_offset          ; i*32 - i*4 = i*28
    clc
    adc  #<(BLOB_ADDR+8)
    sta  rt_reclo
    lda  #>(BLOB_ADDR+8)
    adc  #0
    sta  rt_rechi
    ; route record ptr through ptr2 (ZP) for indirect addressing
    lda  rt_reclo
    sta  ptr2
    lda  rt_rechi
    sta  ptr2+1
    ; x = r[0], y = r[1]
    ldy  #0
    lda  (ptr2),y
    sta  rt_x
    ldy  #1
    lda  (ptr2),y
    sta  rt_y
    ; grounded = r[3] & 0x01
    ldy  #3
    lda  (ptr2),y
    sta  rt_status
    and  #$01
    sta  rt_grounded
    ; build_sprite(i, r[4], r[3]&0x04)
    ldy  #4
    lda  (ptr2),y
    sta  tmp1               ; track
    lda  rt_status
    and  #$04
    sta  tmp2               ; track_unknown
    lda  rt_i
    jsr  build_sprite
    ; sprite color
    lda  rt_i
    tay
    lda  rt_grounded
    bne  @grey
    lda  #SPR_GREEN
    bne  @setcol
@grey:
    lda  #SPR_GREY
@setcol:
    sta  VIC_SPR_COL0,y
    ; sprite X: $D000 + i*2 = 24 + x - 11
    lda  rt_x
    clc
    adc  #24
    sec
    sbc  #11
    sta  rt_spx
    ; MSB check (>255): x is 0-199, +24-11=+13, max=212 < 256, never MSB
    lda  rt_i
    asl  a                  ; i*2
    tay
    lda  rt_spx
    sta  VIC_SPR_X0,y
    ; sprite Y: $D001 + i*2 = 50 + y - 10
    lda  rt_y
    clc
    adc  #50
    sec
    sbc  #10
    iny
    sta  VIC_SPR_X0,y       ; $D001 + i*2
    inc  rt_i
    jmp  @sprloop
@sprdone:
    ; VIC_SPR_EN = (1<<count)-1
    lda  rt_count
    beq  @off
    lda  #1
    ldx  rt_count
@shft:
    asl  a
    dex
    bne  @shft
    sec
    sbc  #1
    jmp  @seten
@off:
    lda  #0
@seten:
    sta  VIC_SPR_EN

    ; draw table rows (two per target, 8 targets = rows 4-19)
    lda  #0
    sta  rt_i
@tblloop:
    lda  rt_i
    cmp  #MAX_AC
    bne  :+
    jmp  @tbldone
:

    ; clear line buffers
    ldy  #0
    lda  #$20               ; space in screen codes
@clrA:
    cpy  #TBL_W
    beq  @clrAd
    sta  rt_lineA,y
    iny
    jmp  @clrA
@clrAd:
    ldy  #0
@clrB:
    cpy  #TBL_W
    beq  @clrBd
    sta  rt_lineB,y
    iny
    jmp  @clrB
@clrBd:
    lda  #COL_GREEN_BLACK
    sta  rt_rowcol
    lda  rt_i
    cmp  rt_count
    bcc  :+
    jmp  @empty_row
:

    ; populate from record
    ; r = blob + 8 + i*28
    lda  rt_i
    asl  a
    asl  a
    sta  rt_offset
    lda  rt_i
    asl  a
    asl  a
    asl  a
    asl  a
    asl  a
    sec
    sbc  rt_offset          ; *28
    clc
    adc  #<(BLOB_ADDR+8)
    sta  rt_reclo
    lda  #>(BLOB_ADDR+8)
    adc  #0
    sta  rt_rechi
    ; route record ptr through ptr2 (ZP) for indirect addressing
    lda  rt_reclo
    sta  ptr2
    lda  rt_rechi
    sta  ptr2+1
    ; grounded flag → color
    ldy  #3
    lda  (ptr2),y
    sta  rt_status
    and  #$01
    beq  :+
    lda  #COL_GREY_BLACK
    sta  rt_rowcol
:   ; lineA[0] = '1'+i (screen code for digit 1-8)
    lda  rt_i
    clc
    adc  #$31
    sta  rt_lineA+0

    ; memcpy(lineA+1, r+6, 8) -- callsign
    lda  rt_reclo
    sta  ptr2
    lda  rt_rechi
    sta  ptr2+1
    ; Use absolute indexed X for fixed dest buffers; Y walks the source record.
    ldy  #6                 ; r+6
    ldx  #0
@cs:
    cpx  #8
    beq  @csd
    lda  (ptr2),y           ; source: record field via ptr2+Y
    sta  rt_lineA+1,x       ; dest: fixed buffer, absolute indexed X
    inx
    iny
    jmp  @cs
@csd:
    ; memcpy(lineA+10, r+14, 4) -- type
    ldy  #14
    ldx  #0
@ty:
    cpx  #4
    beq  @tyd
    lda  (ptr2),y
    sta  rt_lineA+10,x
    inx
    iny
    jmp  @ty
@tyd:
    ; memcpy(lineB+1, r+18, 5) -- alt
    ldy  #18
    ldx  #0
@al:
    cpx  #5
    beq  @ald
    lda  (ptr2),y
    sta  rt_lineB+1,x
    inx
    iny
    jmp  @al
@ald:
    ; memcpy(lineB+7, r+23, 4) -- gs
    ldy  #23
    ldx  #0
@gs:
    cpx  #4
    beq  @gsd
    lda  (ptr2),y
    sta  rt_lineB+7,x
    inx
    iny
    jmp  @gs
@gsd:
    ; lineB[11] = 'K', lineB[12] = 'T' (screen codes: K=$0B, T=$14)
    lda  #$0B
    sta  rt_lineB+11
    lda  #$14
    sta  rt_lineB+12
    ; vertical status
    lda  rt_status
    and  #$18
    cmp  #$08
    bne  @not_climb
    lda  #SC_UP_ARROW
    sta  rt_lineB+6
    jmp  @vstatus_done
@not_climb:
    cmp  #$10
    bne  @vstatus_done
    lda  #SC_DOWN_ARROW
    sta  rt_lineB+6
@vstatus_done:
    jmp  @draw_rows

@empty_row:
    ; i==0 special case: "NO TRAFFIC"
    lda  rt_i
    bne  @draw_rows
    ; memset(mtx + 4*40 + TBL_COL, COL_GREEN_BLACK, TBL_W)
    lda  #<(MATRIX + 4*40 + TBL_COL)
    sta  ptr3
    lda  #>(MATRIX + 4*40 + TBL_COL)
    sta  ptr3+1
    ldy  #0
    lda  #COL_GREEN_BLACK
    ldx  #TBL_W
@mc:
    sta  (ptr3),y
    iny
    dex
    bne  @mc
    ; memset row 5
    lda  #<(MATRIX + 5*40 + TBL_COL)
    sta  ptr3
    lda  #>(MATRIX + 5*40 + TBL_COL)
    sta  ptr3+1
    ldy  #0
    ldx  #TBL_W
    lda  #COL_GREEN_BLACK
@mc2:
    sta  (ptr3),y
    iny
    dex
    bne  @mc2
    lda  #TBL_COL
    sta  tmp1
    lda  #4
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<str_no_traf
    sta  ptr2
    lda  #>str_no_traf
    sta  ptr2+1
    jsr  draw_ascii
    ; draw empty lineB at row 5
    lda  #TBL_COL
    sta  tmp1
    lda  #5
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<rt_lineB
    sta  ptr2
    lda  #>rt_lineB
    sta  ptr2+1
    jsr  draw_sc
    inc  rt_i
    jmp  @tblloop

@draw_rows:
    ; compute rowA = 4 + i*2, rowB = 5 + i*2
    lda  rt_i
    asl  a                  ; i*2
    clc
    adc  #4
    sta  rt_rowa
    clc
    adc  #1
    sta  rt_rowb
    ; set matrix colors for rowA
    lda  rt_rowa
    jsr  row_matrix_ptr
    ldy  #0
    lda  rt_rowcol
    ldx  #TBL_W
@rcs:
    sta  (ptr3),y
    iny
    dex
    bne  @rcs
    ; same for rowB
    lda  rt_rowb
    jsr  row_matrix_ptr
    ldy  #0
    lda  rt_rowcol
    ldx  #TBL_W
@rcs2:
    sta  (ptr3),y
    iny
    dex
    bne  @rcs2
    ; draw_sc(TBL_COL, rowA, lineA, TBL_W)
    lda  #TBL_COL
    sta  tmp1
    lda  rt_rowa
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<rt_lineA
    sta  ptr2
    lda  #>rt_lineA
    sta  ptr2+1
    jsr  draw_sc
    ; if i < count: draw_sc_reverse(TBL_COL, rowA, lineA[0])
    lda  rt_i
    cmp  rt_count
    bcs  @skip_rev
    lda  #TBL_COL
    sta  tmp1
    lda  rt_rowa
    sta  tmp2
    lda  rt_lineA+0
    jsr  draw_sc_reverse
@skip_rev:
    ; draw_sc(TBL_COL, rowB, lineB, TBL_W)
    lda  #TBL_COL
    sta  tmp1
    lda  rt_rowb
    sta  tmp2
    lda  #TBL_W
    sta  tmp3
    lda  #<rt_lineB
    sta  ptr2
    lda  #>rt_lineB
    sta  ptr2+1
    jsr  draw_sc
    inc  rt_i
    jmp  @tblloop
@tbldone:
    rts
.endproc

; row_matrix_ptr -- ptr3 = MATRIX + row*40 + TBL_COL
; In: A=row (0..24), Out: ptr3 set
.proc row_matrix_ptr
    sta  mc_row
    ; row*8
    asl  a
    asl  a
    asl  a
    sta  mc_lo
    lda  #0
    rol  a
    sta  mc_hi
    ; add row*32 by left-shifting 16-bit row*8 by 2
    lda  mc_lo
    sta  mc_tmp
    lda  mc_hi
    sta  mc_tmp2
    asl  mc_tmp
    rol  mc_tmp2
    asl  mc_tmp
    rol  mc_tmp2
    ; row*40 = row*8 + row*32
    lda  mc_lo
    clc
    adc  mc_tmp
    sta  mc_lo
    lda  mc_hi
    adc  mc_tmp2
    sta  mc_hi
    ; add TBL_COL and MATRIX base
    lda  mc_lo
    clc
    adc  #TBL_COL
    sta  mc_lo
    lda  mc_hi
    adc  #0
    sta  mc_hi
    lda  mc_lo
    clc
    adc  #<MATRIX
    sta  ptr3
    lda  mc_hi
    adc  #>MATRIX
    sta  ptr3+1
    rts
.endproc

; render_targets working variables
rt_count:  .res 1
rt_total:  .res 1
rt_age:    .res 1
rt_i:      .res 1
rt_x:      .res 1
rt_y:      .res 1
rt_status: .res 1
rt_grounded:.res 1
rt_spx:    .res 1
rt_offset: .res 1
rt_reclo:  .res 1
rt_rechi:  .res 1
rt_lineA:  .res TBL_W
rt_lineB:  .res TBL_W
rt_rowcol: .res 1
rt_rowa:   .res 1
rt_rowb:   .res 1
rt_tmp:    .res 16
mc_tmp:    .res 1
mc_tmp2:   .res 1
mc_row:    .res 1
mc_lo:     .res 1
mc_hi:     .res 1
ir_tens:   .res 1
ir_ones:   .res 1

; =============================================================================
; read_blob -> A = result  (signed-like: actual count, or $FE==-2, $FF==-1, $FD==-3)
;   Uses BLOB_ADDR buffer.  Calls uii_socketread(sock, 512) via cc65 C calling conv.
; =============================================================================
.proc read_blob
    ; total=0, needed=8
    lda  #0
    sta  rb_total
    sta  rb_total+1
    lda  #8
    sta  rb_needed
    lda  #0
    sta  rb_needed+1
    ; t0 = jiffy clock
    lda  JIFFY_LO
    sta  rb_t0
    lda  JIFFY_HI
    sta  rb_t0+1

@mainloop:
    ; check F1 key
    lda  KBD_BUF_CNT
    beq  @no_key
    jsr  GETIN
    cmp  #$85               ; F1 in PETSCII
    bne  @no_key
    lda  #$FD               ; -3
    rts
@no_key:
    ; n = uii_socketread(sock, 512)
    ; cc65 C convention: push sock (left arg), pass 512 in AX (right arg)
    lda  STATE_ADDR+0       ; sock (unsigned char)
    jsr  pusha              ; push 1-byte arg (cc65 ABI)
    lda  #<512
    ldx  #>512
    jsr  _uii_socketread    ; result in AX (signed int)
    sta  rb_n
    stx  rb_n+1
    ; if n==0: break (server closed)
    bne  @not_zero
    txa
    bne  @not_zero
    jmp  @break
@not_zero:
    ; if n < 0 (hi byte has bit 7 set): skip to timeout check
    lda  rb_n+1
    bpl  :+
    jmp  @timeout_check
:   ; n > 0: copy to blob
    ; clamp: if total+n > BLOB_SZ: n = BLOB_SZ - total
    lda  rb_total
    clc
    adc  rb_n
    sta  rb_tmp
    lda  rb_total+1
    adc  rb_n+1
    bne  @clamp             ; total+n > 255, definitely > BLOB_SZ=232
    lda  rb_tmp
    cmp  #BLOB_SZ+1
    bcc  @no_clamp
@clamp:
    ; n = BLOB_SZ - total
    lda  #BLOB_SZ
    sec
    sbc  rb_total
    sta  rb_n
    lda  #0
    sta  rb_n+1
@no_clamp:
    lda  rb_n
    bne  :+
    jmp  @timeout_check     ; n=0 after clamp, skip copy
:
    ; memcpy(blob+total, uii_data+2, n)
    ; dest = BLOB_ADDR + total
    lda  #<BLOB_ADDR
    clc
    adc  rb_total
    sta  ptr1
    lda  #>BLOB_ADDR
    adc  rb_total+1
    sta  ptr1+1
    ; src = uii_data + 2
    lda  #<(_uii_data+2)
    sta  ptr2
    lda  #>(_uii_data+2)
    sta  ptr2+1
    lda  rb_n
    jsr  memcpy_fn
    ; total += n
    lda  rb_total
    clc
    adc  rb_n
    sta  rb_total
    lda  rb_total+1
    adc  #0
    sta  rb_total+1
    ; if total >= 8: check magic
    lda  rb_total
    cmp  #8
    bcc  @timeout_check
    ; check blob[0]==MAGIC0, blob[1]==MAGIC1, blob[4]<=MAX_AC
    lda  BLOB_ADDR+0
    cmp  #MAGIC0
    bne  @bad
    lda  BLOB_ADDR+1
    cmp  #MAGIC1
    bne  @bad
    lda  BLOB_ADDR+4
    cmp  #MAX_AC+1
    bcc  @ok_hdr
@bad:
    lda  #$FE               ; -2
    rts
@ok_hdr:
    ; needed = 8 + count*28 (count is 0..MAX_AC)
    ldx  BLOB_ADDR+4
    lda  needed_by_count,x
    sta  rb_needed
    lda  #0
    sta  rb_needed+1

@timeout_check:
    ; check (jiffy - t0) > REPLY_JIF
    lda  JIFFY_LO
    sec
    sbc  rb_t0
    sta  rb_elapsed
    lda  JIFFY_HI
    sbc  rb_t0+1
    ; AX = elapsed
    ; compare 16-bit elapsed vs REPLY_JIF (1200=$04B0)
    cmp  #>REPLY_JIF
    bcc  @continue
    bne  @timeout
    lda  rb_elapsed
    cmp  #<REPLY_JIF
    bcc  @continue
    ; bge: timeout
@timeout:
    lda  #$FF               ; -1
    rts
@continue:
    ; compare total vs needed
    lda  rb_total+1
    cmp  rb_needed+1
    bcs  :+
    jmp  @mainloop
:   bne  @break
    lda  rb_total
    cmp  rb_needed
    bcs  :+
    jmp  @mainloop
:   jmp  @break
@break:
    ; return total >= needed ? total : -1
    lda  rb_total+1
    cmp  rb_needed+1
    bcc  @return_neg1
    bne  @return_total
    lda  rb_total
    cmp  rb_needed
    bcc  @return_neg1
@return_total:
    lda  rb_total           ; return total (low byte; <=232 fits in byte)
    rts
@return_neg1:
    lda  #$FF
    rts
.endproc

rb_total:   .res 2
rb_needed:  .res 2
rb_t0:      .res 2
rb_n:       .res 2
rb_tmp:     .res 1
rb_tmp2:    .res 1
rb_elapsed: .res 1
needed_by_count:
    .byte 8, 36, 64, 92, 120, 148, 176, 204, 232

; =============================================================================
; fetch -> A = ST_xxx status
; =============================================================================
.proc fetch
    ; uii_abort() only pulses the ABORT bit in the control register.
    ; Do NOT drain/accept after it -- the C version doesn't, and doing so
    ; can leave UCI in a confused state for the subsequent connect command.
    jsr  _uii_abort
    ; sock = uii_tcpconnect(feed_host, FEED_PORT)
    lda  #<FEED_HOST_ADDR
    ldx  #>FEED_HOST_ADDR
    jsr  pushax
    lda  #<FEED_PORT
    ldx  #>FEED_PORT
    jsr  _uii_tcpconnect
    sta  STATE_ADDR+0       ; sock
    ; if (!uii_success()) return ST_DOWN
    lda  _uii_status+0
    cmp  #$30
    bne  @conn_down
@connected:
    ; if (feed_request[0]) send request
    lda  FEED_REQ_ADDR
    beq  @skip_req
    lda  STATE_ADDR+0       ; sock (unsigned char)
    jsr  pusha              ; push 1-byte arg (cc65 ABI)
    lda  #<FEED_REQ_ADDR
    ldx  #>FEED_REQ_ADDR
    jsr  _uii_socketwrite
    ; if (!uii_success()) close socket and return ST_DOWN
    lda  _uii_status+0
    cmp  #$30
    beq  @skip_req
    lda  STATE_ADDR+0
    ldx  #0
    jsr  _uii_socketclose
@conn_down:
    lda  #ST_DOWN
    rts
@skip_req:
    jsr  read_blob
    sta  ft_r
    ; close socket
    lda  STATE_ADDR+0
    ldx  #0
    jsr  _uii_socketclose
    ; evaluate result
    lda  ft_r
    cmp  #$FD               ; -3 = F1 pressed
    bne  @not_f1
    lda  #ST_EXIT
    rts
@not_f1:
    cmp  #$FE               ; -2 = bad data
    bne  @not_bad
    lda  #ST_BAD
    rts
@not_bad:
    cmp  #$FF               ; -1 = timeout/down
    beq  @down
    bcc  @not_down          ; positive = success
@down:
    lda  #ST_DOWN
    rts
@not_down:
    ; check blob[3] & 0x04 = bad location
    lda  BLOB_ADDR+3
    and  #$04
    beq  @not_location
    lda  #ST_LOCATION
    rts
@not_location:
    ; check link_down_displayed: if not down, render targets
    lda  STATE_ADDR+1
    bne  @no_render
    jsr  render_targets
@no_render:
    lda  BLOB_ADDR+3
    and  #$01
    beq  @ok
    lda  #ST_STALE
    rts
@ok:
    lda  #ST_OK
    rts
.endproc
ft_r:    .res 1

; =============================================================================
; wait_jiffies  -- tmp1/tmp2 = jiffies (lo/hi)  -> A=1 if F1 pressed, A=0 timeout
; =============================================================================
.proc wait_jiffies
    lda  JIFFY_LO
    sta  wj_t0
    lda  JIFFY_HI
    sta  wj_t0+1
@loop:
    lda  KBD_BUF_CNT
    beq  @nokey
    jsr  GETIN
    cmp  #$85               ; F1
    bne  @nokey
    lda  #1
    rts
@nokey:
    lda  JIFFY_LO
    sec
    sbc  wj_t0
    sta  wj_el
    lda  JIFFY_HI
    sbc  wj_t0+1
    ; compare elapsed (AX) vs POLL_JIF (300 = $012C)
    cmp  #>POLL_JIF
    bcc  @loop
    bne  @done
    lda  wj_el
    cmp  #<POLL_JIF
    bcc  @loop
@done:
    lda  #0
    rts
.endproc
wj_t0: .res 2
wj_el: .res 1

; =============================================================================
; init_text_video
; =============================================================================
.proc init_text_video
    lda  #0
    sta  VIC_SPR_EN
    lda  #$1B
    sta  VIC_CTRL1
    lda  #$C8
    sta  VIC_CTRL2
    lda  CIA2_DDRA
    ora  #$03
    sta  CIA2_DDRA
    lda  CIA2_PA
    and  #$FC
    ora  #$03               ; VIC bank 0 ($0000)
    sta  CIA2_PA
    lda  #$17               ; screen $0400, charset ROM (lowercase/uppercase)
    sta  VIC_MEMCTRL
    lda  #0
    sta  VIC_BORDER
    sta  VIC_BGCOL
    rts
.endproc

; =============================================================================
; MAIN ENTRY POINT
; =============================================================================
.export  start
start:
    cld                     ; ensure all ADC/SBC math runs in binary mode

    ; Initialise CPU hardware stack pointer like cc65 crt0 does.
    ; Without this, deep C helper calls can run on a stale BASIC stack
    ; position and hang/crash unpredictably.
    ldx  #$FF
    txs

    ; Initialise the cc65 software stack pointer (sp at $FD/$FE).
    ; cc65's crt0.s normally does this; we must do it ourselves.
    ; Stack grows DOWN from $5A00 (the hard ceiling set in the linker config).
    lda  #$00
    sta  $FD                ; sp lo = $00
    lda  #$5A
    sta  $FE                ; sp hi = $5A  →  sp = $5A00
    ; cc65 C-stack pointer (c_sp at ZP $02/$03) must also be initialized.
    ; crt0 usually keeps c_sp in sync with sp; asm entry must do it manually.
    lda  $FD
    sta  $02                ; c_sp lo
    lda  $FE
    sta  $03                ; c_sp hi
    jsr  init_config
    jsr  copy_charset

@main_loop:
    jsr  init_text_video
    jsr  setup_location
    jsr  init_video
    jsr  init_sprites
    jsr  draw_static_scope
    lda  #0
    sta  STATE_ADDR+1       ; link_down_displayed = 0
    lda  #ST_WAIT
    jsr  show_status_w

@inner_loop:
    jsr  fetch
    sta  main_status
    cmp  #ST_EXIT
    beq  @exit_inner
    cmp  #ST_DOWN
    bne  @not_down
    lda  STATE_ADDR+1       ; link_down_displayed
    bne  @skip_down
    jsr  show_link_down
@skip_down:
    jmp  @wait
@not_down:
    ; not down: if link was down, reinitialise display
    lda  STATE_ADDR+1
    beq  @no_reinit
    jsr  init_video
    jsr  init_sprites
    jsr  draw_static_scope
    jsr  render_targets
    lda  #0
    sta  STATE_ADDR+1
@no_reinit:
    lda  main_status
    jsr  show_status_w
@wait:
    jsr  wait_jiffies
    bne  @exit_inner
    jmp  @inner_loop
@exit_inner:
    jmp  @main_loop
    ; (never exits to BASIC)

main_status: .res 1

; =============================================================================
; END OF FILE
; =============================================================================
