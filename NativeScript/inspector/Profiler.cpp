//
//  Profiler.cpp
//  NativeScript
//
//  Created by Igor Randjelovic on 2023. 03. 25..
//  Copyright © 2023. Progress. All rights reserved.
//

#include <stdio.h>
#include "Profiler.h"
#include "ArgConverter.h"
#include "v8-profiler.h"
#include "NativeScriptException.h"
#include <sstream>
#include "Helpers.h"

using namespace v8;
using namespace std;
using namespace tns;

Profiler::Profiler() {
}

void Profiler::Init(Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate, const string& appName, const string& outputDir) {
    m_appName = appName;
    m_outputDir = outputDir;
    m_isolate = isolate;
    
    auto extData = External::New(isolate, this);
    globalTemplate->Set(tns::ToV8String(isolate, "__startCPUProfiler"), FunctionTemplate::New(isolate, Profiler::StartCPUProfilerCallback, extData));
    globalTemplate->Set(tns::ToV8String(isolate, "__stopCPUProfiler"), FunctionTemplate::New(isolate, Profiler::StopCPUProfilerCallback, extData));
    globalTemplate->Set(tns::ToV8String(isolate, "__heapSnapshot"), FunctionTemplate::New(isolate, Profiler::HeapSnapshotMethodCallback, extData));
}

void Profiler::StartCPUProfilerCallback(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto isolate = args.GetIsolate();
    
    try {
        
        auto extData = args.Data().As<External>();
        auto thiz = static_cast<Profiler*>(extData->Value());
        thiz->StartCPUProfilerCallbackImpl(args);
    } catch (NativeScriptException& e) {
        e.ReThrowToV8(isolate);
    } catch (std::exception e) {
        stringstream ss;
        ss << "Error: c++ exception: " << e.what() << endl;
        NativeScriptException nsEx(ss.str());
        nsEx.ReThrowToV8(isolate);
    } catch (...) {
        NativeScriptException nsEx(std::string("Error: c++ exception!"));
        nsEx.ReThrowToV8(isolate);
    }
}

void Profiler::StartCPUProfilerCallbackImpl(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto isolate = args.GetIsolate();
    auto started = false;
    if ((args.Length() == 1) && (args[0]->IsString())) {
        auto context = isolate->GetCurrentContext();
        auto name = args[0]->ToString(context).ToLocalChecked();
        StartCPUProfiler(isolate, name);
        started = true;
    }
    args.GetReturnValue().Set(started);
}

void Profiler::StopCPUProfilerCallback(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto isolate = args.GetIsolate();
    try {
        auto extData = args.Data().As<External>();
        auto thiz = static_cast<Profiler*>(extData->Value());
        thiz->StopCPUProfilerCallbackImpl(args);
    } catch (NativeScriptException& e) {
        e.ReThrowToV8(isolate);
    } catch (std::exception e) {
        stringstream ss;
        ss << "Error: c++ exception: " << e.what() << endl;
        NativeScriptException nsEx(ss.str());
        nsEx.ReThrowToV8(isolate);
    } catch (...) {
        NativeScriptException nsEx(std::string("Error: c++ exception!"));
        nsEx.ReThrowToV8(isolate);
    }
}

void Profiler::StopCPUProfilerCallbackImpl(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto isolate = args.GetIsolate();
    auto stopped = false;
    if ((args.Length() == 1) && (args[0]->IsString())) {
        auto context = isolate->GetCurrentContext();
        auto name = args[0]->ToString(context).ToLocalChecked();
        stopped = StopCPUProfiler(isolate, name);
    }
    args.GetReturnValue().Set(stopped);
}

void Profiler::StartCPUProfiler(v8::Isolate* isolate, const v8::Local<v8::String>& name) {
    if(m_profiler != nullptr) {
        return;
    }
    m_profiler = CpuProfiler::New(isolate);
     m_profiler->SetSamplingInterval(500);
    auto res = m_profiler->StartProfiling(name, true);
}

bool Profiler::StopCPUProfiler(v8::Isolate* isolate, const v8::Local<v8::String>& name) {
//    return false;
    if(m_profiler == nullptr) {
        return false;
    }
    v8::HandleScope handleScope(isolate);
    auto cpuProfile = m_profiler->StopProfiling(name);

    auto success = false;

    if (nullptr != cpuProfile) {
        success = Write(cpuProfile);
        cpuProfile->Delete();
    }

    m_profiler->Dispose();
    m_profiler = nullptr;

    return success;
}


bool Profiler::Write(CpuProfile* cpuProfile) {
    // v8_inspector::protocol::Profiler::Profile

    //
    struct timespec nowt;
    clock_gettime(CLOCK_MONOTONIC, &nowt);
    uint64_t now = (int64_t) nowt.tv_sec * 1000000000LL + nowt.tv_nsec;

    auto sec = static_cast<unsigned long>(now / 1000000);
    auto usec = static_cast<unsigned long>(now % 1000000);

    char filename[256];
    auto profileName = tns::ToString(m_isolate, cpuProfile->GetTitle());
    snprintf(filename, sizeof(filename), "%s/%s-%s-%lu.%lu.cpuprofile", m_outputDir.c_str(), m_appName.c_str(), profileName.c_str(), sec, usec);
    
    Log("FILENAME: %s", filename);

    auto fp = fopen(filename, "w");
    if (nullptr == fp) {
        return false;
    }

    fwrite("{\"head\":", sizeof(char), 8, fp);

    stack<const CpuProfileNode*> s;
    s.push(cpuProfile->GetTopDownRoot());
    

    char buff[1024];
    auto COMMA_NODE = reinterpret_cast<const CpuProfileNode*>(1);
    auto CLOSE_NODE = reinterpret_cast<const CpuProfileNode*>(2);
    auto PREFIX = string("RegExp:");

    while (!s.empty()) {
        const CpuProfileNode* node = s.top();
        s.pop();
        if (node == CLOSE_NODE) {
            fwrite("]}", sizeof(char), 2, fp);
        } else if (node == COMMA_NODE) {
            fwrite(",", sizeof(char), 1, fp);
        } else {
            auto funcName = tns::ToString(m_isolate, node->GetFunctionName());
            auto scriptName = tns::ToString(m_isolate, node->GetScriptResourceName());
            auto lineNumber = node->GetLineNumber();
            auto columnNumber = node->GetColumnNumber();
            if (funcName.compare(0, PREFIX.size(), PREFIX) == 0) {
                stringstream ss;
                ss << "RegExp_" << scriptName << "_" << lineNumber << "_" << columnNumber;
                funcName = ss.str();
            }
            snprintf(buff, sizeof(buff), "{\"functionName\":\"%s\",\"scriptId\":%d,\"url\":\"%s\",\"lineNumber\":%d,\"columnNumber\":%d,\"hitCount\":%u,\"deoptReason\":\"%s\",\"id\":%u,\"children\":[",
                     funcName.c_str(),
                     node->GetScriptId(),
                     scriptName.c_str(),
                     lineNumber,
                     columnNumber,
                     node->GetHitCount(),
                     node->GetBailoutReason(),
                     node->GetNodeId());
            fwrite(buff, sizeof(char), strlen(buff), fp);

            s.push(CLOSE_NODE);

            int count = node->GetChildrenCount();
            for (int i = 0; i < count; i++) {
                if (i > 0) {
                    s.push(COMMA_NODE);
                }
                s.push(node->GetChild(i));
            }
        }
    }

    const double CONV_RATIO = 1000000.0;
    auto startTime = static_cast<double>(cpuProfile->GetStartTime()) / CONV_RATIO;
    auto endTime = static_cast<double>(cpuProfile->GetEndTime()) / CONV_RATIO;
    snprintf(buff, sizeof(buff), ",\"startTime\":%lf,\"endTime\":%lf,\"samples\":[", startTime, endTime);
    fwrite(buff, sizeof(char), strlen(buff), fp);
    int sampleCount = cpuProfile->GetSamplesCount();
    for (int i = 0; i < sampleCount; i++) {
        auto format = (i > 0) ? ",%d" : "%d";
        snprintf(buff, sizeof(buff), format, cpuProfile->GetSample(i)->GetNodeId());
        fwrite(buff, sizeof(char), strlen(buff), fp);
    }

    snprintf(buff, sizeof(buff), "],\"timestamps\":[");
    fwrite(buff, sizeof(char), strlen(buff), fp);
    for (int i=0; i<sampleCount; i++) {
        auto format = (i > 0) ? ",%lld" : "%lld";
        snprintf(buff, sizeof(buff), format, cpuProfile->GetSampleTimestamp(i));
        fwrite(buff, sizeof(char), strlen(buff), fp);
    }

    fwrite("]}", sizeof(char), 2, fp);
    fclose(fp);

    return true;
}


class FileOutputStream: public OutputStream {
    public:
        FileOutputStream(FILE* stream) :
            stream_(stream) {
        }

        virtual int GetChunkSize() {
            return 65536; // big chunks == faster
        }

        virtual void EndOfStream() {
        }

        virtual WriteResult WriteAsciiChunk(char* data, int size) {
            const size_t len = static_cast<size_t>(size);
            size_t off = 0;

            while (off < len && !feof(stream_) && !ferror(stream_)) {
                off += fwrite(data + off, 1, len - off, stream_);
            }

            return off == len ? kContinue : kAbort;
        }

    private:
        FILE* stream_;
};

void Profiler::HeapSnapshotMethodCallback(const v8::FunctionCallbackInfo<v8::Value>& args) {
    auto isolate = args.GetIsolate();
    try {
        auto extData = args.Data().As<External>();
        auto thiz = static_cast<Profiler*>(extData->Value());
        thiz->HeapSnapshotMethodCallbackImpl(args);
    } catch (NativeScriptException& e) {
        e.ReThrowToV8(isolate);
    } catch (std::exception e) {
        stringstream ss;
        ss << "Error: c++ exception: " << e.what() << endl;
        NativeScriptException nsEx(ss.str());
        nsEx.ReThrowToV8(isolate);
    } catch (...) {
        NativeScriptException nsEx(std::string("Error: c++ exception!"));
        nsEx.ReThrowToV8(isolate);
    }
}

void Profiler::HeapSnapshotMethodCallbackImpl(const v8::FunctionCallbackInfo<v8::Value>& args) {
    struct timespec nowt;
    clock_gettime(CLOCK_MONOTONIC, &nowt);
    uint64_t now = (int64_t) nowt.tv_sec * 1000000000LL + nowt.tv_nsec;

    unsigned long sec = static_cast<unsigned long>(now / 1000000);
    unsigned long usec = static_cast<unsigned long>(now % 1000000);

    char filename[256];
    snprintf(filename, sizeof(filename), "%s/%s-heapdump-%lu.%lu.heapsnapshot", m_outputDir.c_str(), m_appName.c_str(), sec, usec);

    FILE* fp = fopen(filename, "w");
    if (fp == nullptr) {
        return;
    }

    auto isolate = args.GetIsolate();

    const HeapSnapshot* snap = isolate->GetHeapProfiler()->TakeHeapSnapshot();

    FileOutputStream stream(fp);
    snap->Serialize(&stream, HeapSnapshot::kJSON);
    fclose(fp);
    const_cast<HeapSnapshot*>(snap)->Delete();
}

