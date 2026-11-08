import Foundation
import Darwin
import MachO

/// The main thread's call stack, read from another thread while the main one is stuck: what a
/// hang report needs and MetricKit only delivers a day later. Costs nothing until it is asked:
/// it remembers the main thread's port once, and reads the stack only when a hang is caught.
///
/// The main thread is suspended for the read and nothing is allocated while it is (it may hold
/// the allocator's lock): the frame-pointer chain is walked into a buffer made beforehand, each
/// read through `vm_read_overwrite`, which fails instead of crashing on a bad pointer. Names and
/// image offsets are looked up after it runs again.
enum MainThreadSampler {
    nonisolated(unsafe) private static var mainThread: thread_act_t = 0

    /// Call once, on the main thread.
    static func remember() {
        guard pthread_main_np() != 0, mainThread == 0 else { return }
        mainThread = mach_thread_self()
    }

    /// Return addresses of the main thread, innermost first; empty when it couldn't be read.
    static func addresses(most: Int = 64) -> [UInt] {
        let thread = mainThread
        guard thread != 0, pthread_main_np() == 0 else { return [] }
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: most)
        defer { buffer.deallocate() }
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        let count = walk(thread, into: buffer, most: most)
        thread_resume(thread)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    /// The stack as text: one line per frame with its image, offset and the image's UUID, which is
    /// what `atos` needs against that build's dSYM.
    static func sample(most: Int = 64) -> String? {
        let frames = addresses(most: most)
        guard !frames.isEmpty else { return nil }
        var lines: [String] = []
        var images: [String: String] = [:]
        for (index, address) in frames.enumerated() {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase else {
                lines.append("\(index)\t???\t0x\(String(address, radix: 16))")
                continue
            }
            let path = info.dli_fname.map { String(cString: $0) } ?? "?"
            let name = (path as NSString).lastPathComponent
            let offset = address &- UInt(bitPattern: base)
            let symbol = info.dli_sname.map { String(cString: $0) }.map { " " + $0 } ?? ""
            lines.append("\(index)\t\(name)\t0x\(String(address, radix: 16)) + 0x\(String(offset, radix: 16))\(symbol)")
            if images[name] == nil { images[name] = "\(name)\t\(uuid(of: base) ?? "?")\t0x\(String(UInt(bitPattern: base), radix: 16))" }
        }
        return (lines + ["", "Binary images:"] + images.values.sorted()).joined(separator: "\n")
    }

    /// The first frame that isn't the system's: what a hang groups by.
    static func signature(of sample: String) -> String? {
        let system = ["libsystem", "libdispatch", "libobjc", "libswift", "CoreFoundation", "UIKitCore", "AppKit",
                      "SwiftUI", "SwiftUICore", "Foundation", "QuartzCore", "GraphicsServices", "dyld", "???"]
        for line in sample.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            let image = String(parts[1])
            if system.contains(where: image.hasPrefix) { continue }
            return "\(image) \(parts[2].split(separator: "+").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")"
        }
        return nil
    }

    private static func walk(_ thread: thread_act_t, into buffer: UnsafeMutablePointer<UInt>, most: Int) -> Int {
        var pc: UInt = 0, fp: UInt = 0, lr: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__pc); fp = UInt(state.__fp); lr = UInt(state.__lr)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__rip); fp = UInt(state.__rbp)
        #else
        return 0
        #endif
        // Pointer authentication bits, if any, are not part of the address.
        let mask: UInt = 0x0000_000F_FFFF_FFFF
        var n = 0
        buffer[n] = pc & mask; n += 1
        if lr != 0, n < most { buffer[n] = lr & mask; n += 1 }
        var frame = (previous: UInt(0), returnAddress: UInt(0))
        while fp != 0, n < most {
            var read: vm_size_t = 0
            let size = vm_size_t(MemoryLayout.size(ofValue: frame))
            let ok = withUnsafeMutablePointer(to: &frame) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), size, vm_address_t(UInt(bitPattern: $0)), &read)
            }
            guard ok == KERN_SUCCESS, read == size, frame.returnAddress != 0 else { break }
            buffer[n] = frame.returnAddress & mask; n += 1
            // The chain only goes up the stack; anything else is a broken frame.
            guard frame.previous > fp else { break }
            fp = frame.previous
        }
        return n
    }

    private static func uuid(of base: UnsafeMutableRawPointer) -> String? {
        let header = base.assumingMemoryBound(to: mach_header_64.self)
        guard header.pointee.magic == UInt32(MH_MAGIC_64) else { return nil }
        var command = UnsafeRawPointer(base).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                let uuid = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}
