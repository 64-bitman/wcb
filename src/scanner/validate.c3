module wcb::scanner::validate;

import wcb::scanner::parser;
import std::io;

excuse NOT_VALID;

// The name must start with one of the ASCII characters a-z, A-Z, or underscore,
// and the following characters may additionally include numbers 0-9.
fn void? valid_name(String name, bool allow_digit_start = false) @private
{
    if (name.len == 0)
    {
        io::eprintfn("Name cannot be empty");
        return NOT_VALID~;
    }

    foreach (idx, c : name)
    {
        if (!allow_digit_start && idx == 0 && c.is_digit())
        {
            io::eprintfn("Name '%s' cannot start with a digit", name);
            return NOT_VALID~;
        }
        if (!c.is_alnum() && c != '_')
        {
            io::eprintfn(
                "Name '%s' can only contain a-x, A-Z, or underscore",
                name
            );
            return NOT_VALID~;
        }
    }
}

// Version numbers must not be zero (except if zero is used as an indicator that
// it was not provided).
fn void? valid_version(uint version, bool since) @private
{
    if (version == 0)
    {
        io::eprintfn(
            "Invalid %s number %d",
            since ? "since" : "version",
            version
        );
        return NOT_VALID~;
    }
}

// No fault if "str" is a unique name in the array
macro name_is_unique(arr, str) @private
{
    bool found = false;
    foreach (ele : arr)
    {
        if (ele.name == str)
        {
            if (!found)
            {
                found = true;
                continue;
            }
            io::eprintfn("Duplicate name '%s'", str);
            return NOT_VALID~;
        }
    }
    return true;
}

// Validate if the parsed protocol is valid
fn void? validate_tree(WaylandProtocol* protocol)
{
    valid_name(protocol.name)!;

    foreach (iface : protocol.interfaces)
    {
        defer catch io::eprintfn("Invalid interface %s", iface.name);

        valid_name(iface.name)!;
        name_is_unique(protocol.interfaces, iface.name)!;
        valid_version(iface.version, false)!;

        WaylandMessage[][] msgs = { iface.events, iface.requests };

        // Validate requests and events
        foreach (&msgarr : msgs)
        {
            if (msgarr.len > ushort::max)
            {
                if (msgarr == &iface.events)
                {
                    io::eprintfn("Too many requests");
                }
                else
                {
                    io::eprintfn("Too many events");
                }
                return NOT_VALID~;
            }
            foreach (&msg : msgarr)
            {
                defer catch io::eprintfn("Invalid message %s", msg.name);

                valid_name(msg.name)!;
                name_is_unique(msgarr, msg.name)!;
                valid_version(msg.since, true)!;

                if (msg.type.len > 0 && msg.type != "destructor")
                {
                    io::eprintfn("Invalid message type '%s'", msg.type);
                    return NOT_VALID~;
                }

                bool has_newid = false;

                foreach (&arg : msg.args)
                {
                    defer catch io::eprintfn("Invalid arg %s", arg.name);

                    valid_name(arg.name)!;
                    name_is_unique(msg.args, arg.name)!;

                    switch (arg.type)
                    {
                        case "int":
                        case "uint":
                        case "fixed":
                        case "string":
                        case "array":
                        case "fd":
                        case "object":
                            break;
                        case "new_id":
                            // Requests and events can only have at most one
                            // new_id arg.
                            if (has_newid)
                            {
                                io::eprintfn(
                                    "Can only have most one new_id argument"
                                );
                                return NOT_VALID~;
                            }
                            has_newid = true;
                        default:
                            io::eprintfn("Invalid arg type '%s'", arg.type);
                            return NOT_VALID~;
                    }

                    // "interface" attribute only valid when arg type is
                    // "object" or "new_id".
                    if (arg.iface.len > 0 && arg.type != "object"
                        && arg.type != "new_id")
                    {
                        io::eprintfn(
                            "attribute 'interface' may only be defined for arg type object and new_id"
                        );
                        return NOT_VALID~;
                    }

                    // "allow-null" attribute only valid when arg type is
                    // "object" or "string".
                    if (arg.allow_null && arg.type != "object"
                        && arg.type != "string")
                    {
                        io::eprintfn(
                            "attribute 'allow-null' may only be defined for arg type object and string"
                        );
                        return NOT_VALID~;
                    }

                    // "enum" attribute only valid when arg type is "int" or
                    // "uint".
                    if (arg.enumeration.len > 0 && arg.type != "int"
                        && arg.type != "uint")
                    {
                        io::eprintfn(
                            "attribute 'enum' may only be defined for arg type int and uint"
                        );
                        return NOT_VALID~;
                    }
                }
            }
        }

        // Validate enums
        foreach (&enumr : iface.enums)
        {
            defer catch io::eprintfn("Invalid enum %s", enumr.name);

            valid_name(enumr.name)!;
            name_is_unique(iface.enums, enumr.name)!;
            valid_version(enumr.since, true)!;

            foreach (&entry : enumr.entries)
            {
                defer catch io::eprintfn("Invalid entry %s", entry.name);

                valid_name(entry.name, true)!;
                name_is_unique(enumr.entries, entry.name)!;
                valid_version(entry.since, true)!;
            }
        }
    }
}
