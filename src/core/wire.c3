module wcb::core::wire @private;

import wcb::core::types;
import libc;

enum WcbMessageType
{
    EVENT,
    REQUEST
}

enum WcbEntity : char (uint base_id, WcbMessageType incoming_type)
{
    CLIENT {0x1, EVENT},
    SERVER {0xff000000, REQUEST}
}

struct WcbNewId
{
    WcbId id;
    WcbInterface* iface;
}

struct WcbArray
{
    union data
    {
        WcbWord* words;
        char* bytes;
    }
    uint len;  // In bytes
}

union WcbArg
{
    int i;
    uint u;
    WcbFixed f;
    String s;
    WcbObject o;
    WcbNewId n;
    WcbArray a;
    Fd h;
}

struct WcbMessage
{
    WcbObject obj;
    WcbHalfWord opcode;
    WcbArg[] args;
}
