//
//  ns-v8-tracing-agent-impl.hpp
//  NativeScript
//
//  Created by Igor Randjelovic on 2023. 04. 03..
//  Copyright © 2023. Progress. All rights reserved.
//

#ifndef ns_v8_tracing_agent_impl_hpp
#define ns_v8_tracing_agent_impl_hpp

#include <stdio.h>

#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "libplatform/v8-tracing.h"
#include "v8.h"

namespace tns {
namespace inspector {

using v8::platform::tracing::TraceBuffer;
using v8::platform::tracing::TraceBufferChunk;
using v8::platform::tracing::TraceConfig;
using v8::platform::tracing::TraceObject;
using v8::platform::tracing::TraceWriter;
using v8::platform::tracing::TracingController;

class NSInMemoryTraceWriter : public TraceWriter {
 public:
  NSInMemoryTraceWriter(const std::string& prefix, const std::string& suffix,
                        size_t ringChunks)
      : ring_capacity_floor_(
            static_cast<int>((ringChunks - 1) * TraceBufferChunk::kChunkSize)),
        stream_(),
        prefix_(prefix),
        suffix_(suffix) {};
  void AppendTraceEvent(TraceObject* trace_event);
  void Flush();
  std::vector<std::string> getTrace();
  bool bufferWasFull() const;

 private:
  void MaybeCreateChunk();
  void MaybeFinalizeChunk();
  int total_traces_ = 0;
  int ring_capacity_floor_;
  std::ostringstream stream_;
  std::unique_ptr<TraceWriter> json_trace_writer_;
  std::string prefix_;
  std::string suffix_;
  std::vector<std::string> traces_;
};

class TracingAgentImpl {
 public:
  struct Result {
    // Tracing.dataCollected notifications, ready to send to the frontend.
    std::vector<std::string> messages;
    bool dataLossOccurred = false;
  };

  TracingAgentImpl();
  ~TracingAgentImpl();

  // Returns false when a trace is already running (started by any agent).
  // bufferSizeInKb <= 0 means the default ring buffer size.
  bool start(const std::vector<std::string>& categories = {},
             double bufferSizeInKb = 0);
  // Returns false unless this agent owns the running trace.
  bool end(Result& result);
  // Stops and drops the running trace if this agent owns it; for frontend
  // disconnect and teardown.
  void stopAndDiscard();

 private:
  // Requires mutex_ held and active_ == this; pass null to drop the trace.
  void stopLocked(Result* result);

  TracingController* tracing_controller_;
  // Owned by the TraceBuffer installed on the controller; only valid while
  // active_ == this.
  NSInMemoryTraceWriter* current_trace_writer_ = nullptr;

  // The TracingController is process-global, so only one agent may trace at
  // a time; a concurrent start would destroy the running trace's buffer (and
  // writer) out from under its owner.
  static std::mutex mutex_;
  static TracingAgentImpl* active_;
};

}  // namespace inspector
}  // namespace tns

#endif /* ns_v8_tracing_agent_impl_hpp */
