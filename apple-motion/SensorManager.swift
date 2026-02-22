import IOKit.hid
import Combine
import Foundation

// MARK: - Data Types

struct SensorSample {
    let timestamp: Double
    let accel: SIMD3<Float>
    let gyro:  SIMD3<Float>
}

// MARK: - Display Snapshot
//
// All display-rate properties (~10 Hz) are bundled here so a single
// @Published assignment triggers exactly one objectWillChange emission
// per display tick instead of one per property.

struct SensorSnapshot {
    var accelHistory:  [SIMD3<Float>] = []
    var gyroHistory:   [SIMD3<Float>] = []
    var orientation:   (roll: Float, pitch: Float, yaw: Float) = (0, 0, 0)
    var spectrumBands: [Float]  = Array(repeating: 0, count: 5)
    var alsLux:        Float    = 0
    var alsChannels:   [UInt32] = [0, 0, 0, 0]
    var lidAngle:      Float    = 0
}

// MARK: - Manager

final class SensorManager: ObservableObject {

    // Status — change rarely and independently; kept as separate @Published.
    // permissionDenied is publicly settable so the view can dismiss the alert.
    @Published private(set) var isConnected  = false
    @Published var permissionDenied          = false
    @Published private(set) var deviceName: String = "Not connected"

    // Display snapshot — one atomic update per display tick (~10 Hz)
    @Published private(set) var snapshot = SensorSnapshot()

    // Events — rare; dispatched individually on event detection
    @Published private(set) var events: [EventRecord] = []

    let samplePublisher = PassthroughSubject<SensorSample, Never>()

    private static let historyCapacity   = 500
    private static let imuDecimation     = 8
    private static let displayDecimation = 10

    private var hidManager: IOHIDManager?

    // ── State touched ONLY from the background HID thread ────────────────────
    private var lastAccel:  SIMD3<Float> = .zero
    private var lastGyro:   SIMD3<Float> = .zero
    private var lastTime:   Double = 0
    private var accelDec:   Int = 0
    private var gyroDec:    Int = 0
    private var displayDec: Int = 0
    private var accelBuf:   [SIMD3<Float>] = [SIMD3<Float>](repeating: .zero, count: 500)
    private var accelHead:  Int = 0
    private var accelCount: Int = 0
    private var gyroBuf:    [SIMD3<Float>] = [SIMD3<Float>](repeating: .zero, count: 500)
    private var gyroHead:   Int = 0
    private var gyroCount:  Int = 0
    private var signalProc = SignalProcessor()

    // Latest ALS / lid values written by their HID callbacks and flushed to main
    // in the batched display update — eliminates 2 extra DispatchQueue.main.async
    // calls (and 2 extra SwiftUI render passes) per display cycle.
    private var latestAlsLux:      Float    = 0
    private var latestAlsChannels: [UInt32] = [0, 0, 0, 0]
    private var latestLidAngle:    Float    = 0

    // Cache (usagePage, usage) per device so reportArrived never calls
    // IOHIDDeviceGetProperty on the hot path (2000+ calls/sec otherwise).
    private var deviceTypes: [(device: IOHIDDevice, page: Int, usage: Int)] = []

    // MARK: - Debug diagnostics (all touched on HID background thread only)

    private struct DebugStats {
        var windowStart:    Double = 0
        var accelRaw:       Int    = 0   // raw HID callbacks before imuDecimation
        var gyroRaw:        Int    = 0
        var alsRaw:         Int    = 0
        var lidRaw:         Int    = 0
        var processed:      Int    = 0   // processSample() calls (~125 Hz expected)
        var displayed:      Int    = 0   // display @Published dispatches (~12.5 Hz expected)
        var eventsFired:    Int    = 0   // detectEvent() returning non-nil (expected: rare)
        var mainDispatches: Int    = 0   // total DispatchQueue.main.async calls
        var procTimeTotal:  Double = 0   // cumulative processSample wall time
        var procTimeMax:    Double = 0   // worst-case processSample
    }
    private var dbg = DebugStats()

    // MARK: - Start / Stop

    func start() {
        guard hidManager == nil else { return }
        wakeupSPUDrivers()
        setupHIDManager()
    }

    func stop() {
        guard let mgr = hidManager else { return }
        hidManager = nil
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        DispatchQueue.main.async { self.isConnected = false }
    }

    func clearEvents() { events.removeAll() }

    // MARK: - Stage 1: Wake AppleSPUHIDDriver

    private func wakeupSPUDrivers() {
        let matching: CFMutableDictionary = IOServiceMatching("AppleSPUHIDDriver")
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let svc = IOIteratorNext(iterator)
            guard svc != IO_OBJECT_NULL else { break }
            IORegistryEntrySetCFProperty(svc, "SensorPropertyReportingState" as CFString, NSNumber(value: 1))
            IORegistryEntrySetCFProperty(svc, "SensorPropertyPowerState"     as CFString, NSNumber(value: 1))
            IORegistryEntrySetCFProperty(svc, "ReportInterval"               as CFString, NSNumber(value: 1000))
            IOObjectRelease(svc)
        }
    }

    // MARK: - Stage 2: HID Manager

    private func setupHIDManager() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matches: [[String: Any]] = [
            [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3],
            [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 9],
            [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 4],
            [kIOHIDPrimaryUsagePageKey: 0x0020, kIOHIDPrimaryUsageKey: 138],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, sensorDeviceAdded,   ctx)
        IOHIDManagerRegisterDeviceRemovalCallback( mgr, sensorDeviceRemoved, ctx)
        IOHIDManagerRegisterInputReportCallback(   mgr, sensorReportArrived, ctx)

        // Store before the thread starts so deviceRemoved() can read hidManager safely.
        hidManager = mgr

        // Run the HID manager on a dedicated background thread instead of the
        // main RunLoop. At ~1 kHz per sensor, 2000+ callbacks/sec on the main
        // thread would peg one CPU core entirely. The background thread keeps all
        // that work off the UI thread; @Published updates are dispatched to main.
        // userInitiated QoS prevents the OS from preempting this thread when the
        // main thread is busy rendering — eliminates scheduling jitter in processSample.
        let hidThread = Thread { [weak self] in
            guard let self else { return }
            IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            let ret = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            guard ret != kIOReturnNotPermitted, ret != kIOReturnExclusiveAccess else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            CFRunLoopRun()
        }
        hidThread.qualityOfService = .userInitiated
        hidThread.start()
    }

    // MARK: - Callbacks (invoked on background HID thread)

    fileprivate func deviceAdded(_ device: IOHIDDevice) {
        // Cache type once per device — eliminates the per-report IOHIDDeviceGetProperty calls
        let page  = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey     as CFString) as? Int) ?? 0
        if !deviceTypes.contains(where: { $0.device === device }) {
            deviceTypes.append((device: device, page: page, usage: usage))
        }
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "AppleSPUHIDDevice"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.deviceName  = name
        }
    }

    fileprivate func deviceRemoved() {
        if let mgr = hidManager {
            let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>
            let connected = !(devs?.isEmpty ?? true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isConnected = connected
                if !connected { self.deviceName = "Not connected" }
            }
        }
    }

    fileprivate func reportArrived(sender: UnsafeMutableRawPointer?,
                                   report: UnsafeMutablePointer<UInt8>,
                                   length: CFIndex) {
        // O(n), n ≤ 4 — far cheaper than two IOHIDDeviceGetProperty calls per report
        var usagePage = 0, usage = 0
        if let ptr = sender {
            let dev = Unmanaged<IOHIDDevice>.fromOpaque(ptr).takeUnretainedValue()
            if let entry = deviceTypes.first(where: { $0.device === dev }) {
                usagePage = entry.page
                usage     = entry.usage
            }
        }

        if usagePage == 0xFF00 {
            switch usage {

            case 3:  // Accelerometer
                dbg.accelRaw += 1
                accelDec += 1
                guard accelDec >= Self.imuDecimation else { return }
                accelDec = 0
                if let v = parseQ16(report, length: length) { lastAccel = v }

            case 9:  // Gyroscope — paired sample trigger
                dbg.gyroRaw += 1
                gyroDec += 1
                guard gyroDec >= Self.imuDecimation else { return }
                gyroDec = 0
                guard let v = parseQ16(report, length: length) else { return }
                lastGyro = v
                let now = Date().timeIntervalSinceReferenceDate
                let dt  = lastTime > 0 ? Float(now - lastTime) : 0.01
                lastTime = now
                let sample = SensorSample(timestamp: now, accel: lastAccel, gyro: lastGyro)
                let t0 = now
                processSample(sample, dt: dt)
                let procTime = Date().timeIntervalSinceReferenceDate - t0
                dbg.procTimeTotal += procTime
                dbg.procTimeMax    = max(dbg.procTimeMax, procTime)
                samplePublisher.send(sample)   // PassthroughSubject.send is thread-safe
                debugTick(now: now)

            case 4:  // ALS
                dbg.alsRaw += 1
                parseALS(report, length: length)

            default: break
            }

        } else if usagePage == 0x0020 && usage == 138 {
            dbg.lidRaw += 1
            parseLid(report, length: length)
        }
    }

    // MARK: - Signal pipeline (background thread)

    private func processSample(_ s: SensorSample, dt: Float) {
        dbg.processed += 1
        signalProc.ingest(accel: s.accel, gyro: s.gyro, dt: dt)

        accelBuf[accelHead] = s.accel
        accelHead = (accelHead + 1) % Self.historyCapacity
        if accelCount < Self.historyCapacity { accelCount += 1 }
        gyroBuf[gyroHead] = s.gyro
        gyroHead = (gyroHead + 1) % Self.historyCapacity
        if gyroCount < Self.historyCapacity { gyroCount += 1 }

        // Events are rare — dispatch individually to main
        if let ev = signalProc.detectEvent() {
            dbg.eventsFired    += 1
            dbg.mainDispatches += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.events.insert(ev, at: 0)
                if self.events.count > 200 { self.events.removeLast(self.events.count - 200) }
            }
        }

        // Throttle display updates to ~10 Hz to keep SwiftUI renders cheap
        displayDec += 1
        guard displayDec >= Self.displayDecimation else { return }
        displayDec = 0

        let snap = SensorSnapshot(
            accelHistory:  ringSnapshot(accelBuf, head: accelHead, count: accelCount),
            gyroHistory:   ringSnapshot(gyroBuf,  head: gyroHead,  count: gyroCount),
            orientation:   signalProc.orientation,
            spectrumBands: signalProc.spectrumBands,
            alsLux:        latestAlsLux,
            alsChannels:   latestAlsChannels,
            lidAngle:      latestLidAngle)

        dbg.displayed      += 1
        dbg.mainDispatches += 1
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = snap
        }
    }

    // Print a 5-second rolling diagnostic to stderr. Called from the gyro path (1000 Hz raw).
    private func debugTick(now: Double) {
        if dbg.windowStart == 0 { dbg.windowStart = now; return }
        let elapsed = now - dbg.windowStart
        guard elapsed >= 5.0 else { return }

        let hz = { (n: Int) in String(format: "%6.0f Hz", Double(n) / elapsed) }
        let us = { (t: Double) in String(format: "%.1f µs", t * 1e6) }
        print("""
        ── apple-motion CPU debug (\(String(format: "%.1f", elapsed))s) ──
          accel raw:       \(hz(dbg.accelRaw))   (expect ~1000)
          gyro  raw:       \(hz(dbg.gyroRaw))   (expect ~1000)
          ALS   raw:       \(hz(dbg.alsRaw))   (expect unknown)
          lid   raw:       \(hz(dbg.lidRaw))   (expect unknown)
          processSample:   \(hz(dbg.processed))   (expect ~125)
          eventsFired:     \(hz(dbg.eventsFired))   (expect: rare — if high, this IS the CPU hog)
          displayUpdate:   \(hz(dbg.displayed))   (expect ~12.5)
          main dispatches: \(hz(dbg.mainDispatches))   (expect ~10 display + events)
          processSample avg: \(us(dbg.procTimeTotal / Double(max(1, dbg.processed))))
          processSample max: \(us(dbg.procTimeMax))
        """)
        dbg = DebugStats()
        dbg.windowStart = now
    }

    // Linearise a ring buffer into a chronologically ordered array (called at 12.5 Hz only).
    private func ringSnapshot(_ buf: [SIMD3<Float>], head: Int, count: Int) -> [SIMD3<Float>] {
        let cap = buf.count
        if count < cap { return Array(buf[0..<count]) }
        return Array(buf[head...] + buf[..<head])
    }

    // MARK: - Report parsers (background thread)

    private func parseQ16(_ buf: UnsafeMutablePointer<UInt8>, length: CFIndex) -> SIMD3<Float>? {
        guard length >= 18 else { return nil }
        let x = readLE32(buf, offset: 6)
        let y = readLE32(buf, offset: 10)
        let z = readLE32(buf, offset: 14)
        return SIMD3<Float>(Float(x), Float(y), Float(z)) / 65536.0
    }

    private func parseALS(_ buf: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 44 else { return }
        latestAlsChannels = [
            readLEU32(buf, offset: 20),
            readLEU32(buf, offset: 24),
            readLEU32(buf, offset: 28),
            readLEU32(buf, offset: 32),
        ]
        latestAlsLux = readLEF32(buf, offset: 40)
        // Flushed to main in the next display update batch (every ~100 ms).
    }

    private func parseLid(_ buf: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 3, buf[0] == 1 else { return }
        let raw = UInt16(buf[1]) | (UInt16(buf[2]) << 8)
        latestLidAngle = Float(raw & 0x1FF)
        // Flushed to main in the next display update batch (every ~100 ms).
    }

    // MARK: - Byte helpers

    private func readLE32(_ buf: UnsafeMutablePointer<UInt8>, offset: Int) -> Int32 {
        Int32(bitPattern:
            UInt32(buf[offset])           |
            UInt32(buf[offset + 1]) << 8  |
            UInt32(buf[offset + 2]) << 16 |
            UInt32(buf[offset + 3]) << 24)
    }

    private func readLEU32(_ buf: UnsafeMutablePointer<UInt8>, offset: Int) -> UInt32 {
        UInt32(buf[offset])           |
        UInt32(buf[offset + 1]) << 8  |
        UInt32(buf[offset + 2]) << 16 |
        UInt32(buf[offset + 3]) << 24
    }

    private func readLEF32(_ buf: UnsafeMutablePointer<UInt8>, offset: Int) -> Float {
        Float(bitPattern: readLEU32(buf, offset: offset))
    }
}

// MARK: - File-scope C callbacks (no captures allowed)

private func sensorDeviceAdded(
    context: UnsafeMutableRawPointer?, result: IOReturn,
    sender: UnsafeMutableRawPointer?, device: IOHIDDevice
) {
    guard let ctx = context else { return }
    Unmanaged<SensorManager>.fromOpaque(ctx).takeUnretainedValue().deviceAdded(device)
}

private func sensorDeviceRemoved(
    context: UnsafeMutableRawPointer?, result: IOReturn,
    sender: UnsafeMutableRawPointer?, device: IOHIDDevice
) {
    guard let ctx = context else { return }
    Unmanaged<SensorManager>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved()
}

private func sensorReportArrived(
    context: UnsafeMutableRawPointer?, result: IOReturn,
    sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
    reportID: UInt32, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex
) {
    guard let ctx = context else { return }
    Unmanaged<SensorManager>.fromOpaque(ctx).takeUnretainedValue()
        .reportArrived(sender: sender, report: report, length: reportLength)
}
