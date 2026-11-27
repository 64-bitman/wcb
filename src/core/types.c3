module wcb::core::types;

import wcb::core::connection;
import std::math;
import libc;

excuse
{
    INVALID_MESSAGE_LENGTH,
    MESSAGE_TOO_BIG,
    SHORT_MESSAGE,
    EXPECTED_FD,
    INVALID_STRING,
    NULL_OBJECT,
    NULL_STRING,
    OBJECT_NOT_EXISTS,
    INVALID_NEW_ID,
    BAD_OPCODE,
    BAD_OBJECT_ID,
    OBJECT_LIMIT_REACHED,
    DISPLAY_ERROR,
    OBJECT_NOT_DESTROYED
}

const sz MESSAGE_MAX_LEN = 4096;
const uint MESSAGE_MAX_ARGS = 20;
const uint MESSAGE_MAX_FDS = 28; // Taken from libwayalnd

// Wire types
alias WcbWord = uint;
alias WcbHalfWord = ushort;
alias WcbId = uint;
alias WcbVersion = uint;
typedef WcbFixed = uint;

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

enum WcbMessageType : char (String str)
{
    EVENT {"event"},
    REQUEST {"request"}
}

bitstruct WcbIOEvents : char
{
    bool readable: 1;
    bool writable: 2;
}

bitstruct WcbArgSignature : char
{
    WcbArgType type: 0..3;
    bool nullable: 4;
}

struct WcbNewId
{
    WcbId id;
    WcbObject parent;
}

union WcbArg
{
    int i;
    uint u;
    WcbFixed f;
    String s;
    WcbObject o;
    WcbNewId n;
    char[] a;
    Fd h;
}

struct WcbMessageDesc
{
    // Name of message
    String name;

    // Minimum version of this message
    WcbVersion since;

    // Signature of arguments
    WcbArgSignature[] signature;

    // Interfaces of object/new_id arguments in "signature". Other types are
    // marked as null.
    WcbInterface*[] arg_interfaces;

    // Number of fd args in "signature"
    sz n_fd_args;
}

struct WcbInterface
{
    // Name of interface
    String name;

    // Version of interface
    WcbVersion version;

    // Events for client, requests for server
    WcbMessageDesc[] messages;
}

struct WcbLog
{
    WcbObject obj;
    WcbId obj_id;
    WcbMessageType type;
    WcbInterface* iface;
    WcbMessageDesc* desc;
    String desc_name; // Set if "desc" is null
    WcbHalfWord opcode;
    WcbArg[] args;
}

interface WcbObject
{
    fn bool? dispatch(WcbHalfWord opcode, WcbArg[] args);
    fn WcbInterface* get_interface();
}

interface WcbIOImpl
{
    // Should not block
    fn sz? read(char[] buf);

    fn Fd? read_fd(sz n_discard = 0, Fd close = -1);

    fn void write(char[] data, Fd fd = -1);
    fn bool? flush();

    fn WcbIOEvents? poll(WcbIOEvents events);
    fn Fd? dup_fd(Fd fd);
    fn void destroy() @optional;
}

interface WcbLogger
{
    fn bool is_enabled();
    fn void? log(WcbLog* info);
}

<* Convert a fixed point to a double *>
fn double WcbFixed.to_double(self)
{
    return (double)self / 256.0;
}

<* Get a fixed point from a double *>
fn WcbFixed double.to_fixed(self)
{
    return (WcbFixed)math::nearbyint(self * 256.0);
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
