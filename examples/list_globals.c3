module wcb::examples::list_globals;

import wcb::core::client;
import wcb::protocol::client;
import wcb::io::socket;
import std::net::os;
import std::io;
import libc;

WlShmPool pool;

fn void? WlRegistry.global(&self, uint name, String iface, uint version) @dynamic
{
    io::printfn("%s#%d version %d", iface, name, version);

    if (iface == client::wayland::WL_SHM_POOL_INTERFACE.name)
    {
        self.bind(name, (WcbProxy*)&pool, version)!!;
    }
}

fn int main(String[] cmdargs)
{
    WcbDisplay display;
    WcbSocketIO io;

    io.init({}, mem)!!;
    display.init(&io, mem);
    defer display.uninit();

    WlRegistry registry;

    display.get_registry(&registry)!!;

    display.roundtrip()!!;
    registry.destroy()!!;

    return 0;
}
