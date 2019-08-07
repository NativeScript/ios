#ifndef Tasks_h
#define Tasks_h

#include <vector>

namespace tns {

typedef void (*TaskCallback)(void* userData);

class Tasks {
public:
    static void Register(TaskCallback task, void* userData);
    static void Drain();
private:
    struct TaskContext {
    public:
        TaskContext(TaskCallback task, void* userData): task_(task), userData_(userData) { }
        TaskCallback task_;
        void* userData_;
    };

    static std::vector<TaskContext*> tasks_;
};

}

#endif /* Tasks_h */
