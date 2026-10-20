#import <UIKit/UIKit.h>
#include "RuntimeBackend.h"
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFoundation/AVFoundation.h>
#include <rex/memory/utils.h>
#include <rex/thread.h>
#include <rex/thread/fiber.h>
#include <atomic>
#include <cmath>
#include <memory>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <string>
#include <cstring>
#include <functional>
#include <stdexcept>
#include <thread>
#include <vector>

static void Check(VkResult result,const char* step) {
    if(result!=VK_SUCCESS) throw std::runtime_error(std::string(step)+" VkResult="+std::to_string(result));
}
struct VulkanRun {
    VkInstance instance{}; VkSurfaceKHR surface{}; VkPhysicalDevice gpu{}; VkDevice device{};
    VkQueue queue{}; uint32_t family{}; VkSwapchainKHR swapchain{};
    VkCommandPool pool{}; VkCommandBuffer cmd{}; VkFence fence{};
    VkSemaphore acquired{}, rendered{};
    VkRenderPass offPass{}, screenPass{}; VkPipelineLayout layout{}; VkPipeline pipeline{};
    VkShaderModule vert{},frag{};
    VkImage image{}; VkDeviceMemory imageMemory{},bufferMemory{}; VkBuffer buffer{};
    std::vector<VkImageView> views; std::vector<VkFramebuffer> frames;
    ~VulkanRun() {
        if(device) {
            vkDeviceWaitIdle(device);
            for(auto f:frames) vkDestroyFramebuffer(device,f,nullptr);
            for(auto v:views) vkDestroyImageView(device,v,nullptr);
            if(pipeline) vkDestroyPipeline(device,pipeline,nullptr);
            if(layout) vkDestroyPipelineLayout(device,layout,nullptr);
            if(vert) vkDestroyShaderModule(device,vert,nullptr);
            if(frag) vkDestroyShaderModule(device,frag,nullptr);
            if(offPass) vkDestroyRenderPass(device,offPass,nullptr);
            if(screenPass) vkDestroyRenderPass(device,screenPass,nullptr);
            if(image) vkDestroyImage(device,image,nullptr);
            if(imageMemory) vkFreeMemory(device,imageMemory,nullptr);
            if(buffer) vkDestroyBuffer(device,buffer,nullptr);
            if(bufferMemory) vkFreeMemory(device,bufferMemory,nullptr);
            if(fence) vkDestroyFence(device,fence,nullptr);
            if(acquired) vkDestroySemaphore(device,acquired,nullptr);
            if(rendered) vkDestroySemaphore(device,rendered,nullptr);
            if(pool) vkDestroyCommandPool(device,pool,nullptr);
            if(swapchain) vkDestroySwapchainKHR(device,swapchain,nullptr);
            vkDestroyDevice(device,nullptr);
        }
        if(surface) vkDestroySurfaceKHR(instance,surface,nullptr);
        if(instance) vkDestroyInstance(instance,nullptr);
    }
    uint32_t memoryType(uint32_t bits,VkMemoryPropertyFlags flags) {
        VkPhysicalDeviceMemoryProperties m{};vkGetPhysicalDeviceMemoryProperties(gpu,&m);
        for(uint32_t i=0;i<m.memoryTypeCount;++i)
            if((bits&(1u<<i)) && (m.memoryTypes[i].propertyFlags&flags)==flags) return i;
        throw std::runtime_error("No suitable Vulkan memory type");
    }
    VkShaderModule shader(NSString* name) {
        NSURL* url=[NSBundle.mainBundle URLForResource:name withExtension:@"spv"];
        NSData* data=[NSData dataWithContentsOfURL:url];
        if(!data || data.length%4 || data.length<20) throw std::runtime_error("Missing/invalid SPIR-V shader");
        std::vector<uint32_t> words(data.length/4);memcpy(words.data(),data.bytes,data.length);
        VkShaderModuleCreateInfo ci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};ci.codeSize=data.length;ci.pCode=words.data();
        VkShaderModule module{};Check(vkCreateShaderModule(device,&ci,nullptr,&module),"shader module");return module;
    }
    VkRenderPass pass(VkFormat format,VkImageLayout finalLayout) {
        VkAttachmentDescription a{};a.format=format;a.samples=VK_SAMPLE_COUNT_1_BIT;
        a.loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR;a.storeOp=VK_ATTACHMENT_STORE_OP_STORE;
        a.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE;a.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE;
        a.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED;a.finalLayout=finalLayout;
        VkAttachmentReference ref{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription sub{};sub.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS;sub.colorAttachmentCount=1;sub.pColorAttachments=&ref;
        VkSubpassDependency deps[2]{};
        deps[0].srcSubpass=VK_SUBPASS_EXTERNAL;deps[0].dstSubpass=0;
        deps[0].srcStageMask=VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;deps[0].dstStageMask=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        deps[0].dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        deps[1].srcSubpass=0;deps[1].dstSubpass=VK_SUBPASS_EXTERNAL;
        deps[1].srcStageMask=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;deps[1].srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        deps[1].dstStageMask=finalLayout==VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL ? VK_PIPELINE_STAGE_TRANSFER_BIT : VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
        deps[1].dstAccessMask=finalLayout==VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL ? VK_ACCESS_TRANSFER_READ_BIT : 0;
        VkRenderPassCreateInfo ci{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};ci.attachmentCount=1;ci.pAttachments=&a;
        ci.subpassCount=1;ci.pSubpasses=&sub;ci.dependencyCount=2;ci.pDependencies=deps;
        VkRenderPass result{};Check(vkCreateRenderPass(device,&ci,nullptr,&result),"render pass");return result;
    }
    VkFramebuffer framebuffer(VkImage target,VkFormat format,VkRenderPass pass,uint32_t w,uint32_t h) {
        VkImageViewCreateInfo vi{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};vi.image=target;vi.viewType=VK_IMAGE_VIEW_TYPE_2D;
        vi.format=format;vi.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        VkImageView view{};Check(vkCreateImageView(device,&vi,nullptr,&view),"image view");views.push_back(view);
        VkFramebufferCreateInfo ci{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};ci.renderPass=pass;ci.attachmentCount=1;
        ci.pAttachments=&view;ci.width=w;ci.height=h;ci.layers=1;
        VkFramebuffer frame{};Check(vkCreateFramebuffer(device,&ci,nullptr,&frame),"framebuffer");frames.push_back(frame);return frame;
    }
    void begin() {
        Check(vkResetCommandBuffer(cmd,0),"reset command buffer");
        VkCommandBufferBeginInfo ci{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};ci.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        Check(vkBeginCommandBuffer(cmd,&ci),"begin command buffer");
    }
    void draw(VkRenderPass pass,VkFramebuffer frame,uint32_t w,uint32_t h) {
        VkClearValue clear{};clear.color={{0.03f,0.05f,0.08f,1.0f}};
        VkRenderPassBeginInfo bi{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};bi.renderPass=pass;bi.framebuffer=frame;
        bi.renderArea.extent={w,h};bi.clearValueCount=1;bi.pClearValues=&clear;
        vkCmdBeginRenderPass(cmd,&bi,VK_SUBPASS_CONTENTS_INLINE);
        VkViewport vp{0,0,float(w),float(h),0,1};VkRect2D sc{{0,0},{w,h}};
        vkCmdSetViewport(cmd,0,1,&vp);vkCmdSetScissor(cmd,0,1,&sc);
        vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);vkCmdDraw(cmd,3,1,0,0);vkCmdEndRenderPass(cmd);
    }
    void submit(bool onscreen) {
        Check(vkEndCommandBuffer(cmd),"end command buffer");Check(vkResetFences(device,1,&fence),"reset fence");
        VkPipelineStageFlags waitStage=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};si.commandBufferCount=1;si.pCommandBuffers=&cmd;
        if(onscreen) {si.waitSemaphoreCount=1;si.pWaitSemaphores=&acquired;si.pWaitDstStageMask=&waitStage;si.signalSemaphoreCount=1;si.pSignalSemaphores=&rendered;}
        Check(vkQueueSubmit(queue,1,&si,fence),"queue submit");
        Check(vkWaitForFences(device,1,&fence,VK_TRUE,30'000'000'000ULL),"GPU completion fence (30s)");
    }
};

static void RunVulkan(CAMetalLayer* layer,std::function<void(NSString*)> log) {
    VulkanRun v;
    uint32_t count=0;Check(vkEnumerateInstanceExtensionProperties(nullptr,&count,nullptr),"instance extensions");
    std::vector<VkExtensionProperties> ie(count);Check(vkEnumerateInstanceExtensionProperties(nullptr,&count,ie.data()),"instance extension list");
    bool portability=false;for(auto& e:ie) if(strcmp(e.extensionName,"VK_KHR_portability_enumeration")==0) portability=true;
    std::vector<const char*> exts={VK_KHR_SURFACE_EXTENSION_NAME,VK_EXT_METAL_SURFACE_EXTENSION_NAME};
    if(portability) exts.push_back("VK_KHR_portability_enumeration");
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};app.pApplicationName="Liberty Vulkan Probe";app.apiVersion=VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};ici.pApplicationInfo=&app;ici.enabledExtensionCount=uint32_t(exts.size());ici.ppEnabledExtensionNames=exts.data();
    if(portability) ici.flags=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    Check(vkCreateInstance(&ici,nullptr,&v.instance),"create Vulkan instance");log(@"PASS Vulkan instance (official MoltenVK 1.4.2)");
    VkMetalSurfaceCreateInfoEXT sci{VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};sci.pLayer=layer;
    Check(vkCreateMetalSurfaceEXT(v.instance,&sci,nullptr,&v.surface),"Metal-backed Vulkan surface");
    count=0;Check(vkEnumeratePhysicalDevices(v.instance,&count,nullptr),"physical device count");
    if(!count) throw std::runtime_error("No Vulkan GPU");
    std::vector<VkPhysicalDevice> gpus(count);Check(vkEnumeratePhysicalDevices(v.instance,&count,gpus.data()),"physical devices");
    for(auto gpu:gpus) {
        uint32_t n=0;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&n,nullptr);std::vector<VkQueueFamilyProperties> qs(n);vkGetPhysicalDeviceQueueFamilyProperties(gpu,&n,qs.data());
        for(uint32_t i=0;i<n;++i) {VkBool32 present=VK_FALSE;Check(vkGetPhysicalDeviceSurfaceSupportKHR(gpu,i,v.surface,&present),"surface support");if((qs[i].queueFlags&VK_QUEUE_GRAPHICS_BIT)&&present){v.gpu=gpu;v.family=i;break;}}
        if(v.gpu) break;
    }
    if(!v.gpu) throw std::runtime_error("No graphics/present queue");
    VkPhysicalDeviceProperties props{};VkPhysicalDeviceFeatures features{};vkGetPhysicalDeviceProperties(v.gpu,&props);vkGetPhysicalDeviceFeatures(v.gpu,&features);
    log([NSString stringWithFormat:@"GPU: %s; Vulkan %u.%u.%u; max 2D texture %u",props.deviceName,VK_VERSION_MAJOR(props.apiVersion),VK_VERSION_MINOR(props.apiVersion),VK_VERSION_PATCH(props.apiVersion),props.limits.maxImageDimension2D]);
    log([NSString stringWithFormat:@"Features: int64=%u float64=%u geometry=%u independentBlend=%u anisotropy=%u",features.shaderInt64,features.shaderFloat64,features.geometryShader,features.independentBlend,features.samplerAnisotropy]);
    count=0;Check(vkEnumerateDeviceExtensionProperties(v.gpu,nullptr,&count,nullptr),"device extension count");std::vector<VkExtensionProperties> de(count);Check(vkEnumerateDeviceExtensionProperties(v.gpu,nullptr,&count,de.data()),"device extension list");
    std::vector<const char*> deviceExts={VK_KHR_SWAPCHAIN_EXTENSION_NAME};NSMutableString* names=[NSMutableString string];
    for(auto& e:de) {if(strcmp(e.extensionName,"VK_KHR_portability_subset")==0)deviceExts.push_back("VK_KHR_portability_subset");[names appendFormat:@"%s ",e.extensionName];}
    log([@"Device extensions: " stringByAppendingString:names]);
    float priority=1;VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};qi.queueFamilyIndex=v.family;qi.queueCount=1;qi.pQueuePriorities=&priority;
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};dci.queueCreateInfoCount=1;dci.pQueueCreateInfos=&qi;dci.enabledExtensionCount=uint32_t(deviceExts.size());dci.ppEnabledExtensionNames=deviceExts.data();
    Check(vkCreateDevice(v.gpu,&dci,nullptr,&v.device),"logical device");vkGetDeviceQueue(v.device,v.family,0,&v.queue);log(@"PASS Vulkan graphics queue");
    VkSurfaceCapabilitiesKHR caps{};Check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(v.gpu,v.surface,&caps),"surface capabilities");
    count=0;Check(vkGetPhysicalDeviceSurfaceFormatsKHR(v.gpu,v.surface,&count,nullptr),"surface formats");std::vector<VkSurfaceFormatKHR> formats(count);Check(vkGetPhysicalDeviceSurfaceFormatsKHR(v.gpu,v.surface,&count,formats.data()),"surface format list");
    if(formats.empty()) throw std::runtime_error("No surface formats");
    auto chosen=formats.front();bool supported=false;
    for(auto f:formats) if(f.format==VK_FORMAT_B8G8R8A8_UNORM || f.format==VK_FORMAT_R8G8B8A8_UNORM){chosen=f;supported=true;break;}
    if(!supported) throw std::runtime_error("No 8-bit UNORM surface format for pixel test");
    VkExtent2D extent=caps.currentExtent;
    if(extent.width==UINT32_MAX){extent.width=std::clamp(uint32_t(layer.drawableSize.width),caps.minImageExtent.width,caps.maxImageExtent.width);extent.height=std::clamp(uint32_t(layer.drawableSize.height),caps.minImageExtent.height,caps.maxImageExtent.height);}
    uint32_t images=std::max(2u,caps.minImageCount);if(caps.maxImageCount)images=std::min(images,caps.maxImageCount);
    VkSwapchainCreateInfoKHR sw{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};sw.surface=v.surface;sw.minImageCount=images;sw.imageFormat=chosen.format;sw.imageColorSpace=chosen.colorSpace;sw.imageExtent=extent;sw.imageArrayLayers=1;sw.imageUsage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;sw.imageSharingMode=VK_SHARING_MODE_EXCLUSIVE;sw.preTransform=caps.currentTransform;
    sw.compositeAlpha=(caps.supportedCompositeAlpha&VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)?VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR:VkCompositeAlphaFlagBitsKHR(caps.supportedCompositeAlpha&(~caps.supportedCompositeAlpha+1));sw.presentMode=VK_PRESENT_MODE_FIFO_KHR;sw.clipped=VK_TRUE;
    Check(vkCreateSwapchainKHR(v.device,&sw,nullptr,&v.swapchain),"swapchain");
    VkCommandPoolCreateInfo cp{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};cp.queueFamilyIndex=v.family;cp.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;Check(vkCreateCommandPool(v.device,&cp,nullptr,&v.pool),"command pool");
    VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};ca.commandPool=v.pool;ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;ca.commandBufferCount=1;Check(vkAllocateCommandBuffers(v.device,&ca,&v.cmd),"command buffer");
    VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};Check(vkCreateFence(v.device,&fi,nullptr,&v.fence),"fence");VkSemaphoreCreateInfo se{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};Check(vkCreateSemaphore(v.device,&se,nullptr,&v.acquired),"acquire semaphore");Check(vkCreateSemaphore(v.device,&se,nullptr,&v.rendered),"render semaphore");
    v.offPass=v.pass(chosen.format,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);v.screenPass=v.pass(chosen.format,VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
    v.vert=v.shader(@"triangle.vert");v.frag=v.shader(@"triangle.frag");
    VkPipelineShaderStageCreateInfo stages[2]{};stages[0].sType=stages[1].sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;stages[0].stage=VK_SHADER_STAGE_VERTEX_BIT;stages[0].module=v.vert;stages[0].pName="main";stages[1].stage=VK_SHADER_STAGE_FRAGMENT_BIT;stages[1].module=v.frag;stages[1].pName="main";
    VkPipelineVertexInputStateCreateInfo vertex{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};assembly.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};viewport.viewportCount=1;viewport.scissorCount=1;
    VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};raster.polygonMode=VK_POLYGON_MODE_FILL;raster.cullMode=VK_CULL_MODE_NONE;raster.frontFace=VK_FRONT_FACE_COUNTER_CLOCKWISE;raster.lineWidth=1;
    VkPipelineMultisampleStateCreateInfo multi{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};multi.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState blend{};blend.colorWriteMask=0xF;VkPipelineColorBlendStateCreateInfo blends{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};blends.attachmentCount=1;blends.pAttachments=&blend;
    VkDynamicState dynamics[]={VK_DYNAMIC_STATE_VIEWPORT,VK_DYNAMIC_STATE_SCISSOR};VkPipelineDynamicStateCreateInfo dyn{VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};dyn.dynamicStateCount=2;dyn.pDynamicStates=dynamics;
    VkPipelineLayoutCreateInfo lc{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};Check(vkCreatePipelineLayout(v.device,&lc,nullptr,&v.layout),"pipeline layout");
    VkGraphicsPipelineCreateInfo pc{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};pc.stageCount=2;pc.pStages=stages;pc.pVertexInputState=&vertex;pc.pInputAssemblyState=&assembly;pc.pViewportState=&viewport;pc.pRasterizationState=&raster;pc.pMultisampleState=&multi;pc.pColorBlendState=&blends;pc.pDynamicState=&dyn;pc.layout=v.layout;pc.renderPass=v.offPass;
    Check(vkCreateGraphicsPipelines(v.device,VK_NULL_HANDLE,1,&pc,nullptr,&v.pipeline),"SPIR-V graphics pipeline");log(@"PASS SPIR-V vertex/fragment pipeline creation");
    const uint32_t side=128;VkImageCreateInfo im{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};im.imageType=VK_IMAGE_TYPE_2D;im.format=chosen.format;im.extent={side,side,1};im.mipLevels=1;im.arrayLayers=1;im.samples=VK_SAMPLE_COUNT_1_BIT;im.tiling=VK_IMAGE_TILING_OPTIMAL;im.usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT;im.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED;
    Check(vkCreateImage(v.device,&im,nullptr,&v.image),"offscreen image");VkMemoryRequirements req{};vkGetImageMemoryRequirements(v.device,v.image,&req);VkMemoryAllocateInfo ma{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ma.allocationSize=req.size;ma.memoryTypeIndex=v.memoryType(req.memoryTypeBits,0);Check(vkAllocateMemory(v.device,&ma,nullptr,&v.imageMemory),"image memory");Check(vkBindImageMemory(v.device,v.image,v.imageMemory,0),"bind image memory");
    VkBufferCreateInfo bc{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};bc.size=side*side*4;bc.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;bc.sharingMode=VK_SHARING_MODE_EXCLUSIVE;Check(vkCreateBuffer(v.device,&bc,nullptr,&v.buffer),"readback buffer");vkGetBufferMemoryRequirements(v.device,v.buffer,&req);ma.allocationSize=req.size;ma.memoryTypeIndex=v.memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);Check(vkAllocateMemory(v.device,&ma,nullptr,&v.bufferMemory),"readback memory");Check(vkBindBufferMemory(v.device,v.buffer,v.bufferMemory,0),"bind readback memory");
    auto offFrame=v.framebuffer(v.image,chosen.format,v.offPass,side,side);v.begin();v.draw(v.offPass,offFrame,side,side);
    VkBufferImageCopy copy{};copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};copy.imageExtent={side,side,1};vkCmdCopyImageToBuffer(v.cmd,v.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,v.buffer,1,&copy);
    VkBufferMemoryBarrier barrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;barrier.buffer=v.buffer;barrier.size=VK_WHOLE_SIZE;vkCmdPipelineBarrier(v.cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&barrier,0,nullptr);
    v.submit(false);void* mapped=nullptr;Check(vkMapMemory(v.device,v.bufferMemory,0,VK_WHOLE_SIZE,0,&mapped),"map GPU readback");
    auto* pixels=static_cast<const uint8_t*>(mapped);auto* centre=pixels+(64*side+64)*4;auto* corner=pixels+(2*side+2)*4;bool bgra=chosen.format==VK_FORMAT_B8G8R8A8_UNORM;int red=centre[bgra?2:0],green=centre[1],blue=centre[bgra?0:2];bool good=red>230&&green>90&&green<115&&blue<40&&centre[3]>245&&corner[0]<30&&corner[1]<30&&corner[2]<30;
    log([NSString stringWithFormat:@"GPU pixels: centre RGB=(%d,%d,%d), corner bytes=(%u,%u,%u)",red,green,blue,corner[0],corner[1],corner[2]]);vkUnmapMemory(v.device,v.bufferMemory);
    if(!good)throw std::runtime_error("GPU triangle/readback colours did not match");log(@"PASS GPU triangle draw and pixel readback");
    uint32_t index=0;VkResult acquire=vkAcquireNextImageKHR(v.device,v.swapchain,10'000'000'000ULL,v.acquired,VK_NULL_HANDLE,&index);if(acquire!=VK_SUBOPTIMAL_KHR)Check(acquire,"acquire swapchain image");count=0;Check(vkGetSwapchainImagesKHR(v.device,v.swapchain,&count,nullptr),"swapchain images");std::vector<VkImage> screenImages(count);Check(vkGetSwapchainImagesKHR(v.device,v.swapchain,&count,screenImages.data()),"swapchain image list");
    auto screenFrame=v.framebuffer(screenImages[index],chosen.format,v.screenPass,extent.width,extent.height);v.begin();v.draw(v.screenPass,screenFrame,extent.width,extent.height);v.submit(true);
    VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};present.waitSemaphoreCount=1;present.pWaitSemaphores=&v.rendered;present.swapchainCount=1;present.pSwapchains=&v.swapchain;present.pImageIndices=&index;VkResult result=vkQueuePresentKHR(v.queue,&present);if(result!=VK_SUBOPTIMAL_KHR)Check(result,"present triangle");Check(vkQueueWaitIdle(v.queue),"present queue completion");
    log(@"PASS Vulkan swapchain presentation submitted and queue completed. Confirm orange triangle visually.");
    // Keep the drawable visible briefly before the swapchain is destroyed.
    std::this_thread::sleep_for(std::chrono::seconds(3));
    log(@"END graphics test. Scope: official MoltenVK baseline, not the full Liberty renderer.");
}

using namespace std::chrono_literals;
using Fiber = rex::thread::Fiber;
struct FiberState { Fiber* root; int count = 0; bool intact = true; };
static void FiberEntry(void* argument) {
    auto* state = static_cast<FiberState*>(argument);
    volatile uint64_t canary = 0x123456789ABCDEF0ULL;
    for (;;) {
        state->intact &= canary == 0x123456789ABCDEF0ULL;
        ++state->count;
        Fiber::SwitchTo(state->root);
    }
}


@interface SurfaceView : UIView
@end
@implementation SurfaceView
+ (Class)layerClass {return CAMetalLayer.class;}
- (void)layoutSubviews { [super layoutSubviews];CAMetalLayer* layer=(CAMetalLayer*)self.layer;layer.contentsScale=self.window.screen.scale ?: UIScreen.mainScreen.scale;layer.drawableSize=CGSizeMake(self.bounds.size.width*layer.contentsScale,self.bounds.size.height*layer.contentsScale); }
@end
@interface GraphicsController : UIViewController
@property(nonatomic,strong) SurfaceView* surface;
@property(nonatomic,strong) UITextView* output;
@property(nonatomic,strong) NSMutableString* report;
@property(nonatomic,strong) NSURL* logURL;
@property(nonatomic,strong) UIButton* runButton;
@property(nonatomic,strong) NSMutableArray<UIButton*>* testButtons;
@property(nonatomic,strong) AVAudioPlayer* player;
@property(nonatomic) BOOL busy;
- (void)record:(NSString*)line;
@end
@implementation GraphicsController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.systemBackgroundColor;
    NSURL* doc=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    self.logURL=[doc URLByAppendingPathComponent:@"liberty-test-lab.log"];
    NSString* saved=[NSString stringWithContentsOfURL:self.logURL encoding:NSUTF8StringEncoding error:nil];
    if(!saved) saved=[NSString stringWithContentsOfURL:[doc URLByAppendingPathComponent:@"liberty-vulkan-probe.log"] encoding:NSUTF8StringEncoding error:nil];
    self.report=[NSMutableString stringWithString:saved ?: @""];
    self.testButtons=[NSMutableArray array];
    UIScrollView* scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:scroll];
    UIStackView* stack=[UIStackView new];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:stack];
    UILabel* title=[UILabel new];title.text=@"Liberty Test Lab";title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];[stack addArrangedSubview:title];
    UILabel* explanation=[UILabel new];explanation.text=@"One app for current and future checks. Run tests individually while the app stays open, then share the combined log. GTA IV is not included.";explanation.numberOfLines=0;[stack addArrangedSubview:explanation];
    self.surface=[SurfaceView new];self.surface.backgroundColor=UIColor.blackColor;[stack addArrangedSubview:self.surface];[self.surface.heightAnchor constraintEqualToConstant:180].active=YES;
    NSArray* labels=@[@"Test native Metal display",@"Test file storage",@"Play audio test tone",@"Test runtime memory",@"Test runtime threads and events",@"Test runtime fibre switching",@"Test Vulkan shaders and presentation",@"Test actual runtime Vulkan backend"];
    SEL actions[]={@selector(metalTest),@selector(storageTest),@selector(audioTest),@selector(memoryTest),@selector(threadTest),@selector(fiberTest),@selector(runTest),@selector(runtimeBackendTest)};
    for(NSUInteger i=0;i<labels.count;++i){UIButton* button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:labels[i] forState:UIControlStateNormal];button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;[button addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside];[stack addArrangedSubview:button];[self.testButtons addObject:button];if(i==6)self.runButton=button;}
    UIButton* audible=[UIButton buttonWithType:UIButtonTypeSystem];[audible setTitle:@"I heard the test tone" forState:UIControlStateNormal];[audible addTarget:self action:@selector(confirmAudio) forControlEvents:UIControlEventTouchUpInside];[stack addArrangedSubview:audible];
    UIButton* confirm=[UIButton buttonWithType:UIButtonTypeSystem];[confirm setTitle:@"I saw the orange Vulkan triangle" forState:UIControlStateNormal];[confirm addTarget:self action:@selector(confirmTriangle) forControlEvents:UIControlEventTouchUpInside];[stack addArrangedSubview:confirm];
    UIButton* share=[UIButton buttonWithType:UIButtonTypeSystem];[share setTitle:@"Share combined log" forState:UIControlStateNormal];[share addTarget:self action:@selector(shareLog:) forControlEvents:UIControlEventTouchUpInside];[stack addArrangedSubview:share];
    self.output=[UITextView new];self.output.editable=NO;self.output.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];self.output.text=self.report;[self.output.heightAnchor constraintEqualToConstant:300].active=YES;[stack addArrangedSubview:self.output];
    UILayoutGuide* safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],[scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-12],[stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],[stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],[stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32]]];
    [self record:[NSString stringWithFormat:@"--- Liberty Test Lab 0.5 launch: %@ %@; RAM %llu MiB ---",UIDevice.currentDevice.systemName,UIDevice.currentDevice.systemVersion,NSProcessInfo.processInfo.physicalMemory/1048576]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stopAudio) name:UIApplicationWillResignActiveNotification object:nil];
}
- (void)record:(NSString*)line {
    @synchronized(self) {
        [self.report appendFormat:@"%@  %@\n",[[NSISO8601DateFormatter new] stringFromDate:NSDate.date],line];
        NSError* error=nil;BOOL saved=[self.report writeToURL:self.logURL atomically:YES encoding:NSUTF8StringEncoding error:&error];NSString* text=[self.report copy];if(!saved)text=[text stringByAppendingFormat:@"\nLOG SAVE FAILED: %@",error.localizedDescription];dispatch_async(dispatch_get_main_queue(),^{self.output.text=text;});
    }
}
- (void)runTest {
    if(self.busy) return;
    [self.surface layoutIfNeeded];CAMetalLayer* layer=(CAMetalLayer*)self.surface.layer;
    layer.device=MTLCreateSystemDefaultDevice();layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;
    [self run:@"Vulkan graphics" block:^{RunVulkan(layer,[self](NSString* message){[self record:message];});}];
}
- (void)run:(NSString*)name block:(void (^)(void))test {
    if(self.busy) return;
    self.busy = YES;
    for(UIButton* b in self.testButtons) b.enabled = NO;
    [self record:[@"BEGIN " stringByAppendingString:name]];
    std::thread([self, test, name] {
        @autoreleasepool {
            try { test(); }
            catch(const std::exception& e) { [self record:[NSString stringWithFormat:@"FAIL exception: %s",e.what()]]; }
            catch(...) { [self record:@"FAIL unknown C++ exception"]; }
            [self record:[@"END " stringByAppendingString:name]];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                for(UIButton* b in self.testButtons) b.enabled = YES;
            });
        }
    }).detach();
}
- (void)memoryTest {
    [self run:@"memory" block:^{
        using namespace rex::memory;
        const size_t size = static_cast<size_t>(getpagesize()) * 4;
        void* allocation = AllocFixed(nullptr, size, AllocationType::kReserveCommit, PageAccess::kReadWrite);
        if(!allocation) { [self record:@"FAIL runtime allocation"]; return; }
        auto* bytes = static_cast<volatile unsigned char*>(allocation);
        for(size_t i=0;i<size;++i) bytes[i] = static_cast<unsigned char>(i*37);
        bool valid = true;
        for(size_t i=0;i<size;++i) if(bytes[i] != static_cast<unsigned char>(i*37)) valid = false;
        [self record:valid ? @"PASS runtime page allocation and read-back" : @"FAIL memory data mismatch"];
        size_t length = 0; PageAccess access = PageAccess::kNoAccess;
        bool query = QueryProtect(allocation,length,access);
        [self record:(query && length>=size && access==PageAccess::kReadWrite) ? @"PASS memory region query (read/write)" : @"FAIL memory region query"];
        bool readonly = Protect(allocation,size,PageAccess::kReadOnly);
        query = QueryProtect(allocation,length,access);
        [self record:(readonly && query && access==PageAccess::kReadOnly) ? @"PASS protection change to read-only" : @"FAIL read-only protection/query"];
        bool writable = Protect(allocation,size,PageAccess::kReadWrite);
        [self record:writable ? @"PASS protection restored to read/write" : @"FAIL restoring page protection"];
        if(writable) { bytes[0]=0x5A; [self record:bytes[0]==0x5A ? @"PASS write after restoring protection" : @"FAIL restored write"]; }
        [self record:DeallocFixed(allocation,size,DeallocationType::kRelease) ? @"PASS runtime page release" : @"FAIL runtime page release"];
        [self record:@"Scope: small anonymous data pages; no executable pages or guest fixed-address reservation tested."];
    }];
}
- (void)threadTest {
    [self run:@"threads/events" block:^{
        using namespace rex::thread;
        auto event = Event::CreateAutoResetEvent(false);
        bool empty = event && Wait(event.get(),false,0ms)==WaitResult::kTimeout;
        if(event) event->Set();
        bool signaled = event && Wait(event.get(),false,100ms)==WaitResult::kSuccess;
        bool reset = event && Wait(event.get(),false,0ms)==WaitResult::kTimeout;
        [self record:(empty && signaled && reset) ? @"PASS runtime event timeout, signal and auto-reset" : @"FAIL runtime event operations"];
        auto semaphore = Semaphore::Create(1,2);
        bool sem = semaphore && Wait(semaphore.get(),false,100ms)==WaitResult::kSuccess;
        sem = sem && Wait(semaphore.get(),false,0ms)==WaitResult::kTimeout;
        int prior = -1;
        sem = sem && semaphore->Release(1,&prior) && prior==0;
        sem = sem && Wait(semaphore.get(),false,100ms)==WaitResult::kSuccess;
        [self record:sem ? @"PASS runtime semaphore acquire/release" : @"FAIL runtime semaphore"];
        auto marker = std::make_shared<std::atomic<int>>(0);
        auto worker = Thread::Create(Thread::CreationParameters{},[marker] { marker->store(42); });
        bool finished = worker && Wait(worker.get(),false,2000ms)==WaitResult::kSuccess;
        [self record:(finished && marker->load()==42) ? @"PASS runtime thread creation, execution and completion wait" : @"FAIL runtime thread/completion wait"];
        if(worker && !finished) { (void)worker.release(); [self record:@"Thread handle retained because completion was not confirmed."]; }
        [self record:@"Scope: normal thread startup; thread suspension/resumption is not tested."];
    }];
}
- (void)fiberTest {
    [self run:@"fibres" block:^{
        Fiber* root = Fiber::ConvertCurrentThread();
        if(!root) { [self record:@"FAIL converting worker to fibre"]; return; }
        FiberState state{root};
        Fiber* child = Fiber::Create(256*1024,FiberEntry,&state);
        if(!child) { root->Destroy(); [self record:@"FAIL creating fibre stack"]; return; }
        [self record:@"Fibre stack created. Entering 100 switches; a crash here identifies the switching path."];
        for(int i=0;i<100;++i) Fiber::SwitchTo(child);
        bool pass = state.count==100 && state.intact && Fiber::Current()==root;
        child->Destroy(); root->Destroy();
        [self record:pass ? @"PASS 100 fibre round trips, stack canary and current-context tracking" : @"FAIL fibre result/context mismatch"];
        [self record:@"Scope: basic cooperative switching; full guest register/SIMD preservation is not established."];
    }];
}

- (void)metalTest {
    if(self.busy) return;
    [self.surface layoutIfNeeded];CAMetalLayer* layer=(CAMetalLayer*)self.surface.layer;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
    [self run:@"native Metal display" block:^{
        id<MTLCommandQueue> queue=[device newCommandQueue];id<CAMetalDrawable> drawable=[layer nextDrawable];id<MTLCommandBuffer> command=[queue commandBuffer];
        if(!device||!queue||!drawable||!command){[self record:@"FAIL native Metal setup/drawable"];return;}
        MTLRenderPassDescriptor* pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0.1,0.25,0.7,1);
        id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder){[self record:@"FAIL native Metal encoder"];return;}[encoder endEncoding];[command presentDrawable:drawable];[command commit];[command waitUntilCompleted];
        [self record:command.status==MTLCommandBufferStatusCompleted ? @"PASS native Metal display command completed (blue panel)" : [NSString stringWithFormat:@"FAIL Metal: %@",command.error.localizedDescription]];
    }];
}
- (void)storageTest {
    [self run:@"file storage" block:^{
        NSURL* file=[[self.logURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"lab-storage-probe.tmp"];
        NSData* expected=[@"Liberty Test Lab storage probe" dataUsingEncoding:NSUTF8StringEncoding];NSError* error=nil;
        BOOL wrote=[expected writeToURL:file options:NSDataWritingAtomic error:&error];NSData* read=wrote ? [NSData dataWithContentsOfURL:file] : nil;
        BOOL same=[expected isEqualToData:read];BOOL removed=wrote && [NSFileManager.defaultManager removeItemAtURL:file error:&error];
        [self record:(wrote&&same&&removed)?@"PASS Documents file write, read-back and delete":[NSString stringWithFormat:@"FAIL storage: %@",error.localizedDescription ?: @"read-back mismatch"]];
    }];
}
- (void)audioTest {
    if(self.busy) return;
    [self record:@"BEGIN audio tone"];
    NSError* error=nil;AVAudioSession* session=AVAudioSession.sharedInstance;
    if(![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error]){[self record:[NSString stringWithFormat:@"FAIL audio session: %@",error.localizedDescription]];return;}
    const uint32_t samples=12000, bytes=samples*2;std::vector<uint8_t> wav(44+bytes,0);
    auto u16=[&](size_t offset,uint16_t v){wav[offset]=v&255;wav[offset+1]=v>>8;};
    auto u32=[&](size_t offset,uint32_t v){for(int i=0;i<4;++i)wav[offset+i]=(v>>(i*8))&255;};
    memcpy(wav.data(),"RIFF",4);u32(4,36+bytes);memcpy(wav.data()+8,"WAVEfmt ",8);u32(16,16);u16(20,1);u16(22,1);u32(24,48000);u32(28,96000);u16(32,2);u16(34,16);memcpy(wav.data()+36,"data",4);u32(40,bytes);
    for(uint32_t i=0;i<samples;++i){double fade=std::min(1.0,std::min(double(i)/240.0,double(samples-i)/240.0));int16_t value=int16_t(std::sin(double(i)*2.0*3.141592653589793*440.0/48000.0)*3900.0*fade);u16(44+i*2,uint16_t(value));}
    [self.player stop];self.player=[[AVAudioPlayer alloc] initWithData:[NSData dataWithBytes:wav.data() length:wav.size()] error:&error];
    if(self.player && [self.player play]) [self record:@"Audio: quarter-second 440 Hz tone scheduled; confirm if audible"];
    else [self record:[NSString stringWithFormat:@"FAIL audio player: %@",error.localizedDescription ?: @"play returned false"]];
    [self record:@"END audio tone scheduling"];
}
- (void)confirmAudio {if(self.player)[self record:@"USER CONFIRMED audible audio test tone"];else [self record:@"Audio confirmation ignored: play a test tone first"] ;}
- (void)stopAudio {[self.player stop];[AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];}
- (void)runtimeBackendTest {
    [self run:@"actual runtime Vulkan backend" block:^{
        RunRuntimeBackend([](const char* message,void* context){
            GraphicsController* owner=(__bridge GraphicsController*)context;
            [owner record:[NSString stringWithUTF8String:message] ?: @"Runtime log encoding error"];
        },(__bridge void*)self);
    }];
}
- (void)confirmTriangle {[self record:@"USER CONFIRMED orange triangle visible"] ;}
- (void)shareLog:(UIButton*)sender {UIActivityViewController* c=[[UIActivityViewController alloc] initWithActivityItems:@[self.logURL] applicationActivities:nil];c.popoverPresentationController.sourceView=sender;c.popoverPresentationController.sourceRect=sender.bounds;[self presentViewController:c animated:YES completion:nil];}
@end
@interface GraphicsDelegate : UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow* window;
@end
@implementation GraphicsDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options {self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[GraphicsController new];[self.window makeKeyAndVisible];return YES;}
@end
int main(int argc,char* argv[]){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(GraphicsDelegate.class));}}
