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
    NULL_ARRAY,
    OBJECT_NOT_EXISTS,
    INVALID_NEW_ID,
    BAD_OPCODE,
}

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

bitstruct WcbArgSignature : char
{
    WcbArgType type: 0..3;
    bool nullable: 4;
}

struct WcbMessageDesc
{
    // Name of message
    String name;

    // Minimum version of this message
    WcbVersion since;

    // Signature of arguments
    WcbArgSignature[] signature;

    // Interface of object/new_id arguments in "signature"
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

interface WcbObject
{
    fn bool? dispatch(WcbHalfWord opcode, args...);
    fn WcbInterface* get_interface();
}

interface WcbIOImpl
{
    // Should return a buffer that must stay valid until read_finish() is
    // called. Return an empty slice if there is no data be read (shouldn't
    // block).
    fn WcbWord[]? read();
    // Called when done using the buffer returned by read(). Passed is the
    // number of words consumed.
    fn void read_finish(sz words_consumed);

    // Return a file descriptor, should return -1 if none
    fn Fd? read_fd();
    // Close the file descriptor
    fn void close_fd(Fd fd);
    // Discard "n" file descriptors
    fn void discard_fds(sz n);

    // Write "data" to a buffer, but do not send it to the peer
    fn void write(WcbWord[] data);
    // Write an fd to a buffer, but do not send it to the peer
    fn void write_fd(Fd fd);
    // Flush all pending data and fds to the peer, should return true if data
    // written, and false if would block.
    fn bool? flush();
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
