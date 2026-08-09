import 'dart:io';
import 'dart:math';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class EncryptionHelper {
  // 暗号化のためのランダムなバイト長
  static const int _dummyByteLength = 64;

  /// 動画ファイルを「暗号化」して保存する
  /// 指定された [sourceFile] の先頭にランダムなバイトを追加して
  /// Application Documents 領域に保存する。
  static Future<File> encryptVideo(File sourceFile) async {
    final appDir = await getApplicationDocumentsDirectory();
    final fileName = 'encrypted_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final encryptedPath = '${appDir.path}/$fileName';
    final sourcePath = sourceFile.path;

    // Isolate（別スレッド）に処理を逃してUIのフリーズを完全に防ぐ
    await Isolate.run(() async {
      final encryptedFile = File(encryptedPath);
      final sink = encryptedFile.openWrite();

      try {
        // 1. 先頭にランダムなダミーバイトを書き込む
        final random = Random.secure();
        final dummyBytes = List<int>.generate(_dummyByteLength, (_) => random.nextInt(256));
        sink.add(dummyBytes);

        // 2. 元の動画データをStreamで読み込みながら書き込む（バケツリレー）
        await sink.addStream(File(sourcePath).openRead());
      } catch (e) {
        debugPrint('Encryption error: $e');
        rethrow;
      } finally {
        await sink.close();
      }
    });

    return File(encryptedPath);
  }

  /// 暗号化された動画ファイルを「復号」して一時領域に保存する
  /// 指定された [encryptedFile] の先頭にあるダミーバイトをスキップして Cache 領域に保存。
  static Future<File> decryptVideo(File encryptedFile) async {
    final cacheDir = await getTemporaryDirectory();
    final fileName = 'decrypted_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final decryptedPath = '${cacheDir.path}/$fileName';
    final encryptedPath = encryptedFile.path;

    // 復号化も同様に別スレッドで処理
    await Isolate.run(() async {
      final decryptedFile = File(decryptedPath);
      final sink = decryptedFile.openWrite();

      try {
        var skippedCount = 0;
        await for (final chunk in File(encryptedPath).openRead()) {
          if (skippedCount < _dummyByteLength) {
            final remainingToSkip = _dummyByteLength - skippedCount;
            if (chunk.length <= remainingToSkip) {
              skippedCount += chunk.length;
            } else {
              final dataChunk = chunk.sublist(remainingToSkip);
              sink.add(dataChunk);
              skippedCount += remainingToSkip;
            }
          } else {
            sink.add(chunk);
          }
        }
      } catch (e) {
        debugPrint('Decryption error: $e');
        rethrow;
      } finally {
        await sink.close();
      }
    });

    return File(decryptedPath);
  }
}
