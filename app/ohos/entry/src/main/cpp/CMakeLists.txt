# nodehost —— 让 ArkTS 能在 App 进程内启动 node
#
# 产物是 libnodehost.so，放进 libs/arm64-v8a/，ArkTS 侧 import nodehost from 'libnodehost.so'
cmake_minimum_required(VERSION 3.5.0)
project(nodehost)

# ⚠️ 必须 C++17：std::string::data() 在 C++14 返回 const char*，
#    C++17 才返回 char*。napi_get_value_string_utf8 要的是 char*，
#    不设的话报 "no matching function"，而且错误信息完全不提标准版本。
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
)

# libnodehost.so —— NAPI 模块，负责 dlopen libnode.so 并调 node::Start
add_library(nodehost SHARED node_host.cpp)

# libace_napi.z.so 提供 napi_* 全套符号（鸿蒙的 NAPI 实现）
target_link_libraries(nodehost PUBLIC libace_napi.z.so)
# OH_LOG_Print 在 libhilog_ndk 里
target_link_libraries(nodehost PUBLIC libhilog_ndk.z.so)
# dl* 不在 libc 里，得显式链 libdl
target_link_libraries(nodehost PUBLIC dl)
target_link_libraries(nodehost PUBLIC pthread)
