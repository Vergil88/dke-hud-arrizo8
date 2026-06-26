// ════════════════════════════════════════════════════════════════
// live_data_service.dart — 实时数据轮询服务 (重構版)
// ════════════════════════════════════════════════════════════════
// ★ 核心改進:
//   - 仅轮询实际勾选的 PID (不再轮询所有)
//   - UDS 模式: Multi-DID 批量读取
//   - Demo 模拟器精简
// ════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math' as math;
import '../models/obd_pids.dart';
import 'bt_manager.dart';

/// 单个数据点
class DataPoint {
  final int timeMs;
  final String pidId;
  final double value;
  const DataPoint(this.timeMs, this.pidId, this.value);
}

/// 一次轮询周期的结果快照
class PollSnapshot {
  final int timeMs;
  final Map<String, double> values;
  PollSnapshot(this.timeMs, this.values);
}

/// 轮询服务
class LiveDataService {
  final void Function(String tag, String msg) onLog;
  final void Function(PollSnapshot snapshot) onData;
  final void Function(int latencyMs) onLatency;

  LiveDataService({
    required this.onLog,
    required this.onData,
    required this.onLatency,
  });

  /// ★ 仅包含用户实际勾选的 PID
  List<ObdPid> selectedPids = [];
  final List<DataPoint> dataPoints = [];
  DateTime? _startTime;

  bool _running = false;
  bool get isRunning => _running;

  bool _dynamicDidOk = false;     // ★ Tier 1: SID 0x2C 动态组合 DID (20 Hz)
  int _dynamicDidTotalLen = 0;    // 组合 DID 总数据长度
  final List<_DidSlice> _didSlices = []; // 拆分映射表
  List<ObdPid> _excludedPids = []; // ★ 未纳入动态 DID 的 PID (需补充轮询)

  /// ★ 动态 DID 目标地址 — 从 BtManager (→ profile) 动态读取
  int get _targetDid => BtManager.instance.dynamicDidTarget;

  bool _multiDidOk = false;       // ★ Tier 2: Multi-DID 批量 (~5 Hz)

  // ── 会话统计 (stop 时输出摘要) ──
  int _totalObd2Ok = 0;
  int _totalObd2Fail = 0;
  int _totalObd2Cycles = 0;
  int _maxCycleElapsedMs = 0;
  int _connectionDrops = 0;

  // ── 自动重连恢复 ──
  StreamSubscription? _reconnectSub;

  bool _demo = false;
  bool get isDemo => _demo;

  int get sampleCount => dataPoints.length;

  int get durationMs {
    if (dataPoints.isEmpty || _startTime == null) return 0;
    return DateTime.now().difference(_startTime!).inMilliseconds;
  }

  // ════════════════════════════════════════════════════════
  // 启动 (真实 ECU)
  // ════════════════════════════════════════════════════════

  /// ★ 仅传入实际需要轮询的 PID
  Future<void> start(List<ObdPid> pids) async {
    if (_running) return;
    if (pids.isEmpty) {
      onLog('ERR', '请先选择至少一个数据项');
      return;
    }

    final bt = BtManager.instance;

    if (!bt.isConnected) {
      onLog('ERR', '请先连接蓝牙');
      return;
    }

    selectedPids = List.of(pids);
    dataPoints.clear();
    _startTime = DateTime.now();
    _running = true;
    _demo = false;

    // ★ 监听 BtManager 重连事件, 自动恢复轮询
    _reconnectSub?.cancel();
    _reconnectSub = BtManager.instance.onReconnect.listen((success) {
      if (success && !_running) {
        _resumeAfterReconnect();
      } else if (!success && _running) {
        // ★ 重连彻底失败, 清理状态
        _running = false;
        _connectionDrops++;
        onLog('SYS', '❌ 自动重连失败, 录制已停止');
      }
    });

    // ★ 重置会话统计
    _totalObd2Ok = 0;
    _totalObd2Fail = 0;
    _totalObd2Cycles = 0;
    _maxCycleElapsedMs = 0;
    _connectionDrops = 0;

    final realCount = pids.where((p) => p.id != 'latency').length;
    onLog('SYS', '▶ 开始数据录制 — $realCount 项 ${bt.commMode == CommMode.obd2 ? "PID" : "DID"}');
    for (final p in pids) {
      if (p.id == 'latency') continue;
      final cmd = bt.commMode == CommMode.obd2 ? p.obd2Cmd : p.udsCmd;
      onLog('SYS', '  ${p.shortName.padRight(8)} → $cmd');
    }

    // ═══ UDS 模式 ═══
    if (bt.commMode == CommMode.uds) {
      final ok = await BtManager.instance.ensureSession(bt.activeEcuTx, bt.activeEcuRx);
      if (!ok) {
        onLog('ERR', 'ECU 会话建立失败');
        _running = false;
        return;
      }

      // ★ STPPMA 芯片端心跳: 不占蓝牙带宽, 轮询期间保持运行
      // ★ Timer 心跳: 会竞争 busLock + 破坏 header 缓存, 必须暂停
      if (!bt.stnAvailable) {
        BtManager.instance.stopHeartbeat();
        onLog('SYS', '⏸ Timer 心跳暂停 (轮询保活)');
      } else {
        onLog('SYS', '⚡ STPPMA 芯片心跳运行中 (零开销)');
      }

      // ═══ 3-Tier 降级策略 ═══
      //   Tier 1: SID 0x2C 动态 DID → 20 Hz (1 次往返读全部)
      //   Tier 2: SID 0x22 Multi-DID → ~5 Hz (分批往返)
      //   Tier 3: SID 0x22 逐个读取  → ~2 Hz (N 次往返)

      final allReal = pids.where((p) => p.id != 'latency' && p.hasUds).toList();

      // ── Tier 1: 尝试动态 DID ──
      _dynamicDidOk = await _setupDynamicDid(bt, allReal);
      if (_dynamicDidOk) {
        onLog('SYS', '✅ Tier 1: 动态 DID 模式 (20 Hz)');
      } else {
        // ── Tier 2: 尝试 Multi-DID ──
        _multiDidOk = await BtManager.instance.testMultiDidSupport();
        onLog('SYS', _multiDidOk
            ? '⚠ Tier 2: Multi-DID 模式 (~5 Hz)'
            : '⚠ Tier 3: 逐个 DID 模式 (~2 Hz)');
      }
    }

    // ═══ OBD-II 模式 ═══
    if (bt.commMode == CommMode.obd2) {
      // ★ 构建轮询顺序: 高频 PID (RPM/车速/油门) 多次出现
      _obd2PollOrder = _buildObd2PollOrder(pids.where((p) => p.hasObd2).toList());
      onLog('SYS', '★ OBD-II 轮询: ${_obd2PollOrder.length} 步/周期');
      for (final p in _obd2PollOrder) {
        onLog('SYS', '  ${p.shortName.padRight(8)} → ${p.obd2Cmd}');
      }
    }

    _pollLoop();
  }

  /// ★ OBD-II 轮询顺序缓存
  List<ObdPid> _obd2PollOrder = [];

  /// 构建 OBD-II 轮询顺序
  /// 策略: 高频参数 (RPM/车速/节气门) 多次出现以提升刷新率
  /// 类似 OBDProxy 的 16-PID 循环: RPM×4, Speed×3, Throttle×3, 其他各1
  List<ObdPid> _buildObd2PollOrder(List<ObdPid> pids) {
    if (pids.isEmpty) return [];

    // 按语义分组 (匹配 aligned IDs)
    ObdPid? rpm, speed, throttle, coolant, map, iat, timing, load, afr;
    final others = <ObdPid>[];
    for (final p in pids) {
      if (p.obd2Pid == '0C' || p.id.contains('rpm')) { rpm = p; }
      else if (p.obd2Pid == '0D' || p.id.contains('speed')) { speed = p; }
      else if (p.obd2Pid == '11' || p.id.contains('accel') || p.id.contains('throttle')) { throttle = p; }
      else if (p.obd2Pid == '05' || p.id.contains('coolant')) { coolant = p; }
      else if (p.obd2Pid == '0B' || p.id.contains('boost') || p.id.contains('map')) { map = p; }
      else if (p.obd2Pid == '0F' || p.id.contains('iat')) { iat = p; }
      else if (p.obd2Pid == '0E' || p.id.contains('ign')) { timing = p; }
      else if (p.obd2Pid == '04' && p.id.contains('load')) { load = p; }
      else if (p.obd2Pid == '04' && p.id.contains('torque')) { /* torque shares 0104, will be parsed from load response */ }
      else if (p.obd2Pid == '44' || p.id.contains('lambda') || p.id.contains('afr')) { afr = p; }
      else { others.add(p); }
    }

    // ★ DKE 式交叉轮询: RPM/Speed/Throttle 高频交叉 + 其他低频
    //    OBDProxy 原版: 010C,010D,0111, 010C,010D,0111, 010C,010D,0111, 010C,0105,010B,...
    //    效果: 每个 PID 响应立即推 HUD (~55ms), RPM/车速/油门 ≈6Hz 独立刷新
    final rpmSlots = rpm != null ? 4 : 0;
    final speedSlots = speed != null ? 3 : 0;
    final throttleSlots = throttle != null ? 3 : 0;
    final maxHighFreq = [rpmSlots, speedSlots, throttleSlots]
        .where((n) => n > 0)
        .fold<int>(0, (a, b) => a > b ? a : b);

    final order = <ObdPid>[];
    // 交叉插入高频 PID: 每轮各取1个, 直到耗尽
    for (int i = 0; i < maxHighFreq; i++) {
      if (i < rpmSlots) order.add(rpm!);
      if (i < speedSlots) order.add(speed!);
      if (i < throttleSlots) order.add(throttle!);
    }
    // 低频段 (每周期1次)
    if (coolant != null) order.add(coolant);
    if (map != null) order.add(map);
    if (iat != null) order.add(iat);
    if (timing != null) order.add(timing);
    if (load != null) order.add(load);
    // ★ 扭矩与负荷共享 0104: 在 load 后面插入 torque, 用同一响应数据不同公式解析
    ObdPid? torque;
    for (final p in pids) {
      if (p.obd2Pid == '04' && p.id.contains('torque')) { torque = p; break; }
    }
    if (torque != null) order.add(torque);
    if (afr != null) order.add(afr);
    order.addAll(others);

    return order;
  }

  // ════════════════════════════════════════════════════════
  // ★ 动态组合 DID 设置 (SID 0x2C)
  // ════════════════════════════════════════════════════════

  /// 设置动态组合 DID — 将多个源 DID 焊接为 0xF300
  Future<bool> _setupDynamicDid(BtManager bt, List<ObdPid> pids) async {
    // Step 1: 过滤适合动态组合的 DID (canBeDynamicDid)
    final candidates = pids.where((p) => p.canBeDynamicDid).toList();
    // ★ 结构性排除: uint32be 等无法放入动态 DID 的 PID → 需要补充轮询
    _excludedPids = pids.where((p) => !p.canBeDynamicDid && p.hasUds).toList();
    if (candidates.isEmpty) {
      onLog('SYS', '  动态 DID: 无候选 DID');
      return false;
    }
    onLog('SYS', '  STPX: ${bt.stpxAvailable ? "✅ 可用" : "❌ 不可用 (可能影响多帧发送)"}');

    // Step 2: 逐个验证每个源 DID 可读 + 确认响应长度 (带重试)
    onLog('SYS', '  验证源 DID 可读性 (${candidates.length} 个):');
    final verified = <ObdPid>[];
    for (final pid in candidates) {
      bool ok = false;
      for (int attempt = 0; attempt < 2 && !ok; attempt++) {
        final resp = await bt.sendUdsData(bt.activeEcuTx, bt.activeEcuRx, pid.udsCmd, timeout: 1.5);
        if (resp != null && resp.length >= 3 && resp[0] == 0x62) {
          final actualLen = resp.length - 3;
          if (actualLen >= pid.udsTotalBytes) {
            verified.add(pid);
            ok = true;
            onLog('SYS', '    ${pid.shortName.padRight(8)} ✅ ${pid.udsTotalBytes}B (ECU返${actualLen}B)${attempt > 0 ? " (重试)" : ""}');
          } else {
            if (attempt == 0) continue; // 重试
            onLog('WARN', '    ${pid.shortName.padRight(8)} ⚠ 长度不足 '
                '(需要${pid.udsTotalBytes}, 实际$actualLen) → 跳过');
          }
        } else {
          if (attempt == 0) {
            onLog('SYS', '    ${pid.shortName.padRight(8)} ⚠ 首次失败, 重试...');
            continue;
          }
          onLog('WARN', '    ${pid.shortName.padRight(8)} ❌ 不可读 (2次) → 跳过');
        }
      }
      // ★ 验证失败的 PID 不加入 _excludedPids — 不补充轮询
      //   (ECU 不响应的 DID, 轮询也会超时, 白白浪费带宽)
    }

    if (verified.isEmpty) {
      onLog('SYS', '  动态 DID: 无可用源 DID');
      return false;
    }

    if (_excludedPids.isNotEmpty) {
      onLog('SYS', '  ⚠ ${_excludedPids.length} 个结构性排除 (补充轮询):');
      for (final p in _excludedPids) {
        onLog('SYS', '    ${p.shortName} (${p.parseMode.name})');
      }
    }

    // Step 4: 计算总数据长度
    int totalLen = 0;
    for (final pid in verified) {
      totalLen += pid.udsTotalBytes;
    }
    onLog('SYS', '  动态 DID: ${verified.length} 个源, 共 $totalLen 字节');

    // Step 5: 构建源定义列表
    final sources = verified.map((p) => DynamicDidSource.fromPid(p)).toList();

    // Step 6: 发送定义命令 (内部先清除再创建)
    final ok = await bt.sendUdsDynamicDefine(bt.activeEcuTx, bt.activeEcuRx, _targetDid, sources);

    if (ok) {
      // Step 6: 记录拆分映射
      _didSlices.clear();
      int offset = 0;
      for (final pid in verified) {
        _didSlices.add(_DidSlice(pid, offset, pid.udsTotalBytes));
        offset += pid.udsTotalBytes;
      }
      _dynamicDidTotalLen = totalLen;

      // Step 7: 验证读取 — 确认 F300 实际可读
      final testPayload = await bt.readDynamicDid(_targetDid, timeout: 1.0);
      if (testPayload == null || testPayload.length < totalLen) {
        onLog('WARN', '  ⚠ F300 验证读取失败 (${testPayload?.length ?? 0}B < ${totalLen}B)');
        _didSlices.clear();
        _dynamicDidTotalLen = 0;
        return false;
      }
      onLog('SYS', '  ✅ F300 验证读取成功 (${testPayload.length}B)');
    }

    return ok;
  }

  // ════════════════════════════════════════════════════════
  // UDS 优先级轮询 — 显式定义慢变化参数
  // ════════════════════════════════════════════════════════

  /// 慢变化 DID (温度/压力/凸轮/空燃比AFR) → 每 N 周期读一次
  /// ★ 从 profile 动态读取 (默认: 内置 C63s 慢变化集合)
  Set<String> get _slowChangeIds => BtManager.instance.slowChangePidIds;

  /// 低频 DID 的读取间隔 (每 N 个周期读一次)
  /// ★ 从 profile 动态读取 (默认 3)
  int get _lowFreqInterval => BtManager.instance.slowChangeInterval;

  // ════════════════════════════════════════════════════════
  // 轮询循环 — 3-Tier 降级策略
  // ════════════════════════════════════════════════════════

  void _pollLoop() async {
    final bt = BtManager.instance;
    int cycle = 0;
    int testerPresentCounter = 0;

    // ★ 预分组: 只做一次, 不在循环中重复计算
    final allReal = selectedPids.where((p) {
      if (p.id == 'latency') return false;
      return p.hasUds;
    }).toList();

    final highFreq = allReal.where((p) => !_slowChangeIds.contains(p.id)).toList();
    final lowFreq  = allReal.where((p) => _slowChangeIds.contains(p.id)).toList();

    if (_dynamicDidOk) {
      onLog('SYS', '★ 动态 DID 模式: ${_didSlices.length} 个参数 → 1 次往返/周期');
      if (_excludedPids.isNotEmpty) {
        onLog('SYS', '  + ${_excludedPids.length} 个补充轮询 (每$_lowFreqInterval周期)');
      }
    } else {
      onLog('SYS', '优先级分组: ${highFreq.length} 高频 + ${lowFreq.length} 低频 (每$_lowFreqInterval周期)');
    }

    // ★ 诊断: 测量周期间隙 (前 30 cycle)
    DateTime? prevCycleEnd;
    int diagGapSum = 0, diagBtSum = 0, diagCount = 0;

    // ★ DynDID 连续失败计数 (需 3 次连续失败才降级)
    int dynDidConsecFails = 0;
    const dynDidFailThreshold = 3;

    // ★ DynDID 降级恢复
    int degradedAtCycle = 0;               // 降级发生的周期
    int dynDidRecoverAttempts = 0;         // 已尝试恢复次数
    const dynDidRecoverInterval = 600;      // 每 600 周期尝试一次 (~60-120s)
    const dynDidMaxRecoverAttempts = 3;     // 最多尝试 3 次

    // ★ 持续 Hz 监视 (每 100 周期报告一次)
    int hzWindowStart = 0;
    int hzWindowCycles = 0;

    while (_running && bt.isConnected) {
      final cycleStart = DateTime.now();

      // ★ 诊断: 测量 event loop gap (从上一周期结束到本周期开始)
      if (prevCycleEnd != null && cycle < 30) {
        final gap = cycleStart.difference(prevCycleEnd).inMilliseconds;
        diagGapSum += gap;
        if (cycle < 5) {
          onLog('SYS', '  [diag] cycle $cycle: gap=${gap}ms');
        }
      }

      final timeMs = cycleStart.difference(_startTime!).inMilliseconds;
      final snapshot = <String, double>{};

      // ★ 轮询周期标记 (trace)
      // bt.tr('--- cycle $cycle ---');

      // ═══ OBD-II 模式: 轮询列表逐项读取 ═══
      if (bt.commMode == CommMode.obd2) {
        if (_obd2PollOrder.isEmpty) {
          // 无可用 PID: 休眠后重试
          await Future.delayed(const Duration(milliseconds: 200));
          prevCycleEnd = DateTime.now();
          cycle++;
          continue;
        }
        final t0 = DateTime.now();
        int okCount = 0, failCount = 0;
        final failPids = <String>[];
        final pidTimings = <String, int>{}; // shortName → μs

        for (final pid in _obd2PollOrder) {
          if (!_running || !bt.isConnected) break;

          final tPid = DateTime.now();
          final data = await bt.sendObd2Pid(pid, timeout: 0.2);
          final pidUs = DateTime.now().difference(tPid).inMicroseconds;
          pidTimings[pid.shortName] = pidUs;

          if (data != null && data.isNotEmpty) {
            final value = pid.parseRaw(data);
            if (value != null) {
              snapshot[pid.id] = value;
              dataPoints.add(DataPoint(timeMs, pid.id, value));
              okCount++;
              // ★ 增量推送: 每个 PID 响应立即刷新 HUD (~18Hz), 消除卡顿
              onData(PollSnapshot(timeMs, {pid.id: value}));
            } else {
              failCount++;
              failPids.add(pid.shortName);
            }
          } else {
            failCount++;
            failPids.add(pid.shortName);
          }
        }

        final elapsed = DateTime.now().difference(t0).inMilliseconds;
        onLatency(elapsed);

        // ★ 前 5 周期: 最详细 (每个 PID 值 + 耗时)
        if (cycle < 5) {
          final parts = <String>[];
          for (final p in _obd2PollOrder) {
            final v = snapshot[p.id];
            final us = pidTimings[p.shortName] ?? 0;
            if (v != null) {
              parts.add('${p.shortName}=${p.formatValue(v)}');
            }
          }
          final unique = parts.toSet().join(' ');
          final timingStr = pidTimings.entries
              .map((e) => '${e.key}:${(e.value / 1000).toStringAsFixed(1)}ms')
              .join(' ');
          onLog('OBD', 'cy$cycle ${elapsed}ms OK:$okCount/$failCount | $unique');
          onLog('OBD', 'cy$cycle timings: $timingStr');
        }
        // ★ 周期 5-30: 简洁版 (值+失败)
        else if (cycle < 30) {
          final vals = <String>[];
          for (final p in _obd2PollOrder) {
            final v = snapshot[p.id];
            if (v != null) vals.add('${p.shortName}=${p.formatValue(v)}');
          }
          final line = vals.toSet().join(' ');
          final failLine = failPids.isNotEmpty ? ' FAIL:${failPids.join(",")}' : '';
          onLog('OBD', 'cy$cycle ${elapsed}ms $line$failLine');
        }
        // ★ 每 10 周期: 摘要 + Hz
        else if (cycle % 10 == 0) {
          final hz = cycle > 0 && timeMs > 0
              ? (cycle * 1000.0 / timeMs).toStringAsFixed(1)
              : '?';
          final failLine = failPids.isNotEmpty ? ' FAIL:${failPids.join(",")}' : '';
          onLog('OBD', 'cy$cycle ${hz}Hz ${elapsed}ms OK:$okCount/$failCount$failLine');
        }

        // ★ 累计失败统计
        _totalObd2Ok += okCount;
        _totalObd2Fail += failCount;
        _totalObd2Cycles++;
        if (elapsed > _maxCycleElapsedMs) _maxCycleElapsedMs = elapsed;

        // ★ 提交快照
        if (snapshot.isNotEmpty) {
          onData(PollSnapshot(timeMs, snapshot));
        }

        prevCycleEnd = DateTime.now();
        cycle++;
        continue; // ★ 跳过 UDS 逻辑
      }

      if (_dynamicDidOk) {
        // ★★★ Tier 1: 动态 DID 模式 — 一次请求读全部 (12+ Hz) ★★★
        final payload = await bt.readDynamicDid(_targetDid, timeout: 0.5);

        if (payload != null && payload.length >= _dynamicDidTotalLen) {
          dynDidConsecFails = 0; // ★ 成功 → 重置计数
          for (final slice in _didSlices) {
            if (slice.offset + slice.length <= payload.length) {
              final bytes = payload.sublist(slice.offset, slice.offset + slice.length);
              final value = slice.pid.parseRaw(bytes);
              if (value != null) {
                snapshot[slice.pid.id] = value;
                dataPoints.add(DataPoint(timeMs, slice.pid.id, value));
              }
            }
          }
        } else if (payload == null && cycle > 10) {
          dynDidConsecFails++;
          if (dynDidConsecFails >= dynDidFailThreshold) {
            // ★ 连续 N 次失败才降级 (非单次)
            onLog('WARN', '⚠ DynDID 连续 $dynDidConsecFails 次失败, 降级');
            _dynamicDidOk = false;
            degradedAtCycle = cycle;       // ★ 记录降级时刻
            dynDidRecoverAttempts = 0;     // ★ 重置恢复计数
            await bt.clearDynamicDid(bt.activeEcuTx, bt.activeEcuRx, _targetDid);
            // ★ 存储降级事件
            BtManager.instance.hudDiagResult =
                '⚠ DynDID 降級 @ cycle $cycle (連續$dynDidConsecFails次失敗)\n'
                '降級前 Hz ≈ ${hzWindowCycles > 0 ? (1000.0 * hzWindowCycles / (timeMs - hzWindowStart)).toStringAsFixed(1) : "?"}';
          }
        }

        // ★ 补充轮询: 未纳入动态 DID 的 PID (每 N 周期逐个读取)
        if (_excludedPids.isNotEmpty && cycle % _lowFreqInterval == 0) {
          for (final pid in _excludedPids) {
            if (!_running) break;
            final cmd = pid.udsCmd;
            if (cmd.isEmpty) continue;
            final data = await bt.sendUdsData(
              pid.udsEcuTx, pid.udsEcuRx, cmd, timeout: 0.8,
            );
            if (data != null && data.length >= 3) {
              final value = pid.parseRaw(data.sublist(3));
              if (value != null) {
                snapshot[pid.id] = value;
                dataPoints.add(DataPoint(timeMs, pid.id, value));
              }
            }
          }
        }

        // ★ TesterPresent: STPPMA 芯片端自动发送 (零开销)
        // 非 STN 设备降级: 每 40 周期手动发一次
        if (!bt.stnAvailable) {
          testerPresentCounter++;
          if (testerPresentCounter >= 40) {
            testerPresentCounter = 0;
            await bt.sendUdsData(bt.activeEcuTx, bt.activeEcuRx, '3E00', timeout: 0.5);
          }
        }

      } else {
        // ── Tier 2/3: Multi-DID 或逐个 (现有逻辑) ──
        final thisRound = <ObdPid>[
          ...highFreq,
          if (cycle % _lowFreqInterval == 0) ...lowFreq,
        ];

        if (_multiDidOk && thisRound.length > 1) {
          // ★★★ Tier 2: Multi-DID 批量 ★★★
          final batchResult = await bt.sendUdsMultiDid(
            thisRound, timeout: 2.0, debug: cycle < 3,
          );
          if (batchResult != null) {
            if (cycle == 0) onLog('SYS', '▶ Multi-DID OK: ${batchResult.length} DIDs');
            for (final pid in thisRound) {
              final bytes = batchResult[pid.id];
              if (bytes != null) {
                final value = pid.parseRaw(bytes);
                if (value != null) {
                  snapshot[pid.id] = value;
                  dataPoints.add(DataPoint(timeMs, pid.id, value));
                }
              }
            }
          } else {
            // Multi-DID 失败 → 降级为逐个读取 (本轮)
            if (cycle < 5) onLog('SYS', '⚠ Multi-DID null → 降级逐个 (cycle $cycle)');
            await _pollIndividual(bt, thisRound, timeMs, snapshot);
          }
        } else if (bt.stpxAvailable && thisRound.length > 1) {
          // ★★★ Tier 3a: STBC 批量 STPX (ECU 不支持 Multi-DID, 但适配器有 STN) ★★★
          // 多个 STPX 通过管道合并为 1-2 次蓝牙往返
          final batchResult = await bt.sendUdsDataBatchStpx(
            thisRound, timeout: 2.0,
          );
          if (batchResult != null) {
            if (cycle == 0) onLog('SYS', '▶ STBC 批量 STPX: ${batchResult.length} DIDs');
            for (final pid in thisRound) {
              final bytes = batchResult[pid.id];
              if (bytes != null) {
                final value = pid.parseRaw(bytes);
                if (value != null) {
                  snapshot[pid.id] = value;
                  dataPoints.add(DataPoint(timeMs, pid.id, value));
                }
              }
            }
          } else {
            // 降级: 逐个 STPX
            await _pollIndividual(bt, thisRound, timeMs, snapshot);
          }
        } else {
          // ★★★ Tier 3b: 逐个读取 (ELM327 兼容模式) ★★★
          await _pollIndividual(bt, thisRound, timeMs, snapshot);
        }

        // ★ TesterPresent: STN 芯片由 STPPMA 自动处理
        if (!bt.stnAvailable) {
          testerPresentCounter++;
          if (testerPresentCounter >= 40) {
            testerPresentCounter = 0;
            await bt.sendUdsData(bt.activeEcuTx, bt.activeEcuRx, '3E00', timeout: 0.5);
          }
        }

        // ★ DynDID 降级恢复尝试
        if (degradedAtCycle > 0
            && dynDidRecoverAttempts < dynDidMaxRecoverAttempts
            && cycle > degradedAtCycle
            && (cycle - degradedAtCycle) % dynDidRecoverInterval == 0) {
          dynDidRecoverAttempts++;
          onLog('SYS', '🔄 DynDID 恢复尝试 '
              '#$dynDidRecoverAttempts/$dynDidMaxRecoverAttempts '
              '(降级后 ${cycle - degradedAtCycle} 周期)');

          final recovered = await _tryRecoverDynDid(bt);
          if (recovered) {
            onLog('SYS', '✅ DynDID 恢复成功! 切回 Tier 1 (20 Hz)');
            degradedAtCycle = 0;
            dynDidConsecFails = 0;
            dynDidRecoverAttempts = 0;
          } else {
            onLog('SYS', '  DynDID 恢复失败'
                '${dynDidRecoverAttempts >= dynDidMaxRecoverAttempts
                    ? " (已达上限, 不再尝试)" : ""}');
          }
        }
      }

      // 计算本轮延迟
      final btDoneTime = DateTime.now();
      final latency = btDoneTime.difference(cycleStart).inMilliseconds;

      // ★ 诊断: 记录 BT 耗时
      if (cycle < 30) {
        diagBtSum += latency;
        diagCount++;
        if (cycle < 5) {
          onLog('SYS', '  [diag] cycle $cycle: BT=${latency}ms');
        }
      }
      if (cycle == 29) {
        final avgGap = diagCount > 1 ? diagGapSum / (diagCount - 1) : 0;
        final avgBt = diagCount > 0 ? diagBtSum / diagCount : 0;
        final totalAvg = avgGap + avgBt;
        final estHz = totalAvg > 0 ? 1000.0 / totalAvg : 0;
        final buf = StringBuffer();
        buf.writeln('═══ HUD 轮询诊断 (30 cycle) ═══');
        buf.writeln('  DynDID参数: ${_didSlices.length}, 排除: ${_excludedPids.length}');
        buf.writeln('  avg BT:  ${avgBt.toStringAsFixed(1)}ms');
        buf.writeln('  avg gap: ${avgGap.toStringAsFixed(1)}ms');
        buf.writeln('  avg 总:  ${totalAvg.toStringAsFixed(1)}ms → ${estHz.toStringAsFixed(1)} Hz');
        if (avgGap > 20) {
          buf.writeln('  ⚠ gap 过大! event loop 阻塞 (UI 渲染?)');
        }
        if (_excludedPids.isNotEmpty) {
          buf.writeln('  ⚠ 排除列表:');
          for (final p in _excludedPids) {
            buf.writeln('    ${p.shortName}');
          }
        }
        buf.writeln('═════════════════════════════');
        final diagText = buf.toString();
        for (final line in diagText.split('\n')) {
          if (line.trim().isNotEmpty) onLog('SYS', line);
        }
        // ★ 持久存储: 退出 HUD 后在首页可查看
        BtManager.instance.hudDiagResult = diagText;
        // ★ 控制台输出: Xcode / Android Studio 可见
        // ignore: avoid_print
        print('[HUD-DIAG]\n$diagText');
      }

      // Latency 作为虚拟 PID
      if (selectedPids.any((p) => p.id == 'latency')) {
        snapshot['latency'] = latency.toDouble();
        dataPoints.add(DataPoint(timeMs, 'latency', latency.toDouble()));
      }

      onLatency(latency);
      if (snapshot.isNotEmpty) {
        onData(PollSnapshot(timeMs, snapshot));
      }

      cycle++;
      hzWindowCycles++;

      // ★ 持续 Hz 监视: 每 100 周期 (~3秒) 检查一次
      final windowElapsed = timeMs - hzWindowStart;
      if (hzWindowCycles >= 100 && windowElapsed > 0) {
        final windowHz = hzWindowCycles * 1000.0 / windowElapsed;
        // ignore: avoid_print
        print('[HUD-Hz] cycle $cycle: ${windowHz.toStringAsFixed(1)} Hz dynOk=$_dynamicDidOk fails=$dynDidConsecFails excl=${_excludedPids.length}');
        // ★ Hz 低于 15 时记录详情
        if (windowHz < 15) {
          final msg = '⚠ Hz=${windowHz.toStringAsFixed(1)} @ cycle $cycle | '
              'dynOk=$_dynamicDidOk fails=$dynDidConsecFails excl=${_excludedPids.length}';
          onLog('WARN', msg);
          BtManager.instance.hudDiagResult =
              '${BtManager.instance.hudDiagResult ?? ''}\n$msg';
        }
        hzWindowStart = timeMs;
        hzWindowCycles = 0;
      }

      // ★ Tier 1: readDynamicDid 内部 await _rxCompleter 等待 ECU 响应 (~33ms),
      //   此期间 event loop 空闲, UI 帧回调自然获得执行时间 → 无需额外 yield
      // ★ Tier 2/3: 每个 sendUdsData 同样内含 await → UI 也有执行时间
      // ★ 仅当单周期 <2ms (不可能发生) 时保护性 yield, 防止 UI 饿死
      if (latency < 2) {
        await Future.delayed(Duration.zero);
      }

      prevCycleEnd = DateTime.now();

      // ★ 防止无限增长: 保留最近 60 秒数据 (约 60s × 20Hz × 9pid = 10800 点)
      if (dataPoints.length > 15000) {
        dataPoints.removeRange(0, dataPoints.length - 12000);
      }
    }

    if (_running) {
      // ★ 如果正在重连, 不立即置 _running=false — 给重连恢复留窗口
      if (BtManager.instance.isReconnecting) {
        onLog('SYS', '⚠ 连接断开, 等待自动重连...');
      } else {
        _running = false;
        _connectionDrops++;
        onLog('SYS', '⚠ 连接断开，录制已停止');
      }
    }
  }

  // ════════════════════════════════════════════════════════
  // ★ DynDID 降级恢复 (Tier 2/3 → Tier 1)
  // ════════════════════════════════════════════════════════

  /// 尝试恢复动态 DID — 失败不影响当前 Tier 2/3 轮询
  Future<bool> _tryRecoverDynDid(BtManager bt) async {
    try {
      // Step 1: 确保 UDS 扩展会话仍有效
      final sessionOk = await bt.ensureSession(bt.activeEcuTx, bt.activeEcuRx);
      if (!sessionOk) return false;

      // Step 2: 重新设置 DynDID (内部: 清除旧定义 → 验证源 DID → 定义 → 确认)
      final allReal = selectedPids.where((p) {
        if (p.id == 'latency') return false;
        return p.hasUds;
      }).toList();

      final ok = await _setupDynamicDid(bt, allReal);
      if (ok) {
        _dynamicDidOk = true;
        return true;
      }
      return false;
    } catch (e) {
      onLog('ERR', '  DynDID 恢复异常: $e');
      return false;
    }
  }

  // ════════════════════════════════════════════════════════
  // ★ 逐个 DID 轮询 (单锁优化)
  // ════════════════════════════════════════════════════════

  /// 逐个读取 DID, 但共享一个 busLock (避免 N 次 lock acquire/release 开销)
  Future<void> _pollIndividual(
    BtManager bt,
    List<ObdPid> pids,
    int timeMs,
    Map<String, double> snapshot,
  ) async {
    // sendUdsData 内部已有 busLock + STPX 优化
    // 对于同一 ECU 的连续读取, STPX 路径不需要 setHeader → 每次省 1 往返
    for (final pid in pids) {
      if (!_running) break;
      final cmd = pid.udsCmd;
      if (cmd.isEmpty) continue;
      final data = await bt.sendUdsData(
        pid.udsEcuTx, pid.udsEcuRx, cmd, timeout: 0.8,
      );
      if (data != null && data.length >= 3) {
        final value = pid.parseRaw(data.sublist(3));
        if (value != null) {
          snapshot[pid.id] = value;
          dataPoints.add(DataPoint(timeMs, pid.id, value));
        }
      }
    }
  }

  // ════════════════════════════════════════════════════════
  // Demo 模式
  // ════════════════════════════════════════════════════════

  void startDemo(List<ObdPid> pids) {
    if (_running) return;
    if (pids.isEmpty) {
      onLog('ERR', '请先选择至少一个数据项');
      return;
    }

    selectedPids = List.of(pids);
    dataPoints.clear();
    _startTime = DateTime.now();
    _running = true;
    _demo = true;

    onLog('SYS', '▶ DEMO 模式启动 — ${pids.length} 项');
    _demoLoop();
  }

  void _demoLoop() async {
    final rng = math.Random();
    final sim = _DemoSimulator();

    while (_running) {
      final cycleStart = DateTime.now();
      final timeMs = cycleStart.difference(_startTime!).inMilliseconds;

      sim.tick(timeMs);

      final snapshot = <String, double>{};
      // ★ 仅为已选 PID 生成模拟数据
      for (final pid in selectedPids) {
        final val = sim.generate(pid.id, rng);
        if (val != null) {
          snapshot[pid.id] = val;
          dataPoints.add(DataPoint(timeMs, pid.id, val));
        }
      }

      final latency = rng.nextInt(20) + 30;
      if (selectedPids.any((p) => p.id == 'latency')) {
        snapshot['latency'] = latency.toDouble();
        dataPoints.add(DataPoint(timeMs, 'latency', latency.toDouble()));
      }

      onLatency(latency);
      if (snapshot.isNotEmpty) {
        onData(PollSnapshot(timeMs, snapshot));
      }

      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  // ════════════════════════════════════════════════════════
  // ★ 重连后恢复轮询
  // ════════════════════════════════════════════════════════

  /// 重连成功后: 重新建立会话 + 重启 _pollLoop
  Future<void> _resumeAfterReconnect() async {
    final bt = BtManager.instance;
    if (!bt.isConnected || selectedPids.isEmpty) return;

    _running = true;
    onLog('SYS', '🔄 重连恢复: 重建轮询...');

    // ═══ OBD-II 模式: 无需会话管理, 直接重启轮询 ═══
    if (bt.commMode == CommMode.obd2) {
      onLog('SYS', '  OBD-II 模式: 直接恢复轮询');
      _pollLoop();
      return;
    }

    // ★ 重新建立 UDS 会话
    if (bt.commMode == CommMode.uds) {
      final ok = await bt.ensureSession(bt.activeEcuTx, bt.activeEcuRx);
      if (!ok) {
        onLog('ERR', '重连后 UDS 会话建立失败');
        _running = false;
        return;
      }

      // ★ 非 STN 设备: 暂停 Timer 心跳 (同 start 逻辑)
      if (!bt.stnAvailable) {
        bt.stopHeartbeat();
      }

      // ★ 尝试恢复 Tier 1 DynDID
      final allReal = selectedPids.where((p) {
        if (p.id == 'latency') return false;
        return p.hasUds;
      }).toList();

      _dynamicDidOk = await _setupDynamicDid(bt, allReal);
      if (_dynamicDidOk) {
        onLog('SYS', '✅ 重连恢复: Tier 1 DynDID 模式');
      } else {
        _multiDidOk = await bt.testMultiDidSupport();
        onLog('SYS', _multiDidOk
            ? '⚠ 重连恢复: Tier 2 Multi-DID 模式'
            : '⚠ 重连恢复: Tier 3 逐个模式');
      }
    }

    // ★ 重启轮询循环
    _pollLoop();
  }

  /// 停止
  void stop() {
    if (!_running) return;
    _running = false;
    _reconnectSub?.cancel();
    _reconnectSub = null;

    // ── 会话摘要 ──
    final durSec = durationMs / 1000.0;
    final modeLabel = _demo ? 'DEMO' : (BtManager.instance.commMode == CommMode.obd2 ? 'OBD-II' : 'UDS');
    onLog('SYS', '══════════════════════════════════════');
    onLog('SYS', '⏹ 会话结束 — $modeLabel 模式');
    onLog('SYS', '  总运行: ${durSec.toStringAsFixed(1)}s');
    onLog('SYS', '  总采样: $sampleCount 点');
    if (_totalObd2Cycles > 0) {
      final total = _totalObd2Ok + _totalObd2Fail;
      final rate = total > 0 ? (_totalObd2Ok * 100.0 / total).toStringAsFixed(1) : '0';
      onLog('SYS', '  OBD-II: $_totalObd2Cycles 周期, $_totalObd2Ok OK / $_totalObd2Fail FAIL ($rate%)');
      final avgHz = durSec > 0 ? (_totalObd2Cycles / durSec).toStringAsFixed(1) : '?';
      onLog('SYS', '  平均: $avgHz Hz, 最大周期耗时: ${_maxCycleElapsedMs}ms');
    }
    if (_connectionDrops > 0) {
      onLog('SYS', '  连接断开: $_connectionDrops 次');
    }
    if (BtManager.instance.hudDiagResult != null) {
      onLog('SYS', '  诊断: ${BtManager.instance.hudDiagResult}');
    }
    onLog('SYS', '══════════════════════════════════════');

    // UDS: 清理动态 DID + 恢复心跳
    if (!_demo && BtManager.instance.commMode == CommMode.uds) {
      // ★ 清除远端动态 DID 定义 (异步, 不阻塞 UI)
      if (_dynamicDidOk) {
        BtManager.instance.clearDynamicDid(BtManager.instance.activeEcuTx, BtManager.instance.activeEcuRx, _targetDid).then((_) {
          _dynamicDidOk = false;
          _didSlices.clear();
          _excludedPids.clear();
          _dynamicDidTotalLen = 0;
        });
      }
      // ★ STPPMA 心跳一直在运行, 无需恢复
      // Timer 心跳 (非 STN) 需要重新启动
      if (!BtManager.instance.stnAvailable) {
        BtManager.instance.startHeartbeat();
      }
    }
    _demo = false;
  }

  /// 清空
  void clearData() {
    dataPoints.clear();
    _startTime = null;
  }

  /// 获取指定 PID 的数据点
  List<DataPoint> pointsFor(String pidId) =>
      dataPoints.where((d) => d.pidId == pidId).toList();
}

// ════════════════════════════════════════════════════════════════
// _DidSlice — 动态组合 DID 的拆分映射
// ════════════════════════════════════════════════════════════════
// 描述虚拟 DID 0xF300 响应数据中每个源 DID 的位置和长度
// 用于从一块连续字节中拆分出各参数的原始数据

class _DidSlice {
  final ObdPid pid;
  final int offset;  // 在组合数据中的字节偏移
  final int length;  // 字节数
  const _DidSlice(this.pid, this.offset, this.length);
}

// ════════════════════════════════════════════════════════════════
// Demo 数据模拟器
// ════════════════════════════════════════════════════════════════

enum _Phase { idle, launch, pull, cruise, coast, wot }

class _DemoSimulator {
  _Phase phase = _Phase.idle;
  int phaseStartMs = 0;

  double rpm = 780, speed = 0, throttle = 0, torque = 0;
  double load = 15, iat = 38, coolant = 88, maf = 12;
  double timing = 18, fuelPres = 55, mapKpa = 101;
  double fuelHp = 12, knockAvg = 0, lambdaB1 = 1.0;

  static const _dur = {
    _Phase.idle: 3500, _Phase.launch: 3000, _Phase.pull: 5000,
    _Phase.cruise: 4000, _Phase.coast: 4000, _Phase.wot: 10000,
  };

  void tick(int timeMs) {
    final elapsed = timeMs - phaseStartMs;
    final dur = _dur[phase]!;
    if (elapsed >= dur) {
      phaseStartMs = timeMs;
      phase = switch (phase) {
        _Phase.idle => _Phase.launch, _Phase.launch => _Phase.pull,
        _Phase.pull => _Phase.cruise, _Phase.cruise => _Phase.coast,
        _Phase.coast => _Phase.wot, _Phase.wot => _Phase.idle,
      };
    }
    final t = elapsed / dur.toDouble();
    switch (phase) {
      case _Phase.idle:
        // ★ 怠速: 燃圧降低 → 触发燃圧喪失
        fuelHp = _l(3.0, 1.2, t);  // ★ dangerLow=2, 悠闲跌破
        knockAvg = 0;
        lambdaB1 = 1.0;
        _s(0.08, rpm: 780, speed: 0, throttle: 0, torque: 50,
          load: 15, maf: 12, timing: 18, fuelPres: 55, iat: 38,
          coolant: (coolant - 0.02).clamp(85, 93), mapKpa: 35);
      case _Phase.launch:
        fuelHp = _l(1.2, 8, t);    // 燃圧恢复
        knockAvg = 0;
        lambdaB1 = _l(1.0, 0.85, t);
        _s(0.12, rpm: _l(1200, 4500, t), speed: _l(0, 60, t),
          throttle: _l(70, 100, t), torque: _l(200, 750, t),
          load: _l(40, 95, t), maf: _l(50, 320, t), timing: _l(16, 8, t),
          fuelPres: _l(55, 95, t), iat: _l(38, 48, t),
          coolant: (coolant + 0.05).clamp(85, 100), mapKpa: _l(120, 220, t));
      case _Phase.pull:
        // ★ 高負荷: 退点火激増 → 非常事態, λ逸脱 → 空燃比異常
        fuelHp = _l(8, 18, t);
        knockAvg = _l(1.0, 6.0, t);                // ★ dangerHigh=4.5, 悠闲突破
        lambdaB1 = t < 0.5 ? _l(0.85, 0.68, t * 2) : _l(0.68, 0.82, (t - 0.5) * 2);  // ★ dangerLow=0.72
        _s(0.18, rpm: _l(5200, 7200, math.sin(t * math.pi * 1.5).abs()),
          speed: _l(60, 220, t), throttle: 100,
          torque: _l(750, 820, t), load: _l(95, 100, t), maf: _l(320, 480, t),
          timing: _l(8, 4, t), fuelPres: _l(95, 110, t), iat: _l(48, 62, t),
          coolant: (coolant + 0.12).clamp(85, 103), mapKpa: _l(220, 250, t));
      case _Phase.cruise:
        // ★ 冷却過熱 → overheat
        final heatT = t < 0.6;
        final cc = heatT ? _l(103, 110, t / 0.6) : _l(110, 100, (t - 0.6) / 0.4);
        fuelHp = _l(18, 12, t);
        knockAvg = _l(6.0, 0.5, t);
        lambdaB1 = _l(0.82, 1.0, t);
        _s(0.06, rpm: 2400, speed: _l(220, 180, t * 0.3), throttle: 25,
          torque: 180, load: 30, maf: 60, timing: 22, fuelPres: 60,
          iat: _l(62, 50, t), coolant: cc, mapKpa: 130);
      case _Phase.coast:
        // ★ 燃圧再次降低 (为下一cycle的wot触发做准备)
        fuelHp = _l(12, 8, t);
        knockAvg = 0;
        lambdaB1 = 1.0;
        _s(0.08, rpm: _l(2400, 850, t), speed: _l(180, 20, t),
          throttle: 0, torque: _l(180, -20, t), load: _l(30, 5, t),
          maf: _l(60, 10, t), timing: _l(22, 20, t), fuelPres: _l(60, 50, t),
          iat: _l(50, 40, t), coolant: (coolant - 0.05).clamp(85, 100), mapKpa: _l(130, 50, t));
      case _Phase.wot:
        // ★ 地板油全力加速 10 秒 — 触発全力全開 Phase 動画
        // t: 0.0 → 1.0 over 10s
        // 模拟 1→2→3→4→5档 连续升档, 速度持续攀升 20→280 km/h
        final gear = (t * 5).floor().clamp(0, 4); // 0-4 = 5 個ギア
        final gearT = (t * 5) - gear; // ギア内進行度 0..1
        // RPM: 各ギアで 3500→7200 まで上昇, 升档で 3500 に戻る
        final gearRpm = _l(3500, 7200, gearT);
        fuelHp = _l(8, 20, t);
        knockAvg = _l(0, 2.0, t);     // 軽微なノック (danger未満)
        lambdaB1 = _l(1.0, 0.78, t);  // リッチ方向 (danger未満)
        _s(0.15, rpm: gearRpm, speed: _l(20, 280, t),
          throttle: 100, torque: _l(600, 850, t),
          load: _l(90, 100, t), maf: _l(250, 520, t),
          timing: _l(14, 6, t), fuelPres: _l(90, 115, t),
          iat: _l(42, 65, t),
          coolant: (coolant + 0.03).clamp(85, 99), // ★ 過熱しない (105未満)
          mapKpa: _l(180, 210, t)); // ★ boost ≈ 31-36 psi (danger=38 未満)
        // ★ 油門直接強制 101 — _s() の平滑化をバイパス
        //   _s(0.15) だと coast(0%) → 100% に ~3秒かかり threshold に届かない
        //   101 にすることで generate() のノイズ (±0.3) を吸収し
        //   閾値 100 を常に超え続ける → fullThrottleTicks が途切れない
        throttle = 101;
    }
  }

  void _s(double f, {required double rpm, required double speed,
    required double throttle, required double torque, required double load,
    required double maf, required double timing, required double fuelPres,
    required double iat, required double coolant, required double mapKpa}) {
    this.rpm += (rpm - this.rpm) * f;
    this.speed += (speed - this.speed) * f;
    this.throttle += (throttle - this.throttle) * f;
    this.torque += (torque - this.torque) * f;
    this.load += (load - this.load) * f;
    this.maf += (maf - this.maf) * f;
    this.timing += (timing - this.timing) * f;
    this.fuelPres += (fuelPres - this.fuelPres) * f;
    this.iat += (iat - this.iat) * f;
    this.coolant = coolant;
    this.mapKpa += (mapKpa - this.mapKpa) * f;
  }

  double? generate(String pidId, math.Random rng) {
    final n = (rng.nextDouble() - 0.5) * 2;
    return switch (pidId) {
      // ── UDS DIDs ──
      'uds_rpm'           => rpm + (rpm.abs() < 10 ? 0 : n * 15),
      'uds_speed'         => math.max(0, speed + (speed.abs() < 1 ? 0 : n * 0.5)),
      'uds_load'          => math.max(0, load + n * 0.3),
      'uds_torque'        => torque + n * 5,
      'uds_accel'         => math.max(0, throttle + n * 0.3),
      'uds_coolant'       => coolant + n * 0.15,
      'uds_iat_b1'        => iat + n * 0.3,
      'uds_manifold_b1'   => (mapKpa * 0.145038) + n * 0.22,         // psi
      'uds_manifold_b2'   => (mapKpa * 0.145038 + 0.073) + n * 0.22, // psi, 微偏
      'uds_ambient'       => 1013 + n * 1,
      'uds_airfilter'     => 1010 + n * 1,
      'uds_boost_b1'      => (load > 50 ? mapKpa * 0.174046 : 14.7) + n * 0.145,   // psi
      'uds_boost_b2'      => (load > 50 ? mapKpa * 0.174046 + 0.29 : 14.7) + n * 0.145, // psi
      'uds_wastegate'     => (load > 50 ? load * 0.8 : 5) + n * 1,
      'uds_fuel_lp'       => fuelPres * 10 + n * 5,
      'uds_fuel_hp'       => fuelHp + n * 0.3,
      'uds_inj_b1'        => (load > 50 ? 5 + load * 0.15 : 1.5) + n * 0.1,
      'uds_inj_b2'        => (load > 50 ? 5.1 + load * 0.15 : 1.55) + n * 0.1,
      'uds_hpfp'          => 120 + load * 0.5 + n * 2,
      'uds_ign_b1'        => timing + n * 0.3,
      'uds_ign_b2'        => timing - 0.5 + n * 0.3,
      'uds_ign_corr'      => timing - 1.0 + n * 0.2,
      'uds_kr_avg'        => math.max(0, knockAvg + n * 0.4),
      'uds_kr_1' || 'uds_kr_2' || 'uds_kr_3' || 'uds_kr_4' ||
      'uds_kr_5' || 'uds_kr_6' || 'uds_kr_7' || 'uds_kr_8'
                          => math.max(0, knockAvg * 0.8 + rng.nextDouble() * knockAvg * 0.4),
      'uds_lambda_b1'     => lambdaB1 * 14.7 + n * 0.15,       // AFR
      'uds_lambda_sp'     => load > 80 ? 12.05 : 14.7,          // AFR
      'uds_exh_cam_b1'    => -25 + load * 0.1 + n * 0.5,
      'uds_int_cam_b1'    => 30 + load * 0.1 + n * 0.5,
      'uds_throttle_ang'  => math.max(0, throttle * 0.88 + n * 0.3),
      'uds_airmass'       => math.max(3, maf * 3.6 + n * 5),  // g/s → kg/h approx
      // ── 档位 (PidGroup.gear — 所有 TCU 版本共用模拟值) ──
      // 返回 722.9 编码 (标准化语义值), GearMapping 在 HUD 端处理
      _ when pidId.startsWith('uds_gear_') => _demoGear(),
      _ => null,
    };
  }

  /// 档位模拟值 (722.9 标准化编码: 0=P/N, 1~7=D档, -1=R)
  double _demoGear() {
    if (speed < 3) return 0;          // P/N
    if (rpm < 300) return 0;
    // 根据速度粗略推算档位
    if (speed < 30)  return 1;
    if (speed < 60)  return 2;
    if (speed < 100) return 3;
    if (speed < 140) return 4;
    if (speed < 180) return 5;
    if (speed < 230) return 6;
    return 7;
  }

  static double _l(double a, double b, double t) => a + (b - a) * t.clamp(0, 1);
}