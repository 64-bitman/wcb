module wcb::binding::un @private;

struct SockaddrUn
{
    ushort sun_family;
    char[108] sun_path;
}
