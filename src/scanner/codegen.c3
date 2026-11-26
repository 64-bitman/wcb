module wcb::scanner::codegen;

import wcb::scanner;
import wcb::scanner::parser;
import std::collections::set;
import std::io::path;
import std::io::file;
import std::core::string;
import std::io;

bool client = false;
String entity;
String iface_type;
String iface_upper;
String obj_type;
String msg_type;
WaylandMessage[] msgs;
WaylandMessage[] methods;

int tablevel = 0;

macro print(OutStream out, String fmt, args...) @format(1) @local
{
    for (int i = 0; i < tablevel; i++) io::fprint(out, "\t")!;
    io::fprintf(out, fmt, ...args)!;
}

macro printi(OutStream out, String fmt, args...) @format(1) @local
{
    io::fprintf(out, fmt, ...args)!;
}

macro printni(OutStream out, String fmt, args...) @format(1) @local
{
    printi(out, fmt, ...args)!;
    io::fprintfn(out, "");
}

macro printn(OutStream out, String fmt, args...) @format(1) @local
{
    print(out, fmt, ...args)!;
    io::fprintfn(out, "");
}

fn String get_type(String str) @local
{
    return str.snake_to_pascal_copy(tmem);
}

fn void? print_constsets(OutStream out, WaylandInterface* iface) @local
{
    foreach (&enumr : iface.enums)
    {
        String ename = enumr.name.snake_to_pascal_copy(tmem);
        printn(out, "constset %s%s", iface_type, ename)!;
        printn(out, "{")!;

        tablevel++;

        foreach (&entry : enumr.entries)
        {
            String entry_name = entry.name.to_upper_tcopy();

            // If first char is a digit (e.g. in wl_output_transform),
            // prefix with enum name.
            if (entry_name[0].is_digit())
            {
                printn(out, "%s_%s = %d,",
                        ename.to_upper_tcopy(), entry_name, entry.value)!;
            }
            else
            {
                printn(out, "%s = %d,", entry_name, entry.value)!;
            }
        }

        tablevel--;

        printn(out, "}")!;
        printn(out, "")!;
    }
}

fn void? print_types(OutStream out, WaylandInterface* iface) @local
{
    printn(out, "typedef %s (WcbObject, %s%s) = %s;",
            iface_type, iface_type, msg_type, obj_type)!;
    printn(out, "typedef %sId = WcbNewId;", iface_type)!;
    printn(out, "")!;

    if (methods.len > 0)
    {
        // Print opcode enums (not for incoming messages)
        printn(out, "enum %sOpcode : WcbHalfWord", iface_type)!;
        printn(out, "{")!;
        tablevel++;

        foreach (&method : methods)
        {
            printn(out, "%s,", method.name.to_upper_tcopy())!;
        }

        tablevel--;
        printn(out, "}")!;
        printn(out, "")!;
    }

    printn(out, "interface %s%s", iface_type, msg_type)!;
    printn(out, "{")!;
    tablevel++;

    // Print messages
    foreach (&msg : msgs)
    {
        print(out, "fn void %s(", msg.name)!;

        // Print arguments
        foreach (arg_idx, &arg : msg.args)
        {
            if (arg_idx > 0) printi(out, ", ")!;
            switch (arg.type)
            {
                case "int":
                    // Add underscore to prevent keyword conflicts
                    printi(out, "int _%s", arg.name)!;
                case "uint":
                    printi(out, "uint _%s", arg.name)!;
                case "fixed":
                    printi(out, "double _%s", arg.name)!;
                case "string":
                    printi(out, "String _%s", arg.name)!;
                case "array":
                    printi(out, "char[] _%s", arg.name)!;
                case "fd":
                    printi(out, "Fd _%s", arg.name)!;
                case "object":
                    if (arg.iface == "")
                    {
                        // wl_display.error
                        printi(out, "WcbId _%s", arg.name)!;
                        break;
                    }
                    printi(out, "%s* _%s", get_type(arg.iface), arg.name)!;
                    break;
                case "new_id":
                    if (arg.iface == "")
                    {
                        // Special case for wl_registry.bind
                        printi(out, "String iface, WcbVersion version")!;
                        break;
                    }
                    printi(out, "%sId _%s", get_type(arg.iface), arg.name)!;
            }
        }

        printni(out, ") @optional;")!;
    }

    tablevel--;
    printn(out, "}")!;
    printn(out, "")!;
}

fn void? print_interface_struct(OutStream out, WaylandInterface* iface) @local
{
    printn(out, "const WcbInterface %s_INTERFACE = {", iface_upper)!;
    tablevel++;

    printn(out, ".name = \"%s\",", iface.name)!;
    printn(out, ".version = %d,", iface.version)!;
    printn(out, ".messages = {")!;
    tablevel++;

    // Print incoming message definitions
    foreach (&msg : msgs)
    {
        printn(out, "{")!;
        tablevel++;

        printn(out, ".name = \"%s\",", msg.name)!;
        printn(out, ".since = %d,", msg.since)!;
        printn(out, ".signature = {")!;
        tablevel++;

        sz n_fd_args = 0;

        foreach (&arg : msg.args)
        {
            print(out, "{.type = ")!;

            switch (arg.type)
            {
                case "int":
                    printi(out, "INT")!;
                case "uint":
                    printi(out, "UINT")!;
                case "fixed":
                    printi(out, "FIXED")!;
                case "string":
                    printi(out, "STRING")!;
                case "array":
                    printi(out, "ARRAY")!;
                case "fd":
                    printi(out, "FD")!;
                    n_fd_args++;
                case "object":
                    if (arg.iface == "")
                    {
                        // wl_display.error
                        printi(out, "UINT")!;
                        break;
                    }
                    printi(out, "OBJECT")!;
                case "new_id":
                    if (arg.iface == "")
                    {
                        // Special case for wl_registry.bind
                        printni(out, "STRING, .nullable = false},")!;
                        print(out, "{.type = UINT")!;
                        break;
                    }
                    printi(out, "NEW_ID")!;
            }

            printni(out, ", .nullable = %s},", arg.allow_null ? "true" : "false")!;
        }

        tablevel--;
        printn(out, "},")!;
        print(out, ".arg_interfaces = {")!;
        foreach (arg_idx, &arg : msg.args)
        {
            if (arg_idx > 0) printi(out, ", ")!;

            if (arg.type == "object")
            {
                if (arg.iface != "")
                {
                    printi(out, "&%s_INTERFACE", arg.iface.to_upper_tcopy())!;
                    continue;
                }
            }
            else if (arg.type == "new_id")
            {
                if (arg.iface == "")
                {
                    printi(out, "null, null")!;
                    continue;
                }
                else
                {
                    printi(out, "&%s_INTERFACE", arg.iface.to_upper_tcopy())!;
                    continue;
                }
            }
            printi(out, "null")!;
        }
        printni(out, "},")!;
        printn(out, ".n_fd_args = %d", n_fd_args)!;

        tablevel--;
        printn(out, "},")!;
    }

    tablevel--;
    printn(out, "}")!;

    tablevel--;
    printn(out, "};")!;
    printn(out, "")!;
}

fn void? print_dispatch(OutStream out, WaylandInterface* iface) @local
{
    print(out, "fn bool? %s.dispatch(&self, WcbHalfWord opcode, WcbArg[] args)",
            iface_type)!;
    printni(out, " @dynamic")!;
    printn(out, "{")!;
    tablevel++;

    printn(out, "%s%s impl = self;", iface_type, msg_type)!;
    printn(out, "switch (opcode)")!;
    printn(out, "{")!;
    tablevel++;

    foreach (opcode, &msg : msgs)
    {
        printn(out, "case %d:", opcode)!;
        tablevel++;

        printn(out, "if (&impl.%s)", msg.name)!;
        printn(out, "{")!;
        tablevel++;

        print(out, "impl.%s(", msg.name)!;

        // Print arguments
        foreach (arg_idx, &arg : msg.args)
        {
            if (arg_idx > 0) printi(out, ", ")!;
            switch (arg.type)
            {
                case "int":
                    printi(out, "args[%d].i", arg_idx)!;
                case "uint":
                    printi(out, "args[%d].u", arg_idx)!;
                case "fixed":
                    printi(out, "args[%d].f.to_double()", arg_idx)!;
                case "string":
                    printi(out, "args[%d].s", arg_idx)!;
                case "array":
                    printi(out, "args[%d].a", arg_idx)!;
                case "fd":
                    printi(out, "args[%d].h", arg_idx)!;
                case "object":
                    if (arg.iface == "")
                    {
                        // No interface, default to id type (wl_display.error)
                        printi(out, "args[%d].u", arg_idx)!;
                        break;
                    }
                    printi(out, "(%s*)args[%d].o", get_type(arg.iface), arg_idx)!;
                case "new_id":
                    if (arg.iface == "")
                    {
                        // Special case for wl_registry.bind
                        printi(out, "args[%d].s, args[%d].u",
                                arg_idx, arg_idx + 1)!;
                        break;
                    }
                    printi(out, "(%sId)args[%d].n", get_type(arg.iface), arg_idx)!;
            }
        }

        printni(out, ");")!;
        printn(out, "return true;")!;
        tablevel--;

        printn(out, "}")!;
        tablevel--;
    }

    tablevel--;
    printn(out, "}")!;
    printn(out, "return false;")!;

    tablevel--;
    printn(out, "}")!;
    printn(out, "")!;
}

fn void? print_get_interface(OutStream out, WaylandInterface* iface) @local
{
    printn(out, "fn WcbInterface* %s.get_interface(&self) @dynamic", iface_type)!;
    printn(out, "{")!;
    tablevel++;

    printn(out, "return &%s_INTERFACE;", iface_upper)!;

    tablevel--;
    printn(out, "}")!;
    printn(out, "")!;
}

fn void? print_instantiate(OutStream out, WaylandInterface* iface) @local
{
    printn(out, "fn void %s.instantiate(&self, %sId new_id) @inline",
            iface_type, iface_type)!;
    printn(out, "{")!;
    tablevel++;
    printn(out, "((%s*)self).instantiate((WcbNewId)new_id, %s::typeid)!!;",
            obj_type, iface_type)!;
    tablevel--;
    printn(out, "}")!;
    printn(out, "")!;
}

fn void? print_methods(OutStream out, WaylandInterface* iface) @local
{
    bool has_destroy = false;

    foreach (&method : methods)
    {
        print(out, "fn void %s.%s(&self", iface_type, method.name)!;

        bool is_registry_bind = false;
        WaylandArg* constructor = null;
        bool is_destructor = method.type == "destructor";

        if (is_destructor) has_destroy = true;

        // Print parameters
        foreach (&arg : method.args)
        {
            printi(out, ", ")!;
            switch (arg.type)
            {
                case "int":
                    printi(out, "int _%s", arg.name)!;
                case "uint":
                    printi(out, "uint _%s", arg.name)!;
                case "fixed":
                    printi(out, "double _%s", arg.name)!;
                case "string":
                    printi(out, "String _%s", arg.name)!;
                case "array":
                    printi(out, "char[] _%s", arg.name)!;
                case "fd":
                    printi(out, "Fd _%s", arg.name)!;
                case "object":
                    if (arg.iface == "")
                    {
                        // wl_display.error
                        printi(out, "WcbId _%s", arg.name)!;
                        break;
                    }
                    printi(out, "%s* _%s", get_type(arg.iface), arg.name)!;
                case "new_id":
                    constructor = arg;
                    if (arg.iface == "")
                    {
                        // Special case for wl_registry.bind
                        printi(out, "%s* obj, WcbVersion version", obj_type)!;
                        is_registry_bind = true;
                        break;
                    }
                    printi(out, "%s* _%s", get_type(arg.iface), arg.name)!;
            }
        }

        printni(out, ") @inline")!;
        printn(out, "{")!;
        tablevel++;

        if (constructor != null)
        {
            if (is_registry_bind)
            {
                print(out, "obj.instantiate({_name, (WcbObject)self}, ")!;
                printni(out, "%s::typeid)!!;", iface_type)!;
            }
            else
            {
                print(out, "((%s*)_%s).create(", obj_type, constructor.name)!;
                printni(out, "(%s*)self, %s::typeid)!!;", obj_type,
                        get_type(constructor.iface))!;
            }
        }

        print(out, "((%s*)self).marshal(%sOpcode.%s.ordinal", obj_type,
                iface_type, method.name.to_upper_tcopy())!;

        foreach (arg : method.args)
        {
            if (arg.type == "new_id" && arg.iface == "")
            {
                // Special case for wl_registry.bind
                printi(out, ", WcbArgType.STRING, WcbArgType.UINT")!;
                continue;
            }
            printi(out, ", WcbArgType.%s", arg.type.to_upper_tcopy())!;
        }

        foreach (arg : method.args)
        {
            printi(out, ", ")!;

            if (arg.type == "new_id")
            {
                if (arg.iface == "")
                {
                    // wl_registry.bind
                    printi(out, "((WcbObject)obj).get_interface().name, version")!;
                }
                else
                {
                    printi(out, "_%s.id", arg.name)!;
                }
                continue;
            }
            if (arg.type == "object")
            {
                printi(out, "_%s.id", arg.name)!;
                continue;
            }
            printi(out, "_%s", arg.name)!;
        }

        printni(out, ")!!;")!;

        if (is_destructor)
        {
            printn(out, "((%s*)self).destroy()!!;", obj_type)!;
        }

        tablevel--;
        printn(out, "}")!;
        printn(out, "")!;
    }

    if (!has_destroy && iface.name != "wl_display")
    {
        // Implicitly add a destroy func (e.g. for wl_registry)
        printn(out, "fn void %s.destroy(&self)", iface_type)!;
        printn(out, "{")!;
        tablevel++;
        printn(out, "((%s*)self).destroy()!!;", obj_type)!;
        tablevel--;
        printn(out, "}")!;
        printn(out, "")!;
    }
}

// Generate C3 code, yay!
fn void? generate_code(
    WaylandProtocol* protocol,
    String module_prefix,
    Path out_file,
    bool is_client,
) => @pool()
{
    File? fp = file::open_path(out_file, "w");

    OutStream? out = out = &fp;

    if (catch err = out)
    {
        io::eprintfn("Error opening file '%s' for writing: %s", out_file, err);
        return err~;
    }

    client = is_client;
    entity = is_client ? "client" : "server";
    obj_type = is_client ? "WcbProxy" : "WcbResource";

    defer (void)fp.close();

    printn(out, "// Generated by wcb_scanner %s", scanner::VERSION)!;
    printn(out, "module %s::%s::%s;", module_prefix, entity, protocol.name)!;
    printn(out, "")!;

    if (module_prefix != "wcb::protocol")
    {
        printn(out, "import %s::%s;", module_prefix, entity)!;
        printn(out, "import wcb::protocol::%s::wayland;", entity)!;
    }

    printn(out, "import wcb::core::%s;", entity)!;
    printn(out, "import wcb::core::types;")!;
    printn(out, "import libc;")!;
    printn(out, "")!;


    foreach (&iface : protocol.interfaces)
    {
        iface_type = iface.name.snake_to_pascal_copy(tmem);
        iface_upper = iface.name.to_upper_tcopy();
        msg_type = client ? "Events" : "Requests";
        msgs = client ? iface.events : iface.requests;
        methods = client ? iface.requests : iface.events;

        print_constsets(out, iface)!;
        print_types(out, iface)!;
        print_interface_struct(out, iface)!;
        print_dispatch(out, iface)!;
        print_get_interface(out, iface)!;
        print_instantiate(out, iface)!;
        print_methods(out, iface)!;
    }
}
