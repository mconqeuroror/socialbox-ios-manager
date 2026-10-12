#pragma once
// Own byte-record declarations for the pinned Apple xnu-8796.141.3 public ABI.
// tools/test_pf_kernel_abi.py validates every consumed offset and ioctl against
// separately acquired, hash-pinned Apple headers on host and arm64-iOS.
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>

typedef struct { uint8_t bytes[1040]; } RBXPFRuleImage;
typedef struct { uint8_t bytes[3104]; } RBXPFRuleRequest;
typedef struct { uint8_t bytes[440]; } RBXPFStatusRequest;
typedef struct { uint8_t bytes[1092]; } RBXPFAnchorRequest;
typedef struct { uint8_t bytes[1136]; } RBXPFPoolRequest;
typedef struct { uint8_t bytes[168]; } RBXPFInterfaceImage;
typedef struct { char name[16]; void *buffer; int32_t elementSize, count, nzero, flags; } RBXPFInterfaceRequest;
typedef struct { int32_t length; uint32_t padding; void *buffer; } RBXPFStatesRequest;

#define RBXPF_GET_STATUS _IOWR('D',21,RBXPFStatusRequest)
#define RBXPF_GET_RULES _IOWR('D',6,RBXPFRuleRequest)
#define RBXPF_GET_RULE _IOWR('D',7,RBXPFRuleRequest)
#define RBXPF_GET_ANCHORS _IOWR('D',58,RBXPFAnchorRequest)
#define RBXPF_GET_POOL _IOWR('D',53,RBXPFPoolRequest)
#define RBXPF_GET_INTERFACES _IOWR('D',87,RBXPFInterfaceRequest)
#define RBXPF_GET_STATES _IOWR('D',25,RBXPFStatesRequest)
enum { RBXPF_RULE_OFFSET=2064, RBXPF_SKIP_FLAG=0x100, RBXPF_MAX_INTERFACES=256 };
enum {
    RBXPFRuleDestination=64, RBXPFRuleDestinationMask=80,
    RBXPFRuleDestinationPortLow=112, RBXPFRuleDestinationPortHigh=114,
    RBXPFRuleDestinationPortOp=116, RBXPFRuleSkip=128, RBXPFRuleLabel=192,
    RBXPFRulePoolFamily=642, RBXPFRuleCounters=648, RBXPFRuleOwner=696,
    RBXPFRuleStates=904, RBXPFRuleSourceNodes=912, RBXPFRuleNumber=948,
    RBXPFRuleCreatorUID=956, RBXPFRuleCreatorPID=960,
    RBXPFRuleAction=1004, RBXPFRuleDirection=1005, RBXPFRuleQuick=1008,
    RBXPFRuleKeepState=1012, RBXPFRuleFamily=1013, RBXPFRuleProtocol=1014,
    RBXPFRuleTCPFlags=1017, RBXPFRuleTCPFlagMask=1018,
    RBXPFRequestAction=0, RBXPFRequestTicket=4, RBXPFRequestNumber=12,
    RBXPFRequestAnchorCall=1040,
    RBXPFStatusRunning=376, RBXPFStatusStates=380,
    RBXPFStatusSourceNodes=384, RBXPFStatusChecksum=424,
    RBXPFPoolTicket=4, RBXPFPoolCount=8, RBXPFPoolRuleNumber=12, RBXPFPoolAction=16,
    RBXPFInterfaceFlags=152, RBXPFStateSize=297,
    RBXPFPass=0, RBXPFDrop=1, RBXPFScrub=2, RBXPFNat=4, RBXPFBinat=6,
    RBXPFRdr=8, RBXPFDummynet=11, RBXPFOut=2, RBXPFEqual=2,
    RBXPFKeepState=1, RBXPFTcpSyn=2, RBXPFTcpAck=0x10
};
_Static_assert(sizeof(void *)==8,"64-bit ABI required");
_Static_assert(__BYTE_ORDER__==__ORDER_LITTLE_ENDIAN__,"little-endian ABI required");
_Static_assert(sizeof(RBXPFInterfaceRequest)==40,"interface ABI");
_Static_assert(offsetof(RBXPFInterfaceRequest,buffer)==16,"interface pointer ABI");
_Static_assert(sizeof(RBXPFStatesRequest)==16,"states ABI");
static inline uint32_t RBXPFU32(const void *bytes,size_t offset) { uint32_t v; memcpy(&v,(const uint8_t *)bytes+offset,4); return v; }
static inline void RBXPFPut32(void *bytes,size_t offset,uint32_t v) { memcpy((uint8_t *)bytes+offset,&v,4); }
