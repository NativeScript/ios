//
//  DisposerPHV.cpp
//  NativeScript
//
//  Created by Eduardo Speroni on 2/25/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#include "DisposerPHV.h"
#include "Constants.h"
#include "Helpers.h"
#include "ObjectManager.h"

using namespace tns;

void DisposerPHV::VisitPersistentHandle(
    v8::Persistent<v8::Value>* value,
    uint16_t class_id) {

    // delete persistent handles on isolate disposal.
    switch (class_id) {
        case Constants::ClassTypes::DataWrapper: {
            v8::HandleScope scope(isolate_);
            // use ObjectManager anyway, as it handles a bigger variety of wrappers
            ObjectManager::DisposeValue(isolate_, value->Get(isolate_), true);
            break;
        }
        case Constants::ClassTypes::ObjectManagedValue: {
            v8::HandleScope scope(isolate_);
            ObjectManager::DisposeValue(isolate_, value->Get(isolate_), true);
            if (value->IsWeak()) {
                ObjectWeakCallbackState* state = value->ClearWeak<ObjectWeakCallbackState>();
                state->target_->Reset();
                delete state;
            };
            break;
        }
        default:
            break;
    }
    if ( class_id== Constants::ClassTypes::DataWrapper ) {
        
    }
}
