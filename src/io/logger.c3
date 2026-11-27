module wcb::io::logger;

import wcb::core::types;
import std::io;
import std::time::datetime;
import libc;

extern fn void flockfile(CFile* filehandle) @cname("flockfile") @local;
extern fn void funlockfile(CFile* filehandle) @cname("funlockfile") @local;

enum WcbDebugState : char (bool val) @local
{
    AUTO {false},
    ENABLED {true},
    DISABLED {false}
}

struct WcbDebug (WcbLogger)
{
    bool enabled;
}

fn void WcbDebug.init(&self, WcbDebugState state = AUTO)
{
    if (state == AUTO)
    {
        ZString debug = libc::getenv("WAYLAND_DEBUG");

        if (debug != null) state = ENABLED;
    }

    self.enabled = state.val;
}

macro print_log(String fmt, ...) @local
{
    io::fprintf(io::stderr(), fmt, ...$vaarg)!;
}

macro print_logn(String fmt, ...) @local
{
    print_log(fmt, ...$vaarg)!;
    io::fprintfn(io::stderr(), "")!;
}

fn bool WcbDebug.is_enabled(&self) @dynamic
{
    return self.enabled;
}

fn void? WcbDebug.log(&self, WcbLog* info) @dynamic
{
    if (!self.enabled) return;

    flockfile(io::stderr().file);
    defer funlockfile(io::stderr().file);

    DateTime dt = datetime::now();
    String desc_name = info.desc == null ? info.desc_name : info.desc.name;

    print_log("[%d:%d:%d.%d] -> ", dt.hour, dt.min, dt.sec, dt.usec)!;
    print_log("%s ", info.type.str)!;
    print_log("%s#%d.%s(", info.iface.name, info.obj_id, desc_name)!;
    print_logn("")!;
}
