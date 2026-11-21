module wcb::core::table @private;

import wcb::core::types;
import std::collections::list;

excuse OBJECT_LIMIT_REACHED, INVALID_OBJECT_ID;

// Maximum number of objects per entity
const uint MAX_OBJECTS = 0x00f00000;
