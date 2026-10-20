#pragma once
// Runs the real RexGlue Vulkan instance/device selection and queue code.
void RunRuntimeBackend(void (*write_log)(const char*, void*), void* context);
