module wcb::scanner::codegen;

import wcb::scanner;
import wcb::scanner::parser;
import std::io::path;
import std::io::file;
import std::core::string;
import std::io;

// Convert "str" into a name suitable for a type
fn String get_type(String str) @local
{
    return str.snake_to_pascal_copy(tmem);
}

fn String get_msg_suffix(bool client) @local
{
    if (client) return "Events";
    return "Requests";
}

// Print typedefs for all externally referenced objects/new_ids (interface from
// a separate protocol).
fn void? print_typedefs(
    OutStream out,
    WaylandInterface[] interfaces,
    bool client
) @local
{
    foreach (&iface : interfaces)
    {
        WaylandMessage[] msgs = client ? iface.events : iface.requests;

        @pool()
        {
            String iface_name = get_type(iface.name);

            foreach (&msg : msgs)
            {
                foreach (&arg : msg.args)
                {
                    if (arg.iface.len > 0)
                    {
                        bool found = false;
                        // Check if interface is from another protocol
                        foreach (&ifacex : interfaces)
                        {
                            if (ifacex.name == iface.name)
                            {
                                found = true;
                                break;
                            }
                        }

                        if (!found)
                        {
                            io::fprintfn(out, "typedef %s = void;", iface_name);
                            io::fprintfn(out, "")!;
                        }
                    }
                }
            }
        };
    }
}

fn void? print_constsets(
    OutStream out,
    WaylandInterface[] interfaces
) @local => @pool()
{
    foreach (&iface : interfaces)
    {
        String name = get_type(iface.name);
        String upname = iface.name.to_upper_tcopy();

        foreach (&enumr : iface.enums)
        {
            String ename = get_type(enumr.name);
            io::fprintfn(out, "constset %s%s", name, ename)!;
            io::fprintfn(out, "{")!;

            foreach (&entry : enumr.entries)
            {
                String entry_name = entry.name.to_upper_tcopy();

                // If first char is a digit (e.g. in wl_output_transform),
                // prefix with enum name.
                if (entry_name[0].is_digit())
                {
                    io::fprintfn(out, "\t%s_%s = %d,",
                        ename.to_upper_tcopy(), entry_name, entry.value)!;
                }
                else
                {
                    io::fprintfn(out, "\t%s = %d,", entry_name, entry.value)!;
                }
            }

            io::fprintfn(out, "}")!;
            io::fprintfn(out, "")!;
        }
    }
}

fn void? print_opcode_enums(
    OutStream out,
    WaylandInterface[] interfaces
) @local => @pool()
{
    foreach (&iface : interfaces)
    {
        String name = get_type(iface.name);

        WaylandMessage[] msgs = iface.client ? iface.events : iface.requests;

        if (msgs.len == 0) continue;

        io::fprintfn(out, "enum %sOpcode", name)!;
        io::fprintfn(out, "{")!;

        foreach (&msg : msgs)
        {
            String msg_name = msg.name.to_upper_tcopy();
            defer msg_name.free(tmem);
            io::fprintfn(out, "\t%s,", msg_name)!;
        }

        io::fprintfn(out, "}")!;
        io::fprintfn(out, "")!;
    }
}

fn void? print_arg_type(
    OutStream out,
    String iface_name,
    WaylandArg* arg,
    bool space = true,
    bool obj_ptr = false,
    bool new_id_is_obj = false
)
{
    if (arg.enumeration.len > 0)
    {
        @pool()
        {
            sz? dot = arg.enumeration.index_of_char('.');

            // If there is a dot, then enum is in from another interface
            if (try dot)
            {
                io::fprintf(
                    out,
                    "%s%s",
                    get_type(arg.enumeration[:dot]),
                get_type(arg.enumeration[dot + 1..])
                )!;
            }
            else
            {
                io::fprintf(
                    out,
                    "%s%s",
                    iface_name,
                    get_type(arg.enumeration)
                )!;
            }
        };
    }
    else
    {
        switch (arg.type)
        {
            case "int":
                io::fprintf(out, "int")!;
            case "uint":
                io::fprintf(out, "uint")!;
            case "fixed":
                io::fprintf(out, "double")!;
            case "string":
                io::fprintf(out, "String")!;
            case "array":
                io::fprintf(out, "WcbWord[]")!;
            case "fd":
                io::fprintf(out, "Fd")!;
            case "object":
                @pool()
                {
                    if (arg.iface.len == 0)
                    {
                        // Happens in wl_display.error event
                        io::fprintf(out, "WcbId")!;
                    }
                    else
                    {
                        io::fprintf(out, "%s", get_type(arg.iface))!;
                        if (obj_ptr) io::fprintf(out, "*")!;
                    }
                };
            case "new_id":
                @pool()
                {
                    if (arg.iface.len == 0)
                    {
                        // interface, version
                        io::fprintf(out, "String, WcbVersion")!;
                    }
                    else
                    {
                        if (new_id_is_obj)
                        {
                            io::fprintf(out, "%s*", get_type(arg.iface))!;
                            break;
                        }
                        io::fprintf(out, "%sId", get_type(arg.iface))!;
                    }
                };
        }
    }

    if (space) io::fprintf(out, " ")!;
}

fn void? print_interfaces(
    OutStream out,
    WaylandInterface[] interfaces
) @local => @pool()
{
    foreach (&iface : interfaces)
    {
        String name = get_type(iface.name);
        String suffix = get_msg_suffix(iface.client);

        io::fprintfn(out, "typedef %s (%s%s) = WcbObject;", name, name, suffix);
        io::fprintfn(out, "typedef %sId = WcbObject;", name);
        io::fprintfn(out, "")!;
        io::fprintfn(out, "interface %s%s", name, suffix)!;
        io::fprintfn(out, "{")!;

        WaylandMessage[] msgs = iface.client ? iface.events : iface.requests;

        foreach (&msg : msgs)
        {
            // Print interface methods
            io::fprintf(out, "\t")!;
            io::fprintf(out, "fn void? %s(", msg.name)!;

            foreach (idx, &arg : msg.args)
            {
                if (arg.type == "new_id" && arg.iface.len == 0)
                {
                    // If interface is not specified, the request shall
                    // implicitly have two additional arguments: A string for an
                    // interface name, and a uint for the new object’s version.
                    // Leaving the interface unspecified is reserved for special
                    // use, wl_registry.bind for example.
                    io::fprintf(out, "String _%s_interface, ", arg.name)!;
                    io::fprintf(out, "WcbVersion _%s_version", arg.name)!;
                }
                else
                {
                    print_arg_type(out, name, arg,
                        obj_ptr: arg.iface.len > 0)!;
                    // Add underscore to prevent conflicting with keywords.
                    io::fprintf(out, "_%s", arg.name)!;
                }

                if (idx < msg.args.len - 1) io::fprintf(out, ", ")!;
            }

            io::fprintfn(out, ") @optional;")!;
        }

        io::fprintfn(out, "}")!;
        io::fprintfn(out, "")!;
    }
}

fn void? print_dispatch(
    OutStream out,
    WaylandInterface[] interfaces
) @local => @pool()
{
    foreach (&iface : interfaces)
    {
        WaylandMessage[] msgs = iface.client ? iface.events : iface.requests;

        // Don't create dispatch function, it will be ignored if so
        if (msgs.len == 0) continue;

        String name = get_type(iface.name);

        io::fprintf(
            out,
            "fn bool? %s.dispatch(&self, WcbHalfWord opcode, WcbArg[] args)",
            name
        )!;
        io::fprintfn(out, " @dynamic")!;
        io::fprintfn(out, "{")!;

        String suffix = get_msg_suffix(iface.client);

        // Print interface variable
        io::fprintfn(out, "\t%s%s impl = self;", name, suffix)!;
        io::fprintfn(out, "")!;

        // Print code
        io::fprintfn(out, "\tswitch ((%sOpcode)opcode)", name)!;
        io::fprintfn(out, "\t{")!;

        foreach (idx, &msg : msgs)
        {
            String msg_name = msg.name.to_upper_tcopy();
            defer msg_name.free(tmem);

            io::fprintfn(out, "\t\tcase %sOpcode.%s:", name, msg_name)!;

            // Create variables to store arguments temporarily
            foreach (aidx, &arg : msg.args)
            {
                if (arg.type == "new_id" && arg.iface.len == 0)
                {
                    io::fprintfn(
                        out,
                        "\t\t\tString _%s_interface = args[%d].s;",
                        arg.name,
                        aidx
                    )!;
                    io::fprintfn(
                        out,
                        "\t\t\tuint _%s_version = args[%d].u;",
                        arg.name,
                        aidx + 1
                    )!;
                    continue;
                }

                io::fprintf(out, "\t\t\t")!;
                print_arg_type(out, name, arg,
                    obj_ptr: arg.iface.len > 0)!;
                io::fprintf(out, "_%s = ", arg.name)!;

                io::fprintf(out, "(")!;
                print_arg_type(out, name, arg, space: false,
                    obj_ptr: arg.iface.len > 0)!;
                io::fprintf(out, ")")!;

                // Assign variable
                io::fprintf(out, "args[%d].", aidx)!;
                switch (arg.type)
                {
                    case "int":
                        io::fprintf(out, "i")!;
                    case "uint":
                        io::fprintf(out, "u")!;
                    case "fixed":
                        io::fprintf(out, "f.to_double()")!;
                    case "object":
                        if (arg.iface.len == 0)
                        {
                            io::fprintf(out, "u")!;
                        }
                        else
                        {
                            io::fprintf(out, "o")!;
                        }
                    case "new_id":
                        io::fprintf(out, "n")!;
                    case "fd":
                        io::fprintf(out, "h")!;
                    case "string":
                        io::fprintf(out, "s")!;
                    case "array":
                        io::fprintf(out, "a")!;
                }

                io::fprintfn(out, ";")!;
            }

            io::fprintfn(out, "")!;

            // Print method call, if its not defined, then don't call it (may
            // leak fds).
            io::fprintfn(out, "\t\t\tif (&impl.%s)", msg.name)!;
            io::fprintfn(out, "\t\t\t{")!;
            io::fprintf(out, "\t\t\t\timpl.%s(", msg.name)!;

            foreach (aidx, &arg : msg.args)
            {
                if (arg.type == "new_id" && arg.iface.len == 0)
                {
                    io::fprintf(out, "_%s_interface, ", arg.name)!;
                    io::fprintf(out, "_%s_version", arg.name)!;
                }
                else
                {
                    io::fprintf(out, "_%s", arg.name)!;
                }
                if (aidx < msg.args.len - 1) io::fprintf(out, ", ")!;
            }
            io::fprintfn(out, ")!;")!;
            io::fprintfn(out, "\t\t\t\treturn true;")!;
            io::fprintfn(out, "\t\t\t}")!;
        }

        io::fprintfn(out, "\t\tdefault:")!;
        io::fprintfn(out, "\t\t\tunreachable();")!;
        io::fprintfn(out, "\t}")!;
        io::fprintfn(out, "\treturn false;")!;

        io::fprintfn(out, "}")!;
        io::fprintfn(out, "")!;
    }
}

fn void? print_get_interface(
    OutStream out,
    WaylandInterface[] interfaces
) @local => @pool()
{
    foreach (&iface : interfaces)
    {
        String name = get_type(iface.name);

        io::fprintfn(
            out,
            "fn WcbInterface* %s.get_interface(&self) @dynamic",
            name
        )!;
        io::fprintfn(out, "{")!;

        io::fprintfn(out, "\tstatic WcbInterface iface = {")!;

        io::fprintfn(out, "\t\t.name = \"%s\",", iface.name)!;
        io::fprintfn(out, "\t\t.version = %d,", iface.version)!;
        io::fprintfn(out, "\t\t.messages = {")!;

        WaylandMessage[] msgs = iface.client ? iface.events : iface.requests;

        // Print message descriptions
        foreach (msg : msgs)
        {
            io::fprintfn(out, "\t\t\t{")!;
            io::fprintfn(out, "\t\t\t\t.name = \"%s\",", msg.name)!;
            io::fprintfn(out, "\t\t\t\t.since = %d,", msg.since)!;

            io::fprintfn(out, "\t\t\t\t.signature = {")!;
            foreach (arg : msg.args)
            {
                String enum_name = arg.type.to_upper_tcopy();
                defer enum_name.free(tmem);
                io::fprintf(out, "\t\t\t\t\t{ .type = WcbArgType.%s, ", enum_name)!;
                io::fprintfn(out, ".nullable = %s },",
                    arg.allow_null ? "true" : "false");
            }
            io::fprintfn(out, "\t\t\t\t},")!;

            io::fprintfn(out, "\t\t\t},")!;
        }

        io::fprintfn(out, "\t\t}")!;
        io::fprintfn(out, "\t};")!;
        io::fprintfn(out, "\treturn &iface;")!;

        io::fprintfn(out, "}")!;
        io::fprintfn(out, "")!;
    }
}

fn void? print_methods(
    OutStream out,
    WaylandInterface[] interfaces,
    bool client
) @local => @pool()
{
    foreach (&iface : interfaces)
    {
        String name = get_type(iface.name);

        WaylandMessage[] msgs = iface.client ? iface.requests : iface.events;

        // Print method functions
        foreach (opcode, &msg : msgs)
        {
            io::fprintf(out, "fn void? %s.%s(&self, ", name, msg.name)!;
            WaylandArg* new_id_arg = null;

            if (iface.name == "wl_registry" && msg.name == "bind")
            {
                // Special case for wl_registry.bind
                io::fprintfn(out,
                    "WcbObject* obj, WcbId name, WcbVersion version)"
                )!;
                io::fprintfn(out, "{")!;

                io::fprintf(out, "\tself.ct.marshal_object(")!;
                io::fprintf(out,
                    "(WcbObject*)self, %d, WcbArgType.UINT, WcbArgType.STRING, "
                    "WcbArgType.UINT, ", opcode
                )!;
                io::fprintf(out,
                    "name, ((WcbObjectImpl)obj).get_interface().name, version"
                )!;
                io::fprintfn(out, ");")!;

                io::fprintfn(out,
                    "\tself.ct.create_object(obj, version)!;"
                )!;

                io::fprintfn(out, "}")!;
                io::fprintfn(out, "")!;
                continue;
            }

            foreach (aidx, &arg : msg.args)
            {
                if (arg.type == "new_id") new_id_arg = arg;

                if (arg.type == "new_id" && arg.iface.len == 0)
                {
                    // wl_registry.bind
                    io::fprintf(out, "String _%s_name, WcbVersion _%s_version",
                        arg.name, arg.name)!;
                }
                else
                {
                    print_arg_type(out, name, arg,
                        obj_ptr: true, new_id_is_obj: true)!;

                    io::fprintf(out, "_%s", arg.name)!;
                }
                if (aidx < msg.args.len - 1) io::fprintf(out, ", ")!;
            }

            io::fprintfn(out, ")")!;
            io::fprintfn(out, "{")!;

            io::fprintf(out,
                "\tself.ct.marshal_object((WcbObject*)self, %d, ", opcode)!;

            // Print types of arguments, then the argument values
            foreach (&arg : msg.args)
            {
                if ((arg.type == "new_id" || arg.type == "object")
                && arg.iface.len == 0)
                {
                    io::fprintf(out, "WcbArgType.UINT, ")!;
                    continue;
                }
                String enum_name = arg.type.to_upper_tcopy();
                defer enum_name.free(tmem);

                io::fprintf(out, "WcbArgType.%s, ", enum_name)!;
            }
            foreach (aidx, &arg : msg.args)
            {
                io::fprintf(out, "_%s", arg.name)!;
                if (aidx < msg.args.len - 1) io::fprintf(out, ", ")!;
            }

            io::fprintfn(out, ");")!;

            if (new_id_arg != null)
            {
                io::fprintfn(out,
                    "\tself.ct.create_object((WcbObject*)_%s, self.version)!;",
                    new_id_arg.name
                );
            }

            io::fprintfn(out, "}")!;
            io::fprintfn(out, "")!;
        }
    }
}

fn void? print_instantiate(
    OutStream out,
    WaylandInterface[] interfaces
) @local => @pool()
{
    foreach (&iface : interfaces)
    {
        String name = get_type(iface.name);

        // This macro instantiates new_id objects.
        io::fprintfn(out, "fn void? %s.init(&self, %sId template)", name, name)!;
        io::fprintfn(out, "{")!;
        io::fprintfn(out, "\tself.id = template.id;")!;
        io::fprintfn(out, "\tself.version = template.version;")!;
        io::fprintfn(out, "\tself.ct = template.ct;")!;
        io::fprintfn(out, "\tself.ct.add_object((WcbObject*)self)!;")!;
        io::fprintfn(out, "}")!;
        io::fprintfn(out, "")!;
    }
}

// Generate C3 code, yay!
fn void? generate_code(
    WaylandProtocol* protocol,
    String module_prefix,
    Path out_file,
    bool client,  // false if server
)
{
    File? fp = file::open_path(out_file, "w");

    OutStream? out = out = &fp;

    if (catch err = out)
    {
        io::eprintfn("Error opening file '%s' for writing: %s", out_file, err);
        return err~;
    }

    defer (void)fp.close();

    io::fprintfn(out, "// Generated by wcb_scanner %s", scanner::VERSION)!;
    io::fprintfn(out, "module %s::%s;",
                module_prefix, client ? "client" : "server")!;
    io::fprintfn(out, "")!;
    io::fprintfn(out, "import wcb::core::types;")!;
    io::fprintfn(out, "import libc;")!;
    io::fprintfn(out, "")!;

    print_typedefs(out, protocol.interfaces, client)!;
    print_constsets(out, protocol.interfaces)!;
    print_opcode_enums(out, protocol.interfaces)!;
    print_interfaces(out, protocol.interfaces)!;
    print_dispatch(out, protocol.interfaces)!;
    print_get_interface(out, protocol.interfaces)!;
    print_instantiate(out, protocol.interfaces)!;
    print_methods(out, protocol.interfaces, client)!;
}
