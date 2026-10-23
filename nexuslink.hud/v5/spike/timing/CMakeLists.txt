cmake_minimum_required(VERSION 3.21)
project(swarm_bench LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick)

# Same rhi/qv4 include hunt as tools/harness/CMakeLists.txt: QRhi is public QtGui
# API but lives under a versioned private-looking path in the Homebrew framework.
find_path(HUD_QRHI_INCLUDE_DIR
    NAMES rhi/qrhi.h
    HINTS
        "${QT6_INSTALL_PREFIX}/include/QtGui"
        "${QT6_INSTALL_PREFIX}/lib/QtGui.framework/Versions/A/Headers/6.12.0/QtGui"
        "${QT6_INSTALL_PREFIX}/lib/QtGui.framework/Headers/6.12.0/QtGui"
)
if(NOT HUD_QRHI_INCLUDE_DIR)
    message(FATAL_ERROR "rhi/qrhi.h not found under ${QT6_INSTALL_PREFIX}")
endif()

add_executable(swarm-bench swarm-bench.cpp)
target_link_libraries(swarm-bench PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)
target_include_directories(swarm-bench PRIVATE "${HUD_QRHI_INCLUDE_DIR}")
