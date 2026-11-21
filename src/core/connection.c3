module wcb::core::connection;

import wcb::core::types;
import wcb::core::table @public;
import std::core::mem::allocators;
import std::collections::list;
import std::collections::ringbuffer;
import libc;

typedef WcbVec = char[];
alias WcbFdFunc = fn Fd?(sz n_discard, Fd close_fd, void* udata);
alias WcbWriteFunc = fn sz?(WcbWord[] data, Fd[] fds, sz* fds_sent, void* udata);

const uint MAX_MESSAGE_LEN = 4096;
const uint MAX_MESSAGE_ARGS = 20;

macro get_remaining(slice, ptr) @local
{
    return (slice.len - (ptr - slice.ptr));
}

struct WcbZombie @local
{
    WcbId id;
    WcbInterface* iface;
}

struct WcbConnection
{
    Allocator allocator;

    WcbTable objects;
    List{WcbZombie} zombies;

    List{WcbWord} output;
    List{Fd} fd_output;
}

<*
@param entity : "If connection is for the client or server"
@param [&inout] allocator : "Allocator to use"
    *>
fn void WcbConnection.init(&self, WcbEntity entity, Allocator allocator)
{
    self.allocator = allocator;
    self.objects.init(entity, allocator);
    self.zombies.init(allocator);
    self.output.init(allocator);
}

fn void WcbConnection.uninit(&self)
{
    self.objects.uninit();
    self.zombies.free();
    self.output.free();
}

<*
@param [inout] buf : "Data to read"
@param fd_func : "Function pointer to read file descriptors"
@param udata : "User data for `func`"
@return "Number of words read"
    *>
fn sz? WcbConnection.feed(&self, WcbWord[] buf, WcbFdFunc fd_func, void* udata)
{
    WcbWord* ptr = buf;

    while (true)
    {
        WcbWord[2] header;

        if (get_remaining(buf, ptr) < header.len) break;

        header[0] = ptr[0];
        header[1] = ptr[1];
        ptr += 2;

        WcbHalfWord msg_len = (WcbHalfWord)(header[1] >> WcbHalfWord::size);

        // Message length must be at least 8 bytes and a multiple of word size
        if (msg_len < 8 || (msg_len & 3) != 0)
        {
            return types::INVALID_MESSAGE_LENGTH~;
        }
        if (msg_len > MAX_MESSAGE_LEN)
        {
            return types::MESSAGE_TOO_LARGE~;
        }

        if (msg_len > get_remaining(buf, ptr)) break;

        WcbHalfWord arg_words = (msg_len - 8) >> 2;
        WcbId obj_id = header[0];
        WcbHalfWord opcode = (ushort)(header[1] & 0x0000ffffU);
        WcbZombie* zombie = null;
        WcbObject* obj;

        foreach (&z : self.zombies)
        {
            if (z.id == obj_id)
            {
                zombie = z;
                break;
            }
        }

        if (zombie != null)
        {
            // Object is a zombie, consume message and any file descriptors.
            ptr += arg_words;
            (void)fd_func(zombie.iface.get_message(opcode)!.n_fd_args,
            -1, udata);
            continue;
        }

        obj = self.objects.lookup(obj_id) ?? types::OBJECT_DOES_NOT_EXIST~!;
        if (obj == null)
        {
            ptr += arg_words;
            continue;
        }

        WcbObjectImpl impl = obj;

        if (!& impl.get_interface) abort("Object has no interface");

        WcbArg[MAX_MESSAGE_ARGS] args;
        WcbInterface* iface = impl.get_interface();
        WcbMessageDesc* desc = iface.get_message(opcode)!;

        if (desc.signature.len > MAX_MESSAGE_ARGS)
        {
            abort("Message signature has too many arguments");
        }

        // Unmarshal arguments from message
        foreach (idx, WcbArgSignature sig : desc.signature)
        {
            // File descriptor arguments take up no bytes
            if (sig.type != WcbArgType.FD)
            {
                if (get_remaining(buf, ptr) == 0) return types::SHORT_MESSAGE~;
            }

            switch (sig.type)
            {
                case INT:
                    args.[idx].i = (int)*ptr++;
                case UINT:
                    args.[idx].u = (uint)*ptr++;
                case FIXED:
                    args.[idx].f = (WcbFixed)*ptr++;
                case STRING:
                case ARRAY:
                    WcbWord len = *ptr++;  // In bytes
                    bool is_array = sig.type == WcbArgType.ARRAY;

                    if (len == 0)
                    {
                        if (!is_array && !sig.nullable) return types::NULL_ARG~;

                        if (is_array)
                        {
                            args[idx].a = {};
                        }
                        else
                        {
                            args[idx].s = {};
                        }
                        continue;
                    }

                    if (len > get_remaining(
                            buf,
                            ptr
                        )) return types::SHORT_MESSAGE~;

                    sz word_len = mem::aligned_offset(
                        len,
                        WcbWord::alignment
                    ) >> 2;

                    if (!is_array)
                    {
                        // String should have NUL byte (included in length), but
                        // no interior NUL bytes.
                        if (ptr[len - 1] != '\0') return types::BAD_STRING~;

                        for (WcbWord i = 0; i < len - 1; i++)
                        {
                            if (ptr[i] == '\0') return types::BAD_STRING~;
                        }
                    }

                    if (is_array)
                    {
                        args[idx].a = (ptr--)[:word_len];
                    }
                    else
                    {
                        args[idx].s =
                        (String)(((char*)((ptr--)[:word_len]))[:len]);
                    }
                    ptr += word_len;
                case OBJECT:
                    WcbId arg_id = *ptr++;

                    if (arg_id == 0)
                    {
                        if (!sig.nullable) return types::NULL_ARG~;

                        args[idx].o = null;
                        continue;
                    }

                    WcbObject* arg_obj = self.objects.lookup(arg_id)!;

                    if (arg_obj == null) return types::OBJECT_DOES_NOT_EXIST~;

                    // Check if interface matches
                    WcbObjectImpl aimpl = arg_obj;

                    if (!& aimpl.get_interface) abort("Object has no interface");

                    if (!impl.get_interface().equal(aimpl.get_interface()))
                    {
                        return types::BAD_OBJECT~;
                    }

                    args[idx].o = arg_obj;
                case NEW_ID:
                    WcbId new_id = *ptr++;

                    if (new_id == 0) return types::NULL_ARG~;

                    // Check if object already exists. This will also validate
                    // the id.
                    WcbObject* o = self.objects.lookup(new_id)!;

                    if (obj != null) return types::OBJECT_EXISTS~;

                    args[idx].n = {
                        .id = new_id,
                        .version = obj.version,
                        .ct = self
                    };
                case FD:
                    args[idx].h = fd_func(0, -1, udata)!;
                default:
                    abort("Unknown argument type %d", sig.type.ordinal);
            }
        }

        bool dispatched = impl.dispatch(opcode, args[..])!;

        // If no method was dispatched, then close any fd arguments
        if (!dispatched && desc.n_fd_args > 0)
        {
            foreach (idx, WcbArgSignature sig : desc.signature)
            {
                if (sig.type != WcbArgType.FD) continue;
                (void)fd_func(0, args[idx].h, udata);
            }
        }
    }

    return ptr - buf.ptr;
}

<*
*>
fn void? WcbConnection.flush(&self, WcbWriteFunc write_func, void* udata)
{
    WcbWord[] buf = self.output.array_view();
    Fd[] fd_buf = self.fd_output.array_view();
}

<*
 @param [&inout] obj : "Object to marshal message for"
 @param opcode : "Opcode of message"
 @param ... : "Types of arguments, then the argument values"
*>
macro WcbConnection.marshal_object(
    &self, WcbObject* obj, WcbHalfWord opcode, ...
)
{
    var $n_args = $vaarg.len / 2;
    sz words = 0;  // In words

    // Find size of message arguments
    $for var $i = 0; $i < $n_args; $i++:
        $if $reflect($vaarg[$i]).type != WcbArgType:
            $error("Argument type is not WcbArgType!");
        $endif

        $switch ($vaarg[$i]):
            $case WcbArgType.INT:
            $case WcbArgType.UINT:
            $case WcbArgType.FIXED:
            $case WcbArgType.OBJECT:
            $case WcbArgType.NEW_ID:
                words += WcbWord::size;
            $case WcbArgType.STRING:
            $case WcbArgType.ARRAY:
                words += WcbWord::size + mem::aligned_offset(
                    $vaarg[$n_args + $i].len, WcbWord::size);
            $case WcbArgType.FD:
        $endswitch
    $endfor

    if (words > MAX_MESSAGE_LEN)
    {
        // Message to large
        return;
    }

    self.output.reserve(words);
    WcbWord* buf = &self.output.array_view()[self.output.len()];

    *buf++ = (WcbWord)obj.id;
    // Message length includes header
    *buf++ = (WcbWord)((((words * 4 + 8) << 16) | (opcode & 0xffff)));
    WcbWord slen;
    sz min;

    $for var $i = 0; $i < $n_args; $i++:
        $switch ($vaarg[$i]):
            $case WcbArgType.INT:
            $case WcbArgType.UINT:
            $case WcbArgType.FIXED:
                *buf++ = (WcbWord)($vaarg[$n_args + $i]);
            $case WcbArgType.OBJECT:
            $case WcbArgType.NEW_ID:
                *buf++ = (WcbWord)($vaarg[$n_args + $i].id);
            $case WcbArgType.STRING:
            $case WcbArgType.ARRAY:
                slen = (WcbWord)($vaarg[$n_args + $i].len);
                min = slen & ~3U;

                *buf++ = slen;

                mem::copy(buf, $vaarg[$n_args + $i].ptr, min);
                // Advance by lowest multiple of word size
                buf += min >> 2;

                // If length if not a multiple of word size, copy leftover
                // bytes.
                if (min - slen > 0)
                {
                    WcbWord w = 0;
                    min >>= 2;
                    mem::copy(&w, $vaarg[$n_args + $i][slen - min..], min);
                    mem::copy(buf++, &w, WcbWord::size);
                }
            $case WcbArgType.FD:
                self.fd_output.push($vaarg[$n_args + $i]);
        $endswitch
    $endfor

    self.output.size += words;
}

<*
 @param [&own] obj : "Object to add to connection"
 @require obj.ct == self
 @return? WcbTable.insert_peer!
*>
fn void? WcbConnection.add_object(&self, WcbObject* obj)
{
    WcbWord[] test;
    self.objects.insert_peer(obj.id, obj)!;
}

<*
 @param [&own] obj : "Object to create for connection"
 @return? WcbTable.insert!
*>
fn void? WcbConnection.create_object(&self, WcbObject* obj, WcbVersion version)
{
    WcbId id = self.objects.insert(obj)!;
    obj.id = id;
    obj.version = version;
    obj.ct = self;
}
