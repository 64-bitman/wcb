module wcb::core::connection <ObjectType> @private;

import wcb::core::types;
import wcb::core::wire @public;
import libc;

interface WcbConnectionImpl
{
    // Return object with given id, or null if object does not exist. This
    // should also validate the "id" every time (and fault if invalid).
    fn any? lookup(WcbId id) @optional;

    // Handle the message
    fn bool? handle(WcbMessage* message) @optional;
}

struct WcbConnection
{
    Allocator allocator;
    WcbConnectionImpl impl;
    WcbIOImpl io;

    WcbWord[] buf;
    sz buf_woff; // In words
    sz buf_len; // In bytes
}

<*
 @param [&inout] allocator : "Allocator to use"
 @param [&inout] impl : "Implementation to use"
 @param [&inout] io : "IO implementation to use"
 @param buf_size : "Buffer size to use in bytes (must be power of 2)"
 @require buf_size % 4 == 0
*>
fn void WcbConnection.init(
    &self,
    WcbConnectionImpl impl,
    WcbIOImpl io,
    Allocator allocator,
    sz buf_size = types::MESSAGE_MAX_LEN * 2)
{
    self.allocator = allocator;
    self.impl = impl;
    self.io = io;

    self.buf = alloc::alloc_array(allocator, WcbWord, buf_size >> 2);
    self.buf_woff = 0;
    self.buf_len = 0;
}

fn void WcbConnection.uninit(&self)
{
    // Flush any pending data before closing
    (void)self.io.flush();

    if (&self.io.destroy) self.io.destroy();

    alloc::free(self.allocator, self.buf);
}

fn WcbWord*? get_words(
    WcbConnection* ct,
    sz n_words,
    bool peek = false,
    bool move = false) @local
{
    sz n_bytes = n_words * WcbWord::size;
    char* bytebuf = (char*)ct.buf;

    if (move && n_bytes > ct.buf_len)
    {
        // Try reading more data
        if (ct.buf_woff > 0)
        {
            sz off = ct.buf_woff * WcbWord::size;
            mem::move(&ct.buf, bytebuf + off, ct.buf_len);
            ct.buf_woff = 0;
        }

        sz remain = (ct.buf.len * WcbWord::size) - ct.buf_len;
        sz r = ct.io.read(bytebuf[:remain])!;

        ct.buf_len += r;
    }

    if (n_bytes > ct.buf_len) return null; // Not enough data

    WcbWord* ptr = &ct.buf[ct.buf_woff];

    if (!peek)
    {
        ct.buf_woff += n_words;
        ct.buf_len -= n_bytes;
    }
    return ptr;
}

<*
 @param max_dispatch : "Maximum number of messages to dispatch, default all"
 @return "Number of messages dispatched, any fault is considered fatal"
 @return? WcbIOImpl.read!, WcbConnectionImpl.lookup!
*>
fn sz? WcbConnection.dispatch(&self, sz max_dispatch = sz::max)
{
    sz dispatched = 0;

    while (dispatched < max_dispatch)
    {
        // Only allow shifting memory around now, because later strings/array
        // args may point into it.
        WcbWord* header_data = get_words(self, 2, move: true)!;

        if (header_data == null) break;  // Incomplete header

        WcbWord[2] header;

        mem::copy(&header, header_data, header.len * WcbWord::size);

        WcbHalfWord msg_len = (WcbHalfWord)(header_data[1] >> 16);

        // Message must be at least 8 bytes and a multiple of word size
        if (msg_len < 8 || (msg_len & 3) != 0)
        {
            return types::INVALID_MESSAGE_LENGTH~;
        }

        if (msg_len > types::MESSAGE_MAX_LEN) return types::MESSAGE_TOO_BIG~;

        WcbHalfWord msg_words = msg_len >> 2;
        WcbHalfWord arg_words = msg_words - 2;

        if (get_words(self, arg_words, peek: true)! == null)
        {
            // Incomplete message
            break;
        }

        WcbId obj_id = header_data[0];
        WcbHalfWord opcode = (WcbHalfWord)(header_data[1] & 0x0000ffff);

        WcbConnectionImpl impl = self.impl;
        ObjectType* obj;
        WcbObject obj_iface; // Implementation of the actual protocol object
        WcbInterface* iface;
        WcbMessageDesc* desc;
        any lookup;
        any obj_type;

        defer try dispatched++;

        // Consider any fault a protocol error
        lookup = impl.lookup(obj_id)!;

        if (lookup.type != ObjectType::typeid)
        {
            // If null, then object does not exist. Otherwise if an interface,
            // then the object is a zombie. In both cases ignore the message and
            // consume any fd args (if possible).
            (void)get_words(self, arg_words);

            if (lookup.type == WcbInterface::typeid)
            {
                iface = lookup.as(WcbInterface*);
                desc = iface.get_message(opcode)!;
                (void)self.io.read_fd(n_discard: desc.n_fd_args)!;
            }
            continue;
        }

        obj = (ObjectType*)lookup;
$if !$defined(obj.type):
    $error("Object does not have type member!");
$endif
        obj_type = lookup.retype_to(obj.type);
        obj_iface = (WcbObject)obj_type;
        iface = obj_iface.get_interface();
        desc = iface.get_message(opcode)!;

        if (desc.signature.len > types::MESSAGE_MAX_ARGS)
        {
            unreachable("Message has too many arguments!");
        }

        WcbArg[types::MESSAGE_MAX_ARGS] args;

        // Unmarshal message arguments
        foreach (arg_idx, WcbArgSignature sig : desc.signature)
        {
            WcbArg* arg = &args[arg_idx];
            WcbWord first_word;

            // Fd args do not take up any space
            if (sig.type != FD)
            {
                WcbWord* wp = get_words(self, 1)!;

                if (wp == null) return types::SHORT_MESSAGE~;
                first_word = *wp;
            }

            switch (sig.type)
            {
                case INT:
                    arg.i = (int)first_word;
                case UINT:
                    arg.u = (uint)first_word;
                case FIXED:
                    arg.f = (WcbFixed)first_word;
                case STRING:
                case ARRAY:
                    bool is_array = sig.type == ARRAY;
                    WcbWord len = first_word;

                    if (len == 0)
                    {
                        if (sig.nullable) break;
                        if (!is_array) return types::NULL_STRING~;
                        break;
                    }

                    sz word_len = mem::aligned_offset(len, WcbWord::size) >> 2;

                    // Validate string/array length
                    WcbWord* data = get_words(self, word_len)!;

                    if (data == null) return types::SHORT_MESSAGE~;

                    if (is_array)
                    {
                        arg.a = ((char *)data)[:len];
                        break;
                    }

                    // String must be NUL terminated, but not have any interior
                    // NUL bytes.
                    char* str = (char*)data;

                    if (str[len - 1] != '\0') return types::INVALID_STRING~;

                    for (WcbWord i = 0; i < len - 1; i++)
                    {
                        if (str[i] == '\0') return types::INVALID_STRING~;
                    }

                    arg.s = (String)(str[:len - 1]); // Don't include NUL
                case OBJECT:
                    WcbId arg_id = first_word;

                    if (arg_id == 0)
                    {
                        if (!sig.nullable) return types::NULL_OBJECT~;

                        arg.o = null;
                        break;
                    }

                    any arg_lookup = impl.lookup(arg_id)!;

                    if (arg_lookup.type != ObjectType::typeid)
                    {
                        if (arg_lookup.type == WcbInterface::typeid)
                        {
                            // Object is a zombie, just set arg to null
                            arg.o = null;
                            break;
                        }
                        return types::OBJECT_NOT_EXISTS~;
                    }

                    arg.o = (WcbObject)anycast(arg_lookup, ObjectType)!!;
                case NEW_ID:
                    WcbId new_id = first_word;

                    // new_id type cannot be null
                    if (new_id == 0) return types::NULL_OBJECT~;

                    // Check if object with id already exists
                    any new_lookup = impl.lookup(new_id)!;

                    if (new_lookup != null) return types::INVALID_NEW_ID~;

                    arg.n.id = new_id;
                    arg.n.parent = obj_iface;
                case FD:
                    arg.h = self.io.read_fd()!;
                    if (arg.h == -1) return types::EXPECTED_FD~;
                default:
                    unreachable("Unknown arg type %d!", sig.type);
            }
        }

        WcbMessage msg = {
            .obj = obj_iface,
            .opcode = opcode,
            .args = args[:desc.signature.len]
        };

        if (!impl.handle(&msg)!)
        {
            // Message was not handled, close any fd args
            foreach (arg_idx, WcbArgSignature sig : desc.signature)
            {
                if (sig.type != FD) continue;

                (void)self.io.read_fd(close: args[arg_idx].h)!;
            }
        }
    }

    return dispatched;
}

macro write_word(WcbIOImpl io, WcbWord word) @local
{
    io.write(((char*)(&word))[:WcbWord::size]);
}

<*
 @param obj_id : "Id of object the message is for"
 @param opcode : "Opcode of message"
 @param ... : "Argument types, then argument values"
 @return? types::MESSAGE_TOO_BIG, WcbIOImpl.dup_fd!
*>
macro WcbConnection.send(&self, WcbId obj_id, WcbHalfWord opcode, ...)
{
    var $n_args = $vaarg.len / 2;
    sz msg_words = 2;  // Message length includes header
    var $n_fds = 0;

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
                msg_words++;
            $case WcbArgType.STRING:
            $case WcbArgType.ARRAY:
                msg_words += 1 + (mem::aligned_offset(
                        $vaarg[$n_args + $i].len, WcbWord::size) >> 2);
            $case WcbArgType.FD:
                $n_fds++;
        $endswitch
    $endfor

    $if $n_fds > types::MESSAGE_MAX_FDS:
        $error("Message has too many fd args!");
    $endif
    if (msg_words > types::MESSAGE_MAX_LEN >> 2) return types::MESSAGE_TOO_BIG~;

    WcbHalfWord msg_len = (WcbHalfWord)msg_words * 4;

    write_word(self.io, obj_id);
    write_word(self.io, (msg_len << 16) | (opcode & 0xffff));

    WcbWord slen;
    sz min;

    $for var $i = 0; $i < $n_args; $i++:
        $switch ($vaarg[$i]):
            $case INT:
            $case UINT:
            $case FIXED:
                write_word(self.io, (WcbWord)$vaarg[$n_args + $i]);
            $case OBJECT:
            $case NEW_ID:
                write_word(self.io, (WcbWord)$vaarg[$n_args + $i]);
            $case STRING:
            $case ARRAY:
                slen = $vaarg[$n_args + $i].len;  // In bytes
                min = (slen & ~3U);

                if ($vaarg[$i] == STRING) slen++; // Length includes NUL
                write_word(self.io, slen);

                self.io.write($vaarg[$n_args + $i]);
                $if $vaarg[$i] == STRING:
                    self.io.write(((char*)&&'\0')[:1]); // Add NUL byte
                $endif

                // If length if not a multiple of word size, copy leftover
                // bytes.
                if (slen - min > 0)
                {
                    char[4] buf;

                    self.io.write(buf[(slen - min)..]);
                }
            $case FD:
                self.io.write({}, fd: self.io.dup_fd($vaarg[$n_args + $i])!);
        $endswitch
    $endfor
}

<*
 @return "Return true if all pending messages were sent, otherwise false"
 @return? WcbIOImpl.flush!
*>
fn bool? WcbConnection.flush(&self)
{
    return self.io.flush();
}

<*
 @param events : "Events to poll for"
 @return "Events returned"
 @return? WcbIOImpl.flush!
*>
fn WcbIOEvents? WcbConnection.poll(&self, WcbIOEvents events)
{
    return self.io.poll(events)!;
}
