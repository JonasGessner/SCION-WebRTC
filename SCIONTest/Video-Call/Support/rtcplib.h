// https://github.com/sipwise/rtpengine/blob/2b4c4d02a543d21972484fca16c29e64ae4336cb/lib/rtcplib.h
// GPL-3.0 License

#ifndef _RTCPLIB_H_
#define _RTCPLIB_H_

#include <string.h>
#include <machine/endian.h>
#include <stdbool.h>
#import <Foundation/Foundation.h>

struct rtcp_header {
#if __BYTE_ORDER == __BIG_ENDIAN
	unsigned	    version:2;	/**< packet type            */
	unsigned	    p:1;	/**< padding flag           */
	unsigned	    count:5;	/**< varies by payload type */
#elif __BYTE_ORDER == __LITTLE_ENDIAN
	unsigned	    count:5;	/**< varies by payload type */
	unsigned	    p:1;	/**< padding flag           */
	unsigned	    version:2;	/**< packet type            */
#else
#error "byte order unknown"
#endif
	unsigned char pt;
	uint16_t length;
} __attribute__ ((packed));

struct rtcp_packet {
	struct rtcp_header header;
	uint32_t ssrc;
} __attribute__ ((packed));


/* RFC 5761 section 4 */
bool rtcp_demux_is_rtcp(const uint8_t *s, size_t count, void (NS_NOESCAPE ^f)(uint16_t, uint16_t));

void rtcp_remove_padding(const uint8_t *s);

#endif
