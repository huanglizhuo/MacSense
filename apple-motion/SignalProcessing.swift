import Foundation
import Accelerate

// MARK: - High-pass filter (single-pole IIR, gravity removal)

struct HighPassFilter {
    var alpha: Float = 0.95   // matches Python hp_alpha = 0.95
    private var prevInput:  SIMD3<Float> = .zero
    private var prevOutput: SIMD3<Float> = .zero

    mutating func process(_ input: SIMD3<Float>) -> SIMD3<Float> {
        let output = alpha * (prevOutput + input - prevInput)
        prevInput  = input
        prevOutput = output
        return output
    }
    mutating func reset() { prevInput = .zero; prevOutput = .zero }
}

// MARK: - Ring buffer (Float, single-axis)

struct RingBuffer {
    private var buf: [Float]
    private var head = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        buf = Array(repeating: 0, count: capacity)
    }

    mutating func append(_ v: Float) {
        buf[head] = v
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    func asArray() -> [Float] {
        guard count > 0 else { return [] }
        if count < capacity { return Array(buf[0..<count]) }
        return Array(buf[head...] + buf[..<head])
    }

    func rms() -> Float {
        guard count > 0 else { return 0 }
        var sq: Float = 0
        vDSP_svesq(buf, 1, &sq, vDSP_Length(count))
        return sqrt(sq / Float(count))
    }
}

// MARK: - Mahony AHRS (quaternion attitude filter)
//
// Parameters match Python reference: kp=1.0, ki=0.05
// Adds quaternion bootstrap from first accelerometer reading to avoid
// the ~10-second convergence delay from the identity initial quaternion.

struct MahonyAHRS {
    var kp: Float = 1.0    // proportional gain (Python: mahony_kp = 1.0)
    var ki: Float = 0.05   // integral gain     (Python: mahony_ki = 0.05)

    // Quaternion (w, x, y, z) — identity = device flat on table
    private var qw: Float = 1, qx: Float = 0, qy: Float = 0, qz: Float = 0
    private var iFBx: Float = 0, iFBy: Float = 0, iFBz: Float = 0
    private var bootstrapped = false

    mutating func update(accel a: SIMD3<Float>, gyro g: SIMD3<Float>, dt: Float) {
        // Align quaternion to gravity on first valid sample (matches Python bootstrap)
        if !bootstrapped {
            bootstrapFromGravity(a)
            bootstrapped = true
        }

        var gxr = g.x * (.pi / 180)
        var gyr = g.y * (.pi / 180)
        var gzr = g.z * (.pi / 180)

        let norm = (a.x*a.x + a.y*a.y + a.z*a.z).squareRoot()
        guard norm > 0.001 else { return }
        let ax = a.x/norm, ay = a.y/norm, az = a.z/norm

        // Estimated gravity direction in body frame (from quaternion)
        let vx =  2*(qx*qz - qw*qy)
        let vy =  2*(qw*qx + qy*qz)
        let vz =  qw*qw - qx*qx - qy*qy + qz*qz

        // Cross-product error: a × (−v)  ≡  v × a
        // Apple Silicon accel reads −1 g on Z when flat (anti-gravity convention),
        // so the estimated gravity vector must be negated before the cross product —
        // exactly matching Python: ex = ay_n*(-vz) − az_n*(-vy)
        let ex = az*vy - ay*vz
        let ey = ax*vz - az*vx
        let ez = ay*vx - ax*vy

        // PI correction
        iFBx += ki * ex * dt
        iFBy += ki * ey * dt
        iFBz += ki * ez * dt
        gxr  += kp*ex + iFBx
        gyr  += kp*ey + iFBy
        gzr  += kp*ez + iFBz

        // Quaternion integration
        let dw = (-qx*gxr - qy*gyr - qz*gzr) * 0.5 * dt
        let dx = ( qw*gxr + qy*gzr - qz*gyr) * 0.5 * dt
        let dy = ( qw*gyr - qx*gzr + qz*gxr) * 0.5 * dt
        let dz = ( qw*gzr + qx*gyr - qy*gxr) * 0.5 * dt
        qw += dw; qx += dx; qy += dy; qz += dz

        let qn = (qw*qw + qx*qx + qy*qy + qz*qz).squareRoot()
        qw /= qn; qx /= qn; qy /= qn; qz /= qn
    }

    /// Initialise quaternion from static gravity reading so orientation is
    /// correct immediately (Python: pitch0 = atan2(-ax_n, -az_n), roll0 = atan2(ay_n, -az_n))
    private mutating func bootstrapFromGravity(_ a: SIMD3<Float>) {
        let norm = (a.x*a.x + a.y*a.y + a.z*a.z).squareRoot()
        guard norm > 0.001 else { return }
        let ax = a.x/norm, ay = a.y/norm, az = a.z/norm

        let pitch = atan2(-ax, -az)
        let roll  = atan2( ay, -az)
        let hp = pitch * 0.5, hr = roll * 0.5

        qw =  cos(hr)*cos(hp)
        qx =  sin(hr)*cos(hp)
        qy =  cos(hr)*sin(hp)
        qz = -sin(hr)*sin(hp)

        let qn = (qw*qw + qx*qx + qy*qy + qz*qz).squareRoot()
        qw /= qn; qx /= qn; qy /= qn; qz /= qn
    }

    var roll:  Float { atan2(2*(qw*qx + qy*qz), 1 - 2*(qx*qx + qy*qy)) * 180 / .pi }
    var pitch: Float { asin (max(-1, min(1, 2*(qw*qy - qz*qx))))         * 180 / .pi }
    var yaw:   Float { atan2(2*(qw*qz + qx*qy), 1 - 2*(qy*qy + qz*qz)) * 180 / .pi }
}

// MARK: - Signal Processor

struct SignalProcessor {

    private var hpf  = HighPassFilter()
    private var ahrs = MahonyAHRS()

    // 5-band IIR envelope (fc ≈ 3/6/12/25/50 Hz)
    private var bandEnergies: [Float] = Array(repeating: 0, count: 5)
    private var bandPrev:     [Float] = Array(repeating: 0, count: 5)

    // Pre-computed IIR alphas for nominal dt = 8 ms. Eliminates 5 exp() calls per sample.
    // Error < 1% even if dt drifts ±1 ms.
    private let spectrumAlphas: [Float] = [
        exp(-2 * Float.pi *  3 * 0.008),
        exp(-2 * Float.pi *  6 * 0.008),
        exp(-2 * Float.pi * 12 * 0.008),
        exp(-2 * Float.pi * 25 * 0.008),
        exp(-2 * Float.pi * 50 * 0.008),
    ]

    // All four detectors
    private var stalta   = STALTADetector()
    private var cusum    = CUSUMDetector()
    private var kurtosis = KurtosisDetector()
    private var peakMad  = PeakMADDetector()

    private(set) var orientation: (roll: Float, pitch: Float, yaw: Float) = (0, 0, 0)
    private(set) var spectrumBands: [Float] = Array(repeating: 0, count: 5)
    // HPF-filtered vibration magnitude from the most recent ingest() call.
    // Near 0 on a stationary Mac; used by detectEvent() so detectors see the
    // vibration signal, not the raw ~1 g gravity-biased magnitude.
    private var filteredMag: Float = 0

    mutating func ingest(accel: SIMD3<Float>, gyro: SIMD3<Float>, dt: Float) {
        ahrs.update(accel: accel, gyro: gyro, dt: dt)
        orientation = (ahrs.roll, ahrs.pitch, ahrs.yaw)

        let filtered = hpf.process(accel)
        filteredMag = (filtered.x*filtered.x + filtered.y*filtered.y + filtered.z*filtered.z).squareRoot()
        updateSpectrum(mag: filteredMag, dt: dt)
    }

    private mutating func updateSpectrum(mag: Float, dt: Float) {
        for i in 0..<5 {
            let a = spectrumAlphas[i]
            let env = (1 - a) * mag + a * bandPrev[i]
            bandPrev[i]      = env
            bandEnergies[i]  = 0.9 * bandEnergies[i] + 0.1 * env
            let db = 20 * log10(max(bandEnergies[i], 1e-6)) + 60
            spectrumBands[i] = max(0, min(1, db / 60))
        }
    }

    mutating func detectEvent() -> EventRecord? {
        // Use HPF-filtered magnitude (set by ingest). This is ~0 on a stationary Mac,
        // which is what all detector thresholds were calibrated for. Using raw accel
        // magnitude (~1 g) caused CUSUM to fire on every sample for ~13 minutes.
        let mag = filteredMag

        // Run all detectors — must call every sample to maintain internal state
        let staltaFired   = stalta.process(mag)
        let cusumFired    = cusum.process(mag)
        let kurtosisFired = kurtosis.process(mag)
        let peakLevel     = peakMad.process(mag)

        // Gate: filteredMag is a norm so it is always ≥ 0, meaning CUSUM sees a
        // half-normal (non-zero-mean) distribution and fires on noise bursts a few
        // times per second. Anything below 2 mg is indistinguishable from sensor
        // noise on a stationary Mac — discard without dispatching.
        guard mag > 0.002 else { return nil }

        // Common case: no event — bail before allocating the sources array
        guard staltaFired || cusumFired || kurtosisFired || peakLevel != nil else { return nil }

        // Rare path: build source labels only when an event actually fired
        var sources: [String] = []
        if staltaFired            { sources.append("STA/LTA") }
        if cusumFired             { sources.append("CUSUM")   }
        if kurtosisFired          { sources.append("KURT")    }
        if let lvl = peakLevel    { sources.append("PEAK-\(lvl.rawValue)") }

        // Multi-source severity classification (mirrors Python motion_live.py)
        let ns = sources.count
        let type: EventRecord.EventType
        if      ns >= 4 && mag > 0.05  { type = .chocMajeur }
        else if ns >= 3 && mag > 0.02  { type = .chocMoyen  }
        else if sources.contains(where: { $0.hasPrefix("PEAK") }) && mag > 0.005 { type = .microChoc }
        else if (sources.contains("STA/LTA") || sources.contains("CUSUM")) && mag > 0.003 { type = .vibration }
        else if mag > 0.001            { type = .vibLegere  }
        else                           { type = .microVib   }

        return EventRecord(timestamp: Date(), type: type, magnitude: mag, sources: sources)
    }
}
