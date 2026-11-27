module wcb::core::table <ObjectType> @private;

import wcb::core::types;
import wcb::core::wire @public;
import std::collections::list;

// Maximum number of objects per entity
const uint MAX_OBJECTS = 0x00f00000;

union WcbTableSlot @local
{
    // Bit 0 is 1 if slot is unoccupied, Bit 1 is a boolean flag (only used if
    // bit 0 is 0).
    void* ptr;
    uptr next_free;
}

struct WcbTable
{
    // The entity that "slots" represents
    WcbEntity entity;

    // Objects allocated by us
    List{WcbTableSlot} slots;
    // Objects allocated by the peer.
    List{ObjectType*} peer_objects;

    uint next_free;  // Next free slot in "slots"
}

fn void WcbTable.init(&self, WcbEntity entity, Allocator allocator)
{
    self.entity = entity;

    self.slots.init(allocator, 0);
    self.peer_objects.init(allocator, 0);

    self.next_free = 0;  // Bottom two bits is unused
}

fn void WcbTable.uninit(&self)
{
    self.slots.free();
    self.peer_objects.free();
}

<*
 @param [&own] obj : "Object to insert"
 @return "Newly allocated id for object"
 @return? types::OBJECT_LIMIT_REACHED
*>
fn WcbId? WcbTable.insert(&self, ObjectType* obj)
{
    uint base = self.entity.base_id;
    uint i = self.next_free >> 1;
    bool full = i == (uint)self.slots.len();

    if (full && self.slots.len() >= MAX_OBJECTS)
    {
        return types::OBJECT_LIMIT_REACHED~;
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
        assert(slot.next_free & 1);

        self.next_free = (uint)slot.next_free;
    }

    slot.ptr = obj;

    return base + i;
}

<*
 @param id : "Id to check"
 @param entity : "Required entity type"
 @param table : "Table to use"
 @param new : "If id may be a new id"
 @return "Entity that this id was created by"
 @return? types::BAD_OBJECT_ID
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
        return types::BAD_OBJECT_ID~;
    }

    WcbEntity id_entity = id < WcbEntity.SERVER.base_id ? WcbEntity.CLIENT
    : WcbEntity.SERVER;

    // Check if id is within bounds
    if (id_entity == table.entity)
    {
        if ((sz)(id - id_entity.base_id) >= table.slots.len())
        {
            return types::BAD_OBJECT_ID~;
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
                return types::BAD_OBJECT_ID~;
            }
        }
        else
        {
            if ((sz)(id - id_entity.base_id) >= table.peer_objects.len())
            {
                return types::BAD_OBJECT_ID~;
            }
        }
    }

    return id_entity;
}

<*
 @param id : "Id of object"
 @param [&own] obj : "Peer created object"
 @return? types::BAD_OBJECT_ID
*>
fn void? WcbTable.insert_peer(&self, WcbId id, ObjectType* obj)
{
    WcbEntity id_entity = id_is_valid(id, self.entity, self, true)!;

    if (id_entity == self.entity) return types::BAD_OBJECT_ID~;

    uint i = id - id_entity.base_id;

    if (i == self.peer_objects.len())
    {
        self.peer_objects.reserve(1);
        self.peer_objects.size++;
    }
    else if (self.peer_objects.get(i) != null)
    {
        return types::BAD_OBJECT_ID~;
    }

    self.peer_objects.set(i, obj);
}

<*
 @param id : "Object to remove"
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
        ObjectType** ptr = self.peer_objects.get_ref(i);

        *ptr = null;
    }
}

<*
 @param id : "Object id to lookup"
 @param [out] flag : "Boolean flag associate with object"
 @return? types::BAD_OBJECT_ID
*>
fn void*? WcbTable.lookup(&self, WcbId id, bool* flag = null)
{
    WcbEntity id_entity = id_is_valid(id, self.entity, self)!;
    uint i = id - id_entity.base_id;

    if (id_entity == self.entity)
    {
        WcbTableSlot* slot = &self.slots.entries[i];

        if (slot.next_free & 1) return null;

        if (flag != null) * flag = (bool)(slot.next_free & 2);
        return (ObjectType*)(slot.next_free & ~((uptr)3));
    }
    else
    {
        if (flag != null) * flag = false;
        return self.peer_objects.get(i);
    }
}

<*
 @param id : "Object to replace"
 @param [&own] ptr : "Pointer to replace with"
 @param flag : "Boolean flag to set"
 @return? types::BAD_OBJECT_ID, types::OBJECT_NOT_EXISTS
*>
fn void? WcbTable.replace(&self, WcbId id, void* ptr, bool flag)
{
    WcbEntity id_entity = id_is_valid(id, self.entity, self)!;
    uint i = id - id_entity.base_id;

    if (id_entity != self.entity) return types::BAD_OBJECT_ID~;

    WcbTableSlot* slot = &self.slots.entries[i];

    // Slot should be occupied
    if (slot.next_free & 1) return types::OBJECT_NOT_EXISTS~;

    slot.ptr = ptr;
    slot.next_free |= (uptr)((uint)flag & 1) << 1;
}
