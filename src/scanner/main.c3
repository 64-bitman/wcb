module wcb::scanner;

import std::io;
import std::io::path;
import wcb::scanner::parser;
import wcb::scanner::validate;
import wcb::scanner::codegen;

const String VERSION = "0.0.1";

fn void help() @private
{
    io::printfn(
        "Usage: wcb_scanner [OPTION] {module_prefix} {client|server} {input_file} {output_fule}"
    );
    io::printfn("");
    io::printfn("Convert Wayland XML protocol files into C3 code files");
    io::printfn("");
    io::printfn("Options:");
    io::printfn("    -h,--help      Display this help message");
    io::printfn("    -v,--version   Print wcb library version");
}

fn int main(String[] cmdargs)
{
    String[] args = cmdargs[1..];

    String modname = "";
    String gen_type = "";
    String in_file = "";
    String out_file = "";

    foreach (arg : args)
    {
        if (arg.len > 1 && arg[0] == '-')
        {
            String longopt = arg.len > 2 ? arg[2..] : "";
            char shortopt = arg[1];

            if (longopt == "help" || shortopt == 'h')
            {
                help();
                return 0;
            }
            else if (longopt == "version" || shortopt == 'v')
            {
                io::printfn("wcb_scanner version %s", VERSION);
                return 0;
            }
            else
            {
                io::eprintfn(
                    "Unknown argument %s",
                    longopt == "" ? arg[..1] : arg[2..]
                );
                return 1;
            }
        }

        if (modname == "")
        {
            modname = arg;
        }
        else if (gen_type == "")
        {
            gen_type = arg;
        }
        else if (in_file == "")
        {
            in_file = arg;
        }
        else if (out_file == "")
        {
            out_file = arg;
        }
        else
        {
            io::eprintfn("Unknown argument %s", arg);
            return 1;
        }
    }

    if (gen_type.len == 0 || in_file.len == 0 || out_file.len == 0)
    {
        io::eprintfn("Not enough arguments");
        return 1;
    }

    if (gen_type != "client" && gen_type != "server")
    {
        io::eprintfn("Unknown type %s to generate", gen_type);
        return 1;
    }

    @pool()
    {
        WaylandProtocol*? protocol = parser::generate_tree(
            path::new(tmem, in_file)!!,
        );

        if (catch err = protocol)
        {
            io::eprintfn("Error parsing xml: %s", err.short_name());
            return 1;
        }

        if (catch err = validate::validate_tree(protocol))
        {
            io::eprintfn("Error validating protocol: %s", err.short_name());
            return 1;
        }

        if (catch err = codegen::generate_code(
                protocol,
                modname,
                path::new(tmem, out_file)!!,
                gen_type == "client"
        ))
        {
            io::eprintfn("Error generating code: %s", err.short_name());
            return 1;
        }
    };

    return 0;
}
