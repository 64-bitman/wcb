module wcb::core::connection @private;

import wcb::core::types;
import wcb::core::wire @public;
import std::collections::list;
import libc;

interface WcbConnectionImpl
{
    fn WcbId? insert(WcbObject obj);
    fn void remove(WcbId id);
    fn WcbObject? lookup(WcbId id);
    fn bool? dispatch(WcbMessage* message);
}

struct WcbConnection
{
    Allocator allocator;

    WcbConnectionImpl impl;
    WcbIOImpl io;
}

fn void WcbConnection.init(&self, Allocator allocator)
{
    self.allocator = allocator;
}

fn void WcbConnection.set_impl(&self, WcbConnectionImpl impl)
{
    self.impl = impl;
}

fn void WcbConnection.set_io(&self, WcbIOImpl io)
{
    self.io = io;
}

<*
 @param impl : "Implementation to use"
 @param header : "Header of message"
 @param args : "Raw arguments of message"
 @return? types::BAD_OPCODE
*>
fn void? dispatch_message(
    WcbConnectionImpl impl,
    WcbWord[2] header,
    WcbWord[] args)
{

}

<*
 @param max_dispatch : "Maximum number of messages to dispatch, default all"
 @return "Number of messages dispatched"
 @return? WcbIOImpl.read!, dispatch_message!
*>
fn sz? WcbConnection.dispatch(&self, sz max_dispatch = 0)
{
    sz msgs_dispatched = 0;

    while (true)
    {
        char[] buf = self.io.read()!;

        if (buf == {}) break; // No more data to read
    }

    return msgs_dispatched;
}

<*
*>
fn bool? WcbConnection.flush(&self)
{
    return true;
}
