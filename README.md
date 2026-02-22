# Apple Motion

A native SwiftUI macOS dashboard that reads the internal MEMS IMU (accelerometer + gyroscope), ambient light sensor, and lid-angle sensor of Apple Silicon MacBooks in real time — with no root access, no Python runtime, and no third-party libraries.

> **Hardware requirement:** Apple Silicon MacBook (M1 / M2 / M3 / M4).
> The `AppleSPUHIDDevice` is not present on Intel Macs or desktop Apple Silicon systems.

---

## Screenshot

```
┌──────────────────────────────────────────────────────────────┐
│ ● AppleSPUHIDDevice   Lid 118°   ☀ 320 lx                    │
├─────────────────────────┬────────────────────────────────────┤
│  Accelerometer (g)      │  Orientation                       │
│  ───────────────────    │  Roll  +12.3°  ████████░░░░       │
│  X ─────────────────    │  Pitch  -4.1°  ████░░░░░░░░       │
│  Y ─────────────────    │  Yaw   +87.6°  █████████░░░       │
│  Z ─────────────────    │                                    │
│                         │  [Artificial Horizon]              │
│  Gyroscope (°/s)        ├────────────────────────────────────┤
│  X ─────────────────    │  Vibration Spectrum                │
│  Y ─────────────────    │  ▄ ▂ █ ▃ ▁  3/6/12/25/50 Hz      │
│  Z ─────────────────    ├────────────────────────────────────┤
│                         │  Event Log                         │
│                         │  VIBRATION  12:34:05  0.0312 g    │
│                         │  MICRO-VIB  12:33:58  0.0041 g    │
└─────────────────────────┴────────────────────────────────────┘
```

---

## Sensor Data Reference

### 1. Accelerometer — `accel: SIMD3<Float>` (unit: **g**)

Measures the **specific force** acting on the device, which is the sum of all non-gravitational forces per unit mass plus the reaction to gravity.

| Axis | Physical direction | Typical value at rest |
|------|-------------------|-----------------------|
| X | Left ← Right across the keyboard | ≈ 0 g |
| Y | Front ↔ Back (hinge direction) | ≈ 0 g |
| Z | Down ↔ Up through the chassis | ≈ −1 g (gravity reaction) |

**Key points:**
- **At rest on a flat surface:** az ≈ −1 g (Apple Silicon SPU convention — gravity is reported on the −Z axis, opposite to many Android devices).
- **Tilt:** Tilting the MacBook changes the distribution of the ≈1 g gravitational component across X, Y, Z.
- **Vibration:** Rapid, small-amplitude fluctuations superimposed on the gravity baseline.
- **Raw sample rate:** ~800 Hz; **decimated to ~100 Hz** (8∶1) before processing.
- **Format:** 22-byte HID report, three `int32` little-endian values at byte offsets 6 / 10 / 14, divided by 65 536 (Q16 fixed-point).

---

### 2. Gyroscope — `gyro: SIMD3<Float>` (unit: **°/s**)

Measures **angular velocity** — how fast and in which direction the device is rotating.

| Axis | Rotation |
|------|----------|
| X | Pitch — screen tilting toward/away from you |
| Y | Roll  — device rolling left/right |
| Z | Yaw   — spinning flat on the table |

**Key points:**
- At rest, all three axes read ≈ 0 °/s (plus a small noise floor).
- Gyroscope drift accumulates over time; it is corrected by the Mahony AHRS using the accelerometer as a gravity reference.
- Same 22-byte HID report format and Q16 scaling as the accelerometer.
- Same 8∶1 decimation → ~100 Hz.

---

### 3. Orientation — Roll / Pitch / Yaw (unit: **°**)

Derived from the **Mahony AHRS** (Attitude and Heading Reference System) — a quaternion-based sensor-fusion algorithm that combines accelerometer and gyroscope data to produce stable, drift-corrected orientation angles.

```
              +Pitch (screen forward)
                    ↑
     +Roll ←────── MacBook ──────→ −Roll
     (left)                        (right)
                    ↓
              −Pitch (screen back)
```

| Angle | Range | Meaning |
|-------|-------|---------|
| **Roll** | −180° … +180° | Rotation around the front-back axis. 0° = level. +90° = right side down. |
| **Pitch** | −90° … +90° | Rotation around the left-right axis. 0° = level. +90° = screen facing up. |
| **Yaw** | −180° … +180° | Rotation around the vertical axis. Heading relative to power-on orientation (no magnetometer — drifts slowly). |

**Algorithm parameters (matching the Python reference):**
- Proportional gain `kp = 1.0` — controls how aggressively accel corrects the gyro.
- Integral gain `ki = 0.05` — eliminates steady-state gyro bias over time.
- Quaternion is **bootstrapped from the first accelerometer reading** to give correct roll/pitch instantly, without waiting ~10 s for convergence.
- The cross-product error uses `v × a` (not `a × v`) because the Apple Silicon SPU reports gravity on the −Z axis.

---

### 4. Vibration Spectrum — 5 frequency bands (unit: **% of full scale**)

Estimates the energy distribution of mechanical vibration across five frequency bands using first-order IIR envelope filters applied to the high-pass-filtered acceleration magnitude.

| Band | Center frequency | Typical sources |
|------|-----------------|-----------------|
| Band 1 | ~3 Hz | Body movement, slow mechanical oscillation, fan imbalance |
| Band 2 | ~6 Hz | Resonant modes of desk / floor, keyboard bounce |
| Band 3 | ~12 Hz | Motor vibration, HVAC ductwork |
| Band 4 | ~25 Hz | Hard-drive spin-up (older systems), compressors |
| Band 5 | ~50 Hz | Mains-frequency electrical vibration, high-speed motors |

**How it is computed:**
1. A **high-pass IIR filter** (α = 0.95, cutoff ≈ 0.16 Hz) removes the static gravity component, leaving only dynamic acceleration.
2. The **magnitude** of the filtered 3-axis vector is computed each sample.
3. Five **first-order envelope followers** with different time constants track the energy in each band.
4. Values are converted to a logarithmic scale (dB-like) and normalised to 0–100 %.

---

### 5. Ambient Light Sensor (ALS) — `alsLux` / `alsChannels`

The ALS reads the **ambient illumination** via a multi-spectral photodetector array built into the SPU (System Power Unit) subsystem.

| Field | Unit | Description |
|-------|------|-------------|
| `alsLux` | lux (lx) | Calibrated luminous intensity of the ambient light |
| `alsChannels[0]` | raw counts | Spectral channel 0 (typically visible-blue range) |
| `alsChannels[1]` | raw counts | Spectral channel 1 (typically visible-green range) |
| `alsChannels[2]` | raw counts | Spectral channel 2 (typically visible-red range) |
| `alsChannels[3]` | raw counts | Spectral channel 3 (typically near-infrared) |

**Key points:**
- 122-byte HID report; channels are `uint32` little-endian at byte offsets 20 / 24 / 28 / 32; lux is `float32` little-endian at offset 40.
- Usage page `0xFF00`, usage `4`.
- Used by macOS for automatic display brightness — reading it here does not interfere with that.

**Practical lux values:**

| Environment | Typical lux |
|-------------|-------------|
| Dark room | < 10 lx |
| Office lighting | 300–500 lx |
| Overcast daylight | 1 000–10 000 lx |
| Direct sunlight | > 50 000 lx |

---

### 6. Lid Angle — `lidAngle` (unit: **°**)

Reports the **opening angle** of the MacBook lid, as measured by a dedicated Hall-effect or mechanical sensor in the hinge.

| Value | State |
|-------|-------|
| 0° | Lid fully closed |
| ~115–120° | Typical typing position |
| ~180° | Lid fully open (flat) |
| Up to 511° | Maximum raw sensor range (9-bit) |

**Key points:**
- 3-byte HID report; byte 0 must equal `1` (report-ID validity check); the angle is a 9-bit `uint16` little-endian at bytes 1–2 (`raw & 0x1FF`).
- Usage page `0x0020` (HID Sensor Page), usage `138`.
- macOS uses this angle to manage keyboard backlight, display sleep, and clamshell mode.

---

## Vibration Event Detection

Events are classified by four independent algorithms running in parallel at ~100 Hz.

### Algorithm 1 — STA/LTA (Short-Term Average / Long-Term Average)

Detects **sudden energy increases** by comparing a fast-rolling average (STA) to a slow-rolling average (LTA). Three timescales run simultaneously:

| Timescale | STA window | LTA window | Trigger ratio | Release ratio |
|-----------|-----------|-----------|--------------|--------------|
| Fast | 3 samples (30 ms) | 100 samples (1 s) | > 3.0 | < 1.5 |
| Medium | 15 samples (150 ms) | 500 samples (5 s) | > 2.5 | < 1.3 |
| Slow | 50 samples (500 ms) | 2 000 samples (20 s) | > 2.0 | < 1.2 |

- Uses **energy** (magnitude²), not amplitude, for better sensitivity to broadband events.
- Hysteresis (separate on/off thresholds) prevents rapid re-triggering.

### Algorithm 2 — CUSUM (Cumulative Sum)

Detects **persistent level shifts** — gradual changes in vibration that grow over many samples.

- Maintains a very slow exponential baseline (`mu += 0.0001 × (mag − mu)`).
- Accumulates both positive (`cusumPos`) and negative (`cusumNeg`) deviations above the baseline.
- Triggers when either accumulator exceeds the decision threshold (`h = 0.01`), then resets.
- Bilateral design catches both increases and decreases in vibration level.

### Algorithm 3 — Kurtosis

Detects **impulsive, non-Gaussian events** such as sharp knocks or impacts.

- Maintains a 100-sample (1 s) sliding window.
- Computes the fourth standardised central moment: `K = E[(x−μ)⁴] / E[(x−μ)²]²`.
- Gaussian noise has K ≈ 3. Sharp impacts push K above the threshold of **6**.

### Algorithm 4 — Peak / MAD (Median Absolute Deviation)

Detects **statistical outliers** relative to the recent background level using a robust noise estimator.

- Maintains a 200-sample (2 s) window.
- Computes the median and MAD: `σ_robust = 1.4826 × median(|x − median|)`.
- Classifies each sample by its deviation from median in units of robust σ:

| Deviation | Label |
|-----------|-------|
| ≥ 2σ | MICRO |
| ≥ 3.5σ | MOYEN |
| ≥ 5σ | FORT |
| ≥ 8σ | MAJEUR |

---

## Event Severity Classification

Each sample frame aggregates the outputs of all four detectors. Events are classified by the number of detectors that fired simultaneously and the peak acceleration magnitude:

| Severity | Condition | Colour |
|----------|-----------|--------|
| **CHOC-MAJEUR** | ≥ 4 detectors fired AND magnitude > 50 mg | 🔴 Red |
| **CHOC-MOYEN** | ≥ 3 detectors fired AND magnitude > 20 mg | 🟠 Orange-red |
| **MICRO-CHOC** | Peak/MAD fired AND magnitude > 5 mg | 🟠 Orange |
| **VIBRATION** | STA/LTA or CUSUM fired AND magnitude > 3 mg | 🟡 Yellow |
| **VIB-LÉGÈRE** | Any detector fired AND magnitude > 1 mg | 🔵 Teal |
| **MICRO-VIB** | Any detector fired, magnitude ≤ 1 mg | ⚪ Gray |

The event log shows the timestamp, severity badge, peak magnitude, and the source detector labels (e.g., `STA/LTA · CUSUM`).

---

## Architecture

```
AppleSPUHIDDriver  (wakened at startup via IOServiceMatching)
        │
        ▼
AppleSPUHIDDevice  (4 HID devices matched)
  ├── usage 3  → Accelerometer (22 B, ~800 Hz, 8∶1 → 100 Hz)
  ├── usage 9  → Gyroscope     (22 B, ~800 Hz, 8∶1 → 100 Hz)
  ├── usage 4  → ALS           (122 B, snapshot)
  └── usage 138 (page 0x0020) → Lid angle (3 B, snapshot)
        │
        ▼
SensorManager  (IOHIDManager, main RunLoop, callbacks on main thread)
        │
        ▼
SignalProcessor  (per-sample, synchronous)
  ├── HighPassFilter    α=0.95 → removes gravity baseline
  ├── MahonyAHRS        kp=1.0, ki=0.05, quaternion bootstrap
  ├── IIR Spectrum      5 envelope followers → frequency band energy
  └── Detectors (×4)
        ├── STALTADetector   3 timescales, EMA on mag², hysteresis
        ├── CUSUMDetector    bilateral, adaptive baseline
        ├── KurtosisDetector 100-sample window, threshold K > 6
        └── PeakMADDetector  200-sample window, 1.4826 × MAD → σ
        │
        ▼
SwiftUI Views  (@Published, main thread)
  ├── WaveformView     Canvas sparklines, 60 fps via TimelineView
  ├── OrientationView  Roll/Pitch/Yaw gauges + artificial horizon
  ├── SpectralView     Swift Charts 5-band bar chart
  └── EventLogView     Severity-coloured event log with source labels
```

---

## Requirements & Setup

| Requirement | Details |
|-------------|---------|
| Hardware | Apple Silicon MacBook (M1 / M2 / M3 / M4) |
| macOS | 14.0 Sonoma or later |
| Xcode | 15.0 or later (Swift 5.9+) |
| Sandbox | **Disabled** — required for IOKit HID hardware access |
| Permission | **Input Monitoring** (System Settings → Privacy & Security → Input Monitoring) |

### Build

```bash
xcodebuild -project apple-motion.xcodeproj \
           -scheme apple-motion \
           -destination "platform=macOS" \
           build
```

Or open `apple-motion.xcodeproj` in Xcode and press **⌘R**.

### Permission

On first launch, if Input Monitoring has not been granted:

1. The app shows an alert.
2. Click **Open System Settings**.
3. Navigate to **Privacy & Security → Input Monitoring**.
4. Enable **apple-motion**.
5. Relaunch the app.

---

## Caveats

| Limitation | Detail |
|------------|--------|
| **Undocumented API** | `AppleSPUHIDDevice` is a private Apple interface. Report formats or device usages may change in future macOS releases. |
| **No magnetometer** | Yaw angle drifts slowly over time because there is no compass for absolute heading correction. |
| **No App Store** | Disabling the sandbox prevents Mac App Store distribution. |
| **ALS / Lid availability** | ALS and lid-angle sensors may not be present or may report 0 on all MacBook models. |
| **Intel Macs** | Not supported — the SPU subsystem is exclusive to Apple Silicon. |

---

## Credits

Sensor access method and HID report format derived from
[olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) (Python reference implementation).
