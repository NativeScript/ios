//
//  IsolateWrapper.cpp
//  NativeScript
//
//  Created by Eduardo Speroni on 8/4/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#include "IsolateWrapper.h"
#include "Runtime.h"

namespace tns {

bool IsolateWrapper::IsValid() const {
    return Runtime::IsAlive(isolate_) && isolate_->GetData(tns::Constants::CACHES_ISOLATE_SLOT) != nullptr && GetCache()->getIsolateId() == isolateId_;
}

}
