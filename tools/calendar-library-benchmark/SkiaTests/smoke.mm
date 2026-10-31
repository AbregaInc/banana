// Build/backend feasibility only; not calendar correctness or performance acceptance.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#include "include/core/SkCanvas.h"
#include "include/core/SkFont.h"
#include "include/core/SkPaint.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTextBlob.h"
#include "include/ports/SkTypeface_mac.h"
#include "include/ports/SkFontMgr_mac_ct.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include "modules/skshaper/include/SkShaper_coretext.h"
#include <vector>
#include <cstring>

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!device || !queue) return 2;
        GrMtlBackendContext backend;
        backend.fDevice = sk_ret_cfp((__bridge const void*)device);
        backend.fQueue = sk_ret_cfp((__bridge const void*)queue);
        auto context = GrDirectContexts::MakeMetal(backend);
        if (!context) return 3;
        context->setResourceCacheLimit(32 * 1024 * 1024);
        auto info = SkImageInfo::MakeN32Premul(1024, 256);
        auto surface = SkSurfaces::RenderTarget(context.get(), skgpu::Budgeted::kYes, info);
        auto shaper = SkShapers::CT::CoreText();
        if (!surface || !shaper) return 4;
        CTFontRef native = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 18, nullptr);
        if (!native) return 5;
        auto face = SkMakeTypefaceFromCTFont(native);
        CFRelease(native);
        if (!face) return 6;
        SkFont font(face, 18);
        auto fontManager = SkFontMgr_New_CoreText(nullptr);
        if (!fontManager) return 10;
        auto canvas = surface->getCanvas();
        canvas->clear(SK_ColorWHITE);
        SkPaint paint;
        paint.setColor(SK_ColorBLUE);
        canvas->drawRect(SkRect::MakeXYWH(16, 16, 992, 48), paint);
        paint.setColor(SK_ColorBLACK);
        const char* titles[] = {"Calendar: planning and review", "Réunion · 東京 · مرحبا", "Design review 👩🏽‍💻 — follow-up"};
        int textRuns = 0;
        for (int i = 0; i < 3; ++i) {
            auto title = titles[i];
            SkTextBlobBuilderRunHandler handler(title, SkPoint::Make(20, 90 + i * 48));
            // The legacy font overload supplies a null fallback manager. Keep
            // multilingual coverage and explicitly provide native font fallback.
            auto fontRuns = SkShaper::MakeFontMgrRunIterator(
                title, std::strlen(title), font, fontManager);
            if (!fontRuns) return 11;
            SkShaper::TrivialBiDiRunIterator bidi(0, 0);
            SkShaper::TrivialScriptRunIterator script(0, 0);
            SkShaper::TrivialLanguageRunIterator language(nullptr, 0);
            shaper->shape(title, std::strlen(title), *fontRuns, bidi, script,
                          language, nullptr, 0, 980, &handler);
            auto blob = handler.makeBlob();
            if (!blob || blob->bounds().isEmpty()) return 7;
            canvas->drawTextBlob(blob, 0, 0, paint);
            ++textRuns;
        }
        context->flushAndSubmit(GrSyncCpu::kYes);
        std::vector<uint32_t> pixels(1024 * 256);
        if (!surface->readPixels(info, pixels.data(), 1024 * 4, 0, 0)) return 8;
        size_t nonWhite = 0;
        uint64_t checksum = 14695981039346656037ULL;
        for (auto pixel : pixels) {
            if (pixel != 0xFFFFFFFFU) ++nonWhite;
            checksum = (checksum ^ pixel) * 1099511628211ULL;
        }
        if (nonWhite < 992 * 48) return 9;
        NSDictionary* result = @{@"status": @"backend-smoke-passed", @"device": device.name,
            @"shapedTextRuns": @(textRuns), @"nonWhitePixels": @(nonWhite), @"pixelChecksum": @(checksum),
            @"scope": @"Mac Metal/Core Text build feasibility only; no calendar parity, accessibility or performance acceptance"};
        NSData* data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
        return 0;
    }
}
