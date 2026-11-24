module wcb::core::client;

import wcb::core::connection @public;
import wcb::core::wire @public;
import wcb::core::table @public;
import wcb::core::types;

struct WcbHandle (WcbConnectionImpl{WcbProxy})
{
    inline WcbConnection{WcbProxy} ct;
    Allocator allocator;

    WcbTable{WcbProxy} objects;
}

struct WcbProxy (WcbObject)
{
    WcbId id;
    WcbVersion version;
    WcbHandle* handle;
}

fn void WcbHandle.init(&self, WcbIOImpl io, Allocator allocator)
{
    self.allocator = allocator;
    self.ct.init(self, io, allocator);
    self.objects.init(CLIENT, allocator);
}

fn void WcbHandle.uninit(&self)
{
    self.ct.uninit();
    self.objects.uninit();
}

fn any? WcbHandle.lookup(&self, WcbId id) @dynamic
{
    bool flag = false;
    void* ptr = self.objects.lookup(id, &flag)!;

    if (flag) return (WcbInterface*)ptr;

    return (WcbProxy*)ptr;
}

fn bool? WcbHandle.handle(&self, WcbMessage* message) @dynamic
{
    WcbProxy* proxy = (WcbProxy*)message.obj;
    WcbObject obj = proxy;

    return obj.dispatch(message.opcode, message.args);
}

fn bool? WcbProxy.dispatch(&self, WcbHalfWord opcode, WcbArg[] args) @dynamic
{
    // Not handled
    return false;
}

fn WcbInterface* WcbProxy.get_interface(&self) @dynamic
{
    abort("WcbProxy %p does not have an interface!", self);
}

<*
 @param [inout] parent : "Parent/factory proxy of this proxy"
 @param version : "Version to use, otherwise inherit parent version"
 @return? WcbTable{WcbProxy}.insert!
*>
fn void? WcbProxy.create(&self, WcbProxy* parent, WcbVersion version = 0)
{
    self.id = parent.handle.objects.insert(self)!;
    if (version == 0)
    {
        self.version = parent.version;
    }
    else
    {
        self.version = version;
    }
    self.handle = parent.handle;
}

<*
 @param new_id : "New id of proxy to instantiate"
*>
fn void? WcbProxy.instantiate(&self, WcbNewId new_id)
{
    WcbProxy* parent = (WcbProxy*)new_id.parent;
    parent.handle.objects.insert_peer(new_id.id, self)!;
    self.id = new_id.id;
    self.version = parent.version;
    self.handle = parent.handle;
}

<*
 @return? WcbTable{WcbProxy}.replace!
*>
fn void? WcbProxy.destroy(&self)
{
    // Don't destroy object immediately, turn it into a zombie and wait for
    // delete_id event.
    self.handle.objects.replace(self.id, self.get_interface(), true)!;
    self.id = 0; // To catch uses of this object after it is destroyed
}

<*
 @param opcode : "Opcode of message to marshal for this proxy"
 @param ... : "Message arguments, first the types then the values"
 @return? WcbConnection{WcbProxy}.send!
*>
macro WcbProxy.marshal(&self, WcbHalfWord opcode, ...)
{
    self.handle.ct.send(self.id, opcode, ...$vaarg)!;
}
