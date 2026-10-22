cmake_minimum_required(VERSION 3.21)
project(hud_qml_shot_harness LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick)

# QRhi is public QtGui API but lives in the rhi/ subdirectory. Distro installs
# expose it as <qt>/include/QtGui/rhi/qrhi.h; Homebrew's framework build keeps
# it only under the versioned framework headers, so point find_path there too.
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

add_executable(qml-shot-harness main.cpp)
target_link_libraries(qml-shot-harness PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)
target_include_directories(qml-shot-harness PRIVATE "${HUD_QRHI_INCLUDE_DIR}")
