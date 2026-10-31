// Isolated offscreen comparison. Core Text shapes both candidates; Skia owns GPU drawing.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#include "include/core/SkCanvas.h"
#include "include/core/SkFont.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPicture.h"
#include "include/core/SkPictureRecorder.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTextBlob.h"
#include "include/ports/SkTypeface_mac.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include <vector>
#include <chrono>
#include <unordered_map>
#include <string>

static double clockMS() {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
struct Event { SkRect rect; SkColor4f color; NSString* title; };
struct Probe {
    sk_sp<GrDirectContext> context;
    std::vector<sk_sp<SkSurface>> tiles;
    std::vector<Event> events;
    int width, scale, days;
    SkColor4f separator;
    bool cgPaths = false, reusePictures = false, recordOnly = false, memoText = false;
    int tileCount = 4;
    sk_sp<SkPicture> pictures[8];
    int storedDrawn[8] = {};
    size_t pictureBytes = 0, pictureLimit = 8 * 1024 * 1024;
    int hits = 0, misses = 0;
    double encodeMS = 0;
    int drawn[8] = {};
    CTFontRef titleFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12, nullptr);
    CTFontRef hourFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 11, nullptr);
    ~Probe() { CFRelease(titleFont); CFRelease(hourFont); }
};
using TextMemo = std::unordered_map<std::string, sk_sp<SkTextBlob>>;
static void text(SkCanvas* canvas, NSString* value, CTFontRef native, float x, float y, TextMemo* memo = nullptr) {
    std::string key = memo ? value.UTF8String : "";
    if (memo) {
        auto found = memo->find(key);
        if (found != memo->end()) {
            SkPaint paint; paint.setColor(SK_ColorBLACK); paint.setAntiAlias(true);
            if (found->second) canvas->drawTextBlob(found->second, x, y, paint);
            return;
        }
    }
    // Match PreparedText's native line and fallback run selection, with no width truncation.
    NSDictionary* attrs = @{(__bridge NSString*)kCTFontAttributeName: (__bridge id)native};
    NSAttributedString* attributed = [[NSAttributedString alloc] initWithString:value attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    SkTextBlobBuilder builder;
    for (id item in (__bridge NSArray*)CTLineGetGlyphRuns(line)) {
        CTRunRef run = (__bridge CTRunRef)item;
        CFIndex count = CTRunGetGlyphCount(run);
        if (!count) continue;
        CTFontRef font = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        SkFont skFont(SkMakeTypefaceFromCTFont(font), CTFontGetSize(font));
        skFont.setSubpixel(true);
        skFont.setEdging(SkFont::Edging::kAntiAlias);
        const auto& buffer = builder.allocRunPos(skFont, (int)count);
        CTRunGetGlyphs(run, CFRangeMake(0, 0), buffer.glyphs);
        std::vector<CGPoint> positions(count);
        CTRunGetPositions(run, CFRangeMake(0, 0), positions.data());
        for (CFIndex i = 0; i < count; ++i) buffer.points()[i] = SkPoint::Make(positions[i].x, -positions[i].y);
    }
    CFRelease(line);
    auto blob = builder.make();
    if (memo) memo->emplace(std::move(key), blob);
    SkPaint paint; paint.setColor(SK_ColorBLACK); paint.setAntiAlias(true);
    if (blob) canvas->drawTextBlob(blob, x, y, paint);
}
extern "C" void* calendar_skia_create(const char* json) {
    @autoreleasepool {
        NSDictionary* input = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:nil];
        if (!input) return nullptr;
        auto probe = std::make_unique<Probe>();
        probe->width = [input[@"width"] intValue]; probe->scale = [input[@"scale"] intValue]; probe->days = [input[@"days"] intValue];
        probe->recordOnly = [input[@"recordOnly"] boolValue];
        probe->memoText = [input[@"memoText"] boolValue];
        probe->tileCount = input[@"tileCount"] ? [input[@"tileCount"] intValue] : 4;
        if (probe->tileCount < 1 || probe->tileCount > 8) return nullptr;
        probe->cgPaths = [input[@"cgPaths"] boolValue];
        probe->reusePictures = [input[@"reusePictures"] boolValue];
        probe->pictureLimit = [input[@"pictureLimit"] unsignedLongLongValue];
        NSArray* separator = input[@"separator"];
        probe->separator = {[separator[0] floatValue], [separator[1] floatValue], [separator[2] floatValue], [separator[3] floatValue]};
        if (!probe->recordOnly) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        GrMtlBackendContext backend;
        backend.fDevice = sk_ret_cfp((__bridge const void*)device);
        backend.fQueue = sk_ret_cfp((__bridge const void*)queue);
        probe->context = GrDirectContexts::MakeMetal(backend);
        if (!probe->context) return nullptr;
        probe->context->setResourceCacheLimit(32 * 1024 * 1024);
        }
        for (NSDictionary* event in input[@"events"]) {
            NSArray* r = event[@"rect"]; NSArray* c = event[@"color"];
            probe->events.push_back({SkRect::MakeXYWH([r[0] floatValue], [r[1] floatValue], [r[2] floatValue], [r[3] floatValue]),
                {[c[0] floatValue], [c[1] floatValue], [c[2] floatValue], [c[3] floatValue]}, event[@"title"]});
        }
        return probe.release();
    }
}
extern "C" double calendar_skia_render(void* opaque, int32_t evict) {
    @autoreleasepool {
        auto& p = *(Probe*)opaque;
        double began = clockMS();
        p.tiles.clear();
        p.hits = p.misses = 0;
        if (evict) {
            for (auto& picture : p.pictures) picture.reset();
            p.pictureBytes = 0;
            if (p.context) p.context->freeGpuResources();
        }
        // Scoped to this preparation job and separated by font. Recorded pictures
        // retain shared immutable blobs; no global cache or cross-style reuse.
        TextMemo titleMemo, hourMemo;
        for (int tile = 0; tile < p.tileCount; ++tile) {
            p.drawn[tile] = 0;
            auto info = SkImageInfo::Make(p.width * p.scale, 256 * p.scale, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
            auto surface = p.recordOnly ? nullptr : SkSurfaces::RenderTarget(p.context.get(), skgpu::Budgeted::kYes, info);
            if (!surface && !p.recordOnly) return -1;
            auto target = surface ? surface->getCanvas() : nullptr;
            if (p.reusePictures && p.pictures[tile]) {
                ++p.hits;
                p.drawn[tile] = p.storedDrawn[tile];
                if (target) target->drawPicture(p.pictures[tile]);
                p.tiles.push_back(surface);
                continue;
            }
            ++p.misses;
            SkPictureRecorder recorder;
            auto canvas = p.reusePictures ? recorder.beginRecording(p.width*p.scale, 256*p.scale) : target;
            canvas->clear(SK_ColorWHITE);
            canvas->scale(p.scale, p.scale); canvas->translate(0, -tile * 256);
            SkPaint grid; grid.setColor4f(p.separator); grid.setStrokeWidth(0.5); grid.setAntiAlias(true);
            for (int hour = 0; hour <= 24; ++hour) canvas->drawLine(48, hour * 80, p.width, hour * 80, grid);
            for (int day = 0; day <= p.days; ++day) {
                float x = 48 + day * float(p.width - 48) / p.days;
                canvas->drawLine(x, 0, x, 1920, grid);
            }
            for (int hour = 0; hour < 24; ++hour) text(canvas, [NSString stringWithFormat:@"%02d:00", hour], p.hourFont, 3, hour * 80 + 13, p.memoText ? &hourMemo : nullptr);
            SkRect region = SkRect::MakeXYWH(0, tile * 256 - 1.0f/p.scale, p.width, 256 + 2.0f/p.scale);
            for (const auto& event : p.events) {
                if (!SkRect::Intersects(region, event.rect)) continue;
                ++p.drawn[tile];
                SkPaint paint; paint.setColor4f(event.color); paint.setAntiAlias(true);
                if (p.cgPaths) {
                    auto rect = event.rect;
                    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(rect.x(), rect.y(), rect.width(), rect.height()),
                        std::min(3.0f, rect.width()/2), std::min(3.0f, rect.height()/2), nullptr);
                    SkPathBuilder builder;
                    CGPathApply(path, &builder, [](void* info, const CGPathElement* element) {
                        auto& b = *(SkPathBuilder*)info; const CGPoint* p = element->points;
                        switch (element->type) {
                            case kCGPathElementMoveToPoint: b.moveTo(p[0].x, p[0].y); break;
                            case kCGPathElementAddLineToPoint: b.lineTo(p[0].x, p[0].y); break;
                            case kCGPathElementAddQuadCurveToPoint: b.quadTo(p[0].x, p[0].y, p[1].x, p[1].y); break;
                            case kCGPathElementAddCurveToPoint: b.cubicTo(p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y); break;
                            case kCGPathElementCloseSubpath: b.close(); break;
                        }
                    });
                    CGPathRelease(path);
                    canvas->drawPath(builder.detach(), paint);
                } else {
                    canvas->drawRoundRect(event.rect, std::min(3.0f, event.rect.width()/2), std::min(3.0f, event.rect.height()/2), paint);
                }
                canvas->save(); canvas->clipRect(event.rect);
                text(canvas, event.title, p.titleFont, event.rect.x()+3, event.rect.y()+14, p.memoText ? &titleMemo : nullptr);
                canvas->restore();
            }
            if (p.reusePictures) {
                auto picture = recorder.finishRecordingAsPicture();
                if (target) target->drawPicture(picture);
                size_t bytes = picture->approximateBytesUsed();
                if (bytes <= p.pictureLimit - p.pictureBytes) {
                    p.pictures[tile] = picture;
                    p.pictureBytes += bytes;
                    p.storedDrawn[tile] = p.drawn[tile];
                }
            }
            p.tiles.push_back(surface);
        }
        p.encodeMS = clockMS() - began;
        if (p.context) p.context->flushAndSubmit(GrSyncCpu::kYes);
        return clockMS() - began;
    }
}
extern "C" double calendar_skia_encode(void* opaque) { return ((Probe*)opaque)->encodeMS; }
extern "C" int32_t calendar_skia_read(void* opaque, int32_t tile, uint8_t* bytes) {
    auto& p = *(Probe*)opaque;
    auto info = SkImageInfo::Make(p.width*p.scale, 256*p.scale, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    return p.tiles.at(tile)->readPixels(info, bytes, p.width*p.scale*4, 0, 0);
}
extern "C" double calendar_skia_cache_bytes(void* opaque) {
    size_t bytes; ((Probe*)opaque)->context->getResourceCacheUsage(nullptr, &bytes); return bytes;
}
extern "C" void calendar_skia_destroy(void* opaque) { delete (Probe*)opaque; }

extern "C" int32_t calendar_skia_drawn(void* opaque, int32_t tile) { return ((Probe*)opaque)->drawn[tile]; }

extern "C" double calendar_skia_picture_stat(void* opaque, int32_t which) {
    auto& p = *(Probe*)opaque;
    if (which == 0) return p.pictureBytes;
    if (which == 1) return p.hits;
    if (which == 2) return p.misses;
    int count = 0; for (const auto& picture : p.pictures) if (picture) ++count;
    return count;
}
