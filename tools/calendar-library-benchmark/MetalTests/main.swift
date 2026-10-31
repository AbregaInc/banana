// Offscreen component experiment only. No drawable, UI latency or frame-delivery claim.
import Foundation
import CoreGraphics
import CoreText
import Metal
import CoreVideo

private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
private enum Failure: Error { case unavailable, mismatch(Int), command(String) }

private final class TileCompositor {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let width: Int, height: Int
    let target: MTLTexture
    var textures: [MTLTexture] = []
    private var textureCache: CVMetalTextureCache?
    // Keep Core Video owners alive until the last command completes. This serial
    // probe waits before eviction; an asynchronous integration needs per-command ownership.
    private var wrappers: [CVMetalTexture] = []
    private var sourceBuffers: [CVPixelBuffer] = []
    init(width: Int, height: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        self.device = device; self.queue = queue; self.width = width; self.height = height
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vertexTile(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
            float2 uv = float2(id & 1, id >> 1);
            V v; v.position = float4(mix(rect.x, rect.z, uv.x), mix(rect.y, rect.w, uv.y), 0, 1);
            v.uv = uv; return v;
        }
        fragment float4 fragmentTile(V v [[stage_in]], texture2d<float> tile [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
            return tile.sample(s, v.uv);
        }
        """
        let library = try device.makeLibrary(source: shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexTile")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentTile")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let output = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        output.storageMode = .shared; output.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: output) else { throw Failure.unavailable }
        self.target = target
    }
    func upload(_ images: [CGImage]) throws {
        textures.removeAll(keepingCapacity: true)
        for image in images {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: image.width, height: image.height, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor),
                  let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { throw Failure.unavailable }
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: bytes, bytesPerRow: image.bytesPerRow)
            textures.append(texture)
        }
    }
    func uploadSurfaces(_ buffers: [CVPixelBuffer], shared: Bool) throws {
        textures.removeAll(keepingCapacity: true)
        wrappers.removeAll(keepingCapacity: true)
        sourceBuffers.removeAll(keepingCapacity: true)
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        if shared && textureCache == nil {
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else {
                throw Failure.unavailable
            }
        }
        for buffer in buffers {
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            precondition(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
            if shared {
                var wrapper: CVMetalTexture?
                let attributes = [kCVMetalTextureUsage: MTLTextureUsage.shaderRead.rawValue] as CFDictionary
                guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache!, buffer,
                    attributes, .bgra8Unorm, width, height, 0, &wrapper) == kCVReturnSuccess,
                    let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else { throw Failure.unavailable }
                sourceBuffers.append(buffer); wrappers.append(wrapper); textures.append(texture)
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: width, height: height, mipmapped: false)
                descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
                guard let texture = device.makeTexture(descriptor: descriptor),
                    CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw Failure.unavailable }
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let bytes = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.unavailable }
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: bytes, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
                textures.append(texture)
            }
        }
    }
    // Deliberately serial completion for isolated cost measurement. Never a main-UI implementation.
    func draw(offset: Int) throws -> [String: Double] {
        let began = now()
        guard let command = queue.makeCommandBuffer() else { throw Failure.unavailable }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.unavailable }
        encoder.setRenderPipelineState(pipeline)
        var top = -offset
        for texture in textures {
            var rect = SIMD4<Float>(-1, 1 - 2 * Float(top) / Float(height),
                                    1, 1 - 2 * Float(top + texture.height) / Float(height))
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            top += texture.height
        }
        encoder.endEncoding(); command.commit()
        let submitted = now()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw Failure.command(String(describing: command.error)) }
        return ["encodeSubmitMS": submitted - began, "completionMS": now() - began,
                "gpuMS": (command.gpuEndTime - command.gpuStartTime) * 1000]
    }
    func pixels() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return bytes
    }
}

@main struct MetalTileProbe {
    @MainActor static func main() throws {
        let config = CalendarFixtureConfiguration(), store = FixtureStore(config)
        let model = PrototypeModel(store: store)
        model.move(to: store.anchor)
        let black = CGColor(gray: 0, alpha: 1)
        let source = config.value("--texture-source", "cgimage-copy")
        guard ["cgimage-copy", "surface-copy", "surface-shared"].contains(source) else { throw Failure.command("Unknown texture source") }
        var style = RasterPage.Style(text: .init(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: .init(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        style.pixelBuffer = source != "cgimage-copy"
        var results: [[String: Any]] = []
        for (points, scale) in [(393, 3), (1366, 2)] {
            let width = points * scale, height = 768 * scale
            let preparation = now()
            let pages = (0..<4).map { index in RasterPage.render(days: model.layouts,
                width: Double(points), height: 1920, gutter: 48, scale: Double(scale), style: style,
                region: CGRect(x: 0, y: index * 256, width: points, height: 256))! }
            let preparationMS = now() - preparation
            // Reference conversion is outside preparation/upload/render timings and
            // present for both surface paths. It remains included in process peak RSS.
            let referenceStart = now()
            let images = pages.map(\.image)
            let referenceSnapshotMS = now() - referenceStart
            let startup = now(); let metal = try TileCompositor(width: width, height: height)
            let startupMS = now() - startup
            guard let cpu = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.unavailable }
            cpu.interpolationQuality = .none; cpu.setBlendMode(.copy)
            var samples: [[String: Any]] = []
            for trial in 0..<3 {
                for state in ["cold-upload", "warm", "eviction-reupload"] {
                    let upload = now()
                    if state != "warm" {
                        if source == "cgimage-copy" { try metal.upload(images) }
                        else { try metal.uploadSurfaces(pages.map { $0.pixelBuffer! }, shared: source == "surface-shared") }
                    }
                    let uploadMS = now() - upload
                    for offset in [0, 128 * scale, 256 * scale, 0] {
                        func cpuDraw() -> Double {
                            let began = now()
                            cpu.setFillColor(CGColor(gray: 1, alpha: 1)); cpu.fill(CGRect(x: 0, y: 0, width: width, height: height))
                            var top = -offset
                            for image in images {
                                cpu.draw(image, in: CGRect(x: 0, y: height - top - image.height, width: width, height: image.height))
                                top += image.height
                            }
                            cpu.flush(); return now() - began
                        }
                        let cpuMS: Double, gpu: [String: Double]
                        if trial.isMultiple(of: 2) { cpuMS = cpuDraw(); gpu = try metal.draw(offset: offset) }
                        else { gpu = try metal.draw(offset: offset); cpuMS = cpuDraw() }
                        let actual = metal.pixels(), expected = cpu.data!.assumingMemoryBound(to: UInt8.self)
                        var maxDifference = 0
                        for i in actual.indices { maxDifference = max(maxDifference, abs(Int(actual[i]) - Int(expected[i]))) }
                        guard maxDifference <= 1 else { throw Failure.mismatch(maxDifference) }
                        samples.append(["trial": trial, "state": state, "offsetPixels": offset,
                            "uploadMS": uploadMS, "cpuCompositeMS": cpuMS, "metal": gpu,
                            "maxChannelDifference": maxDifference])
                    }
                }
            }
            results.append(["widthPoints": points, "scale": scale, "preparedTileMS": preparationMS,
                "referenceSnapshotMS": referenceSnapshotMS,
                "pipelineAndTargetMS": startupMS,
                "sourceSurfaceBytes": pages.reduce(0) { $0 + $1.bytes },
                "additionalTextureBytesLogical": width * (height + (source == "surface-shared" ? 0 : 1024 * scale)) * 4,
                "device": metal.device.name, "samples": samples])
        }
        let report: [String: Any] = ["scope": "Offscreen compositing of identical prepared tiles; no display/input evidence",
            "acceptance": "unmeasured", "textureSource": source, "fixture": store.fixtureSummary, "results": results]
        let path = config.value("--out", "/tmp/metal-tiles.json")
        guard !FileManager.default.fileExists(atPath: path) else { throw Failure.command("Output exists") }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
}
