module wcb::test::connection @test;

import wcb::core::types;
import wcb::core::wire @public;
import wcb::core::connection @public;
import std::collections::map;
import std::collections::list;
import std::io;
import libc;

struct TestConnection (WcbConnectionImpl, WcbIOImpl)
{
    inline WcbConnection base;

    HashMap{WcbId, any} objects;
    WcbId next_id;

    char[16384] bytes;
    ByteBuffer buf;
    List{Fd} fds;
}

fn void TestConnection.init(&self, Allocator allocator)
{
    self.base.init(self, self, allocator);

    self.objects.init(allocator);
    self.next_id = 0;

    // Use a static buffer to guarantee that pointers into the buffer stay
    // valid.
    self.buf.init_with_buffer(self.bytes[..]);
    self.fds.init(allocator);
}

fn void TestConnection.uninit(&self)
{
    self.base.uninit();
    self.objects.free();

    self.buf.free();
    self.fds.free();
}

fn WcbWord*? TestConnection.read(
    &self,
    sz n_words,
    bool peek = false,
    bool skip = false) @dynamic
{
    sz len = n_words * WcbWord::size;

    if (len > self.buf.available()!) return null;

    if (peek) return (WcbWord*)&self.buf.bytes[self.buf.cursor()!];

    WcbWord* data = (WcbWord*)&self.buf.bytes[self.buf.cursor()!];

    self.buf.seek(len, whence: FROM_CURSOR)!;
    return data;
}

fn Fd? TestConnection.read_fd(&self, sz n_discard = 0, Fd close = -1) @dynamic
{
    if (close) return -1;

    if (n_discard > 0)
    {
        for (sz i = 0; i < n_discard; i++) self.fds.remove_first();
        return -1;
    }

    Fd fd = self.fds.get(0);

    self.fds.remove_first();
    return fd;
}

fn WcbId? TestConnection.insert(&self, WcbObject obj) @dynamic
{
    return 0;
}

fn void TestConnection.remove(&self, WcbId id) @dynamic
{}

fn any? TestConnection.lookup(&self, WcbId id) @dynamic
{
    return null;
}

fn bool? TestConnection.handle(&self, WcbMessage* msg) @dynamic
{
    return true;
}

fn void TestConnection.write(&self, char[] data, Fd fd = -1) @dynamic
{
    if (fd != -1)
    {
        self.fds.push(fd);
        return;
    }

    (void)self.buf.write(data)!!;
}

fn void test_unmarshal() => @pool()
{
    TestConnection test;

    test.init(tmem);
    defer test.uninit();

    WcbConnection* ct = &test;

    ct.send(1, 0, WcbArgType.INT, WcbArgType.STRING, 1, "A string")!!;

    test::eq(ct.dispatch()!!, 1);
}
