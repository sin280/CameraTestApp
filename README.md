# CamerAwesome 本番環境 導入ガイド

本番プロジェクトへ `camerawesome` パッケージを導入するための、設計指針と実装ガイドラインです。

---

## 1. 前提条件・ビルド設定
`camerawesome` は最新のカメラAPI（AndroidのCameraX等）を使用するため、古いOSを切る必要があります。
* **Android**: `android/app/build.gradle` にて `minSdk = 24` (Android 7.0) 以上に設定。
* **iOS**: `ios/Podfile` にて `platform :ios, '11.0'` 以上に設定。
* **権限周り**: 公式プラグイン同様、マイク・カメラのパーミッション記述（Info.plist, AndroidManifest.xml）が必須です。

---

## 2. 初期化手順（起動と待機）
旧公式パッケージのような `availableCameras()` の事前呼び出しや、`controller.initialize()` を `await` して待つ処理は**一切不要**です。

`CameraAwesomeBuilder` をWidgetツリーに配置した瞬間から、非同期でネイティブ側での初期化が自動で開始されます。
初期化の完了（準備中）は、`builder` に渡される `cameraState` の型で判別します。

```dart
CameraAwesomeBuilder.custom(
  // 🔽 画像と動画の両方を撮る設定（初期モードは写真）
  saveConfig: SaveConfig.photoAndVideo(
    initialCaptureMode: CaptureMode.photo,
  ),
  builder: (CameraState cameraState, AnalysisPreview preview) {
    // 💡 初期化中は PreparingCameraState になる
    if (cameraState is PreparingCameraState) {
      return const Center(child: CircularProgressIndicator()); // ローディングを出す
    }
    
    // 初期化が完了すると PhotoCameraState などに移行し、プレビューが表示される
    return _buildMyCameraUI(cameraState); 
  },
)
```

---

## 3. 静止画撮影と動画撮影の実装（16:9 / FHD）
「基本は写真、動画にも切り替え可能」とする場合の設定と、解像度の固定方法です。

### 撮影の基本設定
```dart
CameraAwesomeBuilder.custom(
  sensorConfig: SensorConfig.single(
    sensor: Sensor.position(SensorPosition.back),
    aspectRatio: CameraAspectRatios.ratio_16_9, // 16:9固定
  ),
  saveConfig: SaveConfig.photoAndVideo(
    initialCaptureMode: CaptureMode.photo, // 起動時は静止画モード
    videoOptions: VideoOptions(
      android: AndroidVideoOptions(
        quality: VideoRecordingQuality.fhd, // 1080p固定
      ),
    ),
  ),
```

### 【補足】旧プラグインからの画質移行とアスペクト比
旧 `camera` プラグインでは `ResolutionPreset` を指定していましたが、`camerawesome` では「プレビューや写真のアスペクト比」と「動画のエンコード画質」が完全に分離されています。

**旧 `camera` プラグインとの対応表：**

| 目安となる画質 (解像度) | 旧 `camera` パッケージ (`ResolutionPreset`) | `camerawesome` パッケージ (`VideoRecordingQuality`) |
| :--- | :--- | :--- |
| **最高画質（端末依存）** | `max` (強制的に **4:3** になる事故が多い) | `.highest` (指定したアスペクト比を維持して最高画質化) |
| **4K (2160p)** | `ultraHigh` (16:9固定) | `.uhd` |
| **フルHD (1080p)** | `veryHigh` (16:9固定) | `.fhd` |
| **HD (720p)** | `high` (16:9固定) | `.hd` |
| **SD (480p)** | `medium` | `.sd` |
| **最低画質（240p等）** | `low` | `.lowest` |

> [!NOTE]
> 旧プラグインで「高画質にしたいから `max` にしたら、勝手に4:3の写真用センサー解像度で動画が撮られてしまった」という問題がよく発生していました。
> `camerawesome` では、`SensorConfig` で `CameraAspectRatios.ratio_16_9` を指定しつつ、`VideoRecordingQuality.highest` (または `fhd`) を指定することで、**16:9を維持したまま安全に最高画質を狙う**ことができます。1080p (FHD) を明示的に固定したい場合は、`VideoRecordingQuality.fhd` と `ratio_16_9` の組み合わせが旧 `veryHigh` と全く同じ挙動になります。

---

  onMediaCaptureEvent: (event) {
    // 💡 写真や動画の撮影完了をここで検知して処理する
    if (event.status == MediaCaptureStatus.success) {
      if (event.isPicture) {
        // 写真の場合の処理
        final photoPath = event.captureRequest.when(single: (single) => single.file?.path);
        debugPrint('写真が保存されました: $photoPath');
      } else if (event.isVideo) {
        // 動画の場合の処理
        final videoPath = event.captureRequest.when(single: (single) => single.file?.path);
        debugPrint('動画が保存されました: $videoPath');
        // 暗号化などの後続処理へ...
      }
    }
  },
  // ...
```

### 写真を撮る処理
現在のステートが `PhotoCameraState` であることを確認して実行します。
```dart
if (cameraState is PhotoCameraState) {
  await cameraState.takePhoto(); // カシャッ！
}
```

### 動画モードへ切り替えて撮影する処理
モードを切り替えるメソッドを呼び出します。切り替わるとビルダーが再描画され、ステートが `VideoCameraState` に変わります。
```dart
// 1. モードの切り替え
if (cameraState is PhotoCameraState) {
  // 動画モードへ移行 (UIが自動で切り替わる)
  cameraState.switchCameraMode(); 
}

// 2. 録画開始
if (cameraState is VideoCameraState) {
  await cameraState.startRecording();
}

// 3. 録画停止 (15分タイマー等のタイミングで)
if (cameraState is VideoRecordingCameraState) {
  await cameraState.stopRecording();
}
```

---

## 4. バックグラウンド移行と端末ロック時の挙動
`camerawesome` の最大の強みがここです。
ユーザーがアプリを裏に回した（別アプリを開いた）、または端末をスリープ（ロック）した場合、ネイティブ側で**自動的にカメラセンサーを安全に解放し、録画中であれば安全に録画を停止**してくれます。

* **録画停止後のイベント発火**: バックグラウンド移行によって録画が強制停止された場合でも、正常な録画完了時と同様に **`onMediaCaptureEvent` が発火します**。そのため、「意図せずアプリを閉じてしまったせいで、それまで撮っていた動画ファイルが壊れて虚無になる」といった事故を防ぎ、撮影途中までの動画を確実に保存・処理フェーズに回すことができます。
* **開発者がやること**: 基本的に**何もしなくて良い**。`WidgetsBindingObserver` を使って `didChangeAppLifecycleState` で `dispose()` を呼ぶ…といった泥臭いコードは一切不要です。
* **復帰時**: フォアグラウンドに戻ると、自動的にセンサーに再接続し、元のカメラモード（写真 or 動画）でプレビューを再開します。**この際、フラッシュのON/OFF状態、ズーム倍率、インカメラ/アウトカメラの選択状態などの設定（SensorConfigの状態）もすべて自動で引き継がれます。** ユーザーが裏に行く前にアウトカメラでズームしていたら、戻ってきた時もそのままの状態から再開されます。

---

## 5. 画面遷移（Push）時のカメラ停止・再開
カメラ画面から別の画面へ `Navigator.push` で遷移した場合、カメラ画面はバックグラウンドに回らないため、裏でプレビューが稼働し続けてバッテリーを消費してしまいます。
これを防ぐ（遷移時にカメラを一時停止する）には、`RouteObserver` と連携して手動で start/stop します。

```dart
class _CameraScreenState extends State<CameraScreen> with RouteAware {
  CameraState? _currentCameraState;

  @override
  void didPushNext() {
    // 別の画面が上に被さった時：カメラを一時停止してバッテリーを節約
    _currentCameraState?.stop();
  }

  @override
  void didPopNext() {
    // 上の画面が消えてカメラ画面に戻ってきた時：カメラを再開
    _currentCameraState?.start();
  }
}
```
※ `builder` メソッド内で `_currentCameraState = cameraState;` と一時保存しておき、それを呼び出します。
※ **`start()` するだけで再初期化は不要です。** `camerawesome` はWidgetがツリー上に存在する限り、ネイティブ側のカメラセッションを一時停止（ポーズ）しているだけなので、`start()` を呼べば一瞬でプレビューが再開されます。公式パッケージのように `initialize()` を `await` で待ち直す重い処理は発生しません。

---

## 7. カスタムUIの構成サンプル (Stack配置)
AppBarを残した状態で、カメラプレビューを上部中央に配置し、その上にオーバーレイ（Stack）として各種コントロールボタンを配置する最も実用的な画面構造のサンプルです。

`camerawesome` は状態（フラッシュ、アスペクト比、前後カメラ）を `cameraState.sensorConfig` 経由で簡単に操作できるため、ボタンの `onPressed` にそのまま紐付けるだけでUIが完成します。

```dart
@override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(title: const Text('カメラ画面')),
    // 💡プレビューとUIを丸ごと画面全体に広げる
    body: CameraAwesomeBuilder.custom(
      // プレビューの見た目と保存画角を完全に一致させる（見切れないようにする）
      previewFit: CameraPreviewFit.contain,
      // プレビューを上詰め中央寄せ
      previewAlignment: Alignment.topCenter,
      saveConfig: SaveConfig.photoAndVideo(initialCaptureMode: CaptureMode.photo),
      sensorConfig: SensorConfig.single(
        sensor: Sensor.position(SensorPosition.back),
        aspectRatio: CameraAspectRatios.ratio_16_9,
      ),
      builder: (CameraState cameraState, AnalysisPreview preview) {
        return Stack(
          children: [
            // コントロール領域（画面下部に配置）
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.only(bottom: 32, top: 16),
                color: Colors.black45, // 半透明の背景で視認性アップ
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
                          onPressed: () {
                            cameraState.sensorConfig.switchCameraFlash();
                          },
                        );
                      }
                    ),

                    // 2. アスペクト比切り替え (16:9 ↔ 4:3)
                    IconButton(
                      icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                      onPressed: () {
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
                      backgroundColor: cameraState is VideoRecordingCameraState ? Colors.red : Colors.white,
                      onPressed: () {
                        if (cameraState is PhotoCameraState) {
                          cameraState.takePhoto();
                        } else if (cameraState is VideoCameraState) {
                          cameraState.startRecording();
                        } else if (cameraState is VideoRecordingCameraState) {
                          cameraState.stopRecording();
                        }
                      },
                      child: Icon(
                        cameraState is VideoRecordingCameraState ? Icons.stop : Icons.camera,
                        color: cameraState is VideoRecordingCameraState ? Colors.white : Colors.black,
                      ),
                    ),

                    // 4. 写真 ↔ 動画 切り替え
                    IconButton(
                      icon: Icon(
                        cameraState is PhotoCameraState ? Icons.videocam : Icons.camera_alt,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        if (cameraState is PhotoCameraState || cameraState is VideoCameraState) {
                          cameraState.switchCameraMode();
                        }
                      },
                    ),

                    // 5. インカメラ ↔ アウトカメラ 切り替え
                    IconButton(
                      icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                      onPressed: () {
                        cameraState.sensorConfig.switchSensor();
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
  );
}
```

---

## 6. リソースの解放（Dispose）が必要なタイミング
手動で解放を気にしなければいけない状況は**「カメラ画面のWidgetが破棄される時」**だけです。

`CameraAwesomeBuilder` は内部的に `StatefulWidget` として作られており、親の画面が `Navigator.pop` や `pushReplacement` で破棄されたタイミングで、勝手に自身の `dispose` を呼び出し、ネイティブ層のハードウェア解放処理をすべて実行してくれます。

つまり、開発者は **「CameraController の dispose() を呼び忘れてメモリリークする」という概念から完全に解放** されます。親画面の `dispose()` では、自作したUIタイマー (`Timer.periodic` など) を止めることだけを気にしていれば問題ありません。

---

## 8. Riverpod (StateNotifier) との連携アーキテクチャ

既存プロジェクトで `StateNotifier` を利用したアーキテクチャを採用している場合、`camerawesome` との連携には以下の設計原則を守ることが「最適解」となります。

### ① `CameraState` を Notifier に保存しない
`camerawesome` の状態（`CameraState`）はFlutterのWidgetツリーと密接に結びついています。これをNotifierに保存すると、画面遷移や復帰時に古いインスタンスを参照してクラッシュする原因になります。
撮影（`takePhoto`）やフラッシュ切り替えなどの操作は、**UI側のWidget内で完結**させます。

### ② パッケージ固有の型（MediaCapture）で Notifier を汚染しない
`onMediaCaptureEvent` のイベントハンドラをそのままNotifierに定義すると、ビジネスロジック層が `camerawesome` に密結合してしまいます（クリーンアーキテクチャの原則違反）。
UI層でイベントを解釈し、**必要な純粋なデータ（ファイルパス等）だけを抽出してNotifierに渡す**のが正解です。

### ③ コールバック内での動的な `ref.read` を徹底する
関数ティアオフ（例: `onMediaCaptureEvent: notifier.onMediaCaptureEvent`）を使うと、`autoDispose` された破棄済みのインスタンスを呼び出してしまうリスクがあります。イベント発火時に都度 `ref.read` して最新のNotifierを取得します。

### 理想的な実装例

**UI側（Widget）:**
```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  return CameraAwesomeBuilder.custom(
    // ...
    onMediaCaptureEvent: (MediaCapture event) {
      // 💡 1. UI層でパッケージ固有の型を解釈する
      if (event.status == MediaCaptureStatus.success && event.isVideo) {
        final filePath = event.captureRequest.when(single: (s) => s.file?.path);
        
        if (filePath != null) {
          // 💡 2. 純粋なデータ(String)だけをNotifierに渡す
          // 💡 3. 発火時に都度 ref.read することで破棄済みインスタンスを呼ばない
          ref.read(cameraNotifierProvider.notifier).processVideo(filePath);
        }
      }
    },
  );
}
```

**ビジネスロジック側（StateNotifier）:**
```dart
class CameraNotifier extends StateNotifier<CameraStateData> {
  // camerawesome パッケージをimportする必要が一切ない（クリーン！）
  
  void processVideo(String filePath) async {
    state = state.copyWith(isProcessing: true);
    // ... ファイルの暗号化やサーバー送信など重い処理を実行
  }
}
```
このアーキテクチャにより、UIとビジネスロジックが完全に分離され、高い保守性とテスト容易性を保つことができます。

---

## 9. 画質の動的変更（ValueKeyの活用）

旧 `camera` プラグインでは、画質（解像度）を動的に変更する場合、現在のControllerを `dispose` して新しい設定で再度 `initialize` をし直す必要がありました。
`camerawesome` では、手動での再起動処理は不要です。**`CameraAwesomeBuilder` に現在の画質を紐付けた `ValueKey` を渡す**だけで、安全に再起動させることができます。

### 画質変更の実装例
```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  // Notifier等から現在の画質設定を監視
  final currentQuality = ref.watch(cameraNotifierProvider).videoQuality;

  return CameraAwesomeBuilder.custom(
    // 💡 1. 画質が変わったらFlutterにWidgetごと作り直すようKeyを指定する
    key: ValueKey(currentQuality),
    
    saveConfig: SaveConfig.photoAndVideo(
      videoOptions: VideoOptions(
        android: AndroidVideoOptions(
          // 💡 2. ここに現在の画質を渡す
          quality: currentQuality,
        ),
      ),
    ),
    builder: (cameraState, preview) { ... }
  );
}
```

#### 仕組みと安全性
Flutterが `ValueKey` の変更を検知すると、古い `CameraAwesomeBuilder` をWidgetツリーから破棄します。この際、**自動的に内部の `dispose` メソッドが走り、ネイティブのカメラリソースが安全に解放されます。**
その後、新しい画質設定を持ったBuilderが再マウントされ、再初期化が完了するまでは `PreparingCameraState` が返るため、画面上に安全にローディングUIを出すことができます。手動での煩雑なライフサイクル管理から完全に解放されます。

---

> [!TIP]
> **まとめ**
> * **初期化**: Widgetを置くだけ。
> * **サスペンド/レジューム**: OSにお任せで勝手にやってくれる。
> * **解放**: Widgetツリーから消える時に勝手に解放される。
> 非常にリアクティブで「Flutterらしい」宣言的なカメラ管理が可能です！
