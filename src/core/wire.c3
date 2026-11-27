module wcb::core::wire @private;

import wcb::core::types;
import libc;

enum WcbEntity : char (uint base_id, WcbMessageType incoming_type)
{
    CLIENT {0x1, EVENT},
    SERVER {0xff000000, REQUEST}
}

struct WcbMessage
{
    WcbObject obj;
    WcbHalfWord opcode;
    WcbArg[] args;
}
