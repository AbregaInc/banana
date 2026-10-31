// Isolated preview adapter. The renderer owns one serial Metal queue; pages are immutable.
#include "../SkiaTests/bridge.mm"
#import <QuartzCore/CAMetalLayer.h>
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendSurface.h"
#include <os/signpost.h>
#import <CoreVideo/CoreVideo.h>

struct LiveRenderer {
    sk_sp<GrDirectContext> context;
    id<MTLCommandQueue> queue;
};
extern "C" void* calendar_live_prepare(const char* json) {
    auto* page = (Probe*)calendar_skia_create(json);
    if (!page || !page->recordOnly || !page->reusePictures || page->tileCount != 8) { delete page; return nullptr; }
    if (calendar_skia_render(page, 0) < 0 || calendar_skia_picture_stat(page, 3) != 8) { delete page; return nullptr; }
    return page;
}
extern "C" void* calendar_live_renderer(void* rawDevice) {
    @autoreleasepool {
        auto renderer = std::make_unique<LiveRenderer>();
        id<MTLDevice> device = (__bridge id<MTLDevice>)rawDevice;
        renderer->queue = [device newCommandQueue];
        GrMtlBackendContext backend;
        backend.fDevice = sk_ret_cfp((__bridge const void*)device);
        backend.fQueue = sk_ret_cfp((__bridge const void*)renderer->queue);
        renderer->context = GrDirectContexts::MakeMetal(backend);
        if (!renderer->context) return nullptr;
        renderer->context->setResourceCacheLimit(64 * 1024 * 1024);
        return renderer.release();
    }
}
typedef void (*LiveCompletion)(void*, double, double, double, int32_t);
typedef void (*LiveGPUCompletion)(void*, double, int32_t);
extern "C" int32_t calendar_live_draw(void* opaque, void* rawPage, void* rawDrawable,
    double offsetPoints, void* token, LiveCompletion complete, void* gpuToken, LiveGPUCompletion gpuComplete) {
    @autoreleasepool {
        auto& renderer = *(LiveRenderer*)opaque;
        auto& page = *(Probe*)rawPage;
        id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)rawDrawable;
        GrMtlTextureInfo info;
        info.fTexture.retain((__bridge const void*)drawable.texture);
        auto backend = GrBackendRenderTargets::MakeMtl((int)drawable.texture.width, (int)drawable.texture.height, info);
        auto surface = SkSurfaces::WrapBackendRenderTarget(renderer.context.get(), backend,
            kTopLeft_GrSurfaceOrigin, kBGRA_8888_SkColorType, nullptr, nullptr);
        if (!surface) return 0;
        static os_log_t log = os_log_create("com.boris.banana.calendar-metal-review", "Rendering");
        auto signpost = os_signpost_id_generate(log);
        os_signpost_interval_begin(log, signpost, "LiveSkiaEncode");
        double began = CACurrentMediaTime();
        auto canvas = surface->getCanvas();
        canvas->clear(SK_ColorWHITE);
        double offset = offsetPoints * page.scale;
        for (int tile = 0; tile < page.tileCount; ++tile) {
            float top = tile * 256 * page.scale - offset;
            float height = 256 * page.scale;
            if (top >= drawable.texture.height || top + height <= 0) continue;
            canvas->save();
            canvas->clipRect(SkRect::MakeXYWH(0, top, page.width * page.scale, height));
            canvas->translate(0, top);
            canvas->drawPicture(page.pictures[tile]);
            canvas->restore();
        }
        renderer.context->flushAndSubmit(GrSyncCpu::kNo);
        double encoded = CACurrentMediaTime();
        os_signpost_interval_end(log, signpost, "LiveSkiaEncode");
        id<MTLCommandBuffer> present = [renderer.queue commandBuffer];
        if (!present) return 0;
        [present addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            gpuComplete(gpuToken, CACurrentMediaTime(), buffer.status == MTLCommandBufferStatusCompleted ? 1 : 0);
        }];
        [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
            complete(token, began, encoded, shown.presentedTime, shown.presentedTime > 0 ? 1 : 0);
        }];
        [present presentDrawable:drawable];
        [present commit];
        return 1;
    }
}

// GPU preparation is serialized off-main. Returned buffers are immutable after
// the completion fence and can be moved by the native compositor during scrolling.
extern "C" void* calendar_live_raster_page(void* opaque, void* rawPage) {
    @autoreleasepool {
        auto& renderer = *(LiveRenderer*)opaque;
        auto& page = *(Probe*)rawPage;
        CVMetalTextureCacheRef cache = nullptr;
        if (CVMetalTextureCacheCreate(nullptr, nullptr, renderer.queue.device, nullptr, &cache) != kCVReturnSuccess) return nullptr;
        NSMutableArray* buffers = [NSMutableArray arrayWithCapacity:page.tileCount];
        std::vector<sk_sp<SkSurface>> targets;
        std::vector<CVMetalTextureRef> textures;
        bool valid = true;
        for (int tile = 0; tile < page.tileCount; ++tile) {
            CVPixelBufferRef buffer = nullptr;
            NSDictionary* attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                (id)kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: @YES,
                (id)kCVPixelBufferMetalCompatibilityKey: @YES};
            int width = page.width * page.scale, height = 256 * page.scale;
            if (CVPixelBufferCreate(nullptr, width, height, kCVPixelFormatType_32BGRA,
                (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess) { valid = false; break; }
            CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, color, kCVAttachmentMode_ShouldPropagate);
            CGColorSpaceRelease(color);
            CVMetalTextureRef texture = nullptr;
            NSDictionary* textureAttrs = @{(id)kCVMetalTextureUsage: @(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)};
            auto status = CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, buffer, (__bridge CFDictionaryRef)textureAttrs,
                MTLPixelFormatBGRA8Unorm, width, height, 0, &texture);
            if (status != kCVReturnSuccess || !texture) { CVPixelBufferRelease(buffer); valid = false; break; }
            GrMtlTextureInfo info; info.fTexture.retain((__bridge const void*)CVMetalTextureGetTexture(texture));
            auto backend = GrBackendRenderTargets::MakeMtl(width, height, info);
            auto surface = SkSurfaces::WrapBackendRenderTarget(renderer.context.get(), backend,
                kTopLeft_GrSurfaceOrigin, kBGRA_8888_SkColorType, nullptr, nullptr);
            if (!surface) { CFRelease(texture); CVPixelBufferRelease(buffer); valid = false; break; }
            textures.push_back(texture);
            surface->getCanvas()->drawPicture(page.pictures[tile]);
            targets.push_back(surface);
            [buffers addObject:(__bridge id)buffer]; CVPixelBufferRelease(buffer);
        }
        renderer.context->flushAndSubmit(GrSyncCpu::kYes);
        for (auto texture : textures) CFRelease(texture);
        CVMetalTextureCacheFlush(cache, 0); CFRelease(cache);
        if (!valid) return nullptr;
        return (__bridge_retained void*)buffers;
    }
}
