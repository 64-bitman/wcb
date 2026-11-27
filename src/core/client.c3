module wcb::core::client;

import wcb::core::connection @public;
import wcb::core::wire @public;
import wcb::core::table @public;
import wcb::core::types;
import wcb::protocol::client::wayland;

struct WcbDisplay (WcbConnectionImpl{WcbProxy})
{
    inline WlDisplay dpy;

    WcbConnection{WcbProxy} ct;
    Allocator allocator;

    WcbTable{WcbProxy} objects;

    WcbId errid; // If not 0, then display cannot be used now
    uint errcode;
    String errmsg; // Allocated!
}

struct WcbProxy (WcbObjectImpl{WcbProxy})
{
    typeid type;
    WcbId id;
    WcbVersion version;
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
    assert(self.dpy.id == 1);
}

fn void WcbDisplay.uninit(&self)
{
    self.objects.remove(self.dpy.id)!!;

    // TODO output a warning if there are active objects remaining?

    self.ct.uninit();
    self.objects.uninit();
    self.errmsg.free(self.allocator);
}

<*
 @param max_events : "Maximum number of events to dispatch"
 @return "Number of events actually dispatched"
 @return? WcbConnection{WcbProxy}.dispatch!
*>
fn sz? WcbDisplay.dispatch_pending(&self, sz max_events = sz::max)
{
    return self.ct.dispatch(max_events);
}

<*
 @param max_events : "Maximum number of events to dispatch"
 @return "Number of events actually dispatched"
 @return? WcbDisplay.dispatch_pending!, WcbDisplay.flush!
 @return? WcbConnection{WcbProxy}.poll!
*>
fn sz? WcbDisplay.dispatch(&self, sz max_events = sz::max)
{
    sz n_dispatched = self.dispatch_pending(max_events: max_events)!;

    if (n_dispatched > 0) return n_dispatched;

    while (true)
    {
        bool res = self.flush()!;

        if (res) break;

        (void)self.ct.poll({.writable = true})!;
    }

    (void)self.ct.poll({.readable = true})!;

    return self.dispatch_pending(max_events: max_events)!;
}

<*
 Flush pending requests to the server. This function never blocks.

 @return "Return true if all data was written, otherwise false"
 @return? WcbConnection{WcbProxy}.flush!
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
*>
fn sz? WcbDisplay.roundtrip(&self)
{
    WcbCallback callback;

    self.sync(&callback)!;

    sz n_dispatched = 0;

    defer catch {
        if (!callback.got_done) callback.destroy()!!;
    }
    while (!callback.got_done) n_dispatched += self.dispatch()!;

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
    WcbProxy* proxy = (WcbProxy*)message.obj;
    any obj_type = any_make(proxy, proxy.type);
    WcbObject obj = (WcbObject)obj_type;

    return obj.dispatch(message.opcode, message.args);
}

// Handle "wl_display.error" event from server
fn void? WlDisplay.error(&self, WcbId id, uint code, String msg) @dynamic
{
    // Errors are fatal
    self.display.errid = id;
    self.display.errcode = code;
    self.display.errmsg = msg.copy(self.display.allocator);
}

// Handle "wl_display.delete_id" event from server. This allows us to actually
// destroy any proxies (that are zombies).
fn void? WlDisplay.delete_id(&self, uint id) @dynamic
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
 @param [&inout] parent : "Parent/factory proxy of this proxy"
 @param version : "Version to use, otherwise inherit parent version"
 @return? types::DISPLAY_ERROR, WcbTable{WcbProxy}.insert!
*>
fn void? WcbProxy.create(
        &self,
        WcbProxy* parent,
        typeid type,
        WcbVersion version = 0)
{
    if (@unlikely(parent.display.errid != 0)) return types::DISPLAY_ERROR~;

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
 @return? types::DISPLAY_ERROR, WcbTable{WcbProxy}.insert_peer!
*>
fn void? WcbProxy.instantiate(&self, WcbNewId new_id, typeid type)
{
    WcbProxy* parent = (WcbProxy*)new_id.parent;

    if (@unlikely(parent.display.errid != 0)) return types::DISPLAY_ERROR~;

    parent.display.objects.insert_peer(new_id.id, self)!;
    self.type = type;
    self.id = new_id.id;
    self.version = parent.version;
    self.display = parent.display;
}

<*
 @return? types::DISPLAY_ERROR, WcbTable{WcbProxy}.replace!
*>
fn void? WcbProxy.destroy(&self)
{
    if (@unlikely(self.display.errid != 0)) return types::DISPLAY_ERROR~;

    // Don't destroy object immediately, turn it into a zombie and wait for
    // delete_id event.
    WcbObject impl = (WcbObject)any_make(self, self.type);
    self.display.objects.replace(self.id, impl.get_interface(), true)!;
    self.id = 0; // To catch uses of this object after it is destroyed
}

fn typeid WcbProxy.get_type(&self) @dynamic
{
    return self.type;
}

<*
 @param opcode : "Opcode of message to marshal for this proxy"
 @param ... : "Message arguments, first the types then the values"
 @return? types::DISPLAY_ERROR, WcbConnection{WcbProxy}.send!
*>
macro WcbProxy.marshal(&self, WcbHalfWord opcode, ...)
{
    if (@unlikely(self.display.errid != 0)) return types::DISPLAY_ERROR~;

    self.display.ct.send(self.id, opcode, ...$vaarg)!;
}
