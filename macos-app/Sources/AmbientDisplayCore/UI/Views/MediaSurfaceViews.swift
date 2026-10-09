import SwiftUI
import AppKit
import AVKit
import AVFoundation
import WebKit

// MARK: - Looping Video Player NSView
public struct LoopingVideoPlayerView: NSViewRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false

        let playerItem = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)

        context.coordinator.looper = playerLooper
        context.coordinator.player = queuePlayer

        playerView.player = queuePlayer
        queuePlayer.isMuted = true
        queuePlayer.play()

        return playerView
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Player loop remains running
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator {
        var looper: AVPlayerLooper?
        var player: AVQueuePlayer?
    }
}

// MARK: - Ambient Web Dashboard View
public struct AmbientWebView: NSViewRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Remote Ambient Image View
public struct RemoteAmbientImageView: View {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ZStack {
                    Color.black
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                ZStack {
                    Color.black
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Unable to load ambient image")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
            @unknown default:
                Color.black
            }
        }
    }
}
