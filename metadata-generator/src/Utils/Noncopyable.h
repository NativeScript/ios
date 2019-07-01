#pragma once

#define MAKE_NONCOPYABLE(ClassName)       \
                                          \
private:                                  \
    ClassName(const ClassName&) = delete; \
    void operator=(const ClassName&) = delete
