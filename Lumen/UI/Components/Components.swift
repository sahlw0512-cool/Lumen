import AVFoundation
import SwiftUI

enum Theme {
    static let cardRadius: CGFloat = 14
    static let panelRadius: CGFloat = 16
    static let gridSpacing: CGFloat = 22
    static let contentPadding: CGFloat = 28

    static let placeholderGradient = LinearGradient(
        colors: [Color(white: 0.22), Color(white: 0.12)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// Small capsule label used for metadata ("4K", "HDR", "60 fps").
struct Chip: View {
    let text: String
    var symbol: String?
    var prominent = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .background {
            if prominent {
                Capsule().fill(Color.accentColor)
            } else {
                Capsule().fill(.thinMaterial)
            }
        }
    }
}

/// Status indicator for a display's playback state.
struct StatusDot: View {
    let status: RendererStatus
    let pauseReason: PauseReason?

    private var color: Color {
        switch status {
        case .playing: .green
        case .paused: .orange
        case .loading: .blue
        case .failed: .red
        case .empty: .secondary
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: status == .playing ? 3 : 0)
    }

    static func label(status: RendererStatus, pauseReason: PauseReason?) -> String {
        switch status {
        case .paused: pauseReason.map { "Paused — \($0.title)" } ?? "Paused"
        case .failed(let message): "Failed — \(message)"
        default: status.title
        }
    }
}

/// Loads a library thumbnail from the bounded cache, falling back to a placeholder.
struct ThumbnailImage: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    @State private var image: CGImage?

    private var taskKey: String {
        "\(wallpaper.thumbnailFileName ?? "none")#\(model.thumbnailRevision(for: wallpaper.id))"
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.placeholderGradient)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .task(id: taskKey) {
            guard let name = wallpaper.thumbnailFileName else {
                image = nil
                return
            }
            let loaded = await model.thumbnails.image(named: name)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// AppKit-backed AVPlayerLayer host for in-app previews.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        if view.playerLayer.videoGravity != gravity {
            // AVPlayerLayer animates gravity changes implicitly, which reads nicely here.
            view.playerLayer.videoGravity = gravity
        }
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer { playerLayer }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        playerLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}

/// Native open panel for "Locate File…" (kept separate from the main
/// `.fileImporter` to avoid SwiftUI's one-importer-per-hierarchy limitation).
enum FilePanels {
    @MainActor
    static func chooseVideo(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "Choose"
        panel.allowedContentTypes = ImportService.importableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
