module wcb::test::connection @test;

import wcb::core::types;
import wcb::core::wire @public;
import wcb::core::connection @public;
import std::collections::map;
import libc;

struct TestConnection (WcbConnectionImpl, WcbIOImpl)
{
    inline WcbConnection base;

    HashMap{WcbId, any} objects;
    WcbId next_id;
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

fn void TestConnection.write(&self, WcbWord[] data) @dynamic
{
}

fn void TestConnection.write_fd(&self, Fd fd) @dynamic
{
}

fn bool? TestConnection.flush(&self) @dynamic
{
    return true;
}

fn void test_unmarshal() => @pool()
{
    TestConnection ct;

    ct.base.init(tmem);
    ct.base.set_impl(&ct);
}
