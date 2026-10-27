import SwiftUI

/// Full-screen landscape geometry measured from the supplied 1280×588 reference.
/// Artwork and header stay fixed as the lyrics toolbar appears or disappears.
nonisolated struct PhoneLandscapePlayerMetrics {
    let size: CGSize
    var artworkFrame: CGRect {
        let side = min(size.height * (420.0 / 588.0), size.width * (420.0 / 1280.0))
        return CGRect(x: size.width * (126.0 / 1280.0), y: size.height * (85.0 / 588.0), width: side, height: side)
    }
    var controlsFrame: CGRect {
        let x = max(size.width * (600.0 / 1280.0), artworkFrame.maxX + 24)
        let top = size.height * (100.0 / 588.0)
        return CGRect(x: x, y: top, width: max(0, size.width - x - size.width * (106.0 / 1280.0)),
                      height: max(0, size.height - top))
    }
}

struct PhoneLandscapePlayerColumns<Artwork: View, Controls: View>: View {
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            let metrics = PhoneLandscapePlayerMetrics(size: geometry.size)
            let cover = metrics.artworkFrame
            let panel = metrics.controlsFrame
            ZStack(alignment: .topLeading) {
                artwork().frame(width: cover.width, height: cover.height)
                    .position(x: cover.midX, y: cover.midY)
                controls().frame(width: panel.width, height: panel.height)
                    .position(x: panel.midX, y: panel.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
