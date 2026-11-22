module wcb::core::connection @private;

import wcb::core::types;
import wcb::core::wire @public;
import libc;

const sz MESSAGE_MAX_LEN = 4096;
const uint MESSAGE_MAX_ARGS = 20;

interface WcbConnectionImpl
{
    fn void destroy() @optional;
    fn WcbId? insert(WcbObject obj);
    fn void remove(WcbId id);
    fn any? lookup(WcbId id);
    fn bool? dispatch(WcbMessage* message);
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
*>
fn void WcbConnection.init(&self, Allocator allocator, WcbConnectionImpl impl)
{
    self.allocator = allocator;
    self.impl = impl;
}

fn void WcbConnection.uninit(&self)
{}

<*
 @param [&inout] io : "IO interface to use"
*>
fn void WcbConnection.set_io(&self, WcbIOImpl io)
{
    self.io = io;
}

<*
 @param max_dispatch : "Maximum number of messages to dispatch, default all"
 @return "Number of messages dispatched, any fault is considered fatal"
 @return? WcbIOImpl.read!, WcbConnectionImpl.lookup!
*>
fn sz? WcbConnection.dispatch(&self, sz max_dispatch = 0)
{
    sz msgs_dispatched = 0;

    while (true)
    {
        WcbWord[] buf = self.io.read()!;
        sz buf_words = buf.len * WcbWord::size;

        if (buf == {}) break;  // No more data to read

        sz word_offset = 0;  // In words
        sz words_consumed = 0;
        bool short_message = true;  // If not enough data for message

        while (word_offset < buf.len && msgs_dispatched < max_dispatch)
        {
            short_message = true;

            WcbWord[] data = buf[word_offset..];
            WcbWord[2] header;

            if (data.len < header.len * WcbWord::size) break;

            mem::copy(&header, &data, header.len * WcbWord::size);
            data = data[header.len..];
            word_offset += header.len;

            WcbHalfWord msg_len = (WcbHalfWord)(header[1] >> 16);

            // Message must be at least 8 bytes and a multiple of word size
            if (msg_len < 8 || (msg_len & 3) != 0)
            {
                return types::INVALID_MESSAGE_LENGTH~;
            }

            if (msg_len > data.len) break;  // Incomplete message
            if (msg_len > MESSAGE_MAX_LEN) return types::MESSAGE_TOO_BIG~;

            sz arg_words = ((sz)msg_len - 8) >> 2;
            WcbId obj_id = header[0];
            WcbHalfWord opcode = (WcbHalfWord)(header[1] & 0x0000ffff);
            WcbObject obj;
            WcbInterface* iface;
            WcbMessageDesc* desc;
            any lookup;

            // Consider any fault a protocol error.
            lookup = self.impl.lookup(obj_id)!;
            if (lookup.type != WcbObject::typeid)
            {
                // Object does not exist, ignore and advance past message data.
                // If the typeid is an interface, then also discard fds (zombie).
                word_offset += arg_words;
                if (lookup.type == WcbInterface::typeid)
                {
                    iface = lookup.as(WcbInterface*);
                    desc = iface.get_message(opcode)!;
                    self.io.discard_fds(desc.n_fd_args);
                }
                else
                {
                    assert(lookup == null);
                }
                continue;
            }

            obj = lookup.as(WcbObject);
            iface = obj.get_interface();
            desc = iface.get_message(opcode)!;

            WcbArg[MESSAGE_MAX_ARGS] args;

            if (desc.signature.len > MESSAGE_MAX_ARGS)
            {
                unreachable("Message has too many arguments!");
            }

            sz arg_iface_idx = 0;
            sz remain = arg_words;

            // Unmarshal message arguments
            foreach (arg_idx, WcbArgSignature sig : desc.signature)
            {
                WcbArg* arg = &args[arg_idx];

                switch (sig.type)
                {
                    case INT:
                        arg.i = (int)data[0];
                        nextcase FIXED;
                    case UINT:
                        arg.u = (uint)data[0];
                        nextcase FIXED;
                    case FIXED:
                        if (sig.type == FIXED) arg.f = (WcbFixed)data[0];
                        data = data[1..];
                        remain--;
                    case STRING:
                    case ARRAY:
                        bool is_array = sig.type == WcbArgType.ARRAY;
                        WcbWord len = data[0];
                        sz word_len;

                        data = data[1..];

                        if (len == 0)
                        {
                            if (sig.nullable) break;
                            if (!is_array) return types::NULL_ARRAY~;
                            break;
                        }

                        word_len = mem::aligned_offset(len, WcbWord::size) << 2;

                        // Validate string/array length
                        if (word_len > remain) return types::SHORT_MESSAGE~;

                        if (is_array)
                        {
                            arg.a.data.words = data;
                            arg.a.len = len;
                            break;
                        }

                        // String must be NUL terminated, but not have any
                        // interior NUL bytes.
                        char[] str = ((char*)&data)[0..len];

                        if (str[len - 1] != '\0') return types::INVALID_STRING~;

                        for (WcbWord i = 0; i < len - 1; i++)
                        {
                            if (str[i] == '\0') return types::INVALID_STRING~;
                        }

                        arg.s = (String)str;
                    case OBJECT:
                        WcbId arg_id = data[0];

                        data = data[1..];
                        remain--;

                        if (arg_id == 0)
                        {
                            if (!sig.nullable) return types::NULL_OBJECT~;
                            arg.o = null;
                            break;
                        }

                        any arg_lookup = self.impl.lookup(arg_id)!;

                        if (arg_lookup.type != WcbObject::typeid)
                        {
                            if (arg_lookup.type == WcbInterface::typeid)
                            {
                                // Object is a zombie, just set arg to null
                                arg.o = null;
                                break;
                            }
                            return types::OBJECT_NOT_EXISTS~;
                        }

                        arg.o = arg_lookup.as(WcbObject);
                    case NEW_ID:
                        WcbId new_id = data[0];

                        data = data[1..];
                        remain--;

                        // new_id type cannot be null
                        if (new_id == 0) return types::NULL_OBJECT~;

                        // Check if object already exists
                        any new_lookup = self.impl.lookup(new_id)!;

                        if (new_lookup != null) return types::INVALID_NEW_ID~;

                        arg.n.id = new_id;
                        arg.n.iface = desc.arg_interfaces[arg_iface_idx++];
                    case FD:
                        // File descriptors don't take up any space
                        arg.h = self.io.read_fd()!;
                        if (arg.h == -1) return types::EXPECTED_FD~;
                    default:
                        unreachable("Unknown arg type %d!", sig.type);
                }
            }

            WcbMessage msg = {
                .obj = obj,
                .opcode = opcode,
                .args = args[..],
            };

            if (!self.impl.dispatch(&msg)! && desc.n_fd_args > 0)
            {
                // Message was not handled, close any fd args
                foreach (arg_idx, WcbArgSignature sig : desc.signature)
                {
                    if (sig.type != WcbArgType.FD) continue;

                    self.io.close_fd(args[arg_idx].h);
                }
            }

            msgs_dispatched++;
            words_consumed += (sz)msg_len >> 2;
            short_message = false;
        }

        if (short_message || msgs_dispatched >= max_dispatch) break;
    }

    return msgs_dispatched;
}

macro send_word(WcbIOImpl io, WcbWord word) @local
{
    io.send(((char*)(&word))[..WcbWord::size]);
}

<*
 @param obj_id : "Id of object the message is for"
 @param opcode : "Opcode of message"
 @param ... : "Argument types, then argument values"
 @require ($vaarg.len % 2) != 0 : "Missing arguments"
*>
macro WcbConnection.send(&self, WcbId obj_id, WcbHalfWord opcode, ...)
{
    var $n_args = $vaarg.len / 2;
    sz words = 0;

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
                words += 0;
        $endswitch
    $endfor

    if (words > MAX_MESSAGE_LEN) return MESSAGE_TOO_BIG~;  // Message to large

    self.io.reserve(words);

    send_word(self.io, obj_id);
    // Message length includes header
    send_word(self.io, ((words * 4 + 8) << 16) | (opcode & 0xffff));

    WcbWord slen;
    sz min;

    $for var $i = 0; $i < $n_args; $i++:
        var $val = $vaarg[$n_args + $i];
        $switch ($vaarg[$i]):
            $case INT:
            $case UINT:
            $case FIXED:
                send_word(self.io, $val);
            $case OBJECT:
            $case NEW_ID:
                send_word(self.io, $val);
            $case STRING:
            $case ARRAY:
                slen = $val.len;  // In bytes
                min = (slen & ~3U);

                send_word(self.io, slen);
                $if ($vaarg[$i] == WcbArgType.ARRAY):
                    self.io.send($val.data.bytes[..val.data.len]);
                $else
                    self.io.send($val);
                $endif

                // If length if not a multiple of word size, copy leftover
                // bytes.
                if (slen - min > 0)
                {
                    char[4] buf;

                    self.io.send(buf[slen - min..]);
                }
            $case FD:
                self.io.send_fd($vaarg[$n_args + $i]);
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
