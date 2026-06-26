// ════════════════════════════════════════════════════════════════
// boot_animation.dart — MAGI 启动动画
// ════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../main.dart';
import '../theme/eva_theme.dart';

const _bootSteps = [
  'MAGI SYSTEM INITIALIZING...',
  'MELCHIOR·1 ... OK',
  'BALTHASAR·2 ... OK',
  'CASPER·3 ... OK',
  'DK企鹅工程 荣誉出品',
  '一切为了我们心中最纯粹的爱',
];

class BootAnimation extends StatefulWidget {
  final VoidCallback onComplete;
  const BootAnimation({super.key, required this.onComplete});
  @override State<BootAnimation> createState() => _BootAnimationState();
}

class _BootAnimationState extends State<BootAnimation> {
  int _bootStep = 0;
  Timer? _bootTimer;
  final AudioPlayer _atFieldPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _playAtFieldSfx();          // ← 启动动画一开始就播放音效
    _runBootSequence();
  }

  @override
  void dispose() {
    _bootTimer?.cancel();
    _atFieldPlayer.dispose();
    super.dispose();
  }

  void _runBootSequence() {
    _bootTimer = Timer.periodic(const Duration(milliseconds: 400), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        if (_bootStep < _bootSteps.length) {
          _bootStep++;
        } else {
          t.cancel();
          widget.onComplete();
        }
      });
    });
  }

  Future<void> _playAtFieldSfx() async {
    try {
      final ctx = AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          audioMode: AndroidAudioMode.normal,
          stayAwake: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
      );
      await _atFieldPlayer.setAudioContext(ctx);
      final file = Random().nextBool() ? 'atfield' : 'atfield2';
      final ext = Platform.isIOS ? 'aac' : 'ogg';
      await _atFieldPlayer.setReleaseMode(ReleaseMode.stop);
      await _atFieldPlayer.setVolume(0.4);
      await _atFieldPlayer.play(AssetSource('sfx/$file.$ext'));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Center(child: Container(
      width: 320, padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border.all(color: evaAmber.withOpacity(0.15)), color: DS.surface),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('E.V.A. SYSTEM BOOT', style: TextStyle(fontFamily: 'monospace',
            fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 3, color: evaAmber)),
          const SizedBox(height: 4),
          Text('汎用ヒト型決戦兵器', style: TextStyle(fontFamily: 'monospace',
            fontSize: 9, color: evaAmber.withOpacity(0.3))),
          const SizedBox(height: 16),
          ...List.generate(_bootStep.clamp(0, _bootSteps.length), (i) {
            final isLast = i == _bootStep - 1 && _bootStep <= _bootSteps.length;
            return Padding(padding: const EdgeInsets.only(bottom: 3),
              child: Text('> ${_bootSteps[i]}', style: TextStyle(fontFamily: 'monospace',
                fontSize: 10, fontWeight: FontWeight.w700,
                color: isLast ? evaAmber : evaAmber.withOpacity(0.4))));
          }),
          if (_bootStep < _bootSteps.length) ...[
            const SizedBox(height: 6),
            SizedBox(width: double.infinity, height: 2,
              child: LinearProgressIndicator(
                value: _bootStep / _bootSteps.length,
                backgroundColor: evaDim.withOpacity(0.2),
                valueColor: AlwaysStoppedAnimation(evaAmber))),
          ],
        ])));
  }
}