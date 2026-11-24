module wcb::test::connection @test;

import wcb::core::types;
import wcb::core::wire @public;
import wcb::core::connection @public;
import std::collections::map;
import std::collections::list;
import std::io;
import libc;

struct TestObject (WcbObject)
{
    WcbId id;
    WcbInterface* iface;
}

fn bool? TestObject.dispatch(&self, WcbHalfWord opcode, args...) @dynamic
{
    return true;
}

fn WcbInterface* TestObject.get_interface(&self) @dynamic
{
    return self.iface;
}

struct TestConnection (WcbConnectionImpl{TestObject}, WcbIOImpl)
{
    inline WcbConnection{TestObject} base;

    HashMap{WcbId, any} objects;
    WcbId next_id;

    char[16384] bytes;
    ByteBuffer buf;
    List{Fd} fds;
    List{Fd} closed_fds;
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
    self.closed_fds.init(allocator);
}

fn void TestConnection.uninit(&self)
{
    self.base.uninit();
    self.objects.free();

    self.buf.free();
    self.fds.free();
    self.closed_fds.free();
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
    if (close != -1)
    {
        self.closed_fds.push(close);
        return -1;
    }

    if (n_discard > 0)
    {
        for (sz i = 0; i < n_discard; i++) self.fds.remove_first();
        return -1;
    }

    Fd fd = self.fds.get(0);

    self.fds.remove_first();
    return fd;
}

fn any? TestConnection.lookup(&self, WcbId id) @dynamic
{
    any? lookup = self.objects.get(id);
    if (catch err = lookup)
    {
        if (err == NOT_FOUND) return null;
        return err~;
    }
    return lookup;
}

WcbInterface iface1 = {
    .name = "test_object",
    .version = 2,
    .messages = {
        {
            .name = "ping",
            .since = 1,
            .signature = {
                { .type = INT, .nullable = false },
                { .type = FD, .nullable = false },
                { .type = NEW_ID, .nullable = false },
                { .type = OBJECT, .nullable = true }
            },
            .n_fd_args = 1,
            .arg_interfaces = { null, null, &iface1, &iface1 }
        }
    }
};

fn bool? TestConnection.handle(&self, WcbMessage* msg) @dynamic
{
    test::eq(msg.obj.get_interface(), &iface1);
    test::eq(msg.opcode, 0);
    test::eq(msg.args.len, 4);

    test::eq(msg.args[0].i, 1);
    test::eq(msg.args[1].h, 12);
    test::eq(msg.args[2].n.iface, &iface1);
    test::eq(msg.args[2].n.id, (WcbId)3);
    test::eq(msg.args[3].o.get_interface(), &iface1);

    return false;  // Fd arg should be closed
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

fn void test_basic() => @pool()
{
    TestConnection test;

    test.init(tmem);
    defer test.uninit();

    TestObject obj = {
        .id = 1,
        .iface = &iface1
    };

    TestObject obj2 = {
        .id = 2,
        .iface = &iface1
    };

    test.objects.set(obj.id, &obj);
    test.objects.set(obj2.id, &obj2);

    WcbConnection{TestObject} * ct = &test;

    ct.send(obj.id, 0,
        WcbArgType.INT,
        WcbArgType.FD,
        WcbArgType.NEW_ID,
        WcbArgType.OBJECT,
        1,
        12,
        3,
        obj2.id,
    )!!;

    test::eq(ct.dispatch()!!, 1);
    test::eq(test.closed_fds.get(0), 12);

    WcbArray arr = {
        .data.bytes = "array",
        .len = 5
    };

    // Check if sending string and arrays work correctly at compile time
    ct.send(obj.id, 0,
        WcbArgType.STRING,
        WcbArgType.ARRAY,
        "hello",
        &arr
    )!!;
}
