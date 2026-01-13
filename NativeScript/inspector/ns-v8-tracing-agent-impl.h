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
  NSInMemoryTraceWriter(std::string prefix, std::string suffix)
      : stream_(), prefix_(prefix), suffix_(suffix) {};
  void AppendTraceEvent(TraceObject* trace_event);
  void Flush();
  std::vector<std::string> getTrace();

 private:
  void MaybeCreateChunk();
  void MaybeFinalizeChunk();
  int total_traces_ = 0;
  std::ostringstream stream_;
  std::unique_ptr<TraceWriter> json_trace_writer_;
  std::string prefix_;
  std::string suffix_;
  std::vector<std::string> traces_;
};

class TracingAgentImpl {
 public:
  TracingAgentImpl();
  bool start(const std::vector<std::string>& categories = {});
  bool end();
  const std::vector<std::string>& getLastTrace() { return lastTrace_; }

 private:
  bool tracing_ = false;
  TracingController* tracing_controller_;
  NSInMemoryTraceWriter* current_trace_writer_;

  std::vector<std::string> lastTrace_;
};

}  // namespace inspector
}  // namespace tns

#endif /* ns_v8_tracing_agent_impl_hpp */
