import Foundation
import Accelerate

// MARK: - Event Model

struct EventRecord: Identifiable {
    let id        = UUID()
    let timestamp : Date
    let type      : EventType
    let magnitude : Float
    let sources   : [String]   // which detectors fired, e.g. ["STA/LTA","CUSUM"]

    enum EventType: String, CaseIterable {
        case chocMajeur = "CHOC-MAJEUR"   // 4+ detectors, >50 mg
        case chocMoyen  = "CHOC-MOYEN"    // 3+ detectors, >20 mg
        case microChoc  = "MICRO-CHOC"    // PEAK detector, >5 mg
        case vibration  = "VIBRATION"     // STA/LTA or CUSUM, >3 mg
        case vibLegere  = "VIB-LÉGÈRE"    // any detector, >1 mg
        case microVib   = "MICRO-VIB"     // catch-all

        var severity: Int {
            switch self {
            case .chocMajeur: return 5
            case .chocMoyen:  return 4
            case .microChoc:  return 3
            case .vibration:  return 2
            case .vibLegere:  return 1
            case .microVib:   return 0
            }
        }
    }
}

// MARK: - STA/LTA Detector (3 timescales, energy-based EMA, hysteresis)
//
// Matches Python: sta_n=[3,15,50], lta_n=[100,500,2000]
//                 thresh_on=[3.0,2.5,2.0], thresh_off=[1.5,1.3,1.2]
// Uses exponential moving average on energy (mag²), not amplitude.

struct STALTADetector {

    private struct Scale {
        let staN:      Float
        let ltaN:      Float
        let threshOn:  Float
        let threshOff: Float
        var sta:    Float = 1e-12
        var lta:    Float = 1e-12
        var active: Bool  = false
    }

    private var scales: [Scale] = [
        Scale(staN:  3, ltaN:  100, threshOn: 3.0, threshOff: 1.5),  // fast
        Scale(staN: 15, ltaN:  500, threshOn: 2.5, threshOff: 1.3),  // medium
        Scale(staN: 50, ltaN: 2000, threshOn: 2.0, threshOff: 1.2),  // slow
    ]

    /// Returns true if any timescale newly triggers (rising edge only).
    mutating func process(_ mag: Float) -> Bool {
        let e = mag * mag   // energy-based (matches Python)
        var triggered = false
        for i in scales.indices {
            // EMA update: sta/lta += (e - sta/lta) / N
            scales[i].sta += (e - scales[i].sta) / scales[i].staN
            scales[i].lta += (e - scales[i].lta) / scales[i].ltaN
            let ratio = scales[i].sta / (scales[i].lta + 1e-30)

            if !scales[i].active && ratio > scales[i].threshOn {
                scales[i].active = true
                triggered = true
            } else if scales[i].active && ratio < scales[i].threshOff {
                scales[i].active = false
            }
        }
        return triggered
    }
}

// MARK: - CUSUM Detector (bilateral, adaptive baseline)
//
// Matches Python: k=0.0005 (drift), h=0.01 (threshold), mu adapts via 0.0001 EMA.
// Bilateral: detects both positive and negative step changes.

struct CUSUMDetector {
    var drift:     Float = 0.0005   // Python: cusum_k
    var threshold: Float = 0.01    // Python: cusum_h

    private var mu:       Float = 0   // adaptive baseline (very slow EMA)
    private var cusumPos: Float = 0   // positive accumulator
    private var cusumNeg: Float = 0   // negative accumulator

    mutating func process(_ mag: Float) -> Bool {
        mu += 0.0001 * (mag - mu)   // extremely slow baseline tracking

        cusumPos = max(0, cusumPos + mag - mu - drift)
        cusumNeg = max(0, cusumNeg - mag + mu - drift)

        if max(cusumPos, cusumNeg) > threshold {
            cusumPos = 0
            cusumNeg = 0
            return true
        }
        return false
    }
}

// MARK: - Kurtosis Detector (impulsive / non-Gaussian events)
//
// Matches Python: window 100 samples (1 s @ 100 Hz), threshold kurtosis > 6.
// Normal Gaussian kurtosis = 3; impulsive events push it higher.

struct KurtosisDetector {
    let windowSize: Int   = 100
    let threshold:  Float = 6.0

    private var buf:     [Float] = [Float](repeating: 0, count: 100)  // pre-allocated ring
    private var head:    Int     = 0
    private var count:   Int     = 0
    private var ticker:  Int     = 0
    private var workBuf: [Float] = [Float](repeating: 0, count: 100)  // contiguous copy workspace

    mutating func process(_ mag: Float) -> Bool {
        buf[head] = mag
        head = (head + 1) % windowSize
        if count < windowSize { count += 1 }
        guard count == windowSize else { return false }

        // Evaluate every 10 samples to keep CPU cost low
        ticker += 1
        guard ticker % 10 == 0 else { return false }

        // Copy ring into contiguous workBuf without allocating
        let tail = windowSize - head
        workBuf.withUnsafeMutableBufferPointer { dst in
            buf.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + head, count: tail)
                (dst.baseAddress! + tail).update(from: src.baseAddress!, count: head)
            }
        }

        let n = Float(windowSize)
        var mean: Float = 0
        vDSP_meanv(&workBuf, 1, &mean, vDSP_Length(windowSize))
        var m2: Float = 0, m4: Float = 0
        for v in workBuf {
            let d  = v - mean
            let d2 = d * d
            m2 += d2
            m4 += d2 * d2
        }
        m2 /= n; m4 /= n
        guard m2 > 1e-20 else { return false }
        return (m4 / (m2 * m2)) > threshold
    }
}

// MARK: - Peak / MAD Detector (Median Absolute Deviation, 4 severity levels)
//
// Matches Python: window 200 samples (2 s @ 100 Hz), sigma = 1.4826 * MAD.
// Levels: ≥8σ MAJEUR, ≥5σ FORT, ≥3.5σ MOYEN, ≥2σ MICRO.

struct PeakMADDetector {
    let windowSize: Int = 200

    enum Level: String {
        case majeur = "MAJEUR"   // ≥ 8σ
        case fort   = "FORT"     // ≥ 5σ
        case moyen  = "MOYEN"    // ≥ 3.5σ
        case micro  = "MICRO"    // ≥ 2σ
    }

    private var buf     = [Float](repeating: 0, count: 200)  // pre-allocated ring
    private var head    = 0
    private var count   = 0
    private var workBuf = [Float](repeating: 0, count: 200)  // sort workspace, no per-call alloc

    mutating func process(_ mag: Float) -> Level? {
        buf[head] = mag
        head = (head + 1) % windowSize
        if count < windowSize { count += 1 }
        guard count >= 20 else { return nil }

        let n = count
        // Copy ring into contiguous workBuf without allocating
        if count < windowSize {
            workBuf.withUnsafeMutableBufferPointer { dst in
                buf.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress!, count: n)
                }
            }
        } else {
            let tail = windowSize - head
            workBuf.withUnsafeMutableBufferPointer { dst in
                buf.withUnsafeBufferPointer { src in
                    (dst.baseAddress!).update(from: src.baseAddress! + head, count: tail)
                    (dst.baseAddress! + tail).update(from: src.baseAddress!, count: head)
                }
            }
        }

        // Sort #1: get median (SIMD sort, in-place, no allocation)
        vDSP_vsort(&workBuf, vDSP_Length(n), 1)
        let median: Float = n % 2 == 1 ? workBuf[n/2] : (workBuf[n/2-1] + workBuf[n/2]) / 2

        // Compute deviations into workBuf in-place (reuse buffer, no new allocation)
        for i in 0..<n {
            workBuf[i] = abs(buf[(head - n + i + windowSize) % windowSize] - median)
        }
        // Sort #2: get MAD
        vDSP_vsort(&workBuf, vDSP_Length(n), 1)
        let mad: Float = n % 2 == 1 ? workBuf[n/2] : (workBuf[n/2-1] + workBuf[n/2]) / 2
        let sigma = 1.4826 * mad
        guard sigma > 1e-10 else { return nil }

        let absDeviation = abs(mag - median)
        // Below 1 mg absolute deviation the signal is indistinguishable from
        // quantization noise — skip regardless of how small sigma is.
        guard absDeviation > 0.001 else { return nil }

        let dev = absDeviation / sigma
        if      dev >= 8   { return .majeur }
        else if dev >= 5   { return .fort   }
        else if dev >= 3.5 { return .moyen  }
        else if dev >= 2   { return .micro  }
        return nil
    }
}
