import SwiftUI
import AVKit
import AVFoundation
import Photos
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import Combine

// MARK: - App Entry Point
@main
struct SpeedFramePlayerApp: App {
    var body: some Scene {
        WindowGroup {
            VideoLibraryView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Movie Transferable (PhotosPickerで権限ダイアログなしでも動画を読み込める仕組み)
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "picked_\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)"
            let copyURL = tempDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: copyURL.path) {
                try? FileManager.default.removeItem(at: copyURL)
            }
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return Self(url: copyURL)
        }
    }
}

// MARK: - 1. Photo Library Sync Manager (写真アプリとのリアルタイム同期)
@MainActor
final class PhotoLibrarySyncManager: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var videoAssets: [PHAsset] = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isLoading: Bool = false

    private var fetchResult: PHFetchResult<PHAsset>?
    private var isObserverRegistered: Bool = false

    override init() {
        super.init()
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.authorizationStatus = currentStatus
        // 重要: 権限が未決定(.notDetermined)の段階で PHPhotoLibrary.shared() を呼ぶと
        // iOSの権限ダイアログがフリーズするため、許可済みのときだけ登録する
        if currentStatus == .authorized || currentStatus == .limited {
            registerObserverIfNeeded()
            fetchVideos()
        }
    }

    deinit {
        if isObserverRegistered {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    private func registerObserverIfNeeded() {
        guard !isObserverRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        isObserverRegistered = true
    }

    func requestPermissionAndFetch() {
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            self.authorizationStatus = status
            if status == .authorized || status == .limited {
                self.registerObserverIfNeeded()
                self.fetchVideos()
            } else if status == .denied || status == .restricted {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
            }
        }
    }

    func refreshStatus() {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.authorizationStatus = currentStatus
        if currentStatus == .authorized || currentStatus == .limited {
            registerObserverIfNeeded()
            fetchVideos()
        }
    }

    func fetchVideos() {
        isLoading = true
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)

        let result = PHAsset.fetchAssets(with: .video, options: options)
        self.fetchResult = result

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        self.videoAssets = assets
        self.isLoading = false
    }

    // 写真アプリ側で動画の追加・削除・編集があった際に自動同期
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let fetchResult = self.fetchResult,
                  let changes = changeInstance.changeDetails(for: fetchResult) else { return }
            self.fetchResult = changes.fetchResultAfterChanges
            var updatedAssets: [PHAsset] = []
            self.fetchResult?.enumerateObjects { asset, _, _ in
                updatedAssets.append(asset)
            }
            self.videoAssets = updatedAssets
        }
    }
}

// MARK: - 2. Video Player ViewModel (倍速・スロー・コマ送り・長押し2倍速制御)
@MainActor
final class VideoPlayerViewModel: ObservableObject {
    let player = AVPlayer()

    @Published var isPlaying: Bool = false
    @Published var selectedSpeed: Float = 1.0
    @Published var isLongPressing2x: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 1.0
    @Published var nominalFPS: Float = 30.0
    @Published var isLoadingAsset: Bool = true
    @Published var errorMessage: String?

    let speedPresets: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var wasPlayingBeforeLongPress: Bool = false
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

    var effectiveSpeed: Float {
        isLongPressing2x ? 2.0 : selectedSpeed
    }

    var currentFrameNumber: Int {
        guard nominalFPS > 0 else { return 0 }
        return max(0, Int((currentTime * Double(nominalFPS)).rounded()))
    }

    init() {
        setupTimeObserver()
        setupEndObserver()
    }

    func cleanup() {
        player.pause()
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    // PHAsset（写真アプリの動画）を読み込む（iCloud共有動画にも対応）
    func load(phAsset: PHAsset) {
        isLoadingAsset = true
        errorMessage = nil
        player.pause()

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { [weak self] avAsset, _, _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let avAsset = avAsset {
                    await self.configurePlayer(with: avAsset)
                } else {
                    self.isLoadingAsset = false
                    self.errorMessage = "動画の読み込みに失敗しました（iCloud接続を確認してください）。"
                }
            }
        }
    }

    // URLから動画を読み込む（PhotosPicker用）
    func load(url: URL) {
        isLoadingAsset = true
        errorMessage = nil
        player.pause()
        let avAsset = AVURLAsset(url: url)
        Task {
            await configurePlayer(with: avAsset)
        }
    }

    private func configurePlayer(with asset: AVAsset) async {
        do {
            let durationTime = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = tracks.first {
                let fps = try await videoTrack.load(.nominalFrameRate)
                if fps > 0 {
                    self.nominalFPS = fps
                }
            }

            let playerItem = AVPlayerItem(asset: asset)
            // 倍速・スロー再生時も音声のピッチ（声の高さ）を維持する設定
            playerItem.audioTimePitchAlgorithm = .timeDomain

            player.replaceCurrentItem(with: playerItem)
            self.duration = max(CMTimeGetSeconds(durationTime), 0.01)
            self.currentTime = 0.0
            self.isLoadingAsset = false
        } catch {
            self.isLoadingAsset = false
            self.errorMessage = "動画データの解析に失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: 再生 / 一時停止
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        if currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        isPlaying = true
        player.playImmediately(atRate: effectiveSpeed)
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    // MARK: 倍速・スロー再生設定 (0.1x 〜 4.0x)
    func setSpeed(_ speed: Float) {
        let clamped = min(max(speed, 0.1), 4.0)
        selectedSpeed = (clamped * 100).rounded() / 100
        if isPlaying && !isLongPressing2x {
            player.rate = selectedSpeed
        }
    }

    // MARK: コマ送り / コマ戻し（1フレーム単位）
    func stepFrames(count: Int) {
        if isPlaying {
            pause()
        }
        guard let item = player.currentItem else { return }

        if (count > 0 && item.canStepForward) || (count < 0 && item.canStepBackward) {
            item.step(byCount: count)
            currentTime = CMTimeGetSeconds(player.currentTime())
        } else {
            let frameDuration = 1.0 / Double(max(nominalFPS, 1.0))
            let targetTime = min(max(currentTime + Double(count) * frameDuration, 0.0), duration)
            seek(to: targetTime)
        }
        hapticGenerator.impactOccurred(intensity: 0.6)
    }

    // MARK: 長押ししてる間は2倍速再生
    func startLongPress2x() {
        guard !isLongPressing2x else { return }
        isLongPressing2x = true
        wasPlayingBeforeLongPress = isPlaying
        hapticGenerator.impactOccurred(intensity: 0.9)

        if currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        isPlaying = true
        player.playImmediately(atRate: 2.0)
    }

    func endLongPress2x() {
        guard isLongPressing2x else { return }
        isLongPressing2x = false
        hapticGenerator.impactOccurred(intensity: 0.5)

        if wasPlayingBeforeLongPress {
            isPlaying = true
            player.playImmediately(atRate: selectedSpeed)
        } else {
            pause()
        }
    }

    // MARK: シーク（フレーム精度）
    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self else { return }
                let sec = CMTimeGetSeconds(time)
                if sec.isFinite {
                    self.currentTime = sec
                }
            }
        }
    }

    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isPlaying = false
                self.isLongPressing2x = false
            }
        }
    }
}

// MARK: - 3. Custom Video Surface (AVPlayerLayerラッパー)
struct VideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }
        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }
}

// MARK: - 再生対象の識別用モデル
struct PlayableVideoTarget: Identifiable {
    let id = UUID()
    let phAsset: PHAsset?
    let fileURL: URL?
}

// MARK: - 4. Video Library Grid View (写真アプリ同期一覧画面 ＋ 直接ピッカー)
struct VideoLibraryView: View {
    @StateObject private var libraryManager = PhotoLibrarySyncManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeVideoTarget: PlayableVideoTarget?
    @State private var selectedPickerItem: PhotosPickerItem?
    @State private var isImportingPickerVideo: Bool = false

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Group {
                    switch libraryManager.authorizationStatus {
                    case .notDetermined, .denied, .restricted:
                        VStack(spacing: 22) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 56))
                                .foregroundStyle(.yellow)

                            Text("写真アプリの動画を再生")
                                .font(.title2.bold())

                            Text("下の「写真アプリから動画を選択」を押すと、権限設定なしですぐに動画を選んで再生できます。\nすべての動画を一覧表示したい場合は「全動画の自動同期を許可」を押してください。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)

                            // 方法1: 権限ダイアログ不要で確実に動くiOS標準ピッカー
                            PhotosPicker(
                                selection: $selectedPickerItem,
                                matching: .videos,
                                photoLibrary: .shared()
                            ) {
                                Label("写真アプリから動画を選択（すぐ再生）", systemImage: "play.rectangle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(.yellow, in: Capsule())
                                    .foregroundStyle(.black)
                            }
                            .padding(.horizontal, 32)

                            // 方法2: 写真ライブラリ全件の自動同期
                            Button {
                                libraryManager.requestPermissionAndFetch()
                            } label: {
                                Label(
                                    libraryManager.authorizationStatus == .notDetermined
                                        ? "全動画の自動同期を許可する"
                                        : "設定アプリで写真アクセスを許可する",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.white.opacity(0.15), in: Capsule())
                                .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 32)
                        }

                    case .authorized, .limited:
                        if libraryManager.isLoading {
                            ProgressView("写真アプリの動画を同期中...")
                        } else if libraryManager.videoAssets.isEmpty {
                            VStack(spacing: 16) {
                                ContentUnavailableView(
                                    "表示できる動画がありません",
                                    systemImage: "video.slash",
                                    description: Text("写真アプリから動画を選択するか、フルアクセスを許可してください。")
                                )
                                PhotosPicker(
                                    selection: $selectedPickerItem,
                                    matching: .videos,
                                    photoLibrary: .shared()
                                ) {
                                    Label("写真アプリから動画を選択", systemImage: "plus.circle.fill")
                                        .font(.headline)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 12)
                                        .background(.yellow, in: Capsule())
                                        .foregroundStyle(.black)
                                }
                            }
                        } else {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 4) {
                                    ForEach(libraryManager.videoAssets, id: \.localIdentifier) { asset in
                                        Button {
                                            activeVideoTarget = PlayableVideoTarget(phAsset: asset, fileURL: nil)
                                        } label: {
                                            VideoThumbnailCell(asset: asset)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(4)
                            }
                        }
                    @unknown default:
                        EmptyView()
                    }
                }

                if isImportingPickerVideo {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    ProgressView("動画を読み込み中...")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle("動画ライブラリ")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(
                        selection: $selectedPickerItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Label("動画を選択", systemImage: "plus.rectangle.on.folder.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.yellow)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        libraryManager.refreshStatus()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    libraryManager.refreshStatus()
                }
            }
            .onChange(of: selectedPickerItem) { _, newItem in
                guard let newItem = newItem else { return }
                isImportingPickerVideo = true
                Task { @MainActor in
                    defer {
                        isImportingPickerVideo = false
                        selectedPickerItem = nil
                    }
                    if let picked = try? await newItem.loadTransferable(type: PickedMovie.self) {
                        activeVideoTarget = PlayableVideoTarget(phAsset: nil, fileURL: picked.url)
                    }
                }
            }
            .fullScreenCover(item: $activeVideoTarget) { target in
                CustomVideoPlayerScreen(target: target)
            }
        }
    }
}

// MARK: - Thumbnail Cell (動画サムネイル＆再生時間表示)
struct VideoThumbnailCell: View {
    let asset: PHAsset
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.secondary.opacity(0.2)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                    }
                }
                .clipped()

            Text(formatDuration(asset.duration))
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
        .task {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let targetSize = CGSize(width: 300, height: 300)

        manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            if let image = image {
                self.thumbnail = image
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - 5. Custom Video Player Screen (メイン再生画面)
struct CustomVideoPlayerScreen: View {
    let target: PlayableVideoTarget
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var showControls: Bool = true
    @State private var isDraggingSlider: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 映像表示エリア（タップでUI表示切替・長押しで2倍速再生）
            VideoSurfaceView(player: viewModel.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }
                .onLongPressGesture(
                    minimumDuration: 0.2,
                    maximumDistance: 40,
                    pressing: { isPressing in
                        if !isPressing && viewModel.isLongPressing2x {
                            viewModel.endLongPress2x()
                        }
                    },
                    perform: {
                        viewModel.startLongPress2x()
                    }
                )

            // 長押し2倍速中のインジケーター（画面上部）
            VStack {
                if viewModel.isLongPressing2x {
                    HStack(spacing: 6) {
                        Image(systemName: "forward.fill")
                        Text("2.0x 早送り中")
                            .font(.subheadline.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .padding(.top, 16)
                }
                Spacer()
            }
            .animation(.spring(duration: 0.2), value: viewModel.isLongPressing2x)

            if viewModel.isLoadingAsset {
                ProgressView("動画を読み込み中...")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if let errorMessage = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }

            // コントロールパネル
            if showControls && !viewModel.isLongPressing2x {
                VStack {
                    // 上部バー（閉じるボタン & フレーム情報）
                    HStack {
                        Button {
                            viewModel.cleanup()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Spacer()

                        // 現在のフレーム番号・FPS・再生速度表示
                        HStack(spacing: 10) {
                            Text("Frame: \(viewModel.currentFrameNumber)")
                            Text("•")
                            Text(String(format: "%.0f fps", viewModel.nominalFPS))
                            Text("•")
                            Text(String(format: "%.2gx", viewModel.effectiveSpeed))
                                .foregroundStyle(.yellow)
                        }
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    // 下部コントロールパネル（シーク・コマ送り・倍速設定）
                    VStack(spacing: 14) {
                        // 1. シークバー＆タイムスタンプ
                        VStack(spacing: 4) {
                            Slider(
                                value: Binding(
                                    get: { viewModel.currentTime },
                                    set: { newValue in
                                        viewModel.seek(to: newValue)
                                    }
                                ),
                                in: 0...max(viewModel.duration, 0.01),
                                onEditingChanged: { editing in
                                    isDraggingSlider = editing
                                    if editing && viewModel.isPlaying {
                                        viewModel.pause()
                                    }
                                }
                            )
                            .tint(.white)

                            HStack {
                                Text(formatPreciseTime(viewModel.currentTime))
                                Spacer()
                                Text(formatPreciseTime(viewModel.duration))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        }

                        // 2. 再生 / 一時停止 ＆ コマ送り・コマ戻しボタン
                        HStack(spacing: 20) {
                            // 5コマ戻し
                            Button {
                                viewModel.stepFrames(count: -5)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: "backward.frame.fill")
                                        .font(.title3)
                                    Text("-5コマ")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .frame(width: 52, height: 44)
                            }

                            // 1コマ戻し
                            Button {
                                viewModel.stepFrames(count: -1)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: "chevron.backward.to.line")
                                        .font(.title2.bold())
                                    Text("-1コマ")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .frame(width: 60, height: 48)
                                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                            }

                            // 再生 / 一時停止
                            Button {
                                viewModel.togglePlayPause()
                            } label: {
                                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 54))
                            }

                            // 1コマ送り
                            Button {
                                viewModel.stepFrames(count: 1)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: "chevron.forward.to.line")
                                        .font(.title2.bold())
                                    Text("+1コマ")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .frame(width: 60, height: 48)
                                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                            }

                            // 5コマ送り
                            Button {
                                viewModel.stepFrames(count: 5)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: "forward.frame.fill")
                                        .font(.title3)
                                    Text("+5コマ")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .frame(width: 52, height: 44)
                            }
                        }
                        .foregroundStyle(.white)

                        Divider().background(.white.opacity(0.2))

                        // 3. 倍速・スロー再生コントロール（プリセット＋微調整スライダー）
                        VStack(spacing: 8) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(viewModel.speedPresets, id: \.self) { speed in
                                        let isSelected = abs(viewModel.selectedSpeed - speed) < 0.01
                                        Button {
                                            viewModel.setSpeed(speed)
                                        } label: {
                                            Text(String(format: "%gx", speed))
                                                .font(.caption.monospacedDigit().bold())
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(
                                                    isSelected ? Color.yellow : Color.white.opacity(0.15),
                                                    in: Capsule()
                                                )
                                                .foregroundStyle(isSelected ? .black : .white)
                                        }
                                    }
                                }
                            }

                            // 0.1x〜4.0x 無段階スライダー
                            HStack(spacing: 10) {
                                Image(systemName: "tortoise.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                Slider(
                                    value: Binding(
                                        get: { viewModel.selectedSpeed },
                                        set: { viewModel.setSpeed($0) }
                                    ),
                                    in: 0.1...4.0,
                                    step: 0.05
                                )
                                .tint(.yellow)
                                Image(systemName: "hare.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                Text(String(format: "%.2fx", viewModel.selectedSpeed))
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundStyle(.yellow)
                                    .frame(width: 48, alignment: .trailing)
                            }
                        }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            if let asset = target.phAsset {
                viewModel.load(phAsset: asset)
            } else if let url = target.fileURL {
                viewModel.load(url: url)
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }

    private func formatPreciseTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00.00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let hundredths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, hundredths)
    }
}
