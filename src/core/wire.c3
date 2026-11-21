module wcb::core::wire @private;

import wcb::core::types;
import libc;

struct WcbNewId
{
    WcbId id;
    WcbInterface* iface;
}

union WcbArg
{
    int i;
    uint u;
    WcbFixed f;
    String s;
    WcbObject o;
    WcbNewId n;
    WcbWord[] a;
    Fd h;
}

struct WcbMessage
{
    WcbObject obj;
    WcbHalfWord opcode;
    WcbArg[] args;
}
