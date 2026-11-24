module wcb::test::table @test;

import wcb::core::types;
import wcb::core::wire @public;
import wcb::core::table @public;

struct TestObject @local
{
    WcbId id;
}

// Test manipulating objects created by us
fn void test_host()
{
    WcbTable{TestObject} table;

    table.init(WcbEntity.CLIENT, mem);
    defer table.uninit();

    TestObject obj1, obj2;
    WcbId id1, id2;

    id1 = table.insert(&obj1)!!;
    test::eq(table.lookup(id1)!!, &obj1);

    id2 = table.insert(&obj2)!!;
    test::eq(table.lookup(id2)!!, &obj2);

    // Remove object
    table.remove(id1)!!;
    test::eq(table.lookup(id1)!!, null);

    table.remove(id1)!!;  // No-op
    test::eq(table.lookup(id2)!!, &obj2);

    // Invalid ids
    test::@error(table.remove(100), types::BAD_OBJECT_ID);
    test::@error(table.lookup(0), types::BAD_OBJECT_ID);
}

// Test manipulating objects created by peer
fn void test_peer()
{
    WcbTable{TestObject} table;

    table.init(WcbEntity.CLIENT, mem);
    defer table.uninit();

    TestObject obj1, obj2, invalid_obj;

    obj1.id = WcbEntity.SERVER.base_id;
    obj2.id = WcbEntity.SERVER.base_id + 1;
    invalid_obj.id = WcbEntity.SERVER.base_id + 100;

    table.insert_peer(obj1.id, &obj1)!!;
    test::eq(table.lookup(obj1.id)!!, &obj1);
    table.insert_peer(obj2.id, &obj2)!!;
    test::eq(table.lookup(obj1.id)!!, &obj1);
    test::eq(table.lookup(obj2.id)!!, &obj2);

    test::@error(table.insert_peer(obj1.id, &obj2), types::BAD_OBJECT_ID);
    test::@error(table.insert_peer(obj2.id, &obj2), types::BAD_OBJECT_ID);

    table.remove(obj1.id)!!;
    table.remove(obj1.id)!!;  // No-op
    test::eq(table.lookup(obj1.id)!!, null);

    table.insert_peer(obj1.id, &obj1)!!;
}
