module wcb::core::client;

import wcb::core::connection @public;
import wcb::core::wire @public;
import wcb::core::table @public;
import wcb::core::types;

struct WcbProxy
{
    WcbId id;
}

struct WcbDisplay
{
    WcbTable{WcbProxy} objects;
}
