cmake_minimum_required(VERSION 3.29)
project(LibertyVulkanProbe LANGUAGES C CXX OBJC OBJCXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(MVK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../vendor/MoltenVK")
set(MVK_LIBRARY "${MVK_ROOT}/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a")
set(MVK_INCLUDE_DIR "${MVK_ROOT}/MoltenVK/include")
if(NOT EXISTS "${MVK_LIBRARY}")
  message(FATAL_ERROR "Missing official MoltenVK iOS arm64 archive: ${MVK_LIBRARY}")
endif()
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../runtime-core" "${CMAKE_BINARY_DIR}/runtime-core" EXCLUDE_FROM_ALL)
add_executable(VulkanProbe MACOSX_BUNDLE GraphicsProbe.mm triangle.vert.spv triangle.frag.spv "${MVK_ROOT}/LICENSE")
set_source_files_properties(triangle.vert.spv triangle.frag.spv "${MVK_ROOT}/LICENSE" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
target_include_directories(VulkanProbe PRIVATE "${MVK_INCLUDE_DIR}")
target_compile_definitions(VulkanProbe PRIVATE VK_USE_PLATFORM_METAL_EXT)
target_compile_options(VulkanProbe PRIVATE -fobjc-arc)
target_link_libraries(VulkanProbe PRIVATE rexcore "${MVK_LIBRARY}" "-framework UIKit" "-framework Foundation" "-framework Metal" "-framework QuartzCore" "-framework IOSurface" "-framework CoreGraphics" "-framework AVFoundation")
set_target_properties(VulkanProbe PROPERTIES
 MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist.in"
 MACOSX_BUNDLE_GUI_IDENTIFIER "com.libertydiagnostics.vulkanprobe"
 XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
 XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
 XCODE_ATTRIBUTE_ENABLE_BITCODE NO)

# Compile the runtime's actual Vulkan instance/device layer with its feature checks.
set(BACKEND_SDK "${CMAKE_CURRENT_LIST_DIR}/../upstream/glue/rexglue-sdk-main")
target_sources(VulkanProbe PRIVATE
    RuntimeBackend.cpp
    "${BACKEND_SDK}/src/ui/vulkan/vulkan_instance.cpp"
    "${BACKEND_SDK}/src/ui/vulkan/vulkan_device.cpp"
    "${BACKEND_SDK}/src/ui/renderdoc_api.cpp"
    "${BACKEND_SDK}/src/graphics/gta4_native/temporal/dlss_bootstrap.cpp")
target_include_directories(VulkanProbe PRIVATE "${BACKEND_SDK}/src")
# ARC applies to Objective-C++ only, not the runtime's plain C++ translation units.
set_property(TARGET VulkanProbe PROPERTY COMPILE_OPTIONS "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>" -fno-char8_t -fno-strict-aliasing)
target_compile_definitions(VulkanProbe PRIVATE FMT_USE_CONSTEVAL=0 REXGLUE_BUILD_CONFIG="Release")
