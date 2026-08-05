/* host mock of the UCI library surface used by c64u_radar.c:
 * the harness serves a captured feed blob through uii_socketread
 * with the real semantics (payload at uii_data+2, -1 = no data yet,
 * 0 = remote closed). Also pins clock() to a fake jiffy counter so
 * the C64 timeout math is exercised as written. */
#ifndef HOST_UII_MOCK_H
#define HOST_UII_MOCK_H
#include <time.h>
#define clock host_clock
clock_t host_clock(void);

extern char uii_status[256];
extern char uii_data[1794];
#define uii_success() (uii_status[0] == '0' && uii_status[1] == '0')

unsigned char uii_tcpconnect(char* host, unsigned short port);
int  uii_socketread(unsigned char socketid, unsigned short length);
void uii_socketwrite(unsigned char socketid, char* data);
void uii_socketclose(unsigned char socketid);
void uii_abort(void);
#endif
