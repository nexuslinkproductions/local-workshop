# VEC screening on sycl-dev: FORCE_VEC alone, then forced parallel blocks
vec|engines/llama.cpp-sycl-dev/build/bin/llama-server|sycl|SYCL0|GGML_SYCL_FA_FORCE_VEC=1|
vecpb16|engines/llama.cpp-sycl-dev/build/bin/llama-server|sycl|SYCL0|GGML_SYCL_FA_FORCE_VEC=1 GGML_SYCL_FA_PB=16|
vecpb32|engines/llama.cpp-sycl-dev/build/bin/llama-server|sycl|SYCL0|GGML_SYCL_FA_FORCE_VEC=1 GGML_SYCL_FA_PB=32|
vecpb64|engines/llama.cpp-sycl-dev/build/bin/llama-server|sycl|SYCL0|GGML_SYCL_FA_FORCE_VEC=1 GGML_SYCL_FA_PB=64|
vecpb128|engines/llama.cpp-sycl-dev/build/bin/llama-server|sycl|SYCL0|GGML_SYCL_FA_FORCE_VEC=1 GGML_SYCL_FA_PB=128|
