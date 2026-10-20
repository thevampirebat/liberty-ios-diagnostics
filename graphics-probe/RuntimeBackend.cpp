#include "RuntimeBackend.h"
#include <rex/logging.h>
#include <rex/ui/vulkan/device.h>
#include <spdlog/sinks/base_sink.h>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
class ForwardWarnings final : public spdlog::sinks::base_sink<std::mutex> {
 public:
  ForwardWarnings(void (*writer)(const char*,void*),void* context):writer_(writer),context_(context) {set_level(spdlog::level::warn);}
 protected:
  void sink_it_(const spdlog::details::log_msg& message) override {
    std::string line="Runtime: ";line.append(message.payload.data(),message.payload.size());writer_(line.c_str(),context_);
  }
  void flush_() override {}
 private:
  void (*writer_)(const char*,void*);void* context_;
};
struct SinkGuard {
  spdlog::sink_ptr sink;
  ~SinkGuard(){rex::RemoveSink(sink);}
};
void Require(VkResult result,const char* step) {
  if(result!=VK_SUCCESS)throw std::runtime_error(std::string(step)+" VkResult="+std::to_string(result));
}
void Submit(const rex::ui::vulkan::VulkanDevice& device) {
  const auto& fn=device.functions();VkDevice vkDevice=device.device();
  VkCommandPool pool{};VkFence fence{};
  struct Cleanup {
    const rex::ui::vulkan::VulkanDevice& d;VkCommandPool& p;VkFence& f;
    ~Cleanup(){auto q=d.AcquireQueue(d.queue_family_graphics_compute(),0);d.functions().vkQueueWaitIdle(q.queue());if(f)d.functions().vkDestroyFence(d.device(),f,nullptr);if(p)d.functions().vkDestroyCommandPool(d.device(),p,nullptr);}
  }cleanup{device,pool,fence};
  VkCommandPoolCreateInfo pc{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};pc.queueFamilyIndex=device.queue_family_graphics_compute();
  Require(fn.vkCreateCommandPool(vkDevice,&pc,nullptr,&pool),"runtime command pool");
  VkCommandBufferAllocateInfo alloc{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};alloc.commandPool=pool;alloc.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;alloc.commandBufferCount=1;
  VkCommandBuffer command{};Require(fn.vkAllocateCommandBuffers(vkDevice,&alloc,&command),"runtime command buffer");
  VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  Require(fn.vkBeginCommandBuffer(command,&begin),"runtime begin");Require(fn.vkEndCommandBuffer(command),"runtime end");
  VkFenceCreateInfo fc{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};Require(fn.vkCreateFence(vkDevice,&fc,nullptr,&fence),"runtime fence");
  VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&command;
  {auto queue=device.AcquireQueue(device.queue_family_graphics_compute(),0);Require(fn.vkQueueSubmit(queue.queue(),1,&submit,fence),"runtime queue submit");}
  Require(fn.vkWaitForFences(vkDevice,1,&fence,VK_TRUE,10'000'000'000ULL),"runtime submission completion (10s)");
}
}
void RunRuntimeBackend(void (*write_log)(const char*,void*),void* context) {
  using namespace rex::ui::vulkan;
  auto log=[&](const std::string& line){write_log(line.c_str(),context);};
  rex::InitLoggingEarly();auto sink=std::make_shared<ForwardWarnings>(write_log,context);rex::AddSink(sink);SinkGuard guard{sink};
  log("BEGIN actual RexGlue Vulkan instance/device backend (upstream 1922957d9f5a)");
  auto instance=VulkanInstance::Create(true,false);
  if(!instance){log("FAIL actual runtime Vulkan instance. See Runtime messages above.");return;}
  log("PASS actual runtime Vulkan instance with surface-extension selection and statically linked MoltenVK");
  std::vector<VkPhysicalDevice> devices;instance->EnumeratePhysicalDevices(devices);
  if(devices.empty()){log("FAIL runtime physical device enumeration");return;}
  log("Runtime loader API "+std::to_string(VK_VERSION_MAJOR(instance->api_version()))+"."+std::to_string(VK_VERSION_MINOR(instance->api_version())));
  struct Mode {const char* name;bool emulation;bool native;bool dynamic;};
  const Mode modes[]={{"basic",false,false,false},{"native title shaders + dynamic rendering",false,true,true},{"Xenos GPU emulation",true,false,false}};
  for(const auto& mode:modes) {
    log(std::string("CHECK runtime mode: ")+mode.name);
    std::unique_ptr<VulkanDevice> device;
    for(auto physical:devices){device=VulkanDevice::CreateIfSupported(instance.get(),physical,mode.emulation,true,mode.native,mode.dynamic);if(device)break;}
    if(!device){log(std::string("FAIL runtime device mode rejected: ")+mode.name);continue;}
    const auto& p=device->properties();
    log(std::string("PASS runtime device mode: ")+mode.name+"; GPU="+p.deviceName+"; API="+std::to_string(VK_VERSION_MAJOR(p.apiVersion))+"."+std::to_string(VK_VERSION_MINOR(p.apiVersion)));
    Submit(*device);log(std::string("PASS runtime function-table queue submission and fence: ")+mode.name);
  }
  log("END actual runtime device checks. Full renderer, cached game shaders and game execution are not exercised.");
}
