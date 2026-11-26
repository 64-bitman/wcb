module wcb::core::server;

import wcb::core::connection @public;
import wcb::core::wire @public;
import wcb::core::table @public;
import wcb::core::types;

struct WcbResource (WcbObject)
{
    WcbId id;
}

fn bool? WcbResource.dispatch(&self, WcbHalfWord opcode, WcbArg[] args) @dynamic
{
    // Not handled
    return false;
}

fn WcbInterface* WcbResource.get_interface(&self) @dynamic
{
    abort("WcbProxy %p does not have an interface!", self);
}
