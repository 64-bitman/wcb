module wcb::examples::list_globals;

import wcb::core::client;
import wcb::protocol::client;
import wcb::io::socket;
import std::net::os;
import std::io;
import libc;

fn void WlRegistry.global(&self, uint name, String iface, uint version) @dynamic
{
    io::printfn("%s#%d version %d", iface, name, version);
}

fn int main(String[] cmdargs)
{
    WcbDisplay display;
    WcbSocketIO io;

    io.init({}, mem)!!;
    display.init(&io, mem);
    defer display.uninit();

    WlRegistry registry;

    display.get_registry(&registry);

    display.dispatch()!!;
    registry.destroy();

    return 0;
}
