//
//  ns-v8-tracing-agent-impl.cpp
//  NativeScript
//
//  Created by Igor Randjelovic on 2023. 04. 03..
//  Copyright © 2023. Progress. All rights reserved.
//

#include <algorithm>
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

constexpr int kTracesPerChunk = 1000;

void NSInMemoryTraceWriter::AppendTraceEvent(TraceObject* trace_event) {
  MaybeCreateChunk();

  json_trace_writer_->AppendTraceEvent(trace_event);
  total_traces_++;
  if (total_traces_ % kTracesPerChunk == 0) {
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
  traces_.push_back(std::move(stream_).str());
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

bool NSInMemoryTraceWriter::bufferWasFull() const {
  // The ring buffer recycles its oldest chunk once all chunks are in use, and
  // the writer only sees what survives until the flush. Receiving at least a
  // whole buffer minus the (possibly partial) current chunk therefore means
  // the ring was full and earlier events were most likely overwritten.
  return total_traces_ >= ring_capacity_floor_;
}

std::mutex TracingAgentImpl::mutex_;
TracingAgentImpl* TracingAgentImpl::active_ = nullptr;

TracingAgentImpl::TracingAgentImpl() {
  // Runtime installs libplatform's default platform, whose controller is the
  // concrete v8::platform::tracing::TracingController in non-perfetto builds.
  tracing_controller_ =
      static_cast<TracingController*>(tns::Runtime::GetPlatform()->GetTracingController());
}

TracingAgentImpl::~TracingAgentImpl() { stopAndDiscard(); }

bool TracingAgentImpl::start(const std::vector<std::string>& categories, double bufferSizeInKb) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (active_ != nullptr) {
    return false;
  }
  active_ = this;

  size_t ringChunks = TraceBuffer::kRingBufferChunks;
  if (bufferSizeInKb > 0) {
    // traceBufferSizeInKb sizes the in-memory event storage; sizeof(TraceObject)
    // undercounts heap-copied argument strings but is the best compile-time
    // estimate available.
    constexpr size_t kBytesPerChunk = sizeof(TraceObject) * TraceBufferChunk::kChunkSize;
    // The ring buffer preallocates its chunk vector, and casting an
    // out-of-range double to size_t is UB, so clamp the frontend-supplied
    // size in double space before converting.
    constexpr size_t kMaxRingChunks = TraceBuffer::kRingBufferChunks * 16;
    double requestedChunks = bufferSizeInKb * 1024 / kBytesPerChunk;
    ringChunks = requestedChunks >= static_cast<double>(kMaxRingChunks)
                     ? kMaxRingChunks
                     : std::max<size_t>(static_cast<size_t>(requestedChunks), 2);
  }

  current_trace_writer_ = new NSInMemoryTraceWriter(
      R"({"method": "Tracing.dataCollected", "params":)", "}", ringChunks);
  tracing_controller_->Initialize(
      TraceBuffer::CreateTraceBufferRingBuffer(ringChunks, current_trace_writer_));
  // Of the CDP TraceConfig, only includedCategories and traceBufferSizeInKb
  // are honored. recordMode, excludedCategories and bufferUsage reporting
  // would need a custom TraceBuffer (libplatform's ring buffer always records
  // continuously); systrace, argument filtering, sampling and memory dumps
  // are Chromium-only concepts with no V8 counterpart.
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

  return true;
}

bool TracingAgentImpl::end(Result& result) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (active_ != this) {
    return false;
  }
  stopLocked(&result);
  return true;
}

void TracingAgentImpl::stopAndDiscard() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (active_ != this) {
    return;
  }
  stopLocked(nullptr);
}

void TracingAgentImpl::stopLocked(Result* result) {
  // StopTracing flushes the ring buffer into the writer.
  tracing_controller_->StopTracing();

  if (result != nullptr) {
    result->messages = current_trace_writer_->getTrace();
    result->dataLossOccurred = current_trace_writer_->bufferWasFull();
  }

  // Destroys the buffer and with it the writer.
  tracing_controller_->Initialize(nullptr);
  current_trace_writer_ = nullptr;
  active_ = nullptr;
}

}  // namespace inspector
}  // namespace tns
