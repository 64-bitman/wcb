module wcb::core::connection <ObjectType> @private;

import wcb::core::types;
import wcb::core::wire @public;
import libc;

const sz MESSAGE_MAX_LEN = 4096;
const uint MESSAGE_MAX_ARGS = 20;

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
}

<*
 @param [&inout] allocator : "Allocator to use"
 @param [&inout] impl : "Implementation to use"
 @param [&inout] io : "IO implementation to use"
*>
fn void WcbConnection.init(
    &self,
    WcbConnectionImpl impl,
    WcbIOImpl io,
    Allocator allocator)
{
    self.allocator = allocator;
    self.impl = impl;
    self.io = io;
}

fn void WcbConnection.uninit(&self)
{
    if (&self.io.flush)
    {
        (void)self.io.flush();  // Flush any pending data before closing
    }
    if (&self.io.destroy) self.io.destroy();
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
        WcbWord* header = self.io.read(2)!;

        if (header == null) break;  // Incomplete header

        WcbHalfWord msg_len = (WcbHalfWord)(header[1] >> 16);

        // Message must be at least 8 bytes and a multiple of word size
        if (msg_len < 8 || (msg_len & 3) != 0)
        {
            return types::INVALID_MESSAGE_LENGTH~;
        }

        if (msg_len > MESSAGE_MAX_LEN) return types::MESSAGE_TOO_BIG~;

        WcbHalfWord msg_words = msg_len >> 2;
        WcbHalfWord arg_words = msg_words - 2;

        if (self.io.read(arg_words, peek: true)! == null)
        {
            // Incomplete message
            break;
        }

        WcbId obj_id = header[0];
        WcbHalfWord opcode = (WcbHalfWord)(header[1] & 0x0000ffff);

        WcbConnectionImpl impl = self.impl;
        ObjectType* obj;
        WcbObject obj_impl;
        WcbInterface* iface;
        WcbMessageDesc* desc;
        any lookup;

        defer try dispatched++;

        // Consider any fault a protocol error
        lookup = impl.lookup(obj_id)!;

        if (lookup.type != ObjectType::typeid)
        {
            // If null, then object does not exist. Otherwise if an interface,
            // then the object is a zombie. In both cases ignore the message and
            // consume any fd args (if possible).
            self.io.read(arg_words, skip: true)!;
            if (lookup.type == WcbInterface::typeid)
            {
                iface = lookup.as(WcbInterface*);
                desc = iface.get_message(opcode)!;
                self.io.read_fd(n_discard: desc.n_fd_args)!;
            }
            continue;
        }

        obj = (ObjectType*)lookup;
        obj_impl = obj;
        iface = obj_impl.get_interface();
        desc = iface.get_message(opcode)!;

        if (desc.signature.len > MESSAGE_MAX_ARGS)
        {
            unreachable("Message has too many arguments!");
        }

        WcbArg[MESSAGE_MAX_ARGS] args;

        // Unmarshal message arguments
        foreach (arg_idx, WcbArgSignature sig : desc.signature)
        {
            WcbArg* arg = &args[arg_idx];
            WcbWord first_word;

            // Fd args do not take up any space
            if (sig.type != FD)
            {
                WcbWord* wp = self.io.read(1)!;

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
                    WcbWord* data = self.io.read(word_len)!;

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
                    arg.n.parent = obj_impl;
                case FD:
                    arg.h = self.io.read_fd()!;
                    if (arg.h == -1) return types::EXPECTED_FD~;
                default:
                    unreachable("Unknown arg type %d!", sig.type);
            }
        }

        WcbMessage msg = {
            .obj = obj_impl,
            .opcode = opcode,
            .args = args[:desc.signature.len]
        };

        if (!impl.handle(&msg)!)
        {
            // Message was not handled, close any fd args
            foreach (arg_idx, WcbArgSignature sig : desc.signature)
            {
                if (sig.type != FD) continue;

                self.io.read_fd(close: args[arg_idx].h)!;
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
 @return? types::MESSAGE_TOO_BIG
*>
macro WcbConnection.send(&self, WcbId obj_id, WcbHalfWord opcode, ...)
{
    var $n_args = $vaarg.len / 2;
    sz msg_words = 2;  // Message length includes header

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
                msg_words += 0;
        $endswitch
    $endfor

    if (msg_words > MESSAGE_MAX_LEN >> 2) return types::MESSAGE_TOO_BIG~;

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
                self.io.write({}, fd: (Fd)$vaarg[$n_args + $i]);
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
