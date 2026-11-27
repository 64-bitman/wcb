module wcb::examples::list_globals;

import wcb::core::client;
import wcb::core::types;
import wcb::protocol::client;
import wcb::io::logger;
import wcb::io::socket;
import std::net::os;
import std::io;
import libc;

WlShm shm;
WlShmPool pool;

fn void? WlRegistry.global(&self, uint name, String iface, uint version) @dynamic
{
    // io::printfn("%s#%d version %d", iface, name, version);
    if (iface == client::wayland::WL_SHM_INTERFACE.name)
    {
        self.bind(name, &shm, version)!!;

        shm.create_pool(&pool, 2, 1000)!!;
    }
}

fn int main(String[] cmdargs)
{
    WcbDisplay display;
    WcbSocketIO io;
    WcbDebug logger;

    io.init({}, mem)!!;
    display.init(&io, mem);
    logger.init();
    display.set_logger(&logger);
    defer display.uninit();

    WlRegistry registry;

    display.get_registry(&registry)!!;

    display.dispatch()!!;
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
