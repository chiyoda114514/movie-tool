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

// MARK: - Movie Transferable (「プライベートアクセス」のまま権限不要で動画を読み込む仕組み)
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copyURL = tempDir.appendingPathComponent("picked_\(UUID().uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: copyURL.path) {
                try? FileManager.default.removeItem(at: copyURL)
            }
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return Self(url: copyURL)
        }
    }
}

// MARK: - 1. Photo Library Sync Manager
final class PhotoLibrarySyncManager: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var videoAssets: [PHAsset] = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isLoading: Bool = false
    @Published var statusFeedback: String?

    private var fetchResult: PHFetchResult<PHAsset>?
    private var isObserverRegistered: Bool = false

    override init() {
        super.init()
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.authorizationStatus = currentStatus
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
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .denied || current == .restricted {
            statusFeedback = "iPhoneの「設定」アプリで写真へのアクセスを許可してください。"
            if let url = URL(string: UIApplication.openSettingsURLString) {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }
            }
            return
        }

        statusFeedback = "iOSの写真アクセス確認を呼び出しています..."
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.authorizationStatus = status
                switch status {
                case .authorized, .limited:
                    self.statusFeedback = nil
                    self.registerObserverIfNeeded()
                    self.fetchVideos()
                case .denied, .restricted:
                    self.statusFeedback = "「プライベートアクセス」モードです。上の黄色いボタンから動画を選択してください。"
                case .notDetermined:
                    self.statusFeedback = "「プライベートアクセス」モードです。上の黄色いボタンから動画を選択してください。"
                @unknown default:
                    break
                }
            }
        }
    }

    func refreshStatus() {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        DispatchQueue.main.async {
            self.authorizationStatus = currentStatus
            if currentStatus == .authorized || currentStatus == .limited {
                self.registerObserverIfNeeded()
                self.fetchVideos()
            }
        }
    }

    func fetchVideos() {
        DispatchQueue.main.async {
            self.isLoading = true
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)

            let result = PHAsset.fetchAssets(with: .video, options: options)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }

            DispatchQueue.main.async {
                self.fetchResult = result
                self.videoAssets = assets
                self.isLoading = false
            }
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let fetchResult = self.fetchResult,
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

    func setSpeed(_ speed: Float) {
        let clamped = min(max(speed, 0.1), 4.0)
        selectedSpeed = (clamped * 100).rounded() / 100
        if isPlaying && !isLongPressing2x {
            player.rate = selectedSpeed
        }
    }

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

// MARK: - 3. Custom Video Surface
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

// MARK: - 4. Video Library Grid View
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
                        VStack(spacing: 20) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 56))
                                .foregroundStyle(.yellow)

                            Text("写真アプリの動画を再生")
                                .font(.title2.bold())

                            Text("下の黄色い「写真アプリから動画を選択」ボタンを押すと、現在の「プライベートアクセス」のまま、すぐに動画を選んで倍速・コマ送り再生ができます。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)

                            // プライベートアクセスのまま100%確実に動く動画ピッカー
                            PhotosPicker(
                                selection: $selectedPickerItem,
                                matching: .videos
                            ) {
                                Label("写真アプリから動画を選択（すぐ再生）", systemImage: "play.rectangle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(.yellow, in: Capsule())
                                    .foregroundStyle(.black)
                            }
                            .padding(.horizontal, 32)

                            Button {
                                libraryManager.requestPermissionAndFetch()
                            } label: {
                                Label("全動画の自動一覧同期を許可する", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(.white.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 32)

                            if let feedback = libraryManager.statusFeedback {
                                Text(feedback)
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 28)
                            }
                        }

                    case .authorized, .limited:
                        if libraryManager.isLoading {
                            ProgressView("写真アプリの動画を同期中...")
                        } else if libraryManager.videoAssets.isEmpty {
                            VStack(spacing: 16) {
                                ContentUnavailableView(
                                    "表示できる動画がありません",
                                    systemImage: "video.slash",
                                    description: Text("下のボタンから写真アプリの動画を選択してください。")
                                )
                                PhotosPicker(
                                    selection: $selectedPickerItem,
                                    matching: .videos
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
                        matching: .videos
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

// MARK: - Thumbnail Cell
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

// MARK: - 5. Custom Video Player Screen
struct CustomVideoPlayerScreen: View {
    let target: PlayableVideoTarget
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var showControls: Bool = true
    @State private var isDraggingSlider: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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

            if showControls && !viewModel.isLongPressing2x {
                VStack {
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

                    VStack(spacing: 14) {
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

                        HStack(spacing: 20) {
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

                            Button {
                                viewModel.togglePlayPause()
                            } label: {
                                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 54))
                            }

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
