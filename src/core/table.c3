module wcb::core::table @private;

import wcb::core::types;
import std::collections::list;

excuse OBJECT_LIMIT_REACHED, INVALID_OBJECT_ID;

// Maximum number of objects per entity
const uint MAX_OBJECTS = 0x00f00000;

union WcbTableSlot @local
{
    WcbObject* ptr;
    uptr next_free;
}

struct WcbTable
{
    // The entity that "slots" represents
    WcbEntity entity;

    // Objects allocated by us
    List{WcbTableSlot} slots;
    // Objects allocated by the peer.
    List{WcbObject*} peer_objects;

    uint next_free;  // Next free slot in "slots"
}

fn void WcbTable.init(&self, WcbEntity entity, Allocator allocator)
{
    self.entity = entity;

    self.slots.init(allocator, 0);
    self.peer_objects.init(allocator, 0);

    self.next_free = 0;  // Bottom bit is unused
}

fn void WcbTable.uninit(&self)
{
    self.slots.free();
    self.peer_objects.free();
}

<*
 @param [&own] obj : "Object to insert"
 @return "Newly allocated id for object"
 @return? OBJECT_LIMIT_REACHED
*>
fn WcbId? WcbTable.insert(&self, WcbObject* obj)
{
    uint base = self.entity.base_id;
    uint i = self.next_free >> 1;
    bool full = i == (uint)self.slots.len();

    if (full && self.slots.len() >= MAX_OBJECTS)
    {
        return OBJECT_LIMIT_REACHED~;
    }

    WcbTableSlot* slot;

    if (full)
    {
        // Must grow array
        self.slots.reserve(1);
        slot = &self.slots.entries[self.slots.size++];

        self.next_free = (uint)self.slots.len() << 1;
    }
    else
    {
        // Reuse slot
        slot = &self.slots.entries[i];
        assert((slot.next_free & 1) == 0);

        self.next_free = (uint)slot.next_free;
    }

    slot.ptr = obj;

    return base + i;
}

<*
 "If 'id' is not valid, fault."

 @return "Entity that this id was created by"
 @return? INVALID_OBJECT_ID
*>
fn WcbEntity? id_is_valid(
    WcbId id,
    WcbEntity entity,
    WcbTable* table,
    bool new = false
) @local
{
    if (id < WcbEntity.CLIENT.base_id
        || id > WcbEntity.SERVER.base_id + MAX_OBJECTS)
    {
        return INVALID_OBJECT_ID~;
    }

    WcbEntity id_entity = id < WcbEntity.SERVER.base_id ? WcbEntity.CLIENT
    : WcbEntity.SERVER;

    // Check if id is within bounds
    if (id_entity == table.entity)
    {
        if ((sz)(id - id_entity.base_id) >= table.slots.len())
        {
            return INVALID_OBJECT_ID~;
        }
    }
    else
    {
        if (new)
        {
            // New objects can only have an id one greater than the current
            // highest id.
            if ((sz)(id - id_entity.base_id) > table.peer_objects.len())
            {
                return INVALID_OBJECT_ID~;
            }
        }
        else
        {
            if ((sz)(id - id_entity.base_id) >= table.peer_objects.len())
            {
                return INVALID_OBJECT_ID~;
            }
        }
    }

    return id_entity;
}

<*
 @param id : "Id of object"
 @param [&own] obj : "Peer created object"
 @return? INVALID_OBJECT_ID
*>
fn void? WcbTable.insert_peer(&self, WcbId id, WcbObject* obj)
{
    WcbEntity id_entity = id_is_valid(id, self.entity, self, true)!;

    if (id_entity == self.entity) return INVALID_OBJECT_ID~;

    uint i = id - id_entity.base_id;

    if (i == self.peer_objects.len())
    {
        self.peer_objects.reserve(1);
        self.peer_objects.size++;
    }
    else if (self.peer_objects.get(i) != null)
    {
        return INVALID_OBJECT_ID~;
    }

    self.peer_objects.set(i, obj);
}

<*
 "Remove the object with the id from the table. No-op if object does not exist."

 @return? id_is_valid!
*>
fn void? WcbTable.remove(&self, WcbId id)
{
    WcbEntity id_entity = id_is_valid(id, self.entity, self)!;
    uint i = id - id_entity.base_id;

    if (id_entity == self.entity)
    {
        // Id was created by us
        WcbTableSlot* slot;

        slot = &self.slots.entries[i];

        if (slot.next_free & 1)
        {
            // Slot is empty
            return;
        }

        slot.next_free = (uptr)((self.next_free << 1) | 0x1);
        self.next_free = i << 1;
    }
    else
    {
        // Id was created by peer
        WcbObject** ptr = self.peer_objects.get_ref(i);

        *ptr = null;
    }
}

<*
 "Lookup the object with the id. If object does not exist, return null"

 @return? INVALID_OBJECT_ID
*>
fn WcbObject*? WcbTable.lookup(&self, WcbId id)
{
    WcbEntity id_entity = id_is_valid(id, self.entity, self)!;
    uint i = id - id_entity.base_id;

    if (id_entity == self.entity)
    {
        WcbTableSlot* slot = &self.slots.entries[i];

        if (slot.next_free & 1) return null;

        // Must unset bottom bit
        return (WcbObject*)(slot.next_free & ~((uptr)1));
    }
    else
    {
        return self.peer_objects.get(i);
    }
}

// Test manipulating objects created by us
fn void test_host() @test @public
{
    WcbTable table;

    table.init(WcbEntity.CLIENT, mem);
    defer table.uninit();

    WcbObject obj1, obj2;
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
    test::@error(table.remove(100), INVALID_OBJECT_ID);
    test::@error(table.lookup(0), INVALID_OBJECT_ID);
}

// Test manipulating objects created by peer
fn void test_peer() @test @public
{
    WcbTable table;

    table.init(WcbEntity.CLIENT, mem);
    defer table.uninit();

    WcbObject obj1, obj2, invalid_obj;

    obj1.id = WcbEntity.SERVER.base_id;
    obj2.id = WcbEntity.SERVER.base_id + 1;
    invalid_obj.id = WcbEntity.SERVER.base_id + 100;

    table.insert_peer(obj1.id, &obj1)!!;
    test::eq(table.lookup(obj1.id)!!, &obj1);
    table.insert_peer(obj2.id, &obj2)!!;
    test::eq(table.lookup(obj1.id)!!, &obj1);
    test::eq(table.lookup(obj2.id)!!, &obj2);

    test::@error(table.insert_peer(obj1.id, &obj2), INVALID_OBJECT_ID);
    test::@error(table.insert_peer(obj2.id, &obj2), INVALID_OBJECT_ID);

    table.remove(obj1.id)!!;
    table.remove(obj1.id)!!;  // No-op
    test::eq(table.lookup(obj1.id)!!, null);

    table.insert_peer(obj1.id, &obj1)!!;
}
