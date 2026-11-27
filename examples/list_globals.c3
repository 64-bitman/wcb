module wcb::examples::list_globals;

import wcb::core::client;
import wcb::core::types;
import wcb::protocol::client;
import wcb::io::socket;
import std::net::os;
import std::io;
import libc;

WlShm shm;
WlShmPool pool;

fn void? WlRegistry.global(&self, uint name, String iface, uint version) @dynamic
{
    io::printfn("%s#%d version %d", iface, name, version);

    if (iface == client::wayland::WL_SHM_INTERFACE.name)
    {
        self.bind(name, &shm, version)!!;
        shm.create_pool(&pool, 200, 100)!!;
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

    if (catch err = display.roundtrip())
    {
        if (err == types::DISPLAY_ERROR)
        {
            io::printfn("%s", display.errmsg);
        }
        err~!!;
    }
    if (catch err = display.roundtrip())
    {
        if (err == types::DISPLAY_ERROR)
        {
            io::printfn("%s", display.errmsg);
        }
        err~!!;
    }

    registry.destroy()!!;

    return 0;
}
