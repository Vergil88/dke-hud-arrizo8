// ════════════════════════════════════════════════════════════════
// obd_pids.dart — 统一 DID/PID 定义 (UDS + OBD-II)
// ════════════════════════════════════════════════════════════════
// UDS:  Service 22 — MB AMG ME ECU (7E0/7E8)
// OBD-II: Mode 01 — ISO 15765-4 CAN 11/500 (标准 OBD-II)
// ════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'vehicle_profile.dart';

// ═══ 通讯模式 ═══
enum CommMode {
  uds('UDS', 'ISO 14229 — MB AMG 扩展诊断'),
  obd2('OBD-II', 'ISO 15765-4 — 标准 OBD-II Mode 01');
  final String label;
  final String desc;
  const CommMode(this.label, this.desc);
}

// ═══ PID 分组 ═══
enum PidGroup {
  engine('发动机', Color(0xFFFF5252)),
  fuel('燃油', Color(0xFFFFD740)),
  boost('增压', Color(0xFF40C4FF)),
  timing('点火', Color(0xFFB388FF)),
  knock('退点火', Color(0xFFFF6E40)),
  air('进气', Color(0xFF69F0AE)),
  lambda('空燃比', Color(0xFF1DE9B6)),
  cam('配气', Color(0xFFEA80FC)),
  gear('变速箱档位', Color(0xFF76FF03)),
  misc('其他', Color(0xFF80CBC4));
  final String label;
  final Color color;
  const PidGroup(this.label, this.color);
}

// ═══ 值解析模式 ═══
enum ParseMode {
  uint8,      // A
  uint16be,   // (A<<8)|B
  int8,       // A (signed -128~+127)
  int16be,    // (A<<8)|B (signed)
  uint32be,   // 4 字节无符号 (喷油脉宽等)
}

// ════════════════════════════════════════════════════════════════
// ObdPid — UDS DID 定义 (保留类名以减少全局重命名)
// ════════════════════════════════════════════════════════════════
class ObdPid {
  final String id;
  final String name;
  final String shortName;

  // UDS (Service 22)
  final String udsDid;    // hex 如 '2000', 空=不支持
  final String udsEcuTx;
  final String udsEcuRx;

  // OBD-II Mode 01 (标准 OBD-II PID)
  final String obd2Pid;   // hex 如 '0C' (RPM), 空=不支持
  final String obd2Mode;  // hex 如 '01' (Mode 01), '09' (Mode 09)

  // 解析
  final ParseMode parseMode;
  final int byteOffset;
  final double scale;
  final double offset;

  // 显示
  final String unit;
  final PidGroup group;
  final int decimals;
  final double gaugeMax;
  final double? normalMax;

  // 档位映射 (仅 PidGroup.gear 的 PID 使用)
  final GearMapping? gearMapping;

  const ObdPid({
    required this.id, required this.name, required this.shortName,
    this.udsDid = '', this.udsEcuTx = '7E0', this.udsEcuRx = '7E8',
    this.obd2Pid = '', this.obd2Mode = '01',
    this.parseMode = ParseMode.uint8, this.byteOffset = 0,
    this.scale = 1.0, this.offset = 0.0,
    required this.unit, required this.group,
    this.decimals = 1, this.gaugeMax = 100, this.normalMax,
    this.gearMapping,
  });

  String get udsCmd {
    if (udsDid.isEmpty || udsDid.length < 4) return '';
    return '22 ${udsDid.substring(0, 2)} ${udsDid.substring(2, 4)}'.toUpperCase();
  }

  bool get hasUds => udsDid.isNotEmpty;

  /// OBD-II Mode 01 请求命令 (如 '010C' 读 RPM)
  String get obd2Cmd {
    if (obd2Pid.isEmpty || obd2Mode.isEmpty) return '';
    return '$obd2Mode$obd2Pid'.toUpperCase();
  }

  bool get hasObd2 => obd2Pid.isNotEmpty && obd2Mode.isNotEmpty;

  /// 该 PID 在指定通讯模式下是否可用
  bool isAvailableFor(CommMode mode) => switch (mode) {
    CommMode.uds  => hasUds,
    CommMode.obd2 => hasObd2,
  };

  /// UDS 响应数据字节数 (不含 SID 62 和 DID echo)
  /// 例: DID 0x2000 响应 "62 20 00 AA BB" → udsDataBytes = 2
  int get udsDataBytes => switch (parseMode) {
    ParseMode.uint8  => 1,
    ParseMode.int8   => 1,
    ParseMode.uint16be => 2,
    ParseMode.int16be  => 2,
    ParseMode.uint32be => 4,
  };

  /// ★ DID 响应中需要的总字节数 (含 byteOffset)
  /// 用于动态 DID 组合: 需要从 position=1 开始抓取 udsTotalBytes 字节,
  /// 这样 parseRaw 才能正确通过 byteOffset 索引到目标字节
  /// 当 byteOffset=0 时, udsTotalBytes == udsDataBytes (大多数情况)
  int get udsTotalBytes => byteOffset + udsDataBytes;

  /// ★ DID 的原始字节 (2字节) — 用于 SID 0x2C 动态定义
  /// 例: udsDid='2000' → [0x20, 0x00]
  List<int> get udsDidBytes {
    if (udsDid.length < 4) return [0, 0];
    final did = int.parse(udsDid, radix: 16);
    return [(did >> 8) & 0xFF, did & 0xFF];
  }

  /// ★ 是否适合放入动态 DID 组合
  /// 排除: 无 DID、响应总字节过长 (>4字节)
  bool get canBeDynamicDid =>
      hasUds && udsTotalBytes > 0 && udsTotalBytes <= 4;

  double? parseRaw(List<int> dataBytes) {
    if (dataBytes.length <= byteOffset) return null;
    try {
      int raw;
      switch (parseMode) {
        case ParseMode.uint8:
          raw = dataBytes[byteOffset];
        case ParseMode.uint16be:
          if (dataBytes.length <= byteOffset + 1) return null;
          raw = (dataBytes[byteOffset] << 8) | dataBytes[byteOffset + 1];
        case ParseMode.int8:
          raw = dataBytes[byteOffset];
          if (raw > 127) raw -= 256;
        case ParseMode.int16be:
          if (dataBytes.length <= byteOffset + 1) return null;
          raw = (dataBytes[byteOffset] << 8) | dataBytes[byteOffset + 1];
          if (raw > 32767) raw -= 65536;
        case ParseMode.uint32be:
          if (dataBytes.length <= byteOffset + 3) return null;
          raw = (dataBytes[byteOffset] << 24) | (dataBytes[byteOffset + 1] << 16) |
                (dataBytes[byteOffset + 2] << 8) | dataBytes[byteOffset + 3];
      }
      return raw * scale + offset;
    } catch (_) { return null; }
  }

  String formatValue(double? v) {
    if (v == null) return '--';
    if (group == PidGroup.gear) {
      final std = gearMapping?.standardize(v) ?? v.round();
      return gearLabel(std.toDouble());
    }
    return '${v.toStringAsFixed(decimals)} $unit';
  }
}

// ════════════════════════════════════════════════════════════════
// DynamicDidSource — SID 0x2C 动态组合 DID 的源定义
// ════════════════════════════════════════════════════════════════
// UDS SID 0x2C (DynamicallyDefineDataIdentifier) defineByIdentifier
// 每个源 DID 需要: [sourceDID_H] [sourceDID_L] [position] [memorySize]
// position 从 1 开始计数 (跳过 SID+DID echo)
// ════════════════════════════════════════════════════════════════

class DynamicDidSource {
  final int didHigh;
  final int didLow;
  final int position; // 从1开始
  final int size;     // 字节数

  const DynamicDidSource(this.didHigh, this.didLow, this.position, this.size);

  /// 从 ObdPid 创建 (position 固定为1, size 由 udsTotalBytes 推算)
  /// ★ udsTotalBytes = byteOffset + udsDataBytes, 确保抓取足够字节供 parseRaw 索引
  factory DynamicDidSource.fromPid(ObdPid pid) {
    final bytes = pid.udsDidBytes;
    return DynamicDidSource(bytes[0], bytes[1], 1, pid.udsTotalBytes);
  }

  /// 4字节定义负载
  List<int> get defineBytes => [didHigh, didLow, position, size];

  String get didHex =>
      '${didHigh.toRadixString(16).padLeft(2, '0')}${didLow.toRadixString(16).padLeft(2, '0')}'.toUpperCase();

  @override
  String toString() => 'DynSrc(0x$didHex, pos=$position, sz=$size)';
}

// ════════════════════════════════════════════════════════════════
// GearMapping — 档位编码映射 (ECU 原始值 → 标准化语义值)
// ════════════════════════════════════════════════════════════════
// 标准化语义: -2=R过渡  -1=R  0=P/N  1~9=D1~D9
// 不同 TCU 版本的 DID 返回不同编码, GearMapping 负责统一转换
// ════════════════════════════════════════════════════════════════

class GearMapping {
  /// key = ECU 原始值 (parseRaw 输出取整), value = 标准化语义值
  final Map<int, int> rawToStandard;

  /// 最大前进挡数 (用于 UI 显示 "7速" / "9速" 等)
  final int maxForwardGear;

  /// 人类可读描述 (用于 UI)
  final String description;

  const GearMapping({
    required this.rawToStandard,
    required this.maxForwardGear,
    this.description = '',
  });

  /// 将 parseRaw 的输出转换为标准化值
  /// 找不到映射时返回原值 (兜底)
  int standardize(double raw) {
    final r = raw.round();
    return rawToStandard[r] ?? r;
  }

  // ── 预置映射 ──

  /// Bit Gear 目標档位 (DID 0x5024, signed int8)
  /// -1(0xFF)=R  0=P/N  1~7=D1~D7
  static const m722_9 = GearMapping(
    rawToStandard: {
      -2: -2, -1: -1, 0: 0,
      1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7,
    },
    maxForwardGear: 7,
    description: 'W205 7速MCT TCU目標档位',
  );

  /// Engaged Gear 実装档位 (DID 0x5020)
  /// 0x00=P/N  0x01~0x06=D1~D6  0x07=R (倒档齿轮組)
  /// ★ 722.9 为 7AT, 但実装档位信号中 D7 与 R 共用编码 0x07
  static const mW205 = GearMapping(
    rawToStandard: {
      0: 0,                               // P/N
      1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, // D1~D6
      7: -1,                               // R → 标准化为 -1
    },
    maxForwardGear: 6,
    description: 'W205 7速MCT 実装档位',
  );

  // ★ 新增 TCU 版本时, 在此添加映射常量
}

// ════════════════════════════════════════════════════════════════
// 标准化档位显示 (基于统一语义值)
// -2=R过渡  -1=R  0=P/N  1~9=D1~D9
// ════════════════════════════════════════════════════════════════
String gearLabel(double? raw) {
  if (raw == null) return '--';
  final v = raw.round();
  return switch (v) {
    -2 => 'R*',
    -1 => 'R',
     0 => 'P/N',
    _ when v >= 1 && v <= 9 => 'D$v',
    _ => '?($v)',
  };
}

// ════════════════════════════════════════════════════════════════
// UDS DID — 内置默认: MB AMG ME ECU (7E0/7E8)
// ★ 运行时可被 VehicleProfile 覆盖
// ════════════════════════════════════════════════════════════════
const _builtinUdsDids = <ObdPid>[
  // 基础发动机
  ObdPid(id:'uds_rpm',name:'发动机转速',shortName:'RPM',udsDid:'2000',parseMode:ParseMode.uint16be,scale:0.25,unit:'rpm',group:PidGroup.engine,decimals:0,normalMax:7000,gaugeMax:8000),
  ObdPid(id:'uds_load',name:'发动机负荷',shortName:'负荷',udsDid:'2001',parseMode:ParseMode.uint16be,scale:0.0234375,unit:'%',group:PidGroup.engine,decimals:2,gaugeMax:100),
  ObdPid(id:'uds_torque',name:'发动机扭矩',shortName:'扭矩',udsDid:'6000',parseMode:ParseMode.int16be,scale:0.0625,unit:'Nm',group:PidGroup.engine,decimals:1,gaugeMax:900),
  ObdPid(id:'uds_accel',name:'油门踏板位置',shortName:'油门',udsDid:'2029',parseMode:ParseMode.uint16be,scale:0.001525902,unit:'%',group:PidGroup.engine,decimals:1,gaugeMax:100),
  ObdPid(id:'uds_speed',name:'车辆速度',shortName:'车速',udsDid:'5021',parseMode:ParseMode.uint16be,scale:0.0625,unit:'km/h',group:PidGroup.engine,decimals:1,normalMax:250,gaugeMax:300),
  // 温度/压力
  ObdPid(id:'uds_coolant',name:'冷却液温度',shortName:'水温',udsDid:'2011',scale:0.75,offset:-48,unit:'°C',group:PidGroup.engine,decimals:1,normalMax:105,gaugeMax:140),
  ObdPid(id:'uds_iat_b1',name:'进气温度 B1',shortName:'进气B1',udsDid:'2014',scale:0.75,offset:-48,unit:'°C',group:PidGroup.air,decimals:1,normalMax:60,gaugeMax:120),
  ObdPid(id:'uds_manifold_b1',name:'歧管压力 B1',shortName:'歧管B1',udsDid:'2018',parseMode:ParseMode.uint16be,scale:0.001133109,unit:'psi',group:PidGroup.boost,decimals:1,gaugeMax:44),
  ObdPid(id:'uds_manifold_b2',name:'歧管压力 B2',shortName:'歧管B2',udsDid:'7FD8',parseMode:ParseMode.uint16be,scale:0.001133109,unit:'psi',group:PidGroup.boost,decimals:1,gaugeMax:44),
  ObdPid(id:'uds_ambient',name:'环境大气压',shortName:'大气压',udsDid:'2040',parseMode:ParseMode.uint16be,scale:0.0390625,unit:'hPa',group:PidGroup.air,decimals:1,gaugeMax:1100),
  ObdPid(id:'uds_airfilter',name:'空滤后压力 B1',shortName:'空滤B1',udsDid:'2079',parseMode:ParseMode.uint16be,scale:0.0390625,unit:'hPa',group:PidGroup.air,decimals:1,gaugeMax:1100),
  // 增压系统
  ObdPid(id:'uds_boost_b1',name:'增压压力 B1',shortName:'增压B1',udsDid:'2077',parseMode:ParseMode.uint16be,scale:0.001133109,unit:'psi',group:PidGroup.boost,decimals:1,normalMax:29,gaugeMax:44),
  ObdPid(id:'uds_boost_b2',name:'增压压力 B2',shortName:'增压B2',udsDid:'7FD1',parseMode:ParseMode.uint16be,scale:0.001133109,unit:'psi',group:PidGroup.boost,decimals:1,normalMax:29,gaugeMax:44),
  ObdPid(id:'uds_wastegate',name:'Wastegate占空比',shortName:'WG',udsDid:'D062',parseMode:ParseMode.uint16be,scale:0.001525902,unit:'%',group:PidGroup.boost,decimals:1,gaugeMax:100),
  // 燃油系统
  ObdPid(id:'uds_fuel_lp',name:'低压燃油压力',shortName:'低压油',udsDid:'2098',parseMode:ParseMode.uint16be,scale:0.1,unit:'kPa',group:PidGroup.fuel,decimals:1,gaugeMax:800),
  ObdPid(id:'uds_fuel_hp',name:'高压轨压 B1',shortName:'高压油',udsDid:'2071',parseMode:ParseMode.uint16be,scale:0.0005,unit:'MPa',group:PidGroup.fuel,decimals:2,normalMax:20,gaugeMax:25),
  ObdPid(id:'uds_inj_b1',name:'喷油脉宽 B1',shortName:'喷油B1',udsDid:'D051',parseMode:ParseMode.uint32be,scale:0.001,unit:'ms',group:PidGroup.fuel,decimals:3,gaugeMax:30),
  ObdPid(id:'uds_inj_b2',name:'喷油脉宽 B2',shortName:'喷油B2',udsDid:'D052',parseMode:ParseMode.uint32be,scale:0.001,unit:'ms',group:PidGroup.fuel,decimals:3,gaugeMax:30),
  ObdPid(id:'uds_hpfp',name:'HPFP-MSV角度',shortName:'HPFP',udsDid:'D057',parseMode:ParseMode.uint16be,scale:0.1,unit:'°',group:PidGroup.fuel,decimals:1,gaugeMax:360),
  // 点火系统
  ObdPid(id:'uds_ign_b1',name:'点火角度 B1',shortName:'点火B1',udsDid:'D049',parseMode:ParseMode.int8,scale:0.75,unit:'°',group:PidGroup.timing,decimals:2,gaugeMax:50),
  ObdPid(id:'uds_ign_b2',name:'点火角度 B2',shortName:'点火B2',udsDid:'D050',parseMode:ParseMode.int8,scale:0.75,unit:'°',group:PidGroup.timing,decimals:2,gaugeMax:50),
  ObdPid(id:'uds_ign_corr',name:'修正后点火角',shortName:'修正点火',udsDid:'D010',parseMode:ParseMode.int8,scale:0.75,unit:'°',group:PidGroup.timing,decimals:2,gaugeMax:50),
  // 退点火 (爆震)
  ObdPid(id:'uds_kr_avg',name:'全局平均退点火',shortName:'退点火',udsDid:'6040',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,normalMax:3,gaugeMax:15),
  ObdPid(id:'uds_kr_1',name:'退点火 缸1',shortName:'KR#1',udsDid:'6041',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,gaugeMax:15),
  ObdPid(id:'uds_kr_2',name:'退点火 缸2',shortName:'KR#2',udsDid:'6042',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,gaugeMax:15),
  ObdPid(id:'uds_kr_3',name:'退点火 缸3',shortName:'KR#3',udsDid:'6043',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,gaugeMax:15),
  ObdPid(id:'uds_kr_4',name:'退点火 缸4',shortName:'KR#4',udsDid:'6044',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,gaugeMax:15),
  ObdPid(id:'uds_kr_5',name:'退点火 缸5',shortName:'KR#5',udsDid:'6045',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,gaugeMax:15),
  ObdPid(id:'uds_kr_6',name:'退点火 缸6',shortName:'KR#6',udsDid:'6046',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,gaugeMax:15),
  ObdPid(id:'uds_kr_7',name:'退点火 缸7',shortName:'KR#7',udsDid:'6047',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,gaugeMax:15),
  ObdPid(id:'uds_kr_8',name:'退点火 缸8',shortName:'KR#8',udsDid:'6048',scale:0.75,unit:'°',group:PidGroup.knock,decimals:2,gaugeMax:15),
  // 空燃比 (AFR = λ × 14.7)
  ObdPid(id:'uds_lambda_b1',name:'空燃比 B1',shortName:'AFR B1',udsDid:'6131',parseMode:ParseMode.uint16be,scale:0.0004557,unit:'AFR',group:PidGroup.lambda,decimals:2,gaugeMax:22),
  ObdPid(id:'uds_lambda_sp',name:'空燃比设定值 B1',shortName:'AFR SP',udsDid:'6143',parseMode:ParseMode.uint16be,scale:0.003588867,unit:'AFR',group:PidGroup.lambda,decimals:2,gaugeMax:22),
  // 配气机构
  ObdPid(id:'uds_exh_cam_b1',name:'排气凸轮角度 B1',shortName:'排凸B1',udsDid:'6181',parseMode:ParseMode.int16be,scale:0.0078125,unit:'°',group:PidGroup.cam,decimals:2,gaugeMax:50),
  ObdPid(id:'uds_int_cam_b1',name:'进气凸轮角度 B1',shortName:'进凸B1',udsDid:'6183',parseMode:ParseMode.uint16be,scale:0.0078125,unit:'°',group:PidGroup.cam,decimals:2,gaugeMax:60),
  // 变速箱档位 (PidGroup.gear — 可多选, 用户在主页选择)
  ObdPid(id:'uds_gear_722',name:'7速MCT目標档位',shortName:'7MCT目標档位',udsDid:'5024',parseMode:ParseMode.int8,scale:1.0,unit:'',group:PidGroup.gear,decimals:0,gaugeMax:7,gearMapping:GearMapping.m722_9),
  ObdPid(id:'uds_gear_w205',name:'7速MCT実装档位',shortName:'7MCT実装档位',udsDid:'5020',parseMode:ParseMode.uint8,scale:1.0,unit:'',group:PidGroup.gear,decimals:0,gaugeMax:7,gearMapping:GearMapping.mW205),
  // ★ 新增 TCU 版本时, 在此追加 ObdPid 条目
  // 其他
  ObdPid(id:'uds_throttle_ang',name:'节气门角度',shortName:'节气门°',udsDid:'D023',parseMode:ParseMode.uint16be,scale:0.1,unit:'°',group:PidGroup.engine,decimals:1,gaugeMax:90),
  ObdPid(id:'uds_airmass',name:'计算空气质量',shortName:'空气量',udsDid:'6252',parseMode:ParseMode.uint16be,scale:0.1,unit:'kg/h',group:PidGroup.air,decimals:1,gaugeMax:1500),
];

// ════════════════════════════════════════════════════════════════
// OBD-II Mode 01 PID — 内置默认: 艾瑞泽8 2.0T (ISO 15765-4)
// ★ 标准 OBD-II 公式, 输出真实物理值
// ★ 运行时可被 VehicleProfile 覆盖
// ════════════════════════════════════════════════════════════════
const _builtinObd2Pids = <ObdPid>[
  // ── 基础发动机 (标准 OBD-II Mode 01) ──
  // ★ ID 对齐 UDS 命名以便 HUD/通道复用
  // 010C RPM: (A*256+B)/4
  ObdPid(id:'uds_rpm',name:'发动机转速',shortName:'RPM',
    obd2Pid:'0C',parseMode:ParseMode.uint16be,scale:0.25,
    unit:'rpm',group:PidGroup.engine,decimals:0,normalMax:7000,gaugeMax:8000),
  // 010D Speed: A (km/h)
  ObdPid(id:'uds_speed',name:'车辆速度',shortName:'车速',
    obd2Pid:'0D',parseMode:ParseMode.uint8,scale:1.0,
    unit:'km/h',group:PidGroup.engine,decimals:1,normalMax:250,gaugeMax:300),
  // 0111 Throttle: A*100/255
  ObdPid(id:'uds_accel',name:'节气门位置',shortName:'节气门',
    obd2Pid:'11',parseMode:ParseMode.uint8,scale:0.39215686,
    unit:'%',group:PidGroup.engine,decimals:1,gaugeMax:100),
  // 0104 Load: A*100/255
  ObdPid(id:'uds_load',name:'发动机负荷',shortName:'负荷',
    obd2Pid:'04',parseMode:ParseMode.uint8,scale:0.39215686,
    unit:'%',group:PidGroup.engine,decimals:1,gaugeMax:100),
  // ★ 扭矩从负荷推算 (无直接OBD-II PID)
  ObdPid(id:'uds_torque',name:'发动机扭矩 (估算)',shortName:'扭矩',
    obd2Pid:'04',parseMode:ParseMode.uint8,scale:3.0,offset:-60,
    unit:'Nm',group:PidGroup.engine,decimals:1,gaugeMax:500),

  // ── 温度 ──
  // 0105 Coolant: A-40
  ObdPid(id:'uds_coolant',name:'冷却液温度',shortName:'水温',
    obd2Pid:'05',parseMode:ParseMode.uint8,scale:1.0,offset:-40,
    unit:'°C',group:PidGroup.engine,decimals:1,normalMax:105,gaugeMax:140),
  // 010F IAT: A-40
  ObdPid(id:'uds_iat_b1',name:'进气温度',shortName:'进气温度',
    obd2Pid:'0F',parseMode:ParseMode.uint8,scale:1.0,offset:-40,
    unit:'°C',group:PidGroup.air,decimals:1,normalMax:60,gaugeMax:120),

  // ── 增压/压力 ──
  // 010B MAP: 绝对压力 A (kPa) → 相对增压 = (A - 大气压103kPa) / 6.895
  // 负压(真空)时 HUD 显示为 0 (gaugeMax=45, 无负值)
  ObdPid(id:'uds_boost_b1',name:'增压压力',shortName:'Boost',
    obd2Pid:'0B',parseMode:ParseMode.uint8,scale:0.145,offset:-14.94,
    unit:'PSI',group:PidGroup.boost,decimals:1,normalMax:30,gaugeMax:45),

  // ── 点火 ──
  // 010E Timing: A/2-64
  ObdPid(id:'uds_ign_b1',name:'点火提前角',shortName:'点火',
    obd2Pid:'0E',parseMode:ParseMode.uint8,scale:0.5,offset:-64,
    unit:'°',group:PidGroup.timing,decimals:1,gaugeMax:50),

  // ── 退点火 (OBD-II 无直接PID, 设为0)
  ObdPid(id:'uds_kr_avg',name:'退点火 (N/A)',shortName:'退点火',
    obd2Pid:'0E',parseMode:ParseMode.uint8,scale:0.0,offset:0,
    unit:'°',group:PidGroup.knock,decimals:1,gaugeMax:15),

  // ── 燃油 ──
  // 012F Fuel Level: A*100/255
  ObdPid(id:'uds_fuel_lp',name:'燃油液位',shortName:'油位',
    obd2Pid:'2F',parseMode:ParseMode.uint8,scale:0.39215686,
    unit:'%',group:PidGroup.fuel,decimals:1,gaugeMax:100),
  // 015C Oil Temp: A-40
  ObdPid(id:'uds_oil_temp',name:'机油温度',shortName:'机油温',
    obd2Pid:'5C',parseMode:ParseMode.uint8,scale:1.0,offset:-40,
    unit:'°C',group:PidGroup.engine,decimals:1,normalMax:120,gaugeMax:150),
  // 0133 Barometric Pressure: A (kPa)
  ObdPid(id:'uds_baro',name:'大气压力',shortName:'大气压',
    obd2Pid:'33',parseMode:ParseMode.uint8,scale:1.0,
    unit:'kPa',group:PidGroup.air,decimals:1,gaugeMax:120),
  // 0106 Short Term Fuel Trim B1: (A-128)*100/128
  ObdPid(id:'uds_fuel_trim_b1',name:'短期燃油修正B1',shortName:'油修B1',
    obd2Pid:'06',parseMode:ParseMode.uint8,scale:0.78125,offset:-100,
    unit:'%',group:PidGroup.fuel,decimals:1,gaugeMax:25),
  // 0113 O2 Sensor B1 Voltage: A*0.005
  ObdPid(id:'uds_o2_b1',name:'氧传感器B1',shortName:'O2 B1',
    obd2Pid:'13',parseMode:ParseMode.uint8,scale:0.005,
    unit:'V',group:PidGroup.lambda,decimals:3,gaugeMax:1.5),
  // 015E Fuel Flow: (A*256+B)/20
  ObdPid(id:'uds_fuel_flow',name:'燃油流量',shortName:'燃油流量',
    obd2Pid:'5E',parseMode:ParseMode.uint16be,scale:0.05,
    unit:'L/h',group:PidGroup.fuel,decimals:1,gaugeMax:100),

  // ── O2/空燃比 ──
  // 0144 当量比 φ: (A*256+B)/32768
  // 线性近似 AFR: raw*0.000448 (=14.7/32768), λ≈1.0时误差<5%
  ObdPid(id:'uds_lambda_b1',name:'空燃比 AFR',shortName:'AFR',
    obd2Pid:'44',parseMode:ParseMode.uint16be,scale:0.000448,offset:0.2,
    unit:'AFR',group:PidGroup.lambda,decimals:1,gaugeMax:22),

  // ── 其他 ──
  // 0146 Ambient Temp: A-40
  ObdPid(id:'uds_ambient',name:'环境温度',shortName:'环境温度',
    obd2Pid:'46',parseMode:ParseMode.uint8,scale:1.0,offset:-40,
    unit:'°C',group:PidGroup.air,decimals:1,gaugeMax:60),
];

// ════════════════════════════════════════════════════════════════
const _latencyPid = ObdPid(id:'latency',name:'通讯延迟',shortName:'延迟',unit:'ms',group:PidGroup.misc,decimals:0,gaugeMax:500);

class ObdPids {
  ObdPids._();

  /// ★ 运行时 DID 列表 (可被 VehicleProfile 覆盖)
  static List<ObdPid> _activeDids = List.of(_builtinUdsDids);

  /// ★ 运行时 OBD-II PID 列表 (可被 VehicleProfile 覆盖)
  static List<ObdPid> _activeObd2Pids = List.of(_builtinObd2Pids);

  /// 当前活跃的 DID 列表
  static List<ObdPid> get udsDids => _activeDids;

  /// 当前活跃的 OBD-II PID 列表
  static List<ObdPid> get obd2Pids => _activeObd2Pids;

  static ObdPid get latencyPid => _latencyPid;

  /// 所有档位 DID (PidGroup.gear)
  static List<ObdPid> get gearPids =>
      _activeDids.where((p) => p.group == PidGroup.gear).toList();

  /// ★ 根据通讯模式返回可选 PID 列表
  static List<ObdPid> selectableFor(CommMode mode) => switch (mode) {
    CommMode.uds  => [..._activeDids, _latencyPid],
    CommMode.obd2 => [..._activeObd2Pids, _latencyPid],
  };

  /// ★ 根据通讯模式返回可选 PID 列表 (不含延迟)
  static List<ObdPid> pidsFor(CommMode mode) => switch (mode) {
    CommMode.uds  => _activeDids,
    CommMode.obd2 => _activeObd2Pids,
  };

  static ObdPid? byId(String id) {
    if (id == 'latency') return _latencyPid;
    // ★ 向后兼容: 旧版 'uds_gear' → 'uds_gear_722'
    if (id == 'uds_gear') {
      for (final p in _activeDids) { if (p.id == 'uds_gear_722') return p; }
    }
    // ★ UDS 优先: 先搜索 UDS DIDs, 再搜索 OBD-II PIDs
    for (final p in _activeDids) { if (p.id == id) return p; }
    for (final p in _activeObd2Pids) { if (p.id == id) return p; }
    return null;
  }

  static ObdPid? byIdForMode(String id, CommMode mode) {
    if (id == 'latency') return _latencyPid;
    final list = mode == CommMode.uds ? _activeDids : _activeObd2Pids;
    for (final p in list) { if (p.id == id) return p; }
    return null;
  }

  static Map<PidGroup, List<ObdPid>> groupedFor(CommMode mode) {
    final map = <PidGroup, List<ObdPid>>{};
    for (final pid in selectableFor(mode)) {
      map.putIfAbsent(pid.group, () => []).add(pid);
    }
    return map;
  }

  // ═══ ★ VehicleProfile 动态加载 ═══

  /// 从 VehicleProfile 加载 DID/PID 列表 (覆盖内置)
  static void loadFromProfile(VehicleProfile profile) {
    if (profile.dids.isNotEmpty) {
      // 检查 profile 协议类型
      if (profile.protocol.toUpperCase() == 'OBD2' || profile.protocol.toUpperCase() == 'OBD-II') {
        _activeObd2Pids = List.of(profile.dids);
      } else {
        _activeDids = List.of(profile.dids);
      }
    } else {
      _activeDids = List.of(_builtinUdsDids);
      _activeObd2Pids = List.of(_builtinObd2Pids);
    }
  }

  /// 恢复为内置默认列表
  static void resetToBuiltin() {
    _activeDids = List.of(_builtinUdsDids);
    _activeObd2Pids = List.of(_builtinObd2Pids);
  }

  /// 内置 UDS DID 列表 (只读引用)
  static List<ObdPid> get builtinDids => _builtinUdsDids;

  /// 内置 OBD-II PID 列表 (只读引用)
  static List<ObdPid> get builtinObd2Pids => _builtinObd2Pids;
}

const List<Color> chartPalette = [
  Color(0xFFFF5252),Color(0xFF40C4FF),Color(0xFFFFD740),Color(0xFF69F0AE),
  Color(0xFFB388FF),Color(0xFFFF6E40),Color(0xFF1DE9B6),Color(0xFFFFAB40),
  Color(0xFF448AFF),Color(0xFFE040FB),Color(0xFF76FF03),Color(0xFFEA80FC),
];
Color colorForIndex(int i) => chartPalette[i % chartPalette.length];