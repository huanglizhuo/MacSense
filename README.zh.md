# MacSense

一款原生 SwiftUI macOS 应用，实时读取 Apple Silicon MacBook 内置 MEMS IMU（加速度计 + 陀螺仪）、环境光传感器和合盖角度传感器 —— 无需 root 权限、无需 Python 运行时、无第三方依赖。

> **硬件要求：** Apple Silicon MacBook（M1 / M2 / M3 / M4）

![演示截图](image/demo.png)

---

## 功能

- **加速度计 & 陀螺仪** — 三轴实时波形，约 100 Hz（从约 800 Hz 原始采样 8∶1 抽取）
- **姿态角** — 通过 Mahony AHRS 四元数融合计算横滚 / 俯仰 / 偏航
- **振动频谱** — 5 频带 IIR 能量跟踪（3 / 6 / 12 / 25 / 50 Hz）
- **事件检测** — 四种并行算法：STA/LTA、CUSUM、峰度、Peak/MAD
- **环境光** — 经校准的照度（lux）及 4 通道原始光电计数
- **合盖角度** — 铰链开合角度（°）
- **菜单栏** — 实时频谱 / 数值显示、紧凑弹出面板、可配置显示模式

---

## 环境要求

| | |
|---|---|
| 硬件 | Apple Silicon MacBook（M1 / M2 / M3 / M4） |
| macOS | 14.0 Sonoma 或更高版本 |
| Xcode | 15.0 或更高版本 |
| 沙盒 | 已禁用（IOKit HID 硬件访问必须关闭沙盒） |
| 权限 | 输入监控 — 系统设置 → 隐私与安全性 → 输入监控 |

---

## 下载

Apple Silicon 预编译 DMG 可在 [Releases 页面](https://github.com/huanglizhuo/MacSense/releases) 下载。

1. 从最新发布版本中下载 `MacSense-vX.Y.Z-arm64.dmg`
2. 打开 DMG，将 **apple-motion.app** 拖入「应用程序」文件夹
3. 首次启动时 macOS 可能提示无法验证开发者 —— 右键点击应用图标选择**打开**，再在弹窗中点击**打开**即可
4. 按提示在**系统设置 → 隐私与安全性 → 输入监控**中授予权限，然后重新启动应用

---

## 编译运行

```bash
xcodebuild -project apple-motion.xcodeproj -scheme apple-motion -destination "platform=macOS" build
```

或在 Xcode 中打开 `apple-motion.xcodeproj`，按 **⌘R** 运行。

首次启动时按提示授予**输入监控**权限，然后重新启动应用。

---

## TODO

- [ ] 降低 CPU 占用
- [ ] 支持为各检测器参数配置阈值，以减少噪声误报

---

## 致谢

基于 [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) —— 传感器访问方法和 HID 报告格式参考自该 Python 实现。
