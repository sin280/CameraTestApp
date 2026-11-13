import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_screen.dart';
import 'photo_cropper.dart';

/// 公式 camera パッケージで「16:9 プレビュー」を検証する画面
///
/// 構成（外側から）:
///   ClipRect
///    └ AspectRatio(9 / 16)          … 表示枠を縦持ち16:9に固定
///       └ FittedBox(BoxFit.cover)   … 比率を保ったまま枠を埋めるよう拡大
///          └ SizedBox(previewSize.height x previewSize.width) … センサー比率（縦横反転）
///             └ CameraPreview
class OfficialCameraPreviewScreen extends StatefulWidget {
  const OfficialCameraPreviewScreen({super.key});

  @override
  State<OfficialCameraPreviewScreen> createState() =>
      _OfficialCameraPreviewScreenState();
}

enum PreviewMode {
  /// 提示した構成（ClipRect + AspectRatio + FittedBox + SizedBox）
  cropped16x9,

  /// 比較用: CameraPreview をそのまま置いたもの
  raw,
}

class _OfficialCameraPreviewScreenState
    extends State<OfficialCameraPreviewScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  ResolutionPreset _preset = ResolutionPreset.max;
  PreviewMode _mode = PreviewMode.cropped16x9;
  String? _error;
  String? _lastCaptureInfo;
  bool _isCropping = false;

  // 実際に描画された枠のサイズを取得するためのキー
  final GlobalKey _frameKey = GlobalKey();
  Size? _renderedFrameSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 検証を単純にするため縦持ち固定
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      final back = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      final old = _controller;
      _controller = null;
      if (mounted) setState(() {});
      await old?.dispose();

      final controller = CameraController(
        back,
        _preset,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      // 画面は縦固定なので、撮影画像の向きも縦に固定する
      // （端末を横に傾けて撮っても横向き写真にならないように）
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _error = null;
      });
      _measureFrameAfterLayout();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _measureFrameAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _frameKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && mounted) {
        setState(() => _renderedFrameSize = box.size);
      }
    });
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null ||
        controller.value.isTakingPicture ||
        _isCropping) {
      return;
    }
    try {
      final captureWatch = Stopwatch()..start();
      final file = await controller.takePicture();
      captureWatch.stop();
      setState(() {
        _isCropping = true;
        _lastCaptureInfo = '切り抜き処理中...';
      });

      // プレビューで見えている範囲（中央16:9）に切り抜く
      // cropWatch は Isolate の起動・結果受け渡しも含めた「呼び出し側から見た」時間
      final cropWatch = Stopwatch()..start();
      final result = await cropCenterTo16x9(file.path);
      cropWatch.stop();

      final stepText = result.stepMs.entries
          .map((e) => '  ${e.key}: ${e.value}ms')
          .join('\n');
      final timeText = '[処理時間計測]\n'
          '撮影(takePicture): ${captureWatch.elapsedMilliseconds}ms\n'
          '16:9化 合計: ${cropWatch.elapsedMilliseconds}ms '
          '(Isolate内 ${result.elapsedMs}ms / 起動・受渡 '
          '${cropWatch.elapsedMilliseconds - result.elapsedMs}ms)\n'
          '$stepText';

      setState(() {
        _lastCaptureInfo =
            '元画像: ${result.originalWidth}x${result.originalHeight} '
            '(比率 ${_ratioLabel(result.originalWidth.toDouble(), result.originalHeight.toDouble())})\n'
            '保存画像: ${result.width}x${result.height} '
            '(比率 ${_ratioLabel(result.width.toDouble(), result.height.toDouble())})\n'
            '$timeText';
      });
      debugPrint('[検証] $_lastCaptureInfo\n${result.path}');

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _CapturedResultScreen(
            originalPath: file.path,
            croppedPath: result.path,
            info: _lastCaptureInfo!,
          ),
        ),
      );
    } catch (e) {
      setState(() => _lastCaptureInfo = '撮影エラー: $e');
    } finally {
      if (mounted) setState(() => _isCropping = false);
    }
  }

  Future<void> _openCamerawesomeScreen() async {
    // カメラの競合を避けるため、こちらのコントローラを解放してから遷移
    final old = _controller;
    setState(() => _controller = null);
    await old?.dispose();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CameraScreen()),
    );
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initCamera();
  }

  String _ratioLabel(double w, double h) {
    final long = w > h ? w : h;
    final short = w > h ? h : w;
    final r = long / short;
    String name = '';
    if ((r - 16 / 9).abs() < 0.02) name = ' ≒16:9';
    if ((r - 4 / 3).abs() < 0.02) name = ' ≒4:3';
    return '${r.toStringAsFixed(3)}$name';
  }

  // ---------------- プレビュー ----------------

  Widget _buildPreview(CameraController controller) {
    switch (_mode) {
      case PreviewMode.cropped16x9:
        // previewSize はセンサー基準（横長）なので、縦持ちでは縦横を入れ替える
        final Size previewSize = controller.value.previewSize!;
        return ClipRect(
          child: AspectRatio(
            key: _frameKey,
            aspectRatio: 9 / 16,
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: previewSize.height,
                height: previewSize.width,
                child: CameraPreview(controller),
              ),
            ),
          ),
        );
      case PreviewMode.raw:
        return Container(
          key: _frameKey,
          child: CameraPreview(controller),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        title: const Text('公式camera 16:9検証'),
        actions: [
          IconButton(
            tooltip: '既存のCamerAwesome画面へ',
            icon: const Icon(Icons.swap_horiz),
            onPressed: _openCamerawesomeScreen,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _error != null
                  ? Text(_error!, style: const TextStyle(color: Colors.red))
                  : (controller == null || !controller.value.isInitialized)
                      ? const CircularProgressIndicator()
                      // 枠が分かりやすいよう赤い線で囲む
                      : Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.red, width: 2),
                          ),
                          child: _buildPreview(controller),
                        ),
            ),
          ),
          _buildInfoPanel(controller),
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildInfoPanel(CameraController? controller) {
    final lines = <String>[];
    if (controller != null && controller.value.isInitialized) {
      final ps = controller.value.previewSize!;
      lines.add('ResolutionPreset: ${_preset.name}');
      lines.add(
          'previewSize: ${ps.width.toInt()}x${ps.height.toInt()} (比率 ${_ratioLabel(ps.width, ps.height)})');
      lines.add('controller.aspectRatio: ${controller.value.aspectRatio.toStringAsFixed(3)}');
      if (_renderedFrameSize != null) {
        final s = _renderedFrameSize!;
        lines.add(
            '表示枠: ${s.width.toStringAsFixed(1)}x${s.height.toStringAsFixed(1)} (比率 ${_ratioLabel(s.width, s.height)})');
      }
    }
    if (_lastCaptureInfo != null) lines.add(_lastCaptureInfo!);

    return Container(
      width: double.infinity,
      color: Colors.black87,
      padding: const EdgeInsets.all(8),
      child: Text(
        lines.join('\n'),
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.only(bottom: 24, top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton(
            onPressed: () {
              setState(() {
                _mode = _mode == PreviewMode.cropped16x9
                    ? PreviewMode.raw
                    : PreviewMode.cropped16x9;
                _renderedFrameSize = null;
              });
              _measureFrameAfterLayout();
            },
            child: Text(
              _mode == PreviewMode.cropped16x9 ? '表示: 16:9クロップ' : '表示: そのまま',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          FloatingActionButton(
            backgroundColor: Colors.white,
            onPressed: _isCropping ? null : _takePicture,
            child: _isCropping
                ? const CircularProgressIndicator()
                : const Icon(Icons.camera, color: Colors.black),
          ),
          TextButton(
            onPressed: () {
              const order = [
                ResolutionPreset.max,
                ResolutionPreset.ultraHigh,
                ResolutionPreset.veryHigh,
                ResolutionPreset.high,
              ];
              final next = order[(order.indexOf(_preset) + 1) % order.length];
              setState(() {
                _preset = next;
                _renderedFrameSize = null;
              });
              _initCamera();
            },
            child: Text(
              'Preset: ${_preset.name}',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// 撮影結果の確認画面
/// - 「保存画像(16:9)」: 実際に保存された切り抜き後の画像
/// - 「元画像(4:3)」 : takePicture() の元画像に、切り抜き範囲を赤枠で重ねたもの
class _CapturedResultScreen extends StatefulWidget {
  const _CapturedResultScreen({
    required this.originalPath,
    required this.croppedPath,
    required this.info,
  });

  final String originalPath;
  final String croppedPath;
  final String info;

  @override
  State<_CapturedResultScreen> createState() => _CapturedResultScreenState();
}

class _CapturedResultScreenState extends State<_CapturedResultScreen> {
  bool _showCropped = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(title: const Text('撮影結果')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _showCropped
                  ? Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.red, width: 2),
                      ),
                      child: AspectRatio(
                        aspectRatio: 9 / 16,
                        child: Image.file(File(widget.croppedPath),
                            fit: BoxFit.contain),
                      ),
                    )
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        AspectRatio(
                          aspectRatio: 3 / 4,
                          child: Image.file(File(widget.originalPath),
                              fit: BoxFit.contain),
                        ),
                        // 中央 9:16 の切り抜き範囲（プレビューで見えていた範囲）
                        AspectRatio(
                          aspectRatio: 3 / 4,
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 9 / 16,
                              child: Container(
                                decoration: BoxDecoration(
                                  border:
                                      Border.all(color: Colors.red, width: 2),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          Container(
            width: double.infinity,
            color: Colors.black87,
            padding: const EdgeInsets.all(8),
            child: Text(widget.info,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.only(bottom: 24, top: 8),
            child: Center(
              child: TextButton(
                onPressed: () => setState(() => _showCropped = !_showCropped),
                child: Text(
                  _showCropped ? '表示中: 保存画像(16:9) → 元画像に切替' : '表示中: 元画像(4:3) → 保存画像に切替',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
