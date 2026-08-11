//
//  Message.hpp
//  NativeScript
//
//  Created by Eduardo Speroni on 11/22/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#ifndef Message_hpp
#define Message_hpp

#include "StructuredSerialization.h"

namespace tns {
namespace worker {

// What a worker posts: a value serialized on the sending isolate and read back
// on the receiving one. The mechanism is shared with structuredClone; only the
// host-object policy differs (see HostObjectPolicy).
using Message = tns::serialization::SerializedValue;

}  // namespace worker
}  // namespace tns

#endif /* Message_hpp */
