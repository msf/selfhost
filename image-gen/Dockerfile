# stable-diffusion.cpp with the Vulkan backend, for the R9700 (Navi 48, gfx1201).
#
# The runtime stage pulls mesa from trixie-backports on purpose: only Mesa >= 26.x
# exposes VK_KHR_cooperative_matrix on RDNA4. On trixie's 25.0.7 RADV reports
# "matrix cores: none" and matmul falls back to scalar shaders — measured 1.40x
# slower end-to-end (303.64s -> 217.34s at 1024x1024/26 steps, 2026-08-03).
# Keeping mesa in the image rather than on the host leaves the desktop
# (regolith/x2go) and llama-swap untouched.

ARG SDCPP_REF=a8a91b2

FROM debian:trixie AS build
ARG SDCPP_REF
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
        glslc spirv-headers libvulkan-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --recursive https://github.com/leejet/stable-diffusion.cpp.git . \
    && git checkout --recurse-submodules "${SDCPP_REF}"
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release -DSD_VULKAN=ON -DSD_BUILD_SERVER=ON \
    && cmake --build build --config Release -j"$(nproc)"

FROM debian:trixie
RUN echo 'deb http://deb.debian.org/debian trixie-backports main' \
        > /etc/apt/sources.list.d/backports.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends -t trixie-backports \
        mesa-vulkan-drivers libvulkan1 \
    && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/bin/sd-cli /src/build/bin/sd-server /usr/local/bin/

# Device 1 is the R9700; device 0 is the Ryzen 8500G iGPU (Phoenix2, uma=1).
# Making the R9700 the only visible device means it becomes vulkan0 and the
# default placement, so no --backend argument is needed. Same convention as
# llama-swap.service. SYSMEM_FALLBACK=0 turns a silent spill into a loud error.
ENV GGML_VK_VISIBLE_DEVICES=1 \
    GGML_VK_ALLOW_SYSMEM_FALLBACK=0 \
    GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1

EXPOSE 1234
ENTRYPOINT ["sd-server"]
