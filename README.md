# DKE HUD — 奇瑞艾瑞泽8 2.0T 适配版

基于 [PenguinDukeYDAuto/eva_hud_app](https://github.com/PenguinDukeYDAuto/eva_hud_app) 二次开发，适配奇瑞艾瑞泽8 (Arrizo 8) 2024款 劲 2.0T。

## 适配改动

### OBD-II 直连模式
- 新增 `CommMode.obd2`，直接通过 ELM327 适配器 (vLinker MS) 读取标准 SAE J1979 Mode 01 PID
- DKE 式交叉轮询: RPM×4 / 车速×3 / 节气门×3 交替排列，配合增量 HUD 推送实现 ~18Hz 数据刷新
- 支持 ATSP6 (ISO 15765-4 CAN 11-bit 500kbps) 协议自动锁定

### 车辆配置系统
- INI 配置文件系统，支持多车型切换
- 内置 Arrizo 8 2.0T OBD-II / UDS 配置
- 内置 Generic OBD-II 通用配置
- VIN 自动匹配: 连接后通过 0902 读取 VIN，自动切换对应车型配置
- 齿轮比: 7DCT300 (4.308 / 2.684 / 1.594 / 1.114 / 0.894 / 0.829 / 0.638)，终传比 3.944

### 性能优化
- 增量 HUD 推送: 每 PID 响应立即刷新，消除 1.1Hz 卡顿
- OBD2 模式去除 busLock，减少蓝牙串行化开销
- 空轮询保护，防止无可用 PID 时忙等

## 车辆参数

| 项目 | 参数 |
|------|------|
| 车型 | 奇瑞艾瑞泽8 2024款 劲 (SQR7200M1ETB) |
| 发动机 | SQRF4J20 2.0T (187kW/390N·m) |
| 变速箱 | 7DCT300 湿式双离合 |
| 轮胎 | 225/45R18 |
| OBD 适配器 | vLinker MS 06330 (ELM327 v2.3 / STN2120) |
| CAN 协议 | ISO 15765-4, 11-bit, 500kbps |

## 构建

```bash
# Flutter 3.41+ / Dart 3.11+
flutter build apk --debug
```

构建脚本: `build_and_archive.ps1`

## 上游

- 原始项目: [PenguinDukeYDAuto/eva_hud_app](https://github.com/PenguinDukeYDAuto/eva_hud_app)
- OBD 代理参考: OBDProxy App (vLinker MS ↔ DKE HUD 桥接)