import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;

/// 切り抜き結果
class CropResult {
  CropResult({
    required this.path,
    required this.originalWidth,
    required this.originalHeight,
    required this.width,
    required this.height,
    required this.stepMs,
    required this.elapsedMs,
  });

  final String path;
  final int originalWidth;
  final int originalHeight;
  final int width;
  final int height;

  /// 工程ごとの処理時間(ms)。挿入順 = 実行順
  final Map<String, int> stepMs;

  /// Isolate内での合計処理時間(ms)
  final int elapsedMs;
}

/// 撮影画像を、プレビュー（FittedBox(BoxFit.cover) + 中央寄せ）で
/// 見えている範囲と同じく「中央を 16:9 で」切り抜いて保存する。
///
/// 重い処理（12MP〜のデコード/エンコード）なので別Isolateで実行する。
Future<CropResult> cropCenterTo16x9(String srcPath, {int quality = 95}) {
  return Isolate.run(() => _cropSync(srcPath, quality));
}

CropResult _cropSync(String srcPath, int quality) {
  final total = Stopwatch()..start();
  final lap = Stopwatch()..start();
  final steps = <String, int>{};
  void mark(String name) {
    steps[name] = lap.elapsedMilliseconds;
    lap.reset();
  }

  final bytes = File(srcPath).readAsBytesSync();
  mark('ファイル読込');

  final decoded = img.decodeJpg(bytes);
  if (decoded == null) {
    throw Exception('JPEGのデコードに失敗しました: $srcPath');
  }
  mark('JPEGデコード');

  // EXIF の Orientation を画素に焼き込む。
  // 端末によっては画素は横向きのまま EXIF で回転指定されているため、
  // これをしないと「どの辺を切るか」を間違える。
  final image = img.bakeOrientation(decoded);
  mark('EXIF回転反映');

  final w = image.width;
  final h = image.height;

  // プレビューと同じく「中央寄せで長辺:短辺 = 16:9」の領域を求める
  int cropX = 0, cropY = 0, cropW = w, cropH = h;
  final isPortrait = h >= w;
  final long = isPortrait ? h : w;
  final short = isPortrait ? w : h;

  final targetLong = (short * 16 / 9).round();
  if (targetLong <= long) {
    // 4:3 など 16:9 より正方形寄り → 長辺側を削る
    if (isPortrait) {
      cropH = targetLong;
      cropY = (h - cropH) ~/ 2;
    } else {
      cropW = targetLong;
      cropX = (w - cropW) ~/ 2;
    }
  } else {
    // 16:9 より細長い → 短辺側を削る
    final targetShort = (long * 9 / 16).round();
    if (isPortrait) {
      cropW = targetShort;
      cropX = (w - cropW) ~/ 2;
    } else {
      cropH = targetShort;
      cropY = (h - cropH) ~/ 2;
    }
  }

  final cropped =
      img.copyCrop(image, x: cropX, y: cropY, width: cropW, height: cropH);
  mark('切り抜き');

  final encoded = img.encodeJpg(cropped, quality: quality);
  mark('JPEGエンコード');

  final dstPath = srcPath.replaceFirst(
      RegExp(r'\.(jpe?g)$', caseSensitive: false), '_16x9.jpg');
  final outPath = dstPath == srcPath ? '${srcPath}_16x9.jpg' : dstPath;
  File(outPath).writeAsBytesSync(encoded);
  mark('ファイル書込');

  total.stop();
  return CropResult(
    path: outPath,
    originalWidth: w,
    originalHeight: h,
    width: cropW,
    height: cropH,
    stepMs: steps,
    elapsedMs: total.elapsedMilliseconds,
  );
}
