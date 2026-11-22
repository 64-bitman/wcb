module wcb::test::connection @test;

import wcb::core::types;
import wcb::core::wire @public;
import wcb::core::connection @public;
import std::collections::map;
import std::collections::list;
import libc;

struct TestConnection (WcbConnectionImpl, WcbIOImpl)
{
    inline WcbConnection base;

    HashMap{WcbId, any} objects;
    WcbId next_id;

    WcbWord[] in;
    Fd[] in_fds;

    List{char} out;
    List{Fd} out_fds;

    List{Fd} closed_fds;
}

fn void TestConnection.init(&self, Allocator allocator)
{
    self.base.init(allocator, self);
    self.base.set_io(self);

    self.objects.init(allocator);
    self.next_id = 0;

    self.in = {};
    self.in_fds = {};

    self.out.init(allocator);
    self.out_fds.init(allocator);

    self.closed_fds.init(allocator);
}

fn void TestConnection.uninit(&self)
{
    self.base.uninit();
    self.objects.free();

    self.out.free();
    self.out_fds.free();

    self.closed_fds.free();
}

fn WcbId? TestConnection.insert(&self, WcbObject obj) @dynamic
{
    return 0;
}

fn void TestConnection.remove(&self, WcbId id) @dynamic
{
}

fn any? TestConnection.lookup(&self, WcbId id) @dynamic
{
    return {};
}

fn bool? TestConnection.dispatch(&self, WcbMessage* msg) @dynamic
{
    return false;
}

fn WcbWord[]? TestConnection.read(&self) @dynamic
{
    return {};
}

fn void TestConnection.read_finish(&self, sz words_consumed) @dynamic
{
}

fn Fd? TestConnection.read_fd(&self) @dynamic
{
    return -1;
}

fn void TestConnection.close_fd(&self, Fd fd) @dynamic
{
}

fn void TestConnection.discard_fds(&self, sz n) @dynamic
{
}

fn void TestConnection.send(&self, char[] data) @dynamic
{
}

fn void TestConnection.send_fd(&self, Fd fd) @dynamic
{
}

fn bool? TestConnection.flush(&self) @dynamic
{
    return true;
}

fn void test_unmarshal() => @pool()
{
    TestConnection ct;

    ct.init(tmem);
    defer ct.uninit();
}
