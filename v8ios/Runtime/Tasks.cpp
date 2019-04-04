#include "Tasks.h"

namespace tns {

void Tasks::Register(TaskCallback task, void* userData) {
    TaskContext* context = new TaskContext(task, userData);
    tasks_.push_back(context);
}

void Tasks::Drain() {
    auto i = std::begin(tasks_);
    while (i != std::end(tasks_)) {
        TaskContext* context = *i;
        context->task_(context->userData_);
        i = tasks_.erase(i);
        ++i;
    }
}

std::vector<Tasks::TaskContext*> Tasks::tasks_;

}
