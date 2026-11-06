import AVFoundation
import Foundation

/// Plays one depot file as stored. No leveling and no sample-rate conversion.
@MainActor
final class DepotPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingAssetID: String?
    @Published private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(assetID: String, url: URL) throws {
        stop()
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.delegate = self
        audio.prepareToPlay()
        guard audio.play() else {
            throw CocoaError(.fileReadUnknown)
        }
        player = audio
        playingAssetID = assetID
        progress = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        if playingAssetID != nil || progress != 0 {
            playingAssetID = nil
            progress = 0
        }
    }

    private func tick() {
        guard let player else { return }
        if !player.isPlaying {
            stop()
            return
        }
        let duration = player.duration
        progress = duration > 0 ? min(1, player.currentTime / duration) : 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            stop()
        }
    }
}
