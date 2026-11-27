module wcb::io::socket;

import wcb::core::types;
import wcb::binding::un @public;
import wcb::binding::unistd @public;
import wcb::binding::fcntl @public;
import std::collections::ringbuffer;
import std::collections::list;
import std::net::os;
import std::io::path;
import std::os::env;
import libc;

excuse
{
    BAD_ENVIRONMENT,
        ERROR_CONNECTING,
        BAD_READ,
        BAD_WRITE,
        BAD_POLL
}

struct WcbSocketIO (WcbIOImpl)
{
    Fd sock_fd;
    Allocator allocator;

    List{char} out;

    RingBuffer{Fd, 128} in_fds;
    RingBuffer{Fd, 128} out_fds;
}

extern fn sz receive_data(Fd fd, char* buf, usz bufsz, int *fds, usz* fds_read)
    @cname("receive_data") @local;

    extern fn sz send_data(Fd fd, char* buf, usz buflen, Fd *fds,
            usz fds_len, usz* fds_sent) @cname("send_data") @local;

<*
@param [&inout] allocator : "Allocator to use"
@param [inout] name : "Name of socket to connect to"
@return? BAD_ENVIRONMENT, ERROR_CONNECTING
@return? path::tnew!, Path.tappend!, String.is_absolute_path!, os::socket!
@return? NativeSocket.set_non_blocking!
    *>
fn void? WcbSocketIO.init(&self, String name, Allocator allocator)
{
    self.allocator = allocator;

    Fd fd = -1;
    String sock_path = {};

    ZString env_wayland_display = libc::getenv("WAYLAND_DISPLAY");
    ZString env_wayland_socket = libc::getenv("WAYLAND_SOCKET");
    ZString env_xdg_runtime_dir = libc::getenv("XDG_RUNTIME_DIR");

    if (name != {})
    {
        sock_path = name;
    }
    if (env_wayland_socket != null)
    {
        fd = env_wayland_socket.str_view().to_int()!;
    }
    else if (env_wayland_display != null)
    {
        sock_path = env_wayland_display.str_view();
    }
    else
    {
        return BAD_ENVIRONMENT~;
    }

    if (fd == -1)
    {
        @pool()
        {
            Path path;

            // If path is relative, then use $XDG_RUNTIME_DIR as the base.
            // Otherwise connect to the socket at the absolute path.
            if (sock_path.is_absolute_path()!)
            {
                path = path::tnew(sock_path)!;
            }
            else
            {
                Path xdg_runtime_dir;

                if (env_xdg_runtime_dir == null)
                {
                    // Use "/run/user/<uid>"
                    xdg_runtime_dir = path::tnew("/run/user/")!;
                    xdg_runtime_dir.tappend(string::tformat("%d",
                                unistd::getuid()))!;
                }
                else
                {
                    xdg_runtime_dir = path::tnew(env_xdg_runtime_dir.str_view())!;
                }

                path = xdg_runtime_dir.tappend(sock_path)!;
                xdg_runtime_dir.free(tmem);
            }

            NativeSocket sock = os::socket(
                    os::AF_UNIX, os::SOCK_STREAM, (AIProtocol)0
                    );

            if (!sock.is_valid()) return ERROR_CONNECTING~;

            SockaddrUn addr;

            addr.sun_family = (uint)os::AF_UNIX;
            io::bprintf(addr.sun_path[..], "%s", path);

            if (os::connect(sock, (SockAddrPtr)&addr, SockaddrUn::size) == -1)
            {
                return ERROR_CONNECTING~;
            }

            sock.set_non_blocking(true)!;

            fd = (Fd)sock;
        };
    }

    assert(fd != -1);

    self.sock_fd = fd;

    self.out.init(allocator, initial_capacity: 4096);
    self.out_fds.init();
}

fn void WcbSocketIO.uninit(&self)
{
    libc::close(self.sock_fd);

    self.out.free();
}

<*
@return "Return socket fd for this connection"
    *>
fn Fd WcbSocketIO.get_fd(&self)
{
    return self.sock_fd;
}

fn sz? WcbSocketIO.read(&self, char[] buf) @dynamic
{
    Fd[types::MESSAGE_MAX_FDS] fdbuf;
    usz fds_read = 0;

    sz r = receive_data(self.sock_fd, (char*)buf, buf.len, &fdbuf, &fds_read);

    if (r == -1) return BAD_READ~;

    self.in_fds.push_all(fdbuf[:fds_read]);

    return r;
}

fn Fd? WcbSocketIO.read_fd(&self, sz n_discard, Fd close) @dynamic
{
    if (self.in_fds.is_empty()) return -1;

    if (n_discard > 0)
    {
        for (sz i = 0; i < n_discard; i++)
        {
            Fd fd = self.in_fds.pop_first()!;

            libc::close(fd);
        }
    }
    else if (close != -1)
    {
        libc::close(close);
        return - 1;
    }

    return self.in_fds.pop_first()!;
}

fn void WcbSocketIO.write(&self, char[] data, Fd fd) @dynamic
{
    if (fd != -1)
    {
        if (self.out_fds.is_full()) (void)self.flush();

        if (self.out_fds.is_full())
        {
            libc::close(fd);
        }
        else
        {
            self.out_fds.push(fd);
        }
    }
    self.out.push_all(data);
}

fn WcbIOEvents? WcbSocketIO.poll(&self, WcbIOEvents events) @dynamic
{
    Posix_pollfd pfd = {
        .fd = self.sock_fd,
    };

    if (events.readable) pfd.events |= os::POLLIN;
    if (events.writable) pfd.events |= os::POLLOUT;

    while (true)
    {
        if (os::poll(&pfd, 1, -1) == -1)
        {
            if (os::errno() == Errno.EINTR) continue;
            return BAD_POLL~;
        }

        if (pfd.revents & (pfd.events)) break;
    }

    events.readable = (bool)(pfd.revents & os::POLLIN);
    events.writable = (bool)(pfd.revents & os::POLLOUT);

    return events;
}

fn bool? WcbSocketIO.flush(&self) @dynamic
{
    Fd[types::MESSAGE_MAX_FDS] fdbuf;
    sz fdlen = 0;

    for (sz i = 0; i < min(fdbuf.len, self.out_fds.len()); i++)
    {
        fdbuf[i] = self.out_fds.get(i);
        fdlen++;
    }

    sz total_sent = 0;
    sz total_fds_sent = 0;
    sz remaining = self.out.len();

    while (true)
    {
        if (remaining == 0) break; // No more data to send

        usz fds_sent = 0;

        sz w = send_data(self.sock_fd, self.out.array_view(),
                (usz)self.out.len(), &fdbuf, (usz)fdlen, &fds_sent);

        if (w == -1) return BAD_WRITE~;
        if (w == 0) break; // Would block, stop now

        total_sent += w;
        total_fds_sent += (sz)fds_sent;
        remaining -= w;
    }

    mem::move(self.out.entries, self.out.entries + total_sent,
            self.out.len() - total_sent);
    self.out.size -= total_sent;

    for (sz i = 0; i < fdlen; i++)
    {
        libc::close(self.out_fds.pop_first()!!);
    }

    return remaining == 0;
}

fn Fd? WcbSocketIO.dup_fd(&self, Fd fd) @dynamic
{
    Fd new = libc::fcntl(fd, fcntl::F_DUPFD, 0);
    if (new == -1) return io::GENERAL_ERROR~;

    defer catch libc::close(new);

    // Set close-on-exec flag
    CInt flags = libc::fcntl(new, os::F_GETFD);
    if (flags == -1) return io::GENERAL_ERROR~;

    if (libc::fcntl(new, fcntl::F_SETFD, flags | fcntl::FD_CLOEXEC) == -1)
    {
        return io::GENERAL_ERROR~;
    }

    return new;
}

fn void WcbSocketIO.destroy(&self) @dynamic
{
    self.uninit();
}
