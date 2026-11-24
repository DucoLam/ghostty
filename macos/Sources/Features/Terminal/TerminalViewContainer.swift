import AppKit
import AVFoundation
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView: NSView

    /// Window-wide looping video drawn behind all splits (`background-video`).
    private var backgroundVideoView: TerminalBackgroundVideoView?

    /// Background color applied with glass effect
    private(set) var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig?

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }

        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    init<Root: View>(@ViewBuilder rootView: () -> Root) {
        self.terminalView = NSHostingView(rootView: rootView())
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The initial content size to use as a fallback before the SwiftUI
    /// view hierarchy has completed layout (i.e. before @FocusedValue
    /// propagates `lastFocusedSurface`). Once the hosting view reports
    /// a valid intrinsic size, this fallback is no longer used.
    var initialContentSize: NSSize?

    override var intrinsicContentSize: NSSize {
        let hostingSize = terminalView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        if let initialContentSize,
           hostingSize.width < initialContentSize.width || hostingSize.height < initialContentSize.height {
            return initialContentSize
        }
        return hostingSize
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func layout() {
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
    }

    func ghosttyConfigDidChange(_ config: Ghostty.Config, preferredBackgroundColor: NSColor?) {
        updateBackgroundVideo(source: TerminalBackgroundVideoSource(config: config))

        let newValue = DerivedConfig(config: config, preferredBackgroundColor: preferredBackgroundColor, cornerRadius: windowCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Attach the glass effect synchronously if missing to prevent flicker when a new tab appears.
        // Existing updates remain deferred, as they can occur during SwiftUI rendering.
        if glassEffectView == nil {
            updateGlassEffectIfNeeded()
        } else {
            DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
        }
    }
}

// MARK: - Background video

/// Where the window-wide background video comes from.
enum TerminalBackgroundVideoSource: Equatable {
    /// A local file (`background-video`), looped.
    case file(URL)
    /// A remote URL (`background-video-url`): a YouTube or other page that
    /// yt-dlp understands (livestreams included), or a direct media URL.
    case remote(URL)

    init?(config: Ghostty.Config) {
        if let raw = config.backgroundVideoURL?.trimmingCharacters(in: .whitespaces),
           !raw.isEmpty,
           let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            self = .remote(url)
        } else if let path = config.backgroundVideoPath {
            self = .file(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else {
            return nil
        }
    }
}

extension TerminalViewContainer {
    fileprivate func updateBackgroundVideo(source: TerminalBackgroundVideoSource?) {
        guard let source else {
            backgroundVideoView?.removeFromSuperview()
            backgroundVideoView = nil
            return
        }

        let videoView: TerminalBackgroundVideoView
        if let existing = backgroundVideoView {
            videoView = existing
        } else {
            videoView = TerminalBackgroundVideoView()
            addSubview(videoView, positioned: .below, relativeTo: terminalView)
            NSLayoutConstraint.activate([
                videoView.topAnchor.constraint(equalTo: topAnchor),
                videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
                videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
                videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            backgroundVideoView = videoView
        }
        videoView.load(source: source)
    }
}

/// A muted, aspect-filling video that ignores mouse events and pauses while
/// its window is not visible. Local files loop; remote streams play live and
/// are re-resolved when the stream URL fails or expires.
final class TerminalBackgroundVideoView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var currentSource: TerminalBackgroundVideoSource?
    private var occlusionObserver: NSObjectProtocol?
    private var itemObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    /// The resolved remote stream currently playing.
    private var remoteStream: TerminalRemoteVideoResolver.Stream?
    /// Bumped on every load so late yt-dlp results for an old source are dropped.
    private var loadGeneration = 0
    private var retryDelay: TimeInterval = 15
    private var refreshWorkItem: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        // Layer-hosting view: set the layer before wantsLayer.
        layer = playerLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        refreshWorkItem?.cancel()
    }

    func load(source: TerminalBackgroundVideoSource) {
        guard source != currentSource else { return }
        currentSource = source
        loadGeneration += 1
        retryDelay = 15
        reset()

        switch source {
        case .file(let url):
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            updatePlayback()

        case .remote(let url):
            resolveAndPlay(url, bypassCache: false)
        }
    }

    private func reset() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        remoteStream = nil
        player.removeAllItems()
    }

    // MARK: Remote streams

    private func resolveAndPlay(_ pageURL: URL, bypassCache: Bool) {
        let generation = loadGeneration
        TerminalRemoteVideoResolver.shared.resolve(pageURL, bypassCache: bypassCache) { [weak self] result in
            guard let self, generation == self.loadGeneration else { return }
            switch result {
            case .success(let stream):
                self.play(stream, pageURL: pageURL)
            case .failure(let error):
                Ghostty.logger.warning("background-video-url: \(error.localizedDescription, privacy: .public)")
                self.scheduleRetry(pageURL)
            }
        }
    }

    private func play(_ stream: TerminalRemoteVideoResolver.Stream, pageURL: URL) {
        reset()
        remoteStream = stream

        let item = AVPlayerItem(url: stream.mediaURL)
        // Streams can be 4K; the wallpaper never needs more than the window.
        item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.streamFailed(pageURL, item.error) }
        }
        itemObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            self?.streamFailed(pageURL, note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
        })
        itemObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.remoteStream?.isLive == true {
                // A livestream that "ended" usually just went offline; check again later.
                self.scheduleRetry(pageURL)
            } else {
                self.player.seek(to: .zero)
                self.updatePlayback()
            }
        })

        player.insert(item, after: nil)
        retryDelay = 15

        // Signed stream URLs (YouTube's googlevideo) expire after a few
        // hours. Swap in a fresh one before that happens.
        let refresh = DispatchWorkItem { [weak self] in
            self?.resolveAndPlay(pageURL, bypassCache: true)
        }
        refreshWorkItem = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + stream.refreshAfter, execute: refresh)

        updatePlayback()
    }

    private func streamFailed(_ pageURL: URL, _ error: Error?) {
        guard case .remote(let current) = currentSource, current == pageURL else { return }
        Ghostty.logger.warning("background-video-url stream failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        reset()
        scheduleRetry(pageURL)
    }

    private func scheduleRetry(_ pageURL: URL) {
        refreshWorkItem?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 600)
        let retry = DispatchWorkItem { [weak self] in
            self?.resolveAndPlay(pageURL, bypassCache: true)
        }
        refreshWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    // MARK: Playback

    // Clicks and drags go to the terminal, never to the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in self?.updatePlayback() }
        }
        updatePlayback()
    }

    private func updatePlayback() {
        guard let window, window.occlusionState.contains(.visible) else {
            player.pause()
            return
        }

        // A paused livestream falls behind; jump back to the live edge.
        if player.rate == 0,
           remoteStream?.isLive == true,
           let item = player.currentItem,
           let live = item.seekableTimeRanges.last?.timeRangeValue,
           live.duration.seconds > 0 {
            item.seek(to: live.end, completionHandler: nil)
        }
        player.play()
    }
}

/// Turns a page URL (YouTube watch/live/channel links and anything else
/// yt-dlp supports) into a media URL AVPlayer can play, usually HLS.
/// Results are shared between windows so N windows run yt-dlp once.
final class TerminalRemoteVideoResolver {
    struct Stream {
        let mediaURL: URL
        let isLive: Bool
        let resolvedAt: Date

        /// Re-resolve well before googlevideo's ~6h signature expiry.
        var refreshAfter: TimeInterval {
            mediaURL.host?.hasSuffix("googlevideo.com") == true ? 4 * 3600 : 12 * 3600
        }
    }

    enum ResolveError: LocalizedError {
        case ytDlpMissing
        case ytDlpFailed(String)

        var errorDescription: String? {
            switch self {
            case .ytDlpMissing:
                return "yt-dlp not found (install it with `brew install yt-dlp`)"
            case .ytDlpFailed(let message):
                return "yt-dlp failed: \(message)"
            }
        }
    }

    static let shared = TerminalRemoteVideoResolver()

    /// Muted wallpaper: prefer video-only HLS (what YouTube livestreams
    /// offer), capped at 1080p, then progressive H.264 MP4.
    private static let format = [
        "bv*[protocol^=m3u8][height<=1080]",
        "b[protocol^=m3u8]",
        "bv*[ext=mp4][vcodec^=avc1][height<=1080]",
        "b[ext=mp4]",
        "b",
    ].joined(separator: "/")

    /// Extensions AVPlayer plays directly, without yt-dlp.
    private static let directExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov"]

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.background-video-resolver")
    private var cache: [URL: Stream] = [:]
    private var pending: [URL: [(Result<Stream, Error>) -> Void]] = [:]

    /// Calls `completion` on the main queue.
    func resolve(_ pageURL: URL, bypassCache: Bool, completion: @escaping (Result<Stream, Error>) -> Void) {
        if Self.directExtensions.contains(pageURL.pathExtension.lowercased()) {
            let isLive = pageURL.pathExtension.lowercased() == "m3u8"
            completion(.success(Stream(mediaURL: pageURL, isLive: isLive, resolvedAt: Date())))
            return
        }

        queue.async {
            if !bypassCache, let cached = self.cache[pageURL],
               Date().timeIntervalSince(cached.resolvedAt) < cached.refreshAfter - 600 {
                DispatchQueue.main.async { completion(.success(cached)) }
                return
            }
            if self.pending[pageURL] != nil {
                self.pending[pageURL]?.append(completion)
                return
            }
            self.pending[pageURL] = [completion]

            let result = Result<Stream, Error>(catching: { try Self.runYtDlp(pageURL) })
            if case .success(let stream) = result { self.cache[pageURL] = stream }
            let waiters = self.pending.removeValue(forKey: pageURL) ?? []
            DispatchQueue.main.async { waiters.forEach { $0(result) } }
        }
    }

    private static func runYtDlp(_ pageURL: URL) throws -> Stream {
        guard let ytDlp = findYtDlp() else { throw ResolveError.ytDlpMissing }

        let process = Process()
        process.executableURL = ytDlp
        process.arguments = [
            "--no-warnings", "--no-playlist", "--quiet",
            "-f", format,
            "--print", "is_live",
            "--print", "urls",
            pageURL.absoluteString,
        ]
        // GUI apps get a bare PATH; yt-dlp needs a JS runtime (deno/node)
        // from the same places it was installed to.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchDirectories().map(\.path) + [env["PATH"] ?? "/usr/bin:/bin"])
            .joined(separator: ":")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let lines = String(decoding: out, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard process.terminationStatus == 0,
              lines.count >= 2,
              let mediaURL = URL(string: lines[1]) else {
            let message = String(decoding: err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ResolveError.ytDlpFailed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return Stream(mediaURL: mediaURL, isLive: lines[0] == "True", resolvedAt: Date())
    }

    private static func searchDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".nix-profile/bin"),
            URL(fileURLWithPath: "/run/current-system/sw/bin"),
        ]
    }

    private static func findYtDlp() -> URL? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
        return (searchDirectories() + pathDirs)
            .map { $0.appendingPathComponent("yt-dlp") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

// MARK: Glass

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private class TerminalGlassView: NSView, ObservableObject {
    /// We use this to apply glass effect to background colors
    ///
    struct GlassBackground: View {
        @ObservedObject var model: GlassViewModel

        var body: some View {
            model.color
                .glassEffect(
                    model.glass,
                    in: RoundedRectangle(cornerRadius: model.cornerRadius)
                )
        }
    }

    class GlassViewModel: ObservableObject {
        @Published var backgroundColor: Color = .clear
        @Published var backgroundOpacity: Double = 0
        @Published var cornerRadius: CGFloat = 0
        @Published var glass: Glass = .identity

        /// backgroundColor applied with backgroundOpacity
        var color: Color {
            backgroundColor.opacity(backgroundOpacity)
        }
    }

    private let glassEffectView: NSView
    private var topConstraint: NSLayoutConstraint!
    private let glassViewModel: GlassViewModel

    init(topOffset: CGFloat) {
        let viewModel = GlassViewModel()
        self.glassEffectView = NSHostingView(rootView: GlassBackground(model: viewModel))
        self.glassViewModel = viewModel
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Glass effect view fills this view.
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the glass, tint color, corner radius.
    func configure(
        glass: Glass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
    ) {
        glassViewModel.backgroundColor = Color(backgroundColor)
        glassViewModel.backgroundOpacity = backgroundOpacity
        glassViewModel.cornerRadius = cornerRadius ?? 0
        glassViewModel.glass = glass
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }
}
#endif // compiler(>=6.2)

extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
            return nil
        }
        let effectView = TerminalGlassView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    private func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), let derivedConfig else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }

        effectView.configure(
            glass: derivedConfig.glass.official,
            backgroundColor: derivedConfig.backgroundColor,
            backgroundOpacity: derivedConfig.backgroundOpacity,
            cornerRadius: derivedConfig.cornerRadius,
        )
#endif // compiler(>=6.2)
    }

    private func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let themeFrameView = windowThemeFrameView
        else {
            return
        }
        effectView.updateTopInset(-themeFrameView.safeAreaInsets.top)
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        let glass: BackportGlass
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(config: Ghostty.Config, preferredBackgroundColor: NSColor?, cornerRadius: CGFloat?) {
            switch config.backgroundBlur {
            case .macosGlassRegular:
                glass = .regular
            case .macosGlassClear:
                glass = .clear
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}
