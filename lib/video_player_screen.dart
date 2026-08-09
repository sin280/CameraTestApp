import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'encryption_helper.dart';

class VideoPlayerScreen extends StatefulWidget {
  final File encryptedFile;

  const VideoPlayerScreen({super.key, required this.encryptedFile});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  bool _isDecrypting = true;
  File? _decryptedFile;

  @override
  void initState() {
    super.initState();
    _initAndPlay();
  }

  Future<void> _initAndPlay() async {
    try {
      // ★ここでStreamを使った独自の復号処理（バイト削除）を実行
      _decryptedFile = await EncryptionHelper.decryptVideo(widget.encryptedFile);
      
      _controller = VideoPlayerController.file(_decryptedFile!);
      await _controller!.initialize();
      await _controller!.setLooping(true);
      
      if (mounted) {
        setState(() {
          _isDecrypting = false;
        });
        _controller!.play();
      }
    } catch (e) {
      debugPrint('Video Player error: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    // 再生が終わったら、一時領域（Cache）に保存した復号化済み動画を削除
    if (_decryptedFile != null) {
      _decryptedFile!.delete().catchError((_) => _decryptedFile!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video Preview (Decrypted)')),
      body: _isDecrypting
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Decrypting...'),
                ],
              ),
            )
          : _controller != null && _controller!.value.isInitialized
              ? Center(
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
                )
              : const Center(child: Text('Error playing video')),
      floatingActionButton: _isDecrypting
          ? null
          : FloatingActionButton(
              onPressed: () {
                setState(() {
                  _controller!.value.isPlaying
                      ? _controller!.pause()
                      : _controller!.play();
                });
              },
              child: Icon(
                _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            ),
    );
  }
}
