# INTEL knob V-allow-sysmem-fallback: GGML_VK_ALLOW_SYSMEM_FALLBACK=1
# ggml-vulkan.cpp:4015 - oversubscribe VRAM via host-visible memory; bandwidth cliff risk (research/10 wedged the driver)
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
