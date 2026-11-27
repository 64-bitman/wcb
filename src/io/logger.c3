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

    print_log("[%d:%d:%d.%d] -> ", dt.hour, dt.min, dt.sec, dt.usec)!;
    print_log("%s ", info.type.str)!;
    print_log("%s#%d.%s(", info.iface.name, info.obj_id, info.desc.name)!;

    foreach (sig_idx, sig : info.desc.signature)
    {
        if (sig_idx > 0) print_log(", ")!;

        if (sig_idx >= info.args.len) unreachable("Not enough arguments!");

        switch (sig.type)
        {
            case INT:
                print_log("%d", info.args[sig_idx].i)!;
            case UINT:
                print_log("%d", info.args[sig_idx].u)!;
            case FIXED:
                print_log("%lf", info.args[sig_idx].f.to_double())!;
            case STRING:
                if (info.args[sig_idx].s == {})
                {
                    print_log("null")!;
                }
                else
                {
                    print_log("\"%s\"", info.args[sig_idx].s)!;
                }
            case ARRAY:
                print_log("array[%d]", info.args[sig_idx].a.len)!;
            case NEW_ID:
                print_log("new id ")!;
                nextcase OBJECT;
            case OBJECT:
                if (info.desc.arg_interfaces[sig_idx] != null)
                {
                    print_log("%s", info.desc.arg_interfaces[sig_idx].name)!;
                }
                else
                {
                    print_log("unknown")!;
                }
                print_log("#%d", info.args[sig_idx].u)!;
            case FD:
                print_log("fd %d", info.args[sig_idx].h)!;
            default:
                unreachable("Unknown arg type %d!", sig.type);
        }
    }

    print_logn(")")!;
}
