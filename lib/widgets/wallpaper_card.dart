// ════════════════════════════════════════════════════════════════
// wallpaper_card.dart — HUD 壁纸管理卡片
// ════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../theme/eva_theme.dart';

class WallpaperCard extends StatefulWidget {
  final ValueChanged<File?> onWallpaperChanged;
  final ValueChanged<double> onDarknessChanged;
  final File? initialFile;
  final double initialDarkness;

  const WallpaperCard({
    super.key,
    required this.onWallpaperChanged,
    required this.onDarknessChanged,
    this.initialFile,
    this.initialDarkness = 0.72,
  });

  @override State<WallpaperCard> createState() => _WallpaperCardState();
}

class _WallpaperCardState extends State<WallpaperCard> {
  File? _wpFile;
  double _darkness = 0.72;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _wpFile = widget.initialFile;
    _darkness = widget.initialDarkness;
  }

  Future<void> _pickWallpaper() async {
    try {
      final xf = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1920);
      if (xf == null || !mounted) return;
      if (_wpFile != null) FileImage(_wpFile!).evict();
      final dir = await getApplicationDocumentsDirectory();
      for (final old in dir.listSync()) {
        if (old is File && old.path.contains('eva_hud_wallpaper')) {
          FileImage(old).evict();
          try { await old.delete(); } catch (_) {}
        }
      }
      final ext = xf.path.split('.').last;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final dest = File('${dir.path}/eva_hud_wallpaper_$ts.$ext');
      await File(xf.path).copy(dest.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kWpPath, dest.path);
      imageCache.clear(); imageCache.clearLiveImages();
      if (mounted) {
        setState(() => _wpFile = dest);
        widget.onWallpaperChanged(dest);
      }
    } catch (_) {}
  }

  Future<void> _deleteWallpaper() async {
    if (_wpFile != null) FileImage(_wpFile!).evict();
    imageCache.clear(); imageCache.clearLiveImages();
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(kWpPath);
    if (path != null) { try { await File(path).delete(); } catch (_) {} }
    await prefs.remove(kWpPath);
    if (mounted) {
      setState(() => _wpFile = null);
      widget.onWallpaperChanged(null);
    }
  }

  Future<void> _saveDarkness(double v) async {
    setState(() => _darkness = v);
    widget.onDarknessChanged(v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kWpDark, v);
  }

  @override
  Widget build(BuildContext context) {
    final hasWp = _wpFile != null;
    return EvaCard(
      title: 'WALLPAPER', subtitle: 'HUD 壁紙',
      trailing: hasWp ? Text('已设置', style: TextStyle(fontFamily: 'monospace',
        fontSize: 8, fontWeight: FontWeight.w800, color: evaGreen)) : null,
      child: Column(children: [
        GestureDetector(onTap: _pickWallpaper, child: Container(
          width: double.infinity, height: 80,
          decoration: BoxDecoration(color: DS.bg, borderRadius: BorderRadius.circular(6),
            border: Border.all(color: hasWp ? evaAmber.withOpacity(0.2) : DS.border)),
          clipBehavior: Clip.antiAlias,
          child: hasWp
            ? Stack(children: [
                Positioned.fill(child: Image.file(_wpFile!, fit: BoxFit.cover,
                  key: ValueKey(_wpFile!.path), gaplessPlayback: false,
                  errorBuilder: (_, __, ___) => Container(color: DS.bg))),
                Positioned.fill(child: Container(color: Colors.black.withOpacity(_darkness))),
                Center(child: Text('3', style: TextStyle(fontFamily: 'monospace',
                  fontSize: 40, fontWeight: FontWeight.w900, color: evaAmber.withOpacity(0.8),
                  shadows: [Shadow(color: evaAmber.withOpacity(0.3), blurRadius: 12)]))),
              ])
            : Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add_photo_alternate_outlined, size: 28, color: evaDim.withOpacity(0.3)),
                const SizedBox(height: 4),
                Text('点击导入壁纸', style: TextStyle(fontFamily: 'monospace',
                  fontSize: 9, fontWeight: FontWeight.w700, color: evaDim.withOpacity(0.3))),
              ])))),
        if (hasWp) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text('亮', style: TextStyle(fontFamily: 'monospace', fontSize: 8,
              fontWeight: FontWeight.w700, color: evaDim)),
            Expanded(child: SliderTheme(
              data: SliderThemeData(activeTrackColor: evaAmber.withOpacity(0.5),
                inactiveTrackColor: DS.border, thumbColor: evaAmber,
                overlayColor: evaAmber.withOpacity(0.1), trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5)),
              child: Slider(value: _darkness, min: 0.4, max: 0.9,
                onChanged: (v) => setState(() => _darkness = v),
                onChangeEnd: _saveDarkness))),
            Text('暗', style: TextStyle(fontFamily: 'monospace', fontSize: 8,
              fontWeight: FontWeight.w700, color: evaDim)),
          ]),
          Row(children: [
            Expanded(child: evaActionBtn('更换', Icons.swap_horiz, evaAmber, _pickWallpaper)),
            const SizedBox(width: 8),
            Expanded(child: evaActionBtn('删除', Icons.delete_outline, evaRed, _deleteWallpaper)),
          ]),
        ],
      ]));
  }
}
