import AVFoundation
import SwiftUI
import UIKit

struct LoopingVideoPlayer: UIViewRepresentable {
    let resourceName: String

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        LoopingPlayerUIView(resourceName: resourceName)
    }

    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {}
}

final class LoopingPlayerUIView: UIView {
    private var playerLayer = AVPlayerLayer()
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?

    init(resourceName: String) {
        super.init(frame: .zero)
        backgroundColor = .black
        setupPlayer(resourceName: resourceName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    private func setupPlayer(resourceName: String) {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else {
            return
        }

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none

        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)

        player.play()
    }
}
