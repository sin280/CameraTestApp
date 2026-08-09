import 'dart:io';
import 'dart:async';
import 'package:camerawesome/pigeon.dart';
import 'package:flutter/material.dart';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:path_provider/path_provider.dart';
import 'encryption_helper.dart';
import 'video_player_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  bool _isProcessing = false;
  Timer? _maxRecordingTimer;
  Timer? _uiTimer;
  int _recordSeconds = 0;

  // 撮影完了時のイベントをフックして処理へ移行
  void _onMediaCaptureEvent(MediaCapture event) async {
    if (event.status == MediaCaptureStatus.success) {
      event.captureRequest.when(
        single: (single) {
          final filePath = single.file?.path;
          if (filePath != null) {
            if (event.isPicture) {
              debugPrint('写真撮影成功: $filePath');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('写真を保存しました')),
                );
              }
            } else if (event.isVideo) {
              _processVideo(File(filePath));
            }
          }
        },
        multiple: (multiple) {
          // 複数カメラの処理は省略
        },
      );
    }
  }

  Future<void> _processVideo(File sourceFile) async {
    setState(() {
      _isProcessing = true;
    });

    try {
      final stopwatch = Stopwatch()..start();
      final encryptedFile = await EncryptionHelper.encryptVideo(sourceFile);
      stopwatch.stop();
      debugPrint('[処理時間計測] 動画の保存・暗号化処理: ${stopwatch.elapsedMilliseconds} ms');
      
      if (await sourceFile.exists()) {
        await sourceFile.delete();
      }

      if (!mounted) return;
      
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => VideoPlayerScreen(encryptedFile: encryptedFile),
        ),
      );
    } catch (e) {
      debugPrint('Stop recording error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  void _startTimer(CameraState state) {
    setState(() {
      _recordSeconds = 0;
    });
    
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _recordSeconds++;
      });
    });

    _maxRecordingTimer = Timer(const Duration(minutes: 15), () {
      if (state is VideoRecordingCameraState) {
        state.stopRecording();
      }
    });
  }

  void _stopTimer() {
    _maxRecordingTimer?.cancel();
    _uiTimer?.cancel();
  }

  @override
  void dispose() {
    _maxRecordingTimer?.cancel();
    _uiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CamerAwesome Test'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'すべてのテスト動画を削除',
            onPressed: () async {
              try {
                final appDir = await getApplicationDocumentsDirectory();
                final files = appDir.listSync();
                int count = 0;
                for (var file in files) {
                  if (file is File && file.path.endsWith('.mp4')) {
                    await file.delete();
                    count++;
                  }
                }
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$count件のテスト動画を削除しました')),
                );
              } catch (e) {
                debugPrint('Delete error: $e');
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          CameraAwesomeBuilder.custom(
            previewFit: CameraPreviewFit.contain, // プレビューの見た目と保存される画角を完全に一致させる
            previewAlignment: Alignment.topCenter,
            sensorConfig: SensorConfig.single(
              sensor: Sensor.position(SensorPosition.back),
              aspectRatio: CameraAspectRatios.ratio_16_9,
            ),
            saveConfig: SaveConfig.photoAndVideo(
              initialCaptureMode: CaptureMode.photo,
              videoOptions: VideoOptions(
                enableAudio: true,
                quality: VideoRecordingQuality.fhd, // 1920x1080固定
                ios: CupertinoVideoOptions(fps: 30),
                android: AndroidVideoOptions(
                  bitrate: 6000000,
                  fallbackStrategy: QualityFallbackStrategy.lower,
                ),
              ),
            ),
            onMediaCaptureEvent: _onMediaCaptureEvent,
            builder: (cameraState, preview) {
              return Stack(
                children: [
                  // タイマーUI (動画撮影中のみ表示)
                  if (cameraState is VideoRecordingCameraState)
                    Positioned(
                      top: 24,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${(_recordSeconds ~/ 60).toString().padLeft(2, '0')}:${(_recordSeconds % 60).toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  
                  // カスタム録画/撮影コントロール領域
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      padding: const EdgeInsets.only(bottom: 32, top: 16),
                      color: Colors.black54,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // 1. フラッシュ切り替え (StreamBuilderで状態と同期)
                          StreamBuilder<FlashMode>(
                            stream: cameraState.sensorConfig.flashMode$,
                            builder: (context, snapshot) {
                              final mode = snapshot.data ?? FlashMode.none;
                              IconData iconData = Icons.flash_off;
                              if (mode == FlashMode.auto) iconData = Icons.flash_auto;
                              if (mode == FlashMode.on || mode == FlashMode.always) iconData = Icons.flash_on;
                              
                              return IconButton(
                                icon: Icon(iconData, color: Colors.white),
                                onPressed: _isProcessing ? null : () {
                                  cameraState.sensorConfig.switchCameraFlash();
                                },
                              );
                            }
                          ),

                          // 2. アスペクト比切り替え
                          IconButton(
                            icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                            onPressed: _isProcessing ? null : () {
                              final current = cameraState.sensorConfig.aspectRatio;
                              cameraState.sensorConfig.setAspectRatio(
                                current == CameraAspectRatios.ratio_16_9
                                    ? CameraAspectRatios.ratio_4_3
                                    : CameraAspectRatios.ratio_16_9,
                              );
                            },
                          ),

                          // 3. 撮影/録画ボタン
                          FloatingActionButton(
                            onPressed: _isProcessing ? null : () async {
                              if (cameraState is PhotoCameraState) {
                                await cameraState.takePhoto();
                              } else if (cameraState is VideoCameraState) {
                                await cameraState.startRecording();
                                _startTimer(cameraState);
                              } else if (cameraState is VideoRecordingCameraState) {
                                _stopTimer();
                                final stopRecWatch = Stopwatch()..start();
                                await cameraState.stopRecording();
                                stopRecWatch.stop();
                                debugPrint('[処理時間計測] カメラの録画停止（ネイティブ処理）: ${stopRecWatch.elapsedMilliseconds} ms');
                              }
                            },
                            backgroundColor: (cameraState is VideoRecordingCameraState) ? Colors.red : Colors.white,
                            child: Icon(
                              cameraState is VideoRecordingCameraState ? Icons.stop : Icons.camera,
                              color: cameraState is VideoRecordingCameraState ? Colors.white : Colors.black,
                            ),
                          ),

                          // 4. 写真 <-> 動画 切り替え
                          IconButton(
                            icon: Icon(
                              cameraState is PhotoCameraState ? Icons.videocam : Icons.camera_alt,
                              color: Colors.white,
                            ),
                            onPressed: _isProcessing ? null : () {
                              if (cameraState is PhotoCameraState) {
                                cameraState.setState(CaptureMode.video);
                              } else if (cameraState is VideoCameraState) {
                                cameraState.setState(CaptureMode.photo);
                              }
                            },
                          ),

                          // 5. インカメラ <-> アウトカメラ 切り替え
                          IconButton(
                            icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                            onPressed: _isProcessing ? null : () {
                              cameraState.switchCameraSensor();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          
          // 処理中のオーバーレイ表示
          if (_isProcessing)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 16),
                      Text('Processing (Encrypting)...', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
