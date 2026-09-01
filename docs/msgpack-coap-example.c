/* burt-sim
 * Burt Simulator
 *
 * Goal: Allows you to run any burt-sharp apps without being connected to Burt hardware.
 * 
 * Usage:
 *   1) Set your IP to 192.168.100.200
 *   2) Run this program
 *   3) Launch a burt-sharp app
 *   4) Use the mouse to set the XY position of Burt's endpoint, use A/Z to move up/down
 * 
 * How it works:
 *   1) Listens for CoAP GET/PUT requests, unpacks them, responds appropriately
 *   2) Simulates the actual kinematics of Burt hardware
 * 
 */

// Server side implementation of UDP client-server model
#include <stdio.h>
#include <stdlib.h>
//#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>
//#include <netinet/in.h>

#include "hashtable.h" // Simple hashtable from K&R C
    
#define PORT    5683 
#define BUF_SZ  1024

// MessagePack decode
// https://github.com/msgpack/msgpack/blob/master/spec.md
//
// Collection data types:
//        map   arr   str   bin  
// mask  0xF0, 0xF0, 0x0E, 0xFF, 
// type  0x80, 0x90, 0xA0, 0xC4, 
//
// Scalar data types:
//                   pf08  nf08   f32   f64   u08   u16   u32   u64   i08   i16   i32   i64
uint8_t mp_mask[] = {0x80, 0xE0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00};
uint8_t mp_type[] = {0x00, 0xE0, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xD0, 0xD1, 0xD2, 0xD3};
uint8_t mp_len[] =  {0x00, 0x00, 0x04, 0x08, 0x01, 0x02, 0x04, 0x08, 0x01, 0x02, 0x04, 0x08};
int msg_unpack(char *m){
    int bytes = 1;

    // Check for Collections first, then Scalars
    if((*m & 0xF0) == 0x80){ // fixmap (1000:xxxx)
        int objects = 2 * (*m & 0x0F);
        printf("fixmap of %d objects: ", objects);
        while(objects--) bytes += msg_unpack(m+1);
    }else if((*m & 0xF0) == 0x90){ // fixarray (1001:xxxx)
        int objects = (*m & 0x0F);
        printf("fixarray of %d objects: ", objects);
        while(objects--) bytes += msg_unpack(m+1);
    }else if((*m & 0xE0) == 0xA0){ // fixstr (101x:xxxx)
        int len = *m & 0x1F;
        bytes += len;
        printf("fixstr of %d chars: %.*s ", len, len, ++m);
    }else if((*m & 0xFF) == 0xC4){ // binary data
        int len = *++m;
        bytes += len;
        printf("Binary data[%d]: ", len);
        while(len--) printf("%02x ", *++m);
    }else{ // Scalar data types
        uint8_t i = 0;
        for(;mp_mask[i];i++) if((*m & mp_mask[i]) == mp_type[i]) break;
        if(!mp_mask[i]){ printf("MsgPack decode failed!"); return 0; }
        bytes += mp_len[i];
        switch(mp_type[i]){
            case 0x00: 
            case 0xE0: printf("I08: %d ", *m); break; // Pos/Neg fixed int
            case 0xCA: printf("F32: %.3f ", *(float*)m++); break;
            case 0xCB: printf("F64: %.3lf ", *(double*)m++); break;
            case 0xCC: printf("U08: %d ", *(uint8_t*)m++); break;
            case 0xCD: printf("U16: %d ", *(uint16_t*)m++); break;
            case 0xCE: printf("U32: %d ", *(uint32_t*)m++); break;
            case 0xCF: printf("U64: %ld ", *(uint64_t*)m++); break;
            case 0xD0: printf("I08: %d ", *(int8_t*)m++); break;
            case 0xD1: printf("I16: %d ", *(int16_t*)m++); break;
            case 0xD2: printf("I32: %d ", *(int32_t*)m++); break;
            case 0xD3: printf("I64: %ld ", *(int64_t*)m++); break;
        }
    }
    return bytes;
}



/* CoAP RFC7252, Observables RFC7641
 * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 * |Ver| T |  TKL  |      Code     |          Message ID           |
 * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 * |   Token (if any, TKL bytes) ...
 * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 * |   Options (if any) ...
 * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 * |1 1 1 1 1 1 1 1|    Payload (if any) ...
 * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 */
#define DBG(...) printf(__VA_ARGS__)
//#define DBG(...)
int coap_unpack(uint8_t *m, uint16_t buf_len, uint8_t *code, char *route){
    uint8_t *p = m; // Set up a running pointer to the message

    DBG("\nCoAP: ");
    // First byte = [VVTTLLLL] Version, Type, Token Length (rfc7252, sec 3)
    uint8_t v = (*p >> 6) & 0x03;                     DBG("Ver[%d] ", v);
    uint8_t t = (*p >> 4) & 0x03;                     DBG("Type[%s] ", t == 0 ? "Con" : t == 1 ? "Non" : t == 2 ? "Ack" : "Rst");
    uint8_t tkl = *p & 0x0F;                          DBG("TKL[%d] ", tkl);
    *code = *++p;                                     DBG("Code[%d] ", *code); // (rfc7252, sec 12.1.1)
    uint16_t msgid = htons(*(uint16_t*)++p); p += 2;  DBG("MsgID[%d] ", msgid); // (rfc7252, sec 3) Network byte order
    if(tkl){ // If there is a token, show it
        DBG("Token: ");
        for(int i = 0; i < tkl; i++)                  DBG("%02x", p[i]);
        p += tkl; 
    }
    
    // Parse CoAP Option Records (rfc7252, sec 3.1)
    uint16_t opt_type = 0;
    uint16_t opt_number = 0;
    while(((p-m) < buf_len) && (*p != 0xFF)){ // While there are more bytes in the buffer, and we haven't hit the Payload Marker
        uint16_t opt_delta = (*p >> 4) & 0x0F;
        uint16_t opt_length = *p++ & 0x0F;
        ++opt_number; // Count the options

        if(opt_delta == 13) opt_delta = 13 + *p++; 
        else if(opt_delta == 14){ opt_delta = 269 + htons(*(uint16_t*)p); p += 2; }
        opt_type += opt_delta; // CoapSharp depends on uint16 rollover to append an observable option at the end of the option list!
        if(opt_type > 15) break;
 
        if(opt_length == 13) opt_length = 13 + *p++; 
        else if(opt_length == 14){ opt_length = 269 + htons(*(uint16_t*)p); p += 2; }
        DBG("\n  Opt[%d] Type[%d] Len[%d] ", opt_number, opt_type, opt_length);

        // Option Types, rfc7252, sec 5.10 and rfc7641 (observable type = 6)        
        if(opt_type == 6){ DBG("Obs[%d]", opt_length ? *p : 0); p += opt_length; } // 0-3 bytes. And 0 bytes implies value = 0!
        else if(opt_type == 7){ DBG("Port[%d]", htons(*(uint16_t*)p)); p += 2; }
        else{ // String types
            DBG("%s[", opt_type == 3 ? "Uri-Host" : opt_type == 11 ? "Uri-Path" : opt_type == 15 ? "Uri-Query" : "Unknown");
            if(opt_type == 11) *route++ = '/';
            for(int i = 0; i < opt_length; i++, p++){
                if(opt_type == 11) *route++ = *p;
                DBG("%c", *p);
            }
            *route = 0; // Null-terminate
            DBG("]");
        }
    }
    return p-m; // Number of bytes in CoAP header
} 



uint8_t cbGroupServerUpdate(void *data){
   printf("\nServerUpdate!\n"); 
   // map[6]: "timestamp":f32, "position":f32[3], "velocity":f32[3], "joint_potition":f32[3], "joint_velocity":f32[3], "grip_force":f32
}

uint8_t cbGroupStatus(void *data){
   printf("\nGroupStatus!\n"); 
   // map[5]: "handedness":u8, "outerlink":u8, "estop":u8, "outerlink_type":u8, "dof":u8[3]
}

uint8_t cbInfoFaults(void *data){
   printf("\nInfoFaults!\n"); 
   // map[3]: "code":u8, "severity":u8, "is_set":u8
}

uint8_t cbInfoFwVersion(void *data){
   printf("\nInfoFwVersion!\n"); 
   // map[3]: "code":u8, "severity":u8, "is_set":u8
}

void registerCoapEndpoints(hash_table_t *coapRoutes){
    uint8_t (*fn)(); // Serves as a handle to each function
    uint32_t sz = sizeof(uint8_t(*)()); // Size of a function pointer
    insert(coapRoutes, "/group/server_update", sz, (fn = cbGroupServerUpdate, &fn));
    insert(coapRoutes, "/group/status", sz, (fn = cbGroupStatus, &fn));
    insert(coapRoutes, "/info/faults", sz, (fn = cbInfoFaults, &fn));
    insert(coapRoutes, "/info/fw_version", sz, (fn = cbInfoFwVersion, &fn));
}

// Driver code
int main(int argc, char **argv) {
    int sockfd;
    char buffer[BUF_SZ];
    char *hello = "Hello from server";
    struct sockaddr_in servaddr, cliaddr;
        
    // Creating socket file descriptor for UDP datagrams
    if ( (sockfd = socket(AF_INET, SOCK_DGRAM, 0)) < 0 ) {
        perror("socket creation failed");
        exit(EXIT_FAILURE);
    }
        
    memset(&servaddr, 0, sizeof(servaddr));
    memset(&cliaddr, 0, sizeof(cliaddr));
        
    // Filling server information
    servaddr.sin_family = AF_INET; // IPv4
    servaddr.sin_addr.s_addr = INADDR_ANY;
    servaddr.sin_port = htons(PORT);
        
    // Bind the socket with the server address
    if ( bind(sockfd, (const struct sockaddr *)&servaddr,
            sizeof(servaddr)) < 0 )
    {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }
     
    hash_table_t *coapRoutes = new_hashtable(101); // Takes function pointers
    registerCoapEndpoints(coapRoutes);
     
    int len = sizeof(cliaddr); //len is value/result
    uint16_t n; // Number of bytes in UDP payload
    uint8_t code; // CoAP message code [1=GET, 2=POST, 3=PUT, 4=DEL]
    char route[32];
    while(1){ 
        // Wait for UDP packet to arrive on the specified PORT
        n = recvfrom(sockfd, (char *)buffer, BUF_SZ,
                MSG_WAITALL, ( struct sockaddr *) &cliaddr, // Capture the client's IP address!
                &len);

        struct sockaddr_in *addr_in = (struct sockaddr_in *)&cliaddr;
        printf("\nUDP packet from: %s", inet_ntoa(addr_in->sin_addr));

        // The payload of the UDP packet is in our buffer
        int b = coap_unpack((uint8_t*)buffer, n, &code, route);
        printf("\n  %s %s", code == 1 ? "GET" : code == 2 ? "POST" : code == 3 ? "PUT" : code == 4 ? "DEL" : "UNK", route);
        if(b < n) printf("\n  MsgPack: ");
        while(b < n){
            b += msg_unpack(&buffer[b]);
        };
        printf("\n");

        // Respond to CoAP packet
        hash_entry_t *he;
        if(he = lookup(coapRoutes, route, NULL)) { // If the route exists in the hashtable
            uint8_t err = ((uint8_t(*)())*(size_t**)he->data)(buffer); // Call the route handler
        }else{
            printf("\nCouldn't find route: %s", route);
        } 
    }
    sendto(sockfd, (const char *)hello, strlen(hello),
        MSG_CONFIRM, (const struct sockaddr *) &cliaddr,
            len);
    printf("Hello message sent.\n");
        
    return 0;
}

