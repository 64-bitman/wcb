module wcb::core::wire @private;

import wcb::core::types;
import libc;

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
