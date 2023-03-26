//
//  Profiler.h
//  v8ios
//
//  Created by Igor Randjelovic on 2023. 03. 25..
//  Copyright © 2023. Progress. All rights reserved.
//

#ifndef Profiler_h
#define Profiler_h

#include "v8.h"
#include "v8-profiler.h"
#include <string>

namespace tns {
class Profiler {
public:
    Profiler();
    void Init(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate, const std::string& appName, const std::string& outputDir);

private:
    static void StartCPUProfilerCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void StopCPUProfilerCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void HeapSnapshotMethodCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    void StartCPUProfilerCallbackImpl(const v8::FunctionCallbackInfo<v8::Value>& args);
    void StopCPUProfilerCallbackImpl(const v8::FunctionCallbackInfo<v8::Value>& args);
    void HeapSnapshotMethodCallbackImpl(const v8::FunctionCallbackInfo<v8::Value>& args);
    void StartCPUProfiler(v8::Isolate* isolate, const v8::Local<v8::String>& name);
    bool StopCPUProfiler(v8::Isolate* isolate, const v8::Local<v8::String>& name);
    bool Write(v8::CpuProfile* cpuProfile);
    std::string m_appName;
    std::string m_outputDir;
    v8::CpuProfiler* m_profiler = nullptr;
    v8::Isolate* m_isolate = nullptr;
};
}


#endif /* Profiler_h */
