module wcb::core::client;

import wcb::core::connection @public;
import wcb::core::wire @public;
import wcb::core::table @public;
import wcb::core::types;
import wcb::protocol::client::wayland;
import libc;

alias WcbProxyConnection @local = WcbConnection{WcbProxy, WcbMessageType.EVENT};
alias WcbProxyTable @local = WcbTable{WcbProxy};

struct WcbDisplay (WcbConnectionImpl
    {
        WcbProxy, WcbMessageType.EVENT
    }

)
{
    inline WlDisplay dpy;

    WcbProxyConnection ct;
    Allocator allocator;

    WcbProxyTable objects;

    WcbId errid;  // If not 0, then display cannot be used now
    uint errcode;
    String errmsg;  // Allocated!
}

struct WcbProxy
{
    inline WcbObjectBase{WcbProxy, WcbMessageType.EVENT} base;
    WcbDisplay* display;
}

struct WcbCallback @local
{
    inline WlCallback base;
    bool got_done;
}

<*
@param [&inout] io : "IO implementation to use"
@param [&inout] allocator : "Allocator to use"
    *>
fn void WcbDisplay.init(&self, WcbIOImpl io, Allocator allocator)
{
    self.allocator = allocator;
    self.ct.init(self, io, allocator);
    self.objects.init(CLIENT, allocator);

    self.errid = 0;
    self.errmsg = {};

    self.display = self;
    // Shouldn't fail
    ((WcbProxy*)self).create((WcbProxy*)self, WcbDisplay::typeid, 1)!!;
    assert(self.dpy.base.id == 1);
}

fn void WcbDisplay.uninit(&self)
{
    self.objects.remove(self.dpy.base.id)!!;

    // TODO output a warning if there are active objects remaining?

    self.ct.uninit();
    self.objects.uninit();
    self.errmsg.free(self.allocator);
}

<*
 @param [&inout] logger : "Logger to use"
*>
fn void WcbDisplay.set_logger(&self, WcbLogger logger)
{
    self.ct.set_logger(logger);
}

<*
 Get information about the error for this display (if any). Return an empty
 string if none.

 @param [out] obj_id : "Object id for error"
 @param [out] errcode : "Error code"
 @return "Error message as received by the server"
*>
fn String WcbDisplay.get_error(&self, WcbId* obj_id, uint* errcode)
{
    if (self.errid == 0) return "";

    if (obj_id != null) * obj_id = self.errid;
    if (errcode != null) * errcode = self.errcode;

    return self.errmsg;
}

<*
 Dispatch any pending events waiting on the socket. This does not block waiting
 for input.

 @param max_events : "Maximum number of events to dispatch"
 @return "Number of events actually dispatched"
 @return? WcbProxyConnection.dispatch!
*>
fn sz? WcbDisplay.dispatch_pending(&self, sz max_events = sz::max)
{
    return self.ct.dispatch(max_events);
}

<*
 Same as dispatch_pending() but block for input if necessary.

 @param max_events : "Maximum number of events to dispatch"
 @return "Number of events actually dispatched"
 @return? WcbDisplay.dispatch_pending!, WcbDisplay.flush!
 @return? WcbProxyConnection.poll!
*>
fn sz? WcbDisplay.dispatch(&self, sz max_events = sz::max)
{
    sz n_dispatched = self.dispatch_pending(max_events: max_events)!;

    if (n_dispatched > 0) return n_dispatched;

    while (true)
    {
        bool res = self.flush()!;

        if (res) break;

        (void)self.ct.poll(
            {
                .writable = true
            }
        )!;
    }

    (void)self.ct.poll(
        {
            .readable = true
        }
    )!;

    return self.dispatch_pending(max_events: max_events)!;
}

<*
 Flush pending requests to the server. This function never blocks.

 @return "Return true if all data was written, otherwise false"
 @return? WcbProxyConnection.flush!
*>
fn bool? WcbDisplay.flush(&self)
{
    return self.ct.flush();
}

fn void? WcbCallback.done(&self, uint data @unused) @dynamic
{
    self.got_done = true;
    self.destroy()!;
}

<*
 Do a roundtrip by sending a wl_display.sync request and waiting for the
 wl_callback event.

 @return "Number of events dispatched"
 @return? types::DISPLAY_ERROR, WcbDisplay.dispatch!, WcbProxy.destroy!
*>
fn sz? WcbDisplay.roundtrip(&self)
{
    WcbCallback callback;

    self.sync(&callback)!;

    sz n_dispatched = 0;

    defer catch
    {
        if (!callback.got_done)(void)callback.destroy()!!;
    }
    while (self.errid == 0 && !callback.got_done) n_dispatched += self.dispatch()!;

    if (self.errid != 0) return types::DISPLAY_ERROR~;

    return n_dispatched;
}

fn any? WcbDisplay.lookup(&self, WcbId id) @dynamic
{
    bool flag = false;
    void* ptr = self.objects.lookup(id, &flag)!;

    // If flag is set, then proxy is a zombie.
    if (flag) return (WcbInterface*)ptr;

    return (WcbProxy*)ptr;
}

fn bool? WcbDisplay.handle(&self, WcbMessage* message) @dynamic
{
    // Cast the proxy to the actual type that implements the method.
    WcbProxy* proxy = (WcbProxy*)message.obj;
    any obj_type = any_make(proxy, proxy.type);
    WcbObject obj = (WcbObject)obj_type;

    return obj.dispatch(message.opcode, message.args);
}

// Handle "wl_display.error" event from server
fn void? WcbDisplay.error(&self, WcbId id, uint code, String msg) @dynamic
{
    // Errors are fatal
    self.display.errid = id;
    self.display.errcode = code;
    self.display.errmsg = msg.copy(self.display.allocator);
}

// Handle "wl_display.delete_id" event from server. This allows us to actually
// destroy any proxies (that are zombies).
fn void? WcbDisplay.delete_id(&self, uint id) @dynamic
{
    WcbDisplay* display = (WcbDisplay*)self;
    bool flag = false;
    void* ptr @unused = display.objects.lookup(id, &flag)!;

    // If flag is not set, then proxy is therefore not a zombie. This shouldn't
    // happen.
    if (@unlikely(!flag)) return types::OBJECT_NOT_DESTROYED~;

    self.display.objects.remove(id)!;
}

<*
 Initialize the proxy and allocate an id for it.

 @param [&inout] parent : "Parent/factory proxy of this proxy"
 @param version : "Version to use, otherwise inherit parent version"
 @return? WcbProxyTable.insert!
*>
fn void? WcbProxy.create(
    &self,
    WcbProxy* parent,
    typeid type,
    WcbVersion version = 0)
{
    self.type = type;
    self.id = parent.display.objects.insert(self)!;
    if (version == 0)
    {
        self.version = parent.version;
    }
    else
    {
        self.version = version;
    }
    self.display = parent.display;
}

<*
 @param new_id : "New id of proxy to instantiate"
 @return? WcbProxyTable.insert_peer!
*>
fn void? WcbProxy.instantiate(&self, WcbNewId new_id, typeid type)
{
    WcbProxy* parent = (WcbProxy*)new_id.parent;

    parent.display.objects.insert_peer(new_id.id, self)!;
    self.type = type;
    self.id = new_id.id;
    self.version = parent.version;
    self.display = parent.display;
}

<*
 Destroy the proxy, it should not be used after

 @return? WcbProxyTable.replace!
*>
fn void? WcbProxy.destroy(&self)
{
    // Don't destroy object immediately, turn it into a zombie and wait for
    // delete_id event.
    WcbObject impl = (WcbObject)any_make(self, self.type);
    self.display.objects.replace(self.id, impl.get_interface(), true)!;
    self.id = 0;  // To catch uses of this object after it is destroyed
}

<*
 Marshal a message for the proxy

 @param opcode : "Opcode of message to marshal for this proxy"
 @param name : "Name of message"
 @param ... : "Message arguments, first the types then the values"
 @return? WcbProxyConnection.send!
*>
macro WcbProxy.marshal(&self, WcbHalfWord opcode, String name, ...)
{
    self.display.ct.send(self.id, opcode, ...$vaarg)!;

    if (self.display.ct.logger != null && self.display.ct.logger.is_enabled())
    {
        WcbObject impl = (WcbObject)any_make(self, self.type);
        WcbInterface* iface = impl.get_interface();
        WcbArg[types::MESSAGE_MAX_ARGS] args;

        var $n_args = $vaarg.len / 2;

        $for var $i = 0; $i < $n_args; $i++:
            $switch ($vaarg[$i]):
                $case WcbArgType.INT:
                $case WcbArgType.UINT:
                $case WcbArgType.FIXED:
                $case WcbArgType.OBJECT:
                $case WcbArgType.NEW_ID:
                    args[$i].u = (WcbWord)$vaarg[$n_args + $i];
                $case WcbArgType.STRING:
                    args[$i].s = (String)$vaarg[$n_args + $i];
                $case WcbArgType.ARRAY:
                    args[$i].a = (char[])$vaarg[$n_args + $i];
                $case WcbArgType.FD:
                    args[$i].h = (Fd)$vaarg[$n_args + $i];
            $endswitch
        $endfor

        self.display.ct.log(impl, self.id, WcbMessageType.REQUEST,
            iface, null, name, opcode, args[:$n_args]);
    }
}
