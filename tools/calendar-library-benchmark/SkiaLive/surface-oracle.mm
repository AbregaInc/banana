// Offscreen correctness oracle, not performance or display-delivery evidence.
#include "LiveBridge.mm"
#import <ImageIO/ImageIO.h>
#include <cstdio>
static void savePNG(const std::vector<uint8_t>& bytes, int width, int height, NSString* path) {
    CFDataRef data = CFDataCreate(nullptr, bytes.data(), bytes.size());
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width,height,8,32,width*4,color,kCGImageAlphaPremultipliedLast,provider,nullptr,false,kCGRenderingIntentDefault);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],CFSTR("public.png"),1,nullptr);
    CGImageDestinationAddImage(destination,image,nullptr); CGImageDestinationFinalize(destination);
    CFRelease(destination);CGImageRelease(image);CGColorSpaceRelease(color);CGDataProviderRelease(provider);CFRelease(data);
}
static void copyPixels(CVPixelBufferRef buffer, std::vector<uint8_t>& bytes, int width, int height) {
    CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    auto* source = (uint8_t*)CVPixelBufferGetBaseAddress(buffer); size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (int y=0;y<height;++y) for (int x=0;x<width;++x) for (int c=0;c<4;++c)
        bytes[(y*width+x)*4+c]=source[y*stride+x*4+(c==0?2:c==2?0:c)];
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
}
int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc != 3 && argc != 4) return 2;
        bool memoComparison = argc == 4 && strcmp(argv[3], "--memo") == 0;
        bool nativeRepeat = argc == 4 && strcmp(argv[3], "--repeat-native") == 0;
        bool nativeComparison = memoComparison || nativeRepeat;
        if (argc == 4 && !nativeComparison) return 2;
        NSData* inputData = [NSData dataWithContentsOfFile:@(argv[1])];
        NSMutableDictionary* input = [[NSJSONSerialization JSONObjectWithData:inputData options:NSJSONReadingMutableContainers error:nil] mutableCopy];
        input[@"recordOnly"] = @YES; input[@"reusePictures"] = @YES; input[@"tileCount"] = @8;
        input[@"memoText"] = @(memoComparison);
        NSData* data = [NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
        NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        void* page = calendar_live_prepare(json.UTF8String);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        void* renderer = calendar_live_renderer((__bridge void*)device);
        if (!page || !renderer) return 2;
        NSArray* buffers = CFBridgingRelease(calendar_live_raster_page(renderer,page));
        if (buffers.count != 8) return 2;
        input[@"recordOnly"] = @(nativeComparison);
        input[@"memoText"] = @NO;
        data = [NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
        json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        void* control = nativeComparison ? calendar_live_prepare(json.UTF8String) : calendar_skia_create(json.UTF8String);
        if (!control) return 2;
        NSArray* controlBuffers = nil;
        if (nativeComparison) {
            controlBuffers = CFBridgingRelease(calendar_live_raster_page(renderer,control));
            if (controlBuffers.count != 8) return 2;
        } else if (calendar_skia_render(control,0) < 0) return 2;
        int width = [input[@"width"] intValue]*[input[@"scale"] intValue], height = 256*[input[@"scale"] intValue];
        NSMutableArray* rows = [NSMutableArray array]; bool exact = true;
        for (int tile = 0; tile < 8; ++tile) {
            std::vector<uint8_t> expected(width*height*4), actual(width*height*4);
            if (nativeComparison) copyPixels((__bridge CVPixelBufferRef)controlBuffers[tile],expected,width,height);
            else if (!calendar_skia_read(control,tile,expected.data())) return 2;
            CVPixelBufferRef buffer = (__bridge CVPixelBufferRef)buffers[tile];
            CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
            auto* bytes = (uint8_t*)CVPixelBufferGetBaseAddress(buffer); size_t stride = CVPixelBufferGetBytesPerRow(buffer);
            int differences=0, maxDifference=0;
            for (int y=0;y<height;++y) for (int x=0;x<width;++x) {
                bool different=false;
                for (int c=0;c<4;++c) {
                    int index=(y*width+x)*4+c; actual[index]=bytes[y*stride+x*4+(c==0?2:c==2?0:c)];
                    int d=abs(int(actual[index])-int(expected[index])); different |= d!=0; maxDifference=std::max(d,maxDifference);
                }
                differences += different;
            }
            CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
            exact &= differences==0;
            [rows addObject:@{@"tile":@(tile),@"differentPixels":@(differences),@"maxChannelDifference":@(maxDifference)}];
            if (differences) {
                savePNG(expected,width,height,[@(argv[2]) stringByAppendingPathComponent:[NSString stringWithFormat:@"reference-%d.png",tile]]);
                savePNG(actual,width,height,[@(argv[2]) stringByAppendingPathComponent:[NSString stringWithFormat:@"surface-%d.png",tile]]);
            }
        }
        NSData* result = [NSJSONSerialization dataWithJSONObject:@{@"exact":@(exact),@"tiles":rows} options:NSJSONWritingPrettyPrinted error:nil];
        [result writeToFile:[@(argv[2]) stringByAppendingPathComponent:@"pixels.json"] atomically:YES];
        calendar_skia_destroy(control); calendar_skia_destroy(page); delete (LiveRenderer*)renderer;
        return exact ? 0 : 1;
    }
}
