//
//  ns-v8-tracing-agent-impl.cpp
//  NativeScript
//
//  Created by Igor Randjelovic on 2023. 04. 03..
//  Copyright © 2023. Progress. All rights reserved.
//

// #include <iostream>
// #include <vector>
// #include <string>
#include <sstream>

#include "Helpers.h"
#include "Runtime.h"
#include "ns-v8-tracing-agent-impl.h"

namespace tns {
namespace inspector {

using v8::platform::tracing::TraceBuffer;
using v8::platform::tracing::TraceBufferChunk;
using v8::platform::tracing::TraceConfig;
using v8::platform::tracing::TraceObject;
using v8::platform::tracing::TraceRecordMode;
using v8::platform::tracing::TraceWriter;
using v8::platform::tracing::TracingController;

int kTracesPerChunk = 20;

void NSInMemoryTraceWriter::AppendTraceEvent(TraceObject* trace_event) {
  MaybeCreateChunk();

  json_trace_writer_->AppendTraceEvent(trace_event);
  total_traces_++;
  if (total_traces_ > 0 && (total_traces_ % kTracesPerChunk == 0)) {
    MaybeFinalizeChunk();
  }
}

void NSInMemoryTraceWriter::MaybeCreateChunk() {
  if (json_trace_writer_.get() != nullptr) {
    return;
  }
  stream_.str(prefix_);
  stream_.seekp(0, std::ios::end);
  // create a v8 JSON trace writer
  json_trace_writer_.reset(TraceWriter::CreateJSONTraceWriter(stream_, "value"));
}

void NSInMemoryTraceWriter::MaybeFinalizeChunk() {
  if (json_trace_writer_.get() == nullptr) {
    return;
  }
  json_trace_writer_.reset();
  stream_ << suffix_;
  traces_.push_back(stream_.str());
  stream_.str("");
}

void NSInMemoryTraceWriter::Flush() {
  if (json_trace_writer_.get() != nullptr) {
    json_trace_writer_->Flush();
  }
}

std::vector<std::string> NSInMemoryTraceWriter::getTrace() {
  MaybeFinalizeChunk();
  return std::move(traces_);
}

TracingAgentImpl::TracingAgentImpl() {
  tracing_controller_ =
      reinterpret_cast<TracingController*>(tns::Runtime::GetPlatform()->GetTracingController());
}

bool TracingAgentImpl::start(const std::vector<std::string>& categories) {
  if (!tracing_) {
    tracing_ = true;

    // start tracing...
    current_trace_writer_ =
        new NSInMemoryTraceWriter(R"({"method": "Tracing.dataCollected", "params":)", "}");
    tracing_controller_->Initialize(TraceBuffer::CreateTraceBufferRingBuffer(
        TraceBuffer::kRingBufferChunks, current_trace_writer_));
    // todo: create TraceConfig based on params.
    TraceConfig* config = new TraceConfig();
    if (categories.size() > 0) {
      for (const auto& category : categories) {
        config->AddIncludedCategory(category.c_str());
      }
    } else {
      config->AddIncludedCategory("v8");
      config->AddIncludedCategory("disabled-by-default-v8.cpu_profiler");
    }
    config->SetTraceRecordMode(TraceRecordMode::RECORD_CONTINUOUSLY);
    tracing_controller_->StartTracing(config);
  }

  return true;
}

bool TracingAgentImpl::end() {
  if (tracing_) {
    tracing_controller_->StopTracing();

    if (current_trace_writer_ != nullptr) {
      // store last trace on the agent.
      lastTrace_ = current_trace_writer_->getTrace();
      if (lastTrace_.size() > 0) {
        lastTrace_.push_back(
            R"({"method": "Tracing.tracingComplete", "params": {"dataLossOccurred": false}})");
      }

      current_trace_writer_ = nullptr;
    }
    tracing_controller_->Initialize(nullptr);

    tracing_ = false;
  }

  return true;
}

}  // namespace inspector
}  // namespace tns
