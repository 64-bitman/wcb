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
    WcbEnv env = {
        .wayland_display = libc::getenv("WAYLAND_DISPLAY").str_view(),
        .xdg_runtime_dir = libc::getenv("XDG_RUNTIME_DIR").str_view(),
    };

    io.init({}, &env, mem)!!;
    display.init(&io, mem);
    defer display.uninit();

    WlRegistry registry;

    display.get_registry(&registry);

    display.flush()!!;

    Posix_pollfd pfd = {
        .fd = io.get_fd(),
        .events = os::POLLIN
    };

    while (true)
    {
        if (os::poll(&pfd, 1, -1) == -1) return 1;
        if (pfd.revents & os::POLLIN) break;
    }

    display.dispatch_events()!!;

    registry.destroy();

    return 0;
}
