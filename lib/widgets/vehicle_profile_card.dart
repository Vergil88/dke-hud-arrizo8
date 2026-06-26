// ════════════════════════════════════════════════════════════════
// vehicle_profile_card.dart — 車輛設定檔管理卡片
// ════════════════════════════════════════════════════════════════
// INI 檔案的匯入・選擇・刪除・詳細顯示
// ★ pubspec.yaml 需要加入 file_picker 套件:
//   dependencies:
//     file_picker: ^8.0.0
// ════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../models/vehicle_profile.dart';
import '../models/obd_pids.dart';
import '../models/hud_channel_config.dart';
import '../services/bt_manager.dart';
import '../theme/eva_theme.dart';

class VehicleProfileCard extends StatefulWidget {
  final VoidCallback? onProfileChanged;
  const VehicleProfileCard({super.key, this.onProfileChanged});
  @override State<VehicleProfileCard> createState() => _VehicleProfileCardState();
}

class _VehicleProfileCardState extends State<VehicleProfileCard> {
  static const _purple = Color(0xFFBB86FC);
  static const _teal   = Color(0xFF03DAC6);

  bool _expanded = false;
  bool _loading = false;
  String? _error;
  List<_SavedProfile> _savedProfiles = [];

  @override
  void initState() {
    super.initState();
    _loadSavedProfiles();
  }

  // ═══════════════════════════════════════════════════════
  // 讀取已儲存的設定檔列表
  // ═══════════════════════════════════════════════════════

  Future<void> _loadSavedProfiles() async {
    final ids = await ProfileManager.instance.getSavedProfileIds();
    final prefs = await SharedPreferences.getInstance();
    final list = <_SavedProfile>[];
    for (final id in ids) {
      final content = prefs.getString('eva_custom_ini_$id');
      if (content == null) continue;
      try {
        final profile = VehicleProfileFactory.fromIni(content);
        list.add(_SavedProfile(id: id, name: profile.name, profile: profile));
      } catch (_) {
        list.add(_SavedProfile(id: id, name: '[$id] (解析錯誤)', profile: null));
      }
    }
    if (mounted) setState(() => _savedProfiles = list);
  }

  // ═══════════════════════════════════════════════════════
  // INI 檔案匯入
  // ═══════════════════════════════════════════════════════

  Future<void> _importIni() async {
    setState(() { _loading = true; _error = null; });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _loading = false);
        return;
      }

      final file = result.files.single;
      String content;
      if (file.path != null) {
        content = await File(file.path!).readAsString(encoding: utf8);
      } else if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else {
        throw Exception('無法讀取檔案');
      }

      // ★ 驗證 INI 能否解析
      final profile = VehicleProfileFactory.fromIni(content);
      if (profile.dids.isEmpty) {
        throw Exception('[dids] 區段為空 — 請確認 DID 定義');
      }

      await ProfileManager.instance.importIni(content);
      await HudChannelStore.applyProfileDefaults(force: true);
      await _loadSavedProfiles();
      widget.onProfileChanged?.call();
      setState(() { _loading = false; _error = null; });
    } catch (e, st) {
      // ★ file_picker 插件 bug: late static _instance 未初始化
      final msg = e.toString();
      if (msg.contains('LateInitializationError') || msg.contains('_instance')) {
        setState(() { _loading = false; _error = 'FilePicker 插件初始化失敗\n請改用「恢復內建」按鈕\n或重新啟動 App 後再試'; });
      } else {
        debugPrint('INI_IMPORT_ERROR: $e\n$st');
        setState(() { _loading = false; _error = msg; });
      }
    }
  }

  // ═══════════════════════════════════════════════════════
  // 切換至已儲存的設定檔
  // ═══════════════════════════════════════════════════════

  Future<void> _switchToProfile(_SavedProfile sp) async {
    if (sp.profile == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final prefs = await SharedPreferences.getInstance();
      final content = prefs.getString('eva_custom_ini_${sp.id}');
      if (content == null) throw Exception('INI 資料遺失');
      await ProfileManager.instance.importIni(content, profileId: sp.id);
      await HudChannelStore.applyProfileDefaults(force: true);
      widget.onProfileChanged?.call();
      setState(() => _loading = false);
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  // ═══════════════════════════════════════════════════════
  // 恢復為內建設定檔
  // ═══════════════════════════════════════════════════════

  Future<void> _useBuiltin() async {
    setState(() => _loading = true);
    try {
      await ProfileManager.instance.useBuiltin();
      await HudChannelStore.applyProfileDefaults(force: true);
      widget.onProfileChanged?.call();
      setState(() => _loading = false);
    } catch (e, st) {
      debugPrint('BUILTIN_ERROR: $e\n$st');
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  /// 切换到指定内置配置
  Future<void> _selectBuiltin(String id) async {
    setState(() => _loading = true);
    try {
      await ProfileManager.instance.useBuiltin(id);
      await HudChannelStore.applyProfileDefaults(force: true);
      await _loadSavedProfiles();
      widget.onProfileChanged?.call();
      setState(() => _loading = false);
    } catch (e, st) {
      debugPrint('BUILTIN_SELECT_ERROR: $e\n$st');
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  /// 弹出内置配置选择器
  void _showBuiltinPicker() {
    final builtinIds = ProfileManager.instance.builtinProfileIds;
    final activeName = ProfileManager.instance.activeName;
    // 按顺序排列: Arrizo 8 系列优先, 然后是 Generic, 最后 C63s
    final ordered = <String>[];
    for (final id in builtinIds) {
      if (id.contains('arrizo8')) ordered.add(id);
    }
    for (final id in builtinIds) {
      if (id.contains('generic')) ordered.add(id);
    }
    // fallback: 任何未被以上规则捕获的配置
    for (final id in builtinIds) {
      if (!ordered.contains(id)) ordered.add(id);
    }

    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF0A0A10),
      title: Text('選擇內建配置', style: TextStyle(fontFamily: 'monospace',
        fontSize: 14, fontWeight: FontWeight.w800, color: _teal)),
      content: SizedBox(
        width: 300,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: ordered.length,
          itemBuilder: (_, i) {
            final id = ordered[i];
            final label = _builtinLabel(id);
            final desc = _builtinDesc(id);
            final isActive = activeName.contains(_builtinLabel(id).split('(').first.trim());
            return ListTile(
              dense: true,
              title: Text(label, style: TextStyle(fontFamily: 'monospace',
                fontSize: 11, fontWeight: FontWeight.w700,
                color: isActive ? _teal : DS.textSec)),
              subtitle: Text(desc, style: TextStyle(fontFamily: 'monospace',
                fontSize: 8, color: DS.textDim)),
              trailing: isActive
                ? Icon(Icons.check_circle, color: _teal, size: 18)
                : null,
              onTap: () {
                Navigator.pop(ctx);
                _selectBuiltin(id);
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx),
          child: Text('取消', style: TextStyle(fontFamily: 'monospace', color: DS.textDim))),
      ],
    ));
  }

  String _builtinLabel(String id) {
    switch (id) {
      case '__builtin_c63s__':      return 'Mercedes-AMG C63s (W205)';
      case '__builtin_arrizo8_uds__': return 'Arrizo 8 2.0T (UDS)';
      case '__builtin_arrizo8_obd2__':return 'Arrizo 8 2.0T (OBD-II)';
      case '__builtin_generic_obd2__':return 'Generic OBD-II (通用)';
      default: return id;
    }
  }

  String _builtinDesc(String id) {
    switch (id) {
      case '__builtin_c63s__':      return 'UDS · M177 V8 · 7AT · 285/30R19';
      case '__builtin_arrizo8_uds__': return 'UDS · SQRF4J20 · 7DCT300 · 225/45R18';
      case '__builtin_arrizo8_obd2__':return 'OBD-II · SQRF4J20 · 7DCT300 · 225/45R18';
      case '__builtin_generic_obd2__':return 'OBD-II · 通用 · 自动识别';
      default: return '';
    }
  }

  // ═══════════════════════════════════════════════════════
  // 刪除設定檔
  // ═══════════════════════════════════════════════════════

  Future<void> _deleteProfile(_SavedProfile sp) async {
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) =>
      AlertDialog(
        backgroundColor: const Color(0xFF0A0A10),
        title: Text('刪除設定檔', style: TextStyle(fontFamily: 'monospace',
          fontSize: 13, fontWeight: FontWeight.w800, color: evaRed)),
        content: Text('確定要刪除「${sp.name}」嗎？\n若為使用中的設定檔，將自動切換回內建。',
          style: TextStyle(fontFamily: 'monospace',
            fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(fontFamily: 'monospace', color: DS.textDim))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
            child: Text('刪除', style: TextStyle(fontFamily: 'monospace', color: evaRed))),
        ]));
    if (confirmed != true) return;
    await ProfileManager.instance.deleteProfile(sp.id);
    await _loadSavedProfiles();
    widget.onProfileChanged?.call();
    setState(() {});
  }

  // ═══════════════════════════════════════════════════════
  // DID 一覽 Dialog
  // ═══════════════════════════════════════════════════════

  void _showDidList(VehicleProfile? p) {
    final dids = p?.dids ?? ObdPids.builtinDids;
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF0A0A10),
      title: Text('DID 一覽 (${dids.length})', style: TextStyle(fontFamily: 'monospace',
        fontSize: 13, fontWeight: FontWeight.w800, color: _teal)),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: ListView.builder(
          itemCount: dids.length,
          itemBuilder: (_, i) {
            final d = dids[i];
            return Padding(padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                SizedBox(width: 80, child: Text(d.id,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 8,
                    fontWeight: FontWeight.w800, color: _teal.withOpacity(0.8)),
                  overflow: TextOverflow.ellipsis)),
                SizedBox(width: 38, child: Text('0x${d.udsDid}',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 7,
                    fontWeight: FontWeight.w700, color: DS.textDim))),
                SizedBox(width: 28, child: Text(d.udsEcuTx,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 7,
                    fontWeight: FontWeight.w600, color: DS.textDim))),
                Expanded(child: Text(d.name,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 7,
                    fontWeight: FontWeight.w600, color: _teal.withOpacity(0.5)),
                  overflow: TextOverflow.ellipsis)),
              ]));
          })),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx),
          child: Text('關閉', style: TextStyle(fontFamily: 'monospace', color: _teal))),
      ]));
  }

  // ═══════════════════════════════════════════════════════
  // 建構
  // ═══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final pm = ProfileManager.instance;
    final isBuiltin = !pm.hasProfile;
    final p = pm.active;
    final isConnected = BtManager.instance.isConnected;

    // 目前使用中的是哪個已儲存設定檔
    String? activeProfileId;
    if (!isBuiltin) {
      for (final sp in _savedProfiles) {
        if (sp.name == p?.name) { activeProfileId = sp.id; break; }
      }
    }

    return EvaCard(
      title: 'VEHICLE PROFILE',
      subtitle: '車輛設定檔',
      trailing: _statusBadge(isBuiltin),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── 目前啟用的設定 ──
        _activeProfileBox(isBuiltin, p),
        const SizedBox(height: 8),

        // ── 操作按鈕 ──
        Row(children: [
          Expanded(child: _actionBtn(
            Icons.file_upload_outlined, 'INI 匯入', _purple,
            _loading ? null : _importIni)),
          const SizedBox(width: 6),
          Expanded(child: _actionBtn(
            Icons.list_alt, '內建配置', evaAmber,
            _loading ? null : _showBuiltinPicker)),
          const SizedBox(width: 6),
          Expanded(child: _actionBtn(
            _expanded ? Icons.expand_less : Icons.expand_more,
            _expanded ? '收合' : '展開詳情', _teal,
            () => setState(() => _expanded = !_expanded))),
        ]),

        // ── 載入中 ──
        if (_loading) Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            SizedBox(width: 10, height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: _purple)),
            const SizedBox(width: 6),
            Text('處理中...', style: TextStyle(fontFamily: 'monospace',
              fontSize: 8, fontWeight: FontWeight.w700, color: _purple.withOpacity(0.7))),
          ])),

        // ── 錯誤 ──
        if (_error != null) Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: evaRed.withOpacity(0.06),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: evaRed.withOpacity(0.2))),
            child: Text('⚠ $_error', style: TextStyle(fontFamily: 'monospace',
              fontSize: 8, fontWeight: FontWeight.w700, color: evaRed.withOpacity(0.8)),
              maxLines: 3, overflow: TextOverflow.ellipsis))),

        // ── BT 連線中警告 ──
        if (isConnected) Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('⚠ BT 連線中 — 切換後需重新連接才會生效',
            style: TextStyle(fontFamily: 'monospace',
              fontSize: 8, fontWeight: FontWeight.w700, color: evaRed.withOpacity(0.6)))),

        // ═══ 展開區段 ═══
        if (_expanded) ...[
          const SizedBox(height: 10),

          // ── 參數詳情 ──
          _divider('參數詳情'),
          const SizedBox(height: 6),
          _detailSection(isBuiltin ? _builtinDetails() : _profileDetails(p!)),
          const SizedBox(height: 4),

          // ── DID 一覽按鈕 ──
          GestureDetector(
            onTap: () => _showDidList(p),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: _teal.withOpacity(0.04),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _teal.withOpacity(0.15))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.list_alt, size: 12, color: _teal.withOpacity(0.6)),
                const SizedBox(width: 4),
                Text('顯示 DID 一覽 (${isBuiltin ? ObdPids.builtinDids.length : p?.dids.length ?? 0})',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                    fontWeight: FontWeight.w800, color: _teal.withOpacity(0.7))),
              ]))),

          const SizedBox(height: 10),

          // ── 已儲存列表 ──
          _divider('已儲存設定檔 (${_savedProfiles.length})'),
          const SizedBox(height: 6),

          if (_savedProfiles.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('尚無已儲存的設定檔\n匯入 INI 檔案後將自動儲存',
                style: TextStyle(fontFamily: 'monospace',
                  fontSize: 8, fontWeight: FontWeight.w600, color: DS.textDim))),

          for (final sp in _savedProfiles)
            _savedProfileTile(sp, activeProfileId),
        ],
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════
  // 子元件
  // ═══════════════════════════════════════════════════════

  Widget _statusBadge(bool isBuiltin) {
    final label = isBuiltin ? '內建' : 'CUSTOM';
    final c = isBuiltin ? evaAmber : _purple;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withOpacity(0.3))),
      child: Text(label, style: TextStyle(fontFamily: 'monospace',
        fontSize: 8, fontWeight: FontWeight.w900, color: c)));
  }

  Widget _activeProfileBox(bool isBuiltin, VehicleProfile? p) {
    final c = isBuiltin ? evaAmber : _purple;
    final name = ProfileManager.instance.activeName;
    final engine = p?.engine.isNotEmpty == true ? p!.engine : (isBuiltin ? 'M177 4.0T V8' : '—');
    final trans = p?.transmission.isNotEmpty == true ? p!.transmission : (isBuiltin ? '722.9 7AT MCT' : '—');
    final didCount = isBuiltin ? ObdPids.builtinDids.length : (p?.dids.length ?? 0);
    final vinInfo = (p?.vinPattern.isNotEmpty == true)
        ? ' | VIN: ${p!.vinPattern}*'
        : ' | 通用';
    final sub = '$engine | $trans | $didCount DIDs$vinInfo';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.withOpacity(0.04),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withOpacity(0.15))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.directions_car, size: 14, color: c.withOpacity(0.6)),
          const SizedBox(width: 6),
          Expanded(child: Text(name, style: TextStyle(fontFamily: 'monospace',
            fontSize: 11, fontWeight: FontWeight.w800, color: c),
            overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: 3),
        Text(sub, style: TextStyle(fontFamily: 'monospace',
          fontSize: 8, fontWeight: FontWeight.w600, color: c.withOpacity(0.5))),
      ]));
  }

  Widget _actionBtn(IconData icon, String label, Color c, VoidCallback? onTap) {
    return GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: onTap != null ? c.withOpacity(0.06) : DS.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withOpacity(onTap != null ? 0.2 : 0.05))),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 12, color: c.withOpacity(onTap != null ? 0.6 : 0.2)),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontFamily: 'monospace', fontSize: 8,
          fontWeight: FontWeight.w800, color: onTap != null ? c : c.withOpacity(0.3))),
      ])));
  }

  Widget _divider(String label) {
    return Row(children: [
      Expanded(child: Container(height: 1, color: DS.border)),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(label, style: TextStyle(fontFamily: 'monospace',
          fontSize: 8, fontWeight: FontWeight.w800, color: DS.textDim))),
      Expanded(child: Container(height: 1, color: DS.border)),
    ]);
  }

  // ── 參數詳情表格 ──

  Widget _detailSection(List<_DetailRow> rows) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: DS.bg, borderRadius: BorderRadius.circular(6),
        border: Border.all(color: DS.border)),
      child: Column(children: [
        for (final row in rows)
          Padding(padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              SizedBox(width: 90, child: Text(row.label,
                style: TextStyle(fontFamily: 'monospace', fontSize: 8,
                  fontWeight: FontWeight.w700, color: row.color.withOpacity(0.5)))),
              Expanded(child: Text(row.value,
                style: TextStyle(fontFamily: 'monospace', fontSize: 8,
                  fontWeight: FontWeight.w800, color: row.color.withOpacity(0.85)),
                overflow: TextOverflow.ellipsis)),
            ])),
      ]));
  }

  List<_DetailRow> _builtinDetails() => [
    _DetailRow('平台', 'W205', _teal),
    _DetailRow('引擎', 'M177 4.0T V8 (510PS)', _teal),
    _DetailRow('變速箱', '722.9 7AT MCT', _teal),
    _DetailRow('協議', 'UDS | STP 33', _teal),
    _DetailRow('ECU', '7E0/7E8, 7E2/7EA, 7E4/7EC', _teal),
    _DetailRow('STPTO', '50 ms', _teal),
    _DetailRow('STCTOR', '50 / 100 ms', _teal),
    _DetailRow('DynDID', '0xF300 | T:50ms', _teal),
    _DetailRow('STPX T', '150 ms', _teal),
    _DetailRow('診斷會話', '10 03 (Extended)', _teal),
    _DetailRow('心跳', '2000ms | 3E80', _teal),
    _DetailRow('FC', '300000 | Mode 1', _teal),
    _DetailRow('齒輪比', '4.38/2.86/1.92/1.37/1.00/0.82/0.73', _teal),
    _DetailRow('最終傳動比', '2.820', _teal),
    _DetailRow('輪胎', '285/30R19', _teal),
  ];

  List<_DetailRow> _profileDetails(VehicleProfile p) {
    final ecuStr = p.ecuList.map((e) => '${e.tx}/${e.rx}').join(', ');
    final grStr = p.defaultGearRatios.map((g) => g.toStringAsFixed(2)).join('/');
    return [
      _DetailRow('平台', p.platform.isEmpty ? '—' : p.platform, _purple),
      _DetailRow('引擎', p.engine.isEmpty ? '—' : p.engine, _purple),
      _DetailRow('變速箱', p.transmission.isEmpty ? '—' : p.transmission, _purple),
      _DetailRow('協議', '${p.protocol} | STP ${p.stpProtocol}', _purple),
      _DetailRow('ECU', ecuStr.isEmpty ? '—' : ecuStr, _purple),
      _DetailRow('STPTO', '${p.stpto} ms', _purple),
      _DetailRow('STCTOR', '${p.stctorFc} / ${p.stctorCf} ms', _purple),
      _DetailRow('DynDID', '0x${p.dynamicDidTargetHex} | T:${p.dynDidReadTimeout}ms', _purple),
      _DetailRow('STPX T', '${p.stpxCmdTimeout} ms', _purple),
      _DetailRow('診斷會話', '10 ${p.sessionPreferred} / 10 ${p.sessionFallback}', _purple),
      _DetailRow('心跳', '${p.heartbeatInterval}ms | ${p.heartbeatCmd}', _purple),
      _DetailRow('FC', '${p.fcData} | Mode ${p.fcMode}', _purple),
      if (p.defaultGearRatios.isNotEmpty)
        _DetailRow('齒輪比', grStr, _purple),
      _DetailRow('最終傳動比', p.defaultFinalDrive.toStringAsFixed(3), _purple),
      _DetailRow('輪胎', '${p.defaultTireWidth}/${p.defaultTireAspect}R${p.defaultTireRim}', _purple),
      if (p.yearFrom > 0)
        _DetailRow('年式', '${p.yearFrom} — ${p.yearTo == 9999 ? "至今" : p.yearTo}', _purple),
    ];
  }

  // ── 已儲存設定檔列表項 ──

  Widget _savedProfileTile(_SavedProfile sp, String? activeId) {
    final isActive = sp.id == activeId;
    final c = isActive ? _purple : DS.textSec;
    return Padding(padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: isActive ? null : () => _switchToProfile(sp),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isActive ? _purple.withOpacity(0.06) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: isActive ? _purple.withOpacity(0.3) : DS.border)),
          child: Row(children: [
            Icon(isActive ? Icons.radio_button_checked : Icons.radio_button_off,
              color: c, size: 14),
            const SizedBox(width: 6),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(sp.name, style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                fontWeight: FontWeight.w800, color: c),
                overflow: TextOverflow.ellipsis),
              if (sp.profile != null)
                Text('${sp.profile!.engine} | ${sp.profile!.dids.length} DIDs',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 7,
                    fontWeight: FontWeight.w600, color: c.withOpacity(0.5))),
              if (sp.profile == null)
                Text('解析錯誤', style: TextStyle(fontFamily: 'monospace',
                  fontSize: 7, fontWeight: FontWeight.w600, color: evaRed.withOpacity(0.5))),
            ])),
            if (isActive) Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: _purple.withOpacity(0.1)),
              child: Text('ACTIVE', style: TextStyle(fontFamily: 'monospace',
                fontSize: 6, fontWeight: FontWeight.w900, color: _purple.withOpacity(0.7)))),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _deleteProfile(sp),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.delete_outline, size: 14,
                  color: evaRed.withOpacity(0.4)))),
          ]))));
  }
}

// ═══════════════════════════════════════════════════════
// 內部輔助類別
// ═══════════════════════════════════════════════════════

class _SavedProfile {
  final String id;
  final String name;
  final VehicleProfile? profile;
  const _SavedProfile({required this.id, required this.name, this.profile});
}

class _DetailRow {
  final String label;
  final String value;
  final Color color;
  const _DetailRow(this.label, this.value, this.color);
}