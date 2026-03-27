# =============================================================================
# WindowsSimultaneousInterpreter — CMake 构建配置
# =============================================================================
# 目标平台: Windows 10/11 x64
# 编译器: MSVC 2022 (Visual Studio 17)
# C++ 标准: C++17
# 依赖: ONNX Runtime, Windows SDK (WASAPI, Win32 API, GDI+)
#
# 使用方法:
#   cmake -B build -A x64 -DONNXRUNTIME_DIR="C:/path/to/onnxruntime"
#   cmake --build build --config Release
# =============================================================================

cmake_minimum_required(VERSION 3.21)

project(WindowsSimultaneousInterpreter
    VERSION 0.1.0
    DESCRIPTION "Windows 同时传译桌面应用 — 本地离线 Whisper + NLLB-200"
    LANGUAGES CXX
)

# ---------------------------------------------------------------------------
# C++17 要求
# ---------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------------------------------------------------------------------------
# Windows 平台检查
# ---------------------------------------------------------------------------
if(NOT WIN32)
    message(FATAL_ERROR "此项目仅支持 Windows 平台。请使用 MSVC 2022 编译。")
endif()

# ---------------------------------------------------------------------------
# 输出目录
# ---------------------------------------------------------------------------
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG ${CMAKE_BINARY_DIR}/bin/Debug)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE ${CMAKE_BINARY_DIR}/bin/Release)

# ---------------------------------------------------------------------------
# ONNX Runtime 依赖
# ---------------------------------------------------------------------------
if(NOT ONNXRUNTIME_DIR)
    set(ONNXRUNTIME_DIR "${CMAKE_SOURCE_DIR}/third_party/onnxruntime"
        CACHE PATH "ONNX Runtime 安装目录路径")
    message(STATUS "ONNXRUNTIME_DIR 未设置，使用默认值: ${ONNXRUNTIME_DIR}")
endif()

find_path(ONNXRUNTIME_INCLUDE_DIR
    NAMES onnxruntime_cxx_api.h
    PATHS "${ONNXRUNTIME_DIR}/include"
    NO_DEFAULT_PATH
)

find_library(ONNXRUNTIME_LIBRARY
    NAMES onnxruntime
    PATHS "${ONNXRUNTIME_DIR}/lib"
    NO_DEFAULT_PATH
)

if(NOT ONNXRUNTIME_INCLUDE_DIR OR NOT ONNXRUNTIME_LIBRARY)
    message(WARNING
        "未找到 ONNX Runtime。请设置 ONNXRUNTIME_DIR 变量指向 ONNX Runtime 安装目录。\n"
        "下载地址: https://github.com/microsoft/onnxruntime/releases\n"
        "选择 onnxruntime-win-x64-*.zip 包，解压后设置路径。"
    )
endif()

# ---------------------------------------------------------------------------
# Windows SDK 组件链接
# ---------------------------------------------------------------------------
set(WINDOWS_LIBS
    ole32
    Mmdevapi
    Audioses
    comctl32
    gdi32
    gdiplus
    shlwapi
    dwmapi
    user32
    kernel32
    advapi32
)

# ---------------------------------------------------------------------------
# 源文件
# ---------------------------------------------------------------------------
set(SOURCES
    src/main.cpp
    src/AudioCapture.cpp
    src/TranscriptionEngine.cpp
    src/TranslationEngine.cpp
    src/Pipeline.cpp
    src/UI/OverlayWindow.cpp
    src/UI/TextRenderer.cpp
)

set(HEADERS
    src/AudioCapture.h
    src/TranscriptionEngine.h
    src/TranslationEngine.h
    src/Pipeline.h
    src/UI/OverlayWindow.h
    src/UI/TextRenderer.h
)

# ---------------------------------------------------------------------------
# 主可执行文件
# ---------------------------------------------------------------------------
add_executable(${PROJECT_NAME} WIN32 ${SOURCES} ${HEADERS})

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${ONNXRUNTIME_INCLUDE_DIR}
)

target_link_libraries(${PROJECT_NAME} PRIVATE ${WINDOWS_LIBS})

if(ONNXRUNTIME_LIBRARY)
    target_link_libraries(${PROJECT_NAME} PRIVATE ${ONNXRUNTIME_LIBRARY})
    target_compile_definitions(${PROJECT_NAME} PRIVATE HAS_ONNXRUNTIME=1)
    message(STATUS "ONNX Runtime 已找到: ${ONNXRUNTIME_LIBRARY}")
else()
    message(STATUS "ONNX Runtime 未找到 — 将使用模拟模式构建")
endif()

# ---------------------------------------------------------------------------
# 编译选项 (MSVC)
# ---------------------------------------------------------------------------
if(MSVC)
    target_compile_options(${PROJECT_NAME} PRIVATE
        /W4 /WX /permissive- /utf-8 /Zc:inline /Zc:throwingNew
    )
    set_property(TARGET ${PROJECT_NAME} PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
endif()

target_compile_definitions(${PROJECT_NAME} PRIVATE
    UNICODE _UNICODE WINVER=0x0A00 _WIN32_WINNT=0x0A00 NOMINMAX
)

# ---------------------------------------------------------------------------
# 复制 ONNX Runtime DLL
# ---------------------------------------------------------------------------
if(ONNXRUNTIME_LIBRARY)
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNXRUNTIME_DIR}/lib/onnxruntime.dll"
            $<TARGET_FILE_DIR:${PROJECT_NAME}>
        COMMENT "复制 ONNX Runtime DLL 到输出目录"
    )
endif()

# ---------------------------------------------------------------------------
# 安装规则
# ---------------------------------------------------------------------------
install(TARGETS ${PROJECT_NAME} RUNTIME DESTINATION bin COMPONENT Runtime)
install(FILES ${HEADERS} DESTINATION include/${PROJECT_NAME} COMPONENT Development)

message(STATUS "=======================================================")
message(STATUS "项目: ${PROJECT_NAME} v${PROJECT_VERSION}")
message(STATUS "编译器: ${CMAKE_CXX_COMPILER_ID}")
message(STATUS "构建类型: ${CMAKE_BUILD_TYPE}")
message(STATUS "输出目录: ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
message(STATUS "ONNX Runtime: ${ONNXRUNTIME_INCLUDE_DIR}")
message(STATUS "=======================================================")
