# L33 lever: let Vulkan allocations spill to host-visible memory instead of failing.
# ggml/src/ggml-vulkan/ggml-vulkan.cpp:4009 (PREFER_HOST_MEMORY), :4015 (ALLOW_SYSMEM_FALLBACK).
# Risk: bandwidth cliff or a wedged driver (research/10 saw a silent over-commit at -ngl 48).
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export GGML_VK_PREFER_HOST_MEMORY=1
