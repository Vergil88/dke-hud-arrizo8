# DKE HUD — 奇瑞艾瑞泽8 2.0T 适配版

基于 [PenguinDukeYDAuto/eva_hud_app](https://github.com/PenguinDukeYDAuto/eva_hud_app) 二次开发。

原始项目为 Mercedes-AMG C63s (W205) 专用 UDS HUD，本项目将其适配至奇瑞艾瑞泽8 2.0T，并扩展了通用 OBD-II 车辆支持。

## 核心改动

### 1. OBD-II Mode 01 直连模式

原始项目仅支持 UDS (ISO 14229) 协议，依赖 OBDLink MX+/CX 的 STPX 高速指令。适配后新增 `CommMode.obd2`:

- 直接通过标准 ELM327 适配器 (vLinker MS / 蓝牙 SPP) 发送 SAE J1979 Mode 01 PID 请求
- AT 初始化序列: `ATZ → ATE0 → ATH1 → ATSP6 → ATAT2`，秒锁 ISO 15765-4 CAN 11-bit 500kbps
- 适配器无需 STN 芯片 (STPX/STCSEGR)，廉价 ELM327 克隆亦可使用
- DKE 式交叉轮询: 模仿 OBDProxy 的 `010C,010D,0111, 010C,010D,0111...` 模式，RPM/车速/油门交替排列
- 增量 HUD 推送: 每 PID 响应立即刷新插值器，消除串行轮询导致的卡顿

### 2. 车辆配置系统 (INI)

原始项目硬编码 Mercedes ME ECU 参数。重构为 INI 配置文件驱动:

| 配置项 | 文件 |
|--------|------|
| Arrizo 8 2.0T (OBD-II) | `assets/profiles/arrizo8_20t.ini` |
| Arrizo 8 2.0T (UDS) | `assets/profiles/arrizo8_uds.ini` |
| Generic OBD-II | `assets/profiles/generic_obd2.ini` |
| Mercedes-AMG C63s (W205) | 硬编码默认 (向后兼容) |

每个 INI 定义: 协议类型、ECU 地址、CAN 参数、DID/PID 列表及解析公式、齿轮比、轮胎尺寸、HUD 默认通道、慢变化参数等。

### 3. VIN 自动匹配

连接车辆后自动读取 VIN:

- **OBD-II**: 通过 Mode 09 PID 02 读取，匹配 `vin_pattern` 字段
- **UDS**: 通过 SID 22 DID F190 读取
- Arrizo 8 匹配规则: VIN 前缀 `LVVDC24B*`
- 无匹配 → 自动切换到 Generic OBD-II 通用配置
- 误配保护: 当前配置有 VIN 限制但实际车辆不匹配时，自动降级

### 4. 艾瑞泽8 7DCT300 变速箱参数

| 档位 | 齿比 | 终传比 | 综合速比 |
|:----:|:----:|:------:|:--------:|
| 1 | 4.308 | 3.944 | 16.99 |
| 2 | 2.684 | 3.944 | 10.59 |
| 3 | 1.594 | 4.438 | 7.07 |
| 4 | 1.114 | 4.438 | 4.94 |
| 5 | 0.894 | 4.438 | 3.97 |
| 6 | 0.829 | 3.944 | 3.27 |
| 7 | 0.638 | 3.944 | 2.52 |

DCT 双输入轴对应双终传比: 1/2/6/7 档 3.944, 3/4/5/R 档 4.438。轮胎 225/45R18。

### 5. OBD-II PID 映射

| HUD 位置 | HUD 参数 | OBD-II PID | 说明 |
|:--------:|---------|:----------:|------|
| 1 | 增压 PSI | 010B (MAP) | 绝对压力 kPa, 仅正压显示 |
| 2 | 扭矩 Nm | 0104 (Load) | 发动机负荷 % 换算 |
| 3 | 水温 ℃ | 0105 (Coolant) | 冷却液温度 A-40 |
| 4 | 节气门 % | 0111 (Throttle) | 节气门位置 A×100/255 |
| 5 | 退点火 ° | 010E (Timing) | 点火提前角 A/2-64 |
| 6 | 转速 RPM | 010C (RPM) | (A×256+B)/4 |
| 7 | 车速 km/h | 010D (Speed) | 直接读取 A |

### 6. DkeLogger 文件日志

- 写入 App 私有目录 (`/sdcard/Android/data/.../files/DKE/logs/`)，免权限
- TX/RX 模式标签: `TX-O`/`RX-O` (OBD2), `TX-U`/`RX-U` (UDS)
- 毫秒时间戳 + 5 秒定期刷新
- 自动清理保留最近 20 个日志文件

## 构建

```bash
# 要求: Flutter 3.41+ / Dart 3.11+ / Java 17 / Android SDK 36
flutter build apk --debug
```

## 上游

- 原始项目: [PenguinDukeYDAuto/eva_hud_app](https://github.com/PenguinDukeYDAuto/eva_hud_app)
- OBD 代理参考: OBDProxy App — vLinker MS ↔ DKE HUD 桥接