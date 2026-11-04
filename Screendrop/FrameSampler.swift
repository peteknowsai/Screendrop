//
//  FrameSampler.swift
//  Screendrop
//
//  Which moments of a recording Claude Code gets as stills: the first frame,
//  every scene change, at least one every ten seconds, and just after each
//  click. Decided on tiny 32×18 grey thumbnails, so only the picked moments
//  are ever decoded at full size.
//

import Foundation

nonisolated struct Thumb {
    let t: Double
    /// 32×18 luma, row by row.
    let luma: [UInt8]
}

/// How many of the thumbnail's cells moved by at least `threshold`.
nonisolated func changedBlocks(_ a: [UInt8], _ b: [UInt8], threshold: UInt8 = 24) -> Int {
    zip(a, b).count { abs(Int($0) - Int($1)) >= Int(threshold) }
}

nonisolated func pickFrames(
    _ thumbs: [Thumb],
    minBlocks: Int = 12,
    maxGap: Double = 10,
    clicks: [Double] = []
) -> [(t: Double, click: Int?)] {
    var picked: [(t: Double, click: Int?)] = []
    var last: Thumb?
    for thumb in thumbs {
        if let previous = last,
           thumb.t - previous.t < maxGap,
           changedBlocks(thumb.luma, previous.luma) < minBlocks {
            continue
        }
        picked.append((thumb.t, nil))
        last = thumb
    }
    // A quarter second after the click, once the screen has answered it.
    picked += clicks.enumerated().map { (t: $0.element + 0.25, click: $0.offset + 1) }
    // Clicks first at the same moment, so a scene frame can't shadow one.
    picked.sort { $0.t == $1.t ? $0.click != nil && $1.click == nil : $0.t < $1.t }

    var deduped: [(t: Double, click: Int?)] = []
    for frame in picked {
        if let kept = deduped.last, frame.t - kept.t < 0.1 {
            if kept.click == nil, frame.click != nil { deduped[deduped.count - 1] = frame }
            continue
        }
        deduped.append(frame)
    }
    return capped(deduped, at: 400)
}

/// Over the worker's limit: every click that fits, then scene frames spread
/// evenly over what's left, so the whole video stays covered.
private nonisolated func capped(_ frames: [(t: Double, click: Int?)], at limit: Int) -> [(t: Double, click: Int?)] {
    guard frames.count > limit else { return frames }
    func spread(_ list: [(t: Double, click: Int?)], _ count: Int) -> [(t: Double, click: Int?)] {
        guard count > 0, !list.isEmpty else { return [] }
        return (0..<min(count, list.count)).map { list[$0 * list.count / min(count, list.count)] }
    }
    let clicks = frames.filter { $0.click != nil }
    let keptClicks = spread(clicks, limit)
    let scenes = spread(frames.filter { $0.click == nil }, limit - keptClicks.count)
    return (keptClicks + scenes).sorted { $0.t < $1.t }
}
