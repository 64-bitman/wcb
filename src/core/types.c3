module wcb::core::types;

import wcb::core::connection;
import std::core::mem::rc;
import std::math;
import libc;

excuse
{
    INVALID_MESSAGE_LENGTH,
    MESSAGE_TOO_LARGE,
    OBJECT_DOES_NOT_EXIST,
    BAD_OPCODE,
    BAD_STRING,
    BAD_OBJECT,
    NULL_ARG,
    OBJECT_EXISTS,
    SHORT_MESSAGE
}

// Wire types
alias WcbWord = uint;
alias WcbHalfWord = ushort;

// Object id
alias WcbId = uint;

// Protocol versioning
alias WcbVersion = uint;

typedef WcbFixed = uint;

enum WcbEntity : char (uint base_id, WcbMessageType incoming_type)
{
    CLIENT { 0x1, EVENT },
    SERVER { 0xff000000, REQUEST },
}

enum WcbMessageType
{
    EVENT,
    REQUEST
}

enum WcbArgType
{
    INT,
    UINT,
    FIXED,
    STRING,
    OBJECT,
    NEW_ID,
    ARRAY,
    FD
}

union WcbArg
{
    int i;
    uint u;
    WcbFixed f;
    String s;
    WcbObject* o;  // May be null
    WcbObject n;
    WcbWord[] a;
    Fd h;
}

bitstruct WcbArgSignature : char
{
    WcbArgType type: 0..3;
    bool nullable: 4;
}

struct WcbMessageDesc
{
    String name;
    WcbVersion since;
    WcbArgSignature[] signature;
    sz n_fd_args;
}

struct WcbInterface
{
    String name;
    WcbVersion version;

    // Events for client, requests for server
    WcbMessageDesc[] messages;
}

interface WcbObjectImpl
{
    fn bool? dispatch(WcbHalfWord opcode, WcbArg[] args) @optional;
    fn WcbInterface* get_interface() @optional;
}

struct WcbObject (WcbObjectImpl)
{
    WcbId id;
    WcbVersion version;

    WcbConnection* ct;
}

<* Convert a fixed point to a double *>
fn double WcbFixed.to_double(self)
{
    return (double)self / 256.0;
}

<* Initialize a fixed point from a double *>
fn void WcbFixed.init_double(&self, double d)
{
    *self = (WcbFixed)math::nearbyint(d * 256.0);
}

<*
 @param opcode : "Opcode of message to lookup"
 @return "Message description object"
 @return? BAD_OPCODE
*>
fn WcbMessageDesc*? WcbInterface.get_message(&self, WcbHalfWord opcode)
{
    if (opcode >= self.messages.len) return BAD_OPCODE~;

    return &self.messages[opcode];
}

<*
 @param [&inout] other : "Other interface to compare to"
 @return "If both interfaces are the same"
*>
fn bool WcbInterface.equal(&self, WcbInterface* other)
{
    return self == other || self.name == other.name;
}
