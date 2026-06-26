// ════════════════════════════════════════════════════════════════
// hud_interpolator.dart — 30fps HUD 视觉插值引擎
// ════════════════════════════════════════════════════════════════
// 数据采样 5-10Hz, 视觉渲染 30fps
// 每个通道独立指数平滑 + 可选预测
// ════════════════════════════════════════════════════════════════

import 'dart:math' as math;

/// 单通道插值状态
class _ChState {
  double display = 0;   // 当前显示值 (30fps 更新)
  double target = 0;    // 最新采样目标值
  double prevTarget = 0; // 上一次目标值 (用于预测)
  double velocity = 0;   // 变化速率 (单位/秒)
  int targetMs = 0;      // 目标值时间戳 (ms)
  int prevTargetMs = 0;  // 上一次时间戳
  double speed;          // 平滑速度 (越大越快跟踪)
  bool predictive;       // 是否启用预测外推

  _ChState({this.speed = 12.0, this.predictive = false});
}

/// 插值配置预设
class InterpProfile {
  final double speed;       // 平滑因子 (Hz, ~= 1/响应时间)
  final bool predictive;    // 预测外推 (适合快变通道)
  const InterpProfile(this.speed, {this.predictive = false});

  // ── 预设 ──
  static const rpm     = InterpProfile(18.0, predictive: true);  // ~55ms 跟踪
  static const boost   = InterpProfile(15.0, predictive: true);  // ~67ms
  static const torque  = InterpProfile(14.0, predictive: true);  // ~71ms
  static const throttle = InterpProfile(16.0, predictive: true);
  static const fuel    = InterpProfile(12.0);                     // ~83ms
  static const temp    = InterpProfile(4.0);                      // ~250ms (温度缓变)
  static const knock   = InterpProfile(25.0);                     // ~40ms (安全关键, 快响应)
  static const instant = InterpProfile(999.0);                    // 立即跳变
  static const slow    = InterpProfile(6.0);                      // 慢变量
}

class HudInterpolator {
  final Map<String, _ChState> _channels = {};
  int _lastTickMs = 0;
  bool _started = false;

  // 采样计数器 (用于 Hz 计算)
  int _sampleCount = 0;
  int _sampleWindowMs = 0;
  double _dataHz = 0;

  double get dataHz => _dataHz;

  /// 注册通道 + 插值配置
  void register(String key, {InterpProfile profile = const InterpProfile(12.0)}) {
    _channels[key] = _ChState(speed: profile.speed, predictive: profile.predictive);
  }

  /// 批量注册 (常用预设)
  void registerDefaults() {
    // 核心引擎
    register('rpm',           profile: InterpProfile.rpm);
    register('uds_rpm',       profile: InterpProfile.rpm);

    // 增压
    register('uds_boost_b1',  profile: InterpProfile.boost);
    register('boost_target',  profile: InterpProfile.boost);

    // 扭矩 / 油门
    register('uds_torque',    profile: InterpProfile.torque);
    register('torque_actual', profile: InterpProfile.torque);
    register('uds_accel',     profile: InterpProfile.throttle);
    register('accel_pedal',   profile: InterpProfile.throttle);

    // 燃油
    register('uds_fuel_hp',   profile: InterpProfile.fuel);
    register('uds_fuel_lp',   profile: InterpProfile.fuel);

    // 温度 (缓变)
    register('uds_coolant',   profile: InterpProfile.temp);
    register('uds_iat_b1',    profile: InterpProfile.temp);

    // 点火 / 退点火 (安全关键)
    register('uds_ign_b1',    profile: InterpProfile.knock);
    register('uds_kr_avg',    profile: InterpProfile.knock);

    // 速度
    register('speed',         profile: InterpProfile.rpm);
    register('uds_speed',     profile: InterpProfile.rpm);

    // 其他
    register('gear',          profile: InterpProfile.instant);
  }

  /// 接收新数据 (来自 LiveDataService, 5-10Hz)
  void pushData(Map<String, double> values) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Hz 统计
    _sampleCount++;
    if (_sampleWindowMs == 0) _sampleWindowMs = nowMs;
    final windowElapsed = nowMs - _sampleWindowMs;
    if (windowElapsed >= 1000) {
      _dataHz = _sampleCount * 1000.0 / windowElapsed;
      _sampleCount = 0;
      _sampleWindowMs = nowMs;
    }

    for (final e in values.entries) {
      var ch = _channels[e.key];
      if (ch == null) {
        // 动态注册未知通道 (默认中速)
        ch = _ChState(speed: 10.0);
        _channels[e.key] = ch;
      }

      ch.prevTarget = ch.target;
      ch.prevTargetMs = ch.targetMs;
      ch.target = e.value;
      ch.targetMs = nowMs;

      // 计算速率 (用于预测)
      final dt = (ch.targetMs - ch.prevTargetMs).clamp(1, 2000) / 1000.0;
      ch.velocity = (ch.target - ch.prevTarget) / dt;

      // 首次数据: 直接跳到目标
      if (!_started) ch.display = ch.target;
    }
    _started = true;
  }

  /// 30fps tick — 返回 true 表示有变化需要 setState
  bool tick() {
    if (!_started) return false;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastTickMs == 0) {
      _lastTickMs = nowMs;
      return false;
    }

    final dtMs = (nowMs - _lastTickMs).clamp(1, 100);
    _lastTickMs = nowMs;
    final dt = dtMs / 1000.0; // 秒

    bool changed = false;

    for (final ch in _channels.values) {
      final prev = ch.display;

      // 计算有效目标 (可选预测外推)
      double effectiveTarget = ch.target;
      if (ch.predictive && ch.targetMs > 0) {
        // 从最后一次数据推算到现在
        final age = (nowMs - ch.targetMs).clamp(0, 500) / 1000.0;
        if (age < 0.3 && ch.velocity.abs() > 0.1) {
          // 外推, 但限制在合理范围内 (不超过 target±velocity*0.15s)
          final extrap = ch.target + ch.velocity * age * 0.5;
          // 限幅: 外推值不能偏离 target 太远
          final maxDelta = ch.velocity.abs() * 0.2;
          effectiveTarget = extrap.clamp(
            ch.target - maxDelta,
            ch.target + maxDelta,
          );
        }
      }

      // 指数平滑: display += (target - display) * (1 - e^(-speed * dt))
      final alpha = 1.0 - math.exp(-ch.speed * dt);
      ch.display += (effectiveTarget - ch.display) * alpha;

      // 微小抖动抑制 (< 0.01% of target)
      final threshold = (ch.target.abs() * 0.0001).clamp(0.001, 0.1);
      if ((ch.display - ch.target).abs() < threshold) {
        ch.display = ch.target;
      }

      if ((ch.display - prev).abs() > 0.001) changed = true;
    }

    return changed;
  }

  /// 获取插值后的显示值
  double get(String key) => _channels[key]?.display ?? 0;

  /// 批量获取 (兼容 _d 用法)
  Map<String, double> get displayValues {
    return _channels.map((k, v) => MapEntry(k, v.display));
  }

  /// 设置特定通道为即时跳变 (不插值)
  void setImmediate(String key, double value) {
    final ch = _channels[key];
    if (ch != null) {
      ch.target = value;
      ch.display = value;
      ch.velocity = 0;
    }
  }

  void reset() {
    for (final ch in _channels.values) {
      ch.display = 0;
      ch.target = 0;
      ch.velocity = 0;
    }
    _started = false;
    _lastTickMs = 0;
  }
}