//
//  rtcplib.m
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 21.06.21.
//
// Based on: https://github.com/sipwise/rtpengine/blob/2b4c4d02a543d21972484fca16c29e64ae4336cb/lib/rtcplib.h
// GPL-3.0 License

#include "rtcplib.h"
#include <stdio.h>
#include <CoreFoundation/CFByteOrder.h>
#include <assert.h>

#define RTCP_PT_SR    200    /* sender report */
#define RTCP_PT_RR    201    /* receiver report */
#define RTCP_PT_SDES    202    /* source description */
#define RTCP_PT_BYE    203    /* bye */
#define RTCP_PT_APP    204    /* application specific */
#define RTCP_PT_RTPFB    205    /* transport layer feedback message (RTP/AVPF) */
#define RTCP_PT_PSFB    206    /* payload-specific feedback message (RTP/AVPF) */
#define RTCP_PT_XR   207

void rtcp_remove_padding(const uint8_t *s) {
    struct rtcp_packet *rtcp = (void *)s;
    rtcp->header.p = 0;
}

bool rtcp_demux_is_rtcp(const uint8_t *s, size_t count, void (NS_NOESCAPE ^f)(uint16_t, uint16_t)) {
    struct rtcp_packet *rtcp;
    
    uint16_t totalSize = 0;
    
    do {
        if ((count - totalSize) < sizeof(*rtcp)) {
            return totalSize != 0;
        }
        
        rtcp = (void *)(s + totalSize);
        
        if (rtcp->header.pt < 194) {
            return totalSize != 0;
        }

        if (rtcp->header.pt > 223) {
            return totalSize != 0;
        }
        
        uint16_t size = (CFSwapInt16BigToHost(rtcp->header.length) + 1) << 2;
        // Check for overflows
        if (size > count) {
            return totalSize != 0;
        }
        if (totalSize + size < totalSize) {
            return totalSize != 0;
        }
        
        totalSize += size;
        
        if (totalSize > count) {
            return totalSize != 0;
        }
        
//        if (totalSize > 0) {
//            printf("Compound ");
//        }
//
//        if (rtcp->header.pt == RTCP_PT_SR) {
//            printf("Sender report\n");
//        }
//        else
            if (rtcp->header.pt == RTCP_PT_RR) {
//            printf("Receiver report\n");
            f(totalSize - size, size);
        }
//        else {
//            printf("Other rtcp type: %u\n", rtcp->header.pt);
//        }
    }
    while (true);

    return true;
}
