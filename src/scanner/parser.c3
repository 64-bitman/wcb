module wcb::scanner::parser;

import std::encoding::xml;
import std::io::path;
import std::io::file;
import std::io;

excuse NO_INTERFACES, INVALID_BOOL;

// "protocol" element
struct WaylandProtocol
{
    String name;  // "name" attribute

    WaylandCopyright copyright;
    WaylandDescription description;
    WaylandInterface[] interfaces;
}

// "copyright" element
struct WaylandCopyright
{
    String text;
}

// "description" element
struct WaylandDescription
{
    String summary;  // "summary" attribute
    String text;
}

// "interface" element
struct WaylandInterface
{
    String name;  // "name" attribute
    uint version;  // "version" attribute
    bool frozen;  // "frozen" attribute

    WaylandDescription description;
    WaylandMessage[] events;
    WaylandMessage[] requests;
    WaylandEnum[] enums;

    bool client;
}

// "request"/"event" element
struct WaylandMessage
{
    String name;  // "name" attribute
    String type;  // "type" attribute
    uint since;  // "since" attribute
    uint deprecated_since;  // "deprecated-since" attribute

    WaylandDescription description;
    WaylandArg[] args;
}

// "arg" element
struct WaylandArg
{
    String name;  // "name" attribute
    String type;  // "type" attribute
    String summary;  // "summary" attribute
    String iface;  // "interface" attribute
    bool allow_null;  // "allow-null" attribute
    String enumeration;  // "enum" attribute

    WaylandDescription description;
}

// "enum" element
struct WaylandEnum
{
    String name;  // "name" attribute
    uint since;  // "since" attribute
    bool bitfield;  // "bitfield" attribute

    WaylandDescription description;
    WaylandEntry[] entries;
}

// "entry" element
struct WaylandEntry
{
    String name;  // "name" attribute
    int value;  // "value" attribute
    String summary;  // "summary" attribute
    uint since;  // "since" attribute
    uint deprecated_since;  // "deprecated-since" attribute

    WaylandDescription description;
}

fn void? WaylandCopyright.get(&self, XmlNode* parent)
{
    XmlNode*? node = parent.find("copyright");

    if (catch node)
    {
        return;
    }
    self.text = node.text().trim() ?? "";
}

// Return true if description was found
fn bool? WaylandDescription.get(&self, XmlNode* parent)
{
    XmlNode*? node = parent.find("description");
    if (catch node)
    {
        return false;
    }
    self.text = node.text().trim() ?? "";
    self.summary = node.attr("summary").trim() ?? "";
    return true;
}

fn bool? String.to_bool(&self)
{
    if (*self == "true")
    {
        return true;
    }
    else if (*self == "false")
    {
        return false;
    }
    return INVALID_BOOL~;
}

fn void? WaylandInterface.init(&self, XmlNode* node)
{
    {
        defer catch io::eprintfn("Error parsing interface: name missing");
        self.name = node.attr("name").trim()!;
    }

    defer catch io::eprintfn("Error parsing interface %s", self.name);

    self.version = node.attr("version").to_uint()!;
    self.frozen = node.attr("frozen").to_bool() ?? false;

    self.description.get(node)!;

    // Zero requests, events, or enums are allowed

    XmlNodeList request_list;

    node.find_all("request", &request_list);
    if (request_list.len() > 0)
    {
        self.requests = alloc::new_array(
            tmem,
            WaylandMessage,
            request_list.len()
        );

        foreach (idx, event_node : request_list)
        {
            defer catch io::eprintfn(
                "Error parsing request in interface %s",
                self.name
            );
            self.requests[idx].init(event_node)!;
        }
    }

    XmlNodeList event_list;

    node.find_all("event", &event_list);
    if (event_list.len() > 0)
    {
        self.events = alloc::new_array(tmem, WaylandMessage, event_list.len());

        foreach (idx, event_node : event_list)
        {
            defer catch io::eprintfn(
                "Error parsing event in interface %s",
                self.name
            );
            self.events[idx].init(event_node)!;
        }
    }

    XmlNodeList enum_list;

    node.find_all("enum", &enum_list);
    if (enum_list.len() > 0)
    {
        self.enums = alloc::new_array(tmem, WaylandEnum, enum_list.len());

        foreach (idx, enum_node : enum_list)
        {
            defer catch io::eprintfn(
                "Error parsing enum in interface %s",
                self.name
            );
            self.enums[idx].init(enum_node)!;
        }
    }
}

fn void? WaylandMessage.init(&self, XmlNode* node)
{
    self.name = node.attr("name").trim()!;
    self.type = node.attr("type").trim() ?? "";
    self.since = node.attr("since").to_uint() ?? 1;
    self.deprecated_since = node.attr("deprecated-since").to_uint() ?? 0;

    self.description.get(node)!;

    XmlNodeList arg_list;

    node.find_all("arg", &arg_list);
    if (arg_list.len() > 0)
    {
        self.args = alloc::new_array(tmem, WaylandArg, arg_list.len());

        foreach (idx, arg_node : arg_list)
        {
            defer catch io::eprintfn(
                "Error parsing arg in message %s",
                self.name
            );
            self.args[idx].init(arg_node)!;
        }
    }
}

fn void? WaylandArg.init(&self, XmlNode* node)
{
    self.name = node.attr("name").trim()!;
    self.type = node.attr("type").trim()!;

    if (!self.description.get(node)!)
    {
        self.summary = node.attr("summary").trim() ?? "";
    }

    self.iface = node.attr("interface").trim() ?? "";
    self.allow_null = node.attr("allow-null").to_bool() ?? false;
    self.enumeration = node.attr("enum").trim() ?? "";
}

fn void? WaylandEnum.init(&self, XmlNode* node)
{
    self.name = node.attr("name").trim()!;
    self.since = node.attr("since").to_uint() ?? 1;
    self.bitfield = node.attr("bitfield").to_bool() ?? false;

    self.description.get(node)!;

    XmlNodeList entry_list;

    node.find_all("entry", &entry_list);
    if (entry_list.len() > 0)
    {
        self.entries = alloc::new_array(tmem, WaylandEntry, entry_list.len());

        foreach (idx, entry_node : entry_list)
        {
            defer catch io::eprintfn(
                "Error parsing entry in enum %s",
                self.name
            );
            self.entries[idx].init(entry_node)!;
        }
    }
}

fn void? WaylandEntry.init(&self, XmlNode* node)
{
    self.name = node.attr("name").trim()!;
    self.value = node.attr("value").to_int()!;

    if (!self.description.get(node)!)
    {
        self.summary = node.attr("summary").trim() ?? "";
    }

    self.since = node.attr("since").to_uint() ?? 1;
    self.deprecated_since = node.attr("deprecated-since").to_uint() ?? 0;
}

// Parse the XML tree to in memory representation
fn WaylandProtocol*? generate_tree(Path file, bool client)
{
    File? fp = file::open_path(file, "r")!;

    InStream? in_stream;

    {
        defer (catch err)
        {
            io::eprintfn("Error opening file '%s' for reading: %s", file, err);
            (void)fp.close();
        }
        in_stream = (&fp)!;
    }

    defer (void)fp.close();

    XmlDocument*? doc = xml::load(tmem, in_stream)!;
    XmlNode*? root = doc.root!;

    WaylandProtocol* protocol = alloc::new(tmem, WaylandProtocol);

    protocol.name = root.attr("name").trim()!;
    protocol.copyright.get(root)!;
    protocol.description.get(root)!;

    XmlNodeList interface_list;

    root.find_all("interface", &interface_list)!;

    if (interface_list.len() == 0)
    {
        io::eprintfn("No interfaces defined");
        return NO_INTERFACES~;
    }

    protocol.interfaces = alloc::new_array(
        tmem,
        WaylandInterface,
        interface_list.len()
    );

    foreach (idx, iface_node : interface_list)
    {
        protocol.interfaces[idx].init(iface_node)!;
        protocol.interfaces[idx].client = client;
    }

    return protocol;
}
