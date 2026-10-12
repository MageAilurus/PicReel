// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import Foundation
import Photos
import AppKit
import CoreLocation
import ImageIO
import SwiftUI

struct Bucket: Identifiable, Equatable, Codable {
    /// Stable for the life of the bucket. Shown to the user as a POSITION
    /// (index + 1), not as this id: deleting the 2nd of 5 must not renumber the
    /// rest on screen, but it must also not make two tiles claim to be "3".
    var id: Int
    var name: String
    var count: Int = 0
}

/// Which bits of metadata appear under the card on the first-level page.
/// Configurable in 设置 so the caption can stay as quiet as the user wants.
enum CardInfoField: String, CaseIterable, Identifiable, Codable {
    case date, resolution, kind, location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date:       return "拍摄日期"
        case .resolution: return "分辨率"
        case .kind:       return "照片类型"
        case .location:   return "位置标记"
        }
    }

    var hint: String {
        switch self {
        case .date:       return "2026-10-11 21:22"
        case .resolution: return "1440×1920"
        case .kind:       return "截屏 / 实况照片 / 全景"
        case .location:   return "有 GPS 时标一下"
        }
    }
}

/// One photo in the deck.
///
/// Deliberately NOT `PHAsset` directly: the deck state machine (rotation,
/// delete queue, buckets, undo) should be testable without a real photo library
/// and without a screen. `asset` is nil only in headless self-tests.
struct SiftItem: Identifiable, Equatable {
    let id: String
    let date: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    /// 截屏 / 实况照片 / …；空字符串表示普通照片。
    let kind: String
    let hasLocation: Bool
    let asset: PHAsset?
    /// Only populated in `--demo` mode, where the deck is synthesised so that a
    /// screenshot never reveals anything from the user's real library.
    var demoImage: NSImage? = nil

    static func == (lhs: SiftItem, rhs: SiftItem) -> Bool { lhs.id == rhs.id }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Full description. Used for logs, the ⓘ panel and the delete list — never
    /// for the card caption, which is driven by `caption(for:)`.
    var label: String {
        let when = date.map { Self.stamp.string(from: $0) } ?? "无日期"
        return "\(when) · \(pixelWidth)×\(pixelHeight)"
    }

    /// What shows under the card, per the user's chosen fields.
    func caption(for fields: Set<CardInfoField>) -> String {
        var parts: [String] = []
        if fields.contains(.date), let date {
            parts.append(Self.stamp.string(from: date))
        }
        if fields.contains(.resolution), pixelWidth > 0 {
            parts.append("\(pixelWidth)×\(pixelHeight)")
        }
        if fields.contains(.kind), !kind.isEmpty {
            parts.append(kind)
        }
        if fields.contains(.location), hasLocation {
            parts.append("含位置")
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    static func from(_ asset: PHAsset) -> SiftItem {
        SiftItem(id: asset.localIdentifier,
                 date: asset.creationDate,
                 pixelWidth: asset.pixelWidth,
                 pixelHeight: asset.pixelHeight,
                 kind: PhotoStore.kindDescription(asset),
                 hasLocation: asset.location != nil,
                 asset: asset)
    }
}

/// Persisted user settings. Lives in `categories.json` — the filename is frozen
/// along with the bundle id, so upgrades keep reading the same file.
struct AppSettings: Codable {
    /// v0.6 and earlier: exactly five names, position-implicit. Kept so those
    /// files still load.
    var bucketNames: [String]?
    /// v0.7+: the whole list, with stable ids.
    var buckets: [Bucket]?
    var nextBucketID: Int?
    var cardFields: [String]
    var darkMode: Bool
    /// v0.8+: has the first-run guide been completed (or skipped)? `nil` in a
    /// v0.7 file means the user has technically used the app but never seen the
    /// guide, so they get it once — that is deliberate, the album picker is how
    /// the boxes get their real names.
    var hasOnboarded: Bool?
    /// v0.9+: achievement id -> unlock date (timeIntervalSince1970). A dictionary
    /// rather than an array so adding an achievement later cannot shift anyone's
    /// existing dates.
    var achievements: [String: Double]?
    /// v0.9+: was the deck in shuffle mode when the app last closed?
    var shuffleMode: Bool?
    /// v0.9+: has the user ticked「不再显示此提示」on the shuffle explainer?
    var shuffleIntroDismissed: Bool?
}

/// One album assignment waiting to be written.
///
/// Shuffle buffers these for the whole round and writes them in a single pass
/// when the round finishes. Cancelling a round therefore never has to reach back
/// into the photo library to undo itself — the library was never touched.
///
/// Stored as ids rather than `PHAsset` references because it is also written to
/// disk, so a quit or a crash cannot lose work the user never cancelled.
struct PendingAssignment: Codable, Equatable {
    var assetID: String
    var albumName: String
}

/// One of the user's own Photos albums, as offered in the guide's picker.
struct LibraryAlbum: Identifiable, Equatable {
    /// `PHAssetCollection.localIdentifier`. Display/identity only — a bucket
    /// maps to its album by NAME, because that is what the write path already
    /// looks up (`existingAlbum(named:)`).
    let id: String
    let name: String
    let count: Int
}

enum SiftCommand: Equatable {
    case next          // skip -> card goes to the BOTTOM of the deck
    case delete        // -> delete queue
    case back
    case classify(Int)
    case undo
    case commit
    case ignore
}

/// What just happened to a card, so the view knows which way to throw it.
enum CardAction: Equatable {
    case skip              // slide left, back to the bottom of the deck
    case delete            // fly up
    case classify(Int)     // fly into box n
}

/// The card's on-screen box. Lives here rather than in the view so the
/// self-test can lock the invariant that a card hugs its photo instead of
/// floating it inside a big padded frame.
enum CardLayout {
    /// Height of the info bar that sits BELOW the card, outside it.
    static let infoHeight: CGFloat = 34
    static let infoGap: CGFloat = 9

    /// The info bar's width. FIXED, deliberately not tied to the photo.
    ///
    /// Tracking the photo made the bar change width on every card (300 → 326 →
    /// 435 → 580 → 844 …), so the one element that should look stable was the
    /// only thing moving. 360pt fits a date plus a location without crowding.
    static let infoWidth: CGFloat = 360

    /// The card IS the photo: the box is the photo's own aspect ratio fitted into
    /// the stage. No caption strip is reserved inside it any more — the info bar
    /// lives outside, so a 1:4 portrait no longer eats its own info space.
    static func box(pixelWidth: Int, pixelHeight: Int, in stage: CGSize) -> CGSize {
        let maxWidth = max(160, stage.width - 56)
        let maxHeight = max(140, stage.height - 28)
        let ratio: CGFloat = (pixelWidth > 0 && pixelHeight > 0)
            ? CGFloat(pixelWidth) / CGFloat(pixelHeight)
            : 4.0 / 3.0

        var width = maxWidth
        var height = width / ratio
        if height > maxHeight {
            height = maxHeight
            width = max(60, height * ratio)
        }
        return CGSize(width: width, height: height)
    }

    /// How far to shrink the card at `index` in the pile.
    ///
    /// The card keeps its OWN shape (so its proportions never snap when it stops
    /// being the front one — that was the v0.5 undo bug), but it is scaled down
    /// until it fits inside the front card's footprint. Without this a landscape
    /// photo sitting behind a portrait one sticks out ~240pt on each side and
    /// the pile reads as a tray.
    static func backScale(own: CGSize, front: CGSize, index: Int) -> CGFloat {
        guard index > 0 else { return 1 }
        let fit = min(1, front.width / own.width, front.height / own.height)
        return fit * (1 - CGFloat(index) * 0.05)
    }
}

/// Where the storage boxes sit and how wide they are.
///
/// Shared by the box row and the classify flight — if the two computed the row
/// independently, a card would fly to where the boxes *used* to be.
enum BoxLayout {
    static let rowHeight: CGFloat = 118
    static let maxTileWidth: CGFloat = 168
    static let minTileWidth: CGFloat = 48
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 22

    /// Tiles split the row evenly, capped so a single category doesn't become a
    /// slab and ten don't become slivers.
    static func tileWidth(count: Int, stageWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let gaps = spacing * CGFloat(count - 1)
        let available = stageWidth - horizontalPadding * 2 - gaps
        return max(minTileWidth, min(maxTileWidth, available / CGFloat(count)))
    }

    /// Centre-x of the tile at `position` (1-based), in stage coordinates.
    static func tileCentreX(position: Int, count: Int, stageWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return stageWidth / 2 }
        let width = tileWidth(count: count, stageWidth: stageWidth)
        let row = width * CGFloat(count) + spacing * CGFloat(count - 1)
        let left = (stageWidth - row) / 2
        let index = CGFloat(max(1, min(position, count)) - 1)
        return left + index * (width + spacing) + width / 2
    }
}

struct OutgoingCard: Identifiable {
    /// A card currently animating off the top of the deck.
    let id: UUID
    let item: SiftItem
    let action: CardAction
    /// Snapshot of the image at launch time. Without this the flying card and
    /// the freshly-revealed card below it both read the single shared preview,
    /// so the outgoing photo briefly wears the incoming photo's face.
    let image: NSImage?
    var launched: Bool = false
}

/// A card flying back IN after an undo. Starts at the offset its `action` sends
/// cards to, and lands on the top of the deck.
struct ReturningCard: Identifiable {
    let id: UUID
    let item: SiftItem
    let action: CardAction
    let image: NSImage?
    var landed: Bool = false
}

/// Everything the ⓘ panel shows.
struct PhotoDetails {
    var created: String = "—"
    var dimensions: String = "—"
    var fileSize: String = "—"
    var camera: String = "—"
    var lens: String = "—"
    var exposure: String = "—"
    var coordinate: String? = nil
    var place: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var isFavorite: Bool = false
    var source: String = "—"
}

private enum DeckAction {
    case skip(item: SiftItem)
    case delete(item: SiftItem)
    case classify(item: SiftItem, bucket: Int)
}

final class PhotoStore: ObservableObject, @unchecked Sendable {

    static let shared = PhotoStore()

    // MARK: - Deck state

    /// The working deck. `deck[0]` is the card in front.
    ///
    /// Invariant that makes this whole design work: the deck only shrinks when
    /// the user actually decides something (delete / classify). Skipping moves
    /// the card to the back, so `deck.isEmpty` means "every photo is decided".
    @Published var deck: [SiftItem] = []
    @Published var totalCount: Int = 0
    /// Concurrently-flying cards. A single slot made rapid presses cut the
    /// previous flight short mid-air; every launch gets its own.
    @Published var flying: [OutgoingCard] = []
    @Published var pendingDeletes: [SiftItem] = []
    /// Categories are user-managed now: 0 to `maxBuckets`, add/remove from the
    /// 分类 sheet. `id` is bookkeeping; what the user sees and presses is the
    /// POSITION (index + 1).
    @Published var buckets: [Bucket] = (1...5).map { Bucket(id: $0, name: "分类\($0)") }
    @Published var pulsingBucket: Int?
    private var nextBucketID: Int = 6

    /// The user's own albums, for the guide's picker.
    @Published var libraryAlbums: [LibraryAlbum] = []

    /// One thumbnail per album, keyed by album id, for the picker's rows. A name
    /// alone does not tell you whether 「存档」 is screenshots or holiday photos.
    @Published var albumThumbnails: [String: NSImage] = [:]

    /// Side of the album preview in the guide's rows, in points.
    static let albumThumbSide: CGFloat = 34

    /// First-run guide. `nil` = not showing; 0 = 欢迎页, 1 = 选相簿页,
    /// 2 = 使用教程页（`guideLastStep`）。
    @Published var guideStep: Int?
    /// Drives the guide's entrance animations. Held here rather than as view
    /// state because CLT's SDK cannot compile `@State` (see the skill), and
    /// because "everything arrives" is a fact about the guide, not about a view.
    @Published var guideRevealed = false
    /// Which albums are ticked on the picker page — **in the order they were
    /// ticked**. That order IS the numbering: the first row you tick answers to
    /// `1`, whatever row of the list it happens to be. Held here rather than in
    /// the view so "selection → which box gets which number" is testable
    /// headlessly. (Was a `Set` until 0.82, which forced library order onto the
    /// numbers: ticking the bottom row first still gave it the last number.)
    @Published var guideSelection: [String] = []
    private var hasOnboarded = false

    var isGuiding: Bool { guideStep != nil }

    static let maxBuckets = 10

    var canAddBucket: Bool { buckets.count < Self.maxBuckets }

    /// 1-based position of a bucket id, i.e. what its tile shows.
    func bucketPosition(id: Int) -> Int? {
        buckets.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    @discardableResult
    func addBucket() -> Bool {
        guard canAddBucket else { return false }
        let id = nextBucketID
        nextBucketID += 1
        buckets.append(Bucket(id: id, name: "分类\(buckets.count + 1)"))
        saveSettings()
        log("新增分类「\(buckets[buckets.count - 1].name)」   [共 \(buckets.count) 个]")
        return true
    }

    /// Removing a category drops the in-app record of what went into it. It does
    /// NOT touch the library: in write mode those photos are already sitting in
    /// the Photos album of the same name, and in 演练 mode nothing was written to
    /// begin with. So nothing is ever silently lost here.
    func removeBucket(id: Int) {
        guard let index = buckets.firstIndex(where: { $0.id == id }) else { return }
        let name = buckets[index].name
        let dropped = bucketMembers[id]?.count ?? 0
        buckets.remove(at: index)
        bucketMembers.removeValue(forKey: id)
        if pulsingBucket == id { pulsingBucket = nil }
        saveSettings()
        log("删除分类「\(name)」   [丢弃 \(dropped) 条记录，图库未改动，共剩 \(buckets.count) 个]")
    }

    func renameBucket(id: Int, to name: String) {
        guard let index = buckets.firstIndex(where: { $0.id == id }) else { return }
        buckets[index].name = name
        saveSettings()
    }

    // MARK: - First-run guide

    /// Guide timings, on the same `--slowmo` contract as the flight: a 0.3s
    /// cross-fade cannot be caught by a ~100ms screenshot, and cannot be eyeballed
    /// either, so every animation needs a way to be stretched for verification.
    static let guidePageDuration: Double = slowMotion ? 1.6 : 0.32
    static let guideRevealDuration: Double = slowMotion ? 1.5 : 0.44
    /// Gap between consecutive pieces of a page arriving.
    static let guideRevealStagger: Double = slowMotion ? 0.4 : 0.075
    /// Album rows arrive faster than the big furniture, and **the delay is
    /// capped**: 43 rows × per-row stagger would leave the last rows sitting
    /// invisible for over a second on a big library.
    static let guideRowStagger: Double = slowMotion ? 0.22 : 0.03
    static let guideRowStaggerCap = 8

    /// Delay before the `index`-th item of a page starts arriving.
    static func guideDelay(_ index: Int) -> Double {
        Double(index) * guideRevealStagger
    }

    /// Delay before the `index`-th album row arrives.
    static func guideRowDelay(_ index: Int) -> Double {
        Double(min(index, guideRowStaggerCap)) * guideRowStagger
    }

    /// `--guide` (page 1) or `--guide=2` (page 2). For screenshots, and for
    /// looking at either page without clicking through the whole flow.
    static var forcedGuideStep: Int? {
        for arg in CommandLine.arguments where arg.hasPrefix("--guide") {
            if let eq = arg.firstIndex(of: "="), let n = Int(arg[arg.index(after: eq)...]) {
                return max(0, n - 1)
            }
            return 0
        }
        return nil
    }

    /// Show the guide. `force` is what the menu-bar item and `--guide` use: the
    /// user asked for it again even though they have been through it.
    func startGuide(force: Bool = false) {
        guard force || !hasOnboarded else { return }
        guideSelection.removeAll()
        // Start from the hidden state; the view's `onAppear` runs the entrance.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            guideRevealed = false
            guideStep = 0
        }
        log("引导 · 开始（\(force ? "手动重跑" : "首次启动")）")
    }

    /// Called from `bootstrap`, after settings are in. Handles both "never seen
    /// it" and the forcing flags.
    func openRequestedGuide() {
        if let forced = Self.forcedGuideStep {
            guideStep = forced
            log("引导 · 打开第 \(forced + 1) 页（--guide）")
            scheduleGuideFlow()
            return
        }
        // Demo mode never auto-opens it: a demo launch is about the deck, and the
        // screenshots would all come out as the guide.
        guard !Self.isDemo else { return }
        startGuide()
        scheduleGuideFlow()
    }

    /// `--guideflow` steps to the next page on a timer.
    ///
    /// Synthetic clicks do not reach SwiftUI buttons in every environment (see
    /// the `macos-app-clt-only` skill), so the one animation you cannot trigger
    /// by hand here — the page push — would otherwise be unverifiable. Driving
    /// it from code lets it be recorded frame by frame under `--slowmo`.
    private func scheduleGuideFlow() {
        guard CommandLine.arguments.contains("--guideflow") else { return }
        log("引导 · --guideflow：1.6s 后自动翻到下一页")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.advanceGuide()
        }
        // …and then walk off the end, so the dismissal animation is recorded too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { [weak self] in
            self?.finishGuide()
        }
    }

    /// The guide's pages: 0 = 欢迎, 1 = 选相簿, 2 = 使用教程（只看不改的那页）.
    /// Kept here so `advanceGuide` cannot walk off the end into a blank page and
    /// so the self-test can pin the page count.
    static let guideLastStep = 2

    func advanceGuide() {
        guard let step = guideStep, step < Self.guideLastStep else { return }
        hideGuideContent()
        withAnimation(.spring(response: Self.guidePageDuration, dampingFraction: 0.9)) {
            guideStep = step + 1
        }
    }

    /// Run the current page's entrance. The view calls this from `onAppear`:
    /// everything must mount in its "before" position first, because
    /// `.animation(value:)` only fires on a CHANGE — mounting already-revealed
    /// would just pop in with nothing to animate.
    func revealGuide() {
        hideGuideContent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: Self.guideRevealDuration)) {
                self.guideRevealed = true
            }
        }
    }

    /// Snap everything back to its "not arrived yet" state with no animation.
    ///
    /// `.animation(value:)` fires on BOTH ends of a flip, so resetting inside an
    /// animated transaction would make the page visibly rewind through the
    /// entrance it just played before the new one starts.
    private func hideGuideContent() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { guideRevealed = false }
    }

    func toggleGuideSelection(_ albumID: String) {
        if let index = guideSelection.firstIndex(of: albumID) {
            guideSelection.remove(at: index)
        } else {
            guard guideSelection.count < Self.maxBuckets else { return }
            // Appending is what makes the numbering follow the hand: the tick
            // that just happened takes the next number, and unticking closes the
            // gap so the numbers on screen never have a hole in them.
            guideSelection.append(albumID)
        }
    }

    /// Ticked albums, in the order they were ticked.
    var guidePickedAlbums: [LibraryAlbum] {
        guideSelection.compactMap { id in libraryAlbums.first { $0.id == id } }
    }

    /// The shortcut number this album would get if the guide finished right now.
    /// `nil` = not ticked. The row badge shows exactly this, so the numbers on
    /// screen are always the numbers that will actually work.
    func guidePosition(for album: LibraryAlbum) -> Int? {
        guideSelection.firstIndex(of: album.id).map { $0 + 1 }
    }

    /// The shortcut number finally assigned, for pages that want to show "已选".
    var guidePickedCount: Int { guidePickedAlbums.count }

    /// Commit the guide. Ticked albums become the boxes **in tick order**, so the
    /// first row the user clicked answers to `1`, the second to `2`, … and the
    /// tenth to `0` — a key press lands where the badge promised it would.
    func finishGuide() {
        let picked = Array(guidePickedAlbums.prefix(Self.maxBuckets))
        if picked.isEmpty {
            // 跳过，或者一个都没勾：保留用户已有的分类，不动他们的设置。
            log("引导 · 完成：未选择相簿，分类保持 \(buckets.count) 个")
        } else {
            // A bucket writes to its album by NAME (`existingAlbum(named:)`), so
            // naming the box after the album is all the wiring the mapping needs.
            var fresh: [Bucket] = []
            for album in picked {
                fresh.append(Bucket(id: nextBucketID, name: album.name))
                nextBucketID += 1
            }
            // Ids change wholesale here, so the old in-app tallies are dropped.
            // Same policy as removeBucket: the library itself is untouched.
            buckets = fresh
            bucketMembers.removeAll()
            log("引导 · 完成：\(fresh.count) 个分类 ← \(picked.map(\.name).joined(separator: "/"))")
        }
        hasOnboarded = true
        guideSelection.removeAll()
        saveSettings()
        refocus()
        // Leaving is animated too, so the deck is revealed rather than snapped to.
        withAnimation(.easeIn(duration: Self.guidePageDuration * 0.8)) {
            guideStep = nil
        }
    }

    /// The keyboard works in positions (1…9 and 0 → 10), never in ids.
    func classify(atPosition position: Int) {
        guard position >= 1, position <= buckets.count else { return }
        classify(buckets[position - 1].id)
    }

    /// Small thumbnails for the two cards behind the front one, so the deck
    /// looks like a deck instead of grey slabs — obvious during the undo flight.
    @Published var upcomingImages: [String: NSImage] = [:]

    /// Cards flying IN — the undo animation. Mirrors `flying`.
    @Published var returning: [ReturningCard] = []

    // MARK: - UI state

    @Published var authStatus: PHAuthorizationStatus = .notDetermined
    @Published var dryRun: Bool = true
    @Published var logLines: [String] = []
    @Published var statusText: String = "启动中…"
    @Published var preview: NSImage?
    @Published var previewBusy: Bool = false
    @Published var committing: Bool = false
    @Published var lastKey: String = "—"
    @Published var albumCount: Int = 0
    @Published var lastAction: CardAction?

    /// Photos the user has dealt with: filed into a category, queued for
    /// deletion, or **already sitting in a category album** when the app started.
    ///
    /// Explicit rather than derived from `deck.count` (which is how it used to
    /// work): shuffle mode replaces the deck with twenty cards, and a derived
    /// number would jump by thousands the moment you pressed the dice.
    @Published private(set) var decidedCount = 0

    /// What those decisions were, so shuffle can tell what is left.
    private var decidedIDs: Set<String> = []

    /// Photos found already filed in a category album at startup.
    @Published private(set) var alreadyFiledCount = 0

    // MARK: Shuffle

    /// Photos that were never in a category album when the app started.
    private var unfiledPool: [SiftItem] = []
    /// The deck to come back to when shuffle is switched off.
    private var preShuffleDeck: [SiftItem] = []
    @Published var shuffleMode = false

    /// Shuffle flips the deck under you — twenty random photos instead of the
    /// order you were working through — so it explains itself the first time.
    ///
    /// The tick box lives here rather than in the view because this build has no
    /// `@State` (CLT ships no `SwiftUIMacros`), so view-local state is not an
    /// option.
    @Published var showShuffleIntro = false
    @Published var shuffleIntroDismissed = false
    @Published var skipShuffleIntro = false

    /// Asking what to do with an unfinished round when the user leaves early.
    @Published var showShuffleExitConfirm = false
    /// Index into `history` where the current shuffle round was dealt.
    private var shuffleRoundStart = 0

    /// Classifications made this round but **not yet written** to the library.
    ///
    /// Shuffle defers the whole round: pressing 1 updates what you see (the box
    /// count, 已整理, the achievements) but the album write waits until the round
    /// finishes. That is what makes cancelling a round a purely local operation
    /// — nothing out there to take back.
    private var roundAssignments: [PendingAssignment] = []

    /// Exposed for the headless self-test.
    var roundAssignmentCount: Int { roundAssignments.count }

    /// How many cards a shuffle round deals.
    static let shuffleSize = 20

    // MARK: Achievements

    /// Achievement id -> unlock date.
    @Published var unlockedAchievements: [String: Date] = [:]
    /// Unlocks waiting to be announced. A queue, because crossing two thresholds
    /// at once (resuming a big library) would otherwise show only the last one.
    @Published var achievementQueue: [Achievement] = []

    // MARK: - Sheets (no `@State` needed: the store owns the flags)

    @Published var showCategories = false
    @Published var showTrash = false
    @Published var showSettings = false
    @Published var deleteThumbnails: [String: NSImage] = [:]

    // MARK: - User settings

    /// Which metadata shows under the card on the first-level page.
    @Published var cardFields: Set<CardInfoField> = [.date]
    @Published var darkMode = false

    // MARK: - ⓘ details

    @Published var showDetails: Bool = false
    @Published var details: PhotoDetails?
    @Published var detailsLoading: Bool = false

    // MARK: - Private

    private var history: [DeckAction] = []
    private var bucketMembers: [Int: [SiftItem]] = [:]
    private var imageRequest: PHImageRequestID?
    private var detailsRequest: PHImageRequestID?
    private var bootstrapped = false
    private var logHandle: FileHandle?
    private var previewDecodes = 0
    private var upcomingRequests = Set<String>()
    /// Counts how many times the deck asked for a fresh preview. The self-test
    /// asserts this, which is what would have caught the "photo never changes"
    /// bug: each navigation must request a new image.
    private(set) var previewRequests = 0

    /// Exposed only so the headless self-test can assert on it.
    var historyDepth: Int { history.count }

    // MARK: - Paths

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PhotoSift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configURL: URL { supportDir.appendingPathComponent("categories.json") }
    static var runLogURL: URL { supportDir.appendingPathComponent("run.log") }
    /// A shuffle round in flight. Kept in its own tiny file rather than in
    /// `categories.json`: it changes on every key press, and the settings file
    /// is for things the user set, not for work in progress.
    static var pendingRoundURL: URL {
        supportDir.appendingPathComponent("pendingRound.json")
    }

    /// `--demo` swaps the whole photo source for generated samples, so nothing
    /// from the real library can leak into a screenshot or a demo.
    static let isDemo = CommandLine.arguments.contains("--demo")
    static let isSelfTest = CommandLine.arguments.contains("--selftest")
    static let appName = "PicReel"

    /// `--open=trash|categories|settings` presents a secondary panel straight
    /// away. Used to screenshot/verify the panels, which cannot be reached by
    /// synthetic clicks in every environment.
    private static var panelToOpenAtLaunch: String? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--open=") }) else { return nil }
        return String(argument.dropFirst("--open=".count))
    }

    private func openRequestedPanel() {
        guard let panel = Self.panelToOpenAtLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            switch panel {
            case "trash":
                self.loadDeleteThumbnails()
                self.showTrash = true
            case "categories": self.showCategories = true
            case "settings":   self.showSettings = true
            case "details":
                self.loadDetails()
                self.showDetails = true
            default:           self.note("unknown --open target: \(panel)")
            }
        }
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        startRunLog()

        loadSettings()
        applyAppearance()
        openRequestedGuide()
        // Before the demo branch returns, so the motion mode is always on record.
        log("动效 · \(Self.slowMotion ? "慢放(--slowmo)" : "常态")"
            + " · 翻页 \(Self.guidePageDuration)s · 入场 \(Self.guideRevealDuration)s")

        if Self.isDemo {
            authStatus = .authorized
            dryRun = true
            log("启动 · 演示模式（合成示例图，完全不读图库）")
            loadDemoLibrary()
            openRequestedPanel()
            return
        }

        log("启动 · 权限状态 \(Self.describe(authStatus))")

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authStatus = status
                self.log("授权结果：\(Self.describe(status))")
                if status == .authorized || status == .limited {
                    self.loadLibrary()
                    // A shuffle round interrupted by a quit or a crash gets
                    // applied here — the user never cancelled it, so the work was
                    // wanted. Runs after the library so the albums exist.
                    self.applyInterruptedRound()
                } else {
                    self.statusText = "没有图库权限 —— 系统设置 › 隐私与安全性 › 照片"
                    self.log("未获得权限，无法读取图库。")
                }
            }
        }
    }

    /// Demo deck: 24 synthetic photos, with a handful already decided so the
    /// screenshot shows a realistic mid-session state.
    func loadDemoLibrary() {
        let all = DemoLibrary.items(count: 24)
        deck = all
        totalCount = all.count
        // How many categories exist is the user's call now, so the demo can't
        // assume five. Seeding is best-effort, and 0 categories must not crash.
        for i in buckets.indices {
            if i < DemoLibrary.bucketNames.count { buckets[i].name = DemoLibrary.bucketNames[i] }
            buckets[i].count = 0
        }
        history.removeAll()
        bucketMembers.removeAll()
        pendingDeletes.removeAll()

        var decided: [SiftItem] = []
        for _ in 0..<7 { decided.append(deck.removeFirst()) }
        pendingDeletes = [decided[0], decided[1]]
        // Box counts that add up to the filed total: 312+198+154+96+52 = 812.
        let demoFiled = [312, 198, 154, 96, 52]
        for i in buckets.indices where i < demoFiled.count { buckets[i].count = demoFiled[i] }

        // Demo stand-ins for the v0.9 state: a plausible already-filed pile so
        // the readouts have real-looking numbers, and two earned badges so the
        // panel shows both a lit and a locked one.
        //
        // The synthetic library is only 24 photos but stands in for a real one,
        // so the total is faked too — without it the progress reads
        // "第 820 / 24 张", which looks like a bug in the screenshot.
        alreadyFiledCount = 812
        totalCount = 1200
        unfiledPool = deck
        decidedIDs = []
        decidedCount = alreadyFiledCount + 7
        unlockedAchievements = [
            Achievement.firstLaunch.id: Date(timeIntervalSinceNow: -86_400 * 40),
            Achievement.hundred.id:     Date(timeIntervalSinceNow: -86_400 * 12),
        ]
        statusText = "演示模式 · 合成示例图"
        // The picker page needs albums too, or the guide is empty in --demo and
        // the screenshot shows nothing worth looking at.
        libraryAlbums = DemoLibrary.albums
        // If the guide is up (--guide), pre-tick a few. Otherwise every row shows
        // a "–" and the one thing this page is about — that the number in the
        // circle IS the shortcut key — is invisible in the screenshot.
        //
        // Ticked out of list order on purpose: the badges must read 2, 1, 3 down
        // the list, which is what "编号跟点击顺序走" actually looks like. A
        // top-down pre-tick would look identical under either rule and would
        // prove nothing about the fix.
        if guideStep != nil {
            for index in [1, 0, 2] where index < DemoLibrary.albums.count {
                guideSelection.append(DemoLibrary.albums[index].id)
            }
        }
        albumThumbnails = DemoLibrary.albumThumbnails
        albumCount = libraryAlbums.count
        if shuffleMode { enterShuffle() }
        // --shuffleexit: drive the app into the early-exit prompt so it can be
        // photographed. Same reason as --shuffle — no synthetic click reaches a
        // SwiftUI button in this environment.
        if Self.shuffleExitFlag {
            if !shuffleMode { enterShuffle() }
            perform(.classify(1))
            perform(.classify(2))
            perform(.classify(2))
            perform(.delete)
            toggleShuffle()
        }
        if Self.forceAchievementFlag { forceAchievementToast() }
        loadPreview()
        log("演示模式：24 张合成示例图，预置 7 张已处理、\(libraryAlbums.count) 个示例相簿")
    }

    func loadLibrary() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)

        var collected: [SiftItem] = []
        collected.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            collected.append(SiftItem.from(asset))
        }

        // Photos already sitting in a category album count as dealt with: they
        // must not come back around, and 已整理 should describe the whole job,
        // not this session. This is the difference between a 19,000-photo pool
        // and the couple of hundred you have left.
        let scan = scanCategoryAlbums()
        adoptFiledPhotos(ids: scan.ids, counts: scan.counts, library: collected)
        history.removeAll()
        bucketMembers.removeAll()
        pendingDeletes.removeAll()

        let albumResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var found: [LibraryAlbum] = []
        albumResult.enumerateObjects { collection, _, _ in
            // `estimatedAssetCount` is O(1) but returns NSNotFound when it can't
            // estimate. Rendering that as "0" would claim an album is empty when
            // it may well not be, so that single case pays for a real count.
            let estimate = collection.estimatedAssetCount
            let count = estimate == NSNotFound
                ? PHAsset.fetchAssets(in: collection, options: nil).count
                : estimate
            found.append(LibraryAlbum(id: collection.localIdentifier,
                                      name: collection.localizedTitle ?? "未命名相簿",
                                      count: count))
        }
        // Sorted so the picker is predictable, and so the shortcut numbers a
        // user ends up with depend only on which albums they tick.
        libraryAlbums = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        albumCount = libraryAlbums.count

        log("载入图库：\(collected.count) 张照片、\(libraryAlbums.count) 个自建专辑"
            + " · 已在分类里 \(alreadyFiledCount) 张 · 未整理 \(deck.count) 张")
        statusText = collected.isEmpty ? "图库里没有照片" : "就绪"
        if shuffleMode { enterShuffle() }
        unlockFirstLaunch()
        checkAchievements()
        if Self.forceAchievementFlag { forceAchievementToast() }
        loadPreview()
        openRequestedPanel()

        if CommandLine.arguments.contains("--keyprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refocus()
                self?.runKeyProbe()
            }
        }
        if CommandLine.arguments.contains("--writetest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runWriteTest()
            }
        }
        if CommandLine.arguments.contains("--detailsprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.runDetailsProbe()
            }
        }
        loadAlbumThumbnails()
    }

    /// One preview image per album, for the guide's rows.
    ///
    /// Asynchronous on purpose: the picker has to come up the moment it is asked
    /// for, and a 43-album library should not hold the window hostage while 43
    /// images are fetched. Rows draw a placeholder and fill in as they land.
    private func loadAlbumThumbnails() {
        let manager = PHImageManager.default()
        let side = Self.albumThumbSide * 2      // retina
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat       // a hint, not a print
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true   // albums in iCloud only

        for album in libraryAlbums {
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [album.id], options: nil)
            guard let collection = collections.firstObject else { continue }

            let fetch = PHFetchOptions()
            fetch.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetch.fetchLimit = 1
            guard let asset = PHAsset.fetchAssets(in: collection, options: fetch).firstObject
            else { continue }   // an empty album keeps its placeholder

            manager.requestImage(for: asset,
                                 targetSize: NSSize(width: side, height: side),
                                 contentMode: .aspectFill,
                                 options: options) { [weak self] image, _ in
                guard let image else { return }
                DispatchQueue.main.async { self?.albumThumbnails[album.id] = image }
            }
        }
    }

    // MARK: - Key mapping (pure — what the self-test pins down)

    static func command(keyCode: UInt16,
                        characters: String,
                        isCommand: Bool,
                        isShift: Bool) -> SiftCommand {
        if isCommand {
            if keyCode == 36 { return .commit }                        // ⌘⏎
            if characters.lowercased() == "z" { return .undo }         // ⌘Z
            return .ignore
        }
        switch keyCode {
        case 125, 124: return .next          // ↓ and →
        case 126:      return .delete        // ↑
        case 123:      return .back          // ←
        default:       break
        }
        // 分类键按**位置**算：1…9，第 10 个用 0。id 只是内部账，用户看到和按下的
        // 都是位置。
        if !isShift, let digit = Int(characters) {
            if (1...9).contains(digit) { return .classify(digit) }
            if digit == 0 { return .classify(10) }
        }
        return .ignore
    }

    static func keyLabel(_ command: SiftCommand) -> String {
        switch command {
        case .next:            return "→"
        case .delete:          return "↑"
        case .back:            return "←"
        case .classify(let n): return "\(n)"
        case .undo:            return "⌘Z"
        case .commit:          return "⌘⏎"
        case .ignore:          return "—"
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        note("keyDown code=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") mods=\(event.modifierFlags.rawValue)")
        // 引导流程期间一律不接快捷键。屏幕上显示的是引导，不是牌堆 ——
        // 这时候按 ↑ 会给用户的真实照片打上删除标记。
        guard !isGuiding else { return false }
        guard !committing else { return false }
        let command = Self.command(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers ?? "",
            isCommand: event.modifierFlags.contains(.command),
            isShift: event.modifierFlags.contains(.shift)
        )
        guard command != .ignore else { return false }
        lastKey = Self.keyLabel(command)
        return perform(command)
    }

    @discardableResult
    func perform(_ command: SiftCommand) -> Bool {
        switch command {
        case .next:            skip()
        case .delete:          markDelete()
        case .back:            back()
        case .classify(let position): classify(atPosition: position)
        case .undo:            undo()
        case .commit:          commit()
        case .ignore:          return false
        }
        return true
    }

    // MARK: - Deck operations

    var current: SiftItem? { deck.first }

    /// Only the cards we actually draw — the deck can hold 19k items.
    /// Two, not three: a third card was invisible at rest but its edge kept
    /// poking out during animations.
    var topCards: [SiftItem] { Array(deck.prefix(2)) }

    var progressText: String {
        if shuffleMode {
            return "Shuffle · 这轮还剩 \(deck.count) 张 · 已整理 \(decidedCount)"
        }
        return totalCount == 0
            ? "—"
            : "第 \(decidedCount + 1) / \(totalCount) 张 · 已整理 \(decidedCount)"
    }

    var allDone: Bool { totalCount > 0 && deck.isEmpty }

    /// 空格 / → / ↓：跳过。卡片滑走，然后**回到堆底**——它没有被处理，
    /// 之后还会再转回来。所以只有 delete / classify 会让牌堆变小。
    func skip() {
        guard let card = current else { return }
        launch(card, .skip)
        rememberFrontForEntry()
        deck.removeFirst()
        deck.append(card)
        history.append(.skip(item: card))
        loadPreview()
        log("跳过 · \(card.label)   [剩 \(deck.count)]")
    }

    // MARK: - Pile entry (the incoming front card's size)

    /// Pixel size of the front card just before the current one took over.
    ///
    /// A card that was sitting behind is drawn *shrunk* to fit in the front card's
    /// footprint, so when it becomes the front it has to GROW from that size to
    /// full size. Without this the frame it takes over jumps straight to 100% —
    /// with a wide photo behind a narrow one that is a 3–4x pop in a single frame.
    @Published var previousFront: PixelSize?

    struct PixelSize: Equatable {
        var width: Int
        var height: Int
    }

    /// True while the newest outgoing card is still parked over the deck — which
    /// is exactly the window where the pile must sit at its entry scale.
    ///
    /// Deliberately derived from the flying card instead of its own flag+timer:
    /// appending that card is a STRUCTURAL change, so SwiftUI is guaranteed to
    /// commit a frame showing it at rest. A private flag flipped by its own
    /// `asyncAfter` races the display refresh and gets coalesced away — the body
    /// evaluates at the entry scale, no frame is ever committed, and the pile
    /// jumps straight to full size. That is the flash this code exists to stop.
    var pileAtEntry: Bool {
        guard previousFront != nil else { return false }
        return flying.last?.launched == false
    }

    private func rememberFrontForEntry() {
        guard let card = current else {
            previousFront = nil
            return
        }
        previousFront = PixelSize(width: card.pixelWidth, height: card.pixelHeight)
    }

    /// Undo/back bring a card in from off-screen, so there is nothing to grow from.
    private func forgetFrontForEntry() {
        previousFront = nil
    }

    func markDelete() {
        guard let card = current else { return }
        launch(card, .delete)
        rememberFrontForEntry()
        deck.removeFirst()
        if !pendingDeletes.contains(where: { $0.id == card.id }) {
            pendingDeletes.append(card)
        }
        history.append(.delete(item: card))
        markDecided(card)
        loadPreview()
        log("🗑 标记删除 · \(card.label)   [待删 \(pendingDeletes.count)，剩 \(deck.count)]")
    }

    /// Every decision goes through here: it is the one place that knows a photo
    /// has been dealt with, so it is the one place that can count it and check
    /// whether a milestone just fell.
    private func markDecided(_ item: SiftItem) {
        decidedIDs.insert(item.id)
        decidedCount += 1
        checkAchievements()
        maybeRedealShuffle()
    }

    func classify(_ number: Int) {
        guard let card = current, let index = buckets.firstIndex(where: { $0.id == number }) else { return }
        let name = buckets[index].name
        let position = index + 1
        launch(card, .classify(number))
        rememberFrontForEntry()
        deck.removeFirst()
        buckets[index].count += 1
        bucketMembers[number, default: []].append(card)
        history.append(.classify(item: card, bucket: number))
        pulse(number)

        // Buffered BEFORE `markDecided`, and that order matters: markDecided is
        // what notices the round has emptied, and on the twentieth card it would
        // otherwise finish and flush the round one card early — dropping that
        // card's assignment on the floor.
        if shuffleMode {
            roundAssignments.append(PendingAssignment(assetID: card.id, albumName: name))
            persistPendingRound()
        }

        markDecided(card)
        loadPreview()

        if shuffleMode {
            log("\(dryRun ? "[演练] " : "")\(position) →「\(name)」 · \(card.label)"
                + "   [剩 \(deck.count) · 本轮待写 \(roundAssignments.count)]")
            return
        }
        if dryRun {
            log("[演练] \(position) →「\(name)」 · \(card.label)   [剩 \(deck.count)]")
            return
        }
        log("\(position) →「\(name)」 · \(card.label)   [剩 \(deck.count)]")
        if let asset = card.asset { addToAlbum(asset, named: name) }
    }

    /// ←：把牌堆最后一张（也就是你最近跳过的）拉回到最前面。
    func back() {
        guard deck.count > 1 else { return }
        let card = deck.removeLast()
        deck.insert(card, at: 0)
        history.append(.skip(item: card))
        pendingReturn = .skip
        forgetFrontForEntry()
        loadPreview()
        log("← 把 \(card.label) 拉回最前面")
    }

    func undo() {
        guard let action = history.popLast() else {
            log("没有可撤销的操作")
            return
        }
        forgetFrontForEntry()
        switch action {
        case .skip(let item):
            if let index = deck.firstIndex(where: { $0.id == item.id }) {
                deck.remove(at: index)
            }
            deck.insert(item, at: 0)
            pendingReturn = .skip
            log("↩︎ 撤销「跳过」，\(item.label) 回到最前面")
        case .delete(let item):
            pendingDeletes.removeAll { $0.id == item.id }
            deck.insert(item, at: 0)
            pendingReturn = .delete
            undecide(item)
            log("↩︎ 撤销「删除标记」   [待删 \(pendingDeletes.count)]")
        case .classify(let item, let bucket):
            if let index = buckets.firstIndex(where: { $0.id == bucket }) {
                buckets[index].count = max(0, buckets[index].count - 1)
                if isBuffered(item) {
                    // Still sitting in the shuffle round's buffer: drop it from
                    // there instead. Reaching into the album would remove a photo
                    // that was never put in — and the round would write it later
                    // anyway, undoing the undo.
                    roundAssignments.removeAll { $0.assetID == item.id }
                    persistPendingRound()
                } else if !dryRun, let asset = item.asset {
                    removeFromAlbum(asset: asset, albumName: buckets[index].name)
                }
            }
            bucketMembers[bucket]?.removeAll { $0.id == item.id }
            deck.insert(item, at: 0)
            pendingReturn = .classify(bucket)
            undecide(item)
            log("↩︎ 撤销「分类」\(dryRun ? "" : (isBuffered(item) ? "（本轮还没写入，直接从待写里拿掉）" : "（已从专辑移出）"))")
        }
        loadPreview()
    }

    // MARK: - Return animation (undo)

    /// Set just before `loadPreview()` so the inbound animation can start with
    /// the restored photo already decoded, instead of flying in blank.
    private var pendingReturn: CardAction?

    /// True from the instant a return is *queued* until its flight finishes.
    ///
    /// The front card has to stay hidden across that whole window. `deck` changes
    /// — and the front card re-renders in its finished, post-undo arrangement —
    /// a full runloop turn before the photo decode lands and the flight actually
    /// starts. Keying the hide off `returning` alone let the finished state show
    /// through for a frame.
    var isReturning: Bool { pendingReturn != nil || !returning.isEmpty }

    /// Keeps a small thumbnail for the front card and the one behind it.
    ///
    /// The front one matters as much as the back one: it is the instant stand-in
    /// while the full-size preview decodes, so navigating shows the next photo
    /// right away instead of a blank card (or, worse, the photo you just left).
    private func refreshUpcoming() {
        let targets = Array(deck.prefix(2))
        let wanted = Set(targets.map(\.id))
        upcomingImages = upcomingImages.filter { wanted.contains($0.key) }
        upcomingRequests = upcomingRequests.filter { wanted.contains($0) }

        for item in targets where upcomingImages[item.id] == nil && !upcomingRequests.contains(item.id) {
            if let demo = item.demoImage {
                upcomingImages[item.id] = demo
                continue
            }
            guard let asset = item.asset else { continue }
            let key = item.id
            upcomingRequests.insert(key)
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 640, height: 640),
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.upcomingRequests.remove(key)
                    if let image { self.upcomingImages[key] = image }
                }
            }
        }
    }

    private func flushPendingReturn(image: NSImage?) {
        guard let action = pendingReturn, let item = current else { return }
        pendingReturn = nil
        launchReturn(item, from: action, image: image)
    }

    private func launchReturn(_ item: SiftItem, from action: CardAction, image: NSImage?) {
        let card = ReturningCard(id: UUID(), item: item, action: action, image: image, landed: false)
        let token = card.id
        returning.append(card)
        if returning.count > 4 { returning.removeFirst(returning.count - 4) }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            guard let self, let index = self.returning.firstIndex(where: { $0.id == token }) else { return }
            self.returning[index].landed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay + Self.flightDuration + 0.06) { [weak self] in
            self?.returning.removeAll { $0.id == token }
        }
    }

    // MARK: - Flight animation driver

    /// `--slowmo` stretches the flight so it can actually be seen (and captured
    /// mid-air for verification) instead of a 0.4 s blur.
    static let slowMotion = CommandLine.arguments.contains("--slowmo")
    static let flightDuration: Double = slowMotion ? 2.6 : 0.28
    private static let launchDelay: Double = slowMotion ? 0.5 : 0.03

    private func launch(_ item: SiftItem, _ action: CardAction) {
        let card = OutgoingCard(id: UUID(), item: item, action: action,
                                image: preview, launched: false)
        let token = card.id
        lastAction = action
        flying.append(card)
        if flying.count > 6 { flying.removeFirst(flying.count - 6) }

        // Two phases on purpose: SwiftUI has to render the card at rest once
        // before the offset change, or it coalesces both updates and nothing moves.
        //
        // The flip is wrapped in `withAnimation` because the pile's entry scale
        // hangs off this same flag: the pile has to SNAP to its entry size when the
        // card arrives (so it lines up with the size it had a frame ago) and only
        // then grow back to full size. An `.animation(value:)` on the pile would
        // animate both ends of that and it would never actually reach entry size.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            guard let self, let index = self.flying.firstIndex(where: { $0.id == token }) else { return }
            withAnimation(.easeOut(duration: Self.flightDuration)) {
                self.flying[index].launched = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay + Self.flightDuration + 0.06) { [weak self] in
            self?.flying.removeAll { $0.id == token }
        }
    }

    private func pulse(_ bucket: Int) {
        pulsingBucket = bucket
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.slowMotion ? 2.6 : 0.5)) { [weak self] in
            guard let self, self.pulsingBucket == bucket else { return }
            self.pulsingBucket = nil
        }
    }

    // MARK: - Commit — the single point where Photos shows its confirmation sheet

    func commit() {
        guard !committing else { return }
        if dryRun {
            log("⚠️ 演练模式：不执行删除。关掉「演练模式」再提交。")
            statusText = "演练模式，未删除"
            return
        }
        let batch = pendingDeletes.compactMap(\.asset)
        guard !batch.isEmpty else {
            log("没有待删照片，无需提交。")
            return
        }

        committing = true
        statusText = "等待系统确认删除 \(batch.count) 张…"
        log("提交删除 \(batch.count) 张 —— 系统弹一次确认框，确认即一并删除")

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(batch as NSArray)
        }, completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.committing = false
                if success {
                    self.pendingDeletes.removeAll()
                    self.statusText = "已删除 \(batch.count) 张"
                    self.log("✅ 删除成功 \(batch.count) 张（30 天内在「照片 › 最近删除」可恢复）")
                } else {
                    self.statusText = "删除失败"
                    self.log("❌ 删除失败：\(error?.localizedDescription ?? "未知错误")")
                }
            }
        })
    }

    // MARK: - Already-filed photos (v0.9)

    /// One pass over the category albums: which photos are already in them, and
    /// how many each holds.
    ///
    /// One fetch per bucket (ten at most), never one per photo — the other way
    /// round is 19,000 album-membership questions. Doing this at startup is what
    /// makes 已整理 mean "dealt with, ever" instead of "dealt with in this
    /// session", and it is why a resumed library does not re-serve you the
    /// thousand photos you filed last week.
    private func scanCategoryAlbums() -> (ids: Set<String>, counts: [Int: Int]) {
        var ids = Set<String>()
        var counts: [Int: Int] = [:]
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        for bucket in buckets {
            guard let album = existingAlbum(named: bucket.name) else { continue }
            var n = 0
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                ids.insert(asset.localIdentifier)
                n += 1
            }
            counts[bucket.id] = n
        }
        return (ids, counts)
    }

    /// Everything that happens once we know which photos are already filed.
    ///
    /// Split out from `scanCategoryAlbums` because the fetch needs a real photo
    /// library and `--selftest` has none — this is the half the assertions drive.
    func adoptFiledPhotos(ids: Set<String>, counts: [Int: Int], library: [SiftItem]) {
        unfiledPool = library.filter { !ids.contains($0.id) }
        deck = unfiledPool
        totalCount = library.count
        decidedIDs = ids
        decidedCount = ids.count
        alreadyFiledCount = ids.count
        for i in buckets.indices { buckets[i].count = counts[buckets[i].id] ?? 0 }
        // Resuming a library that already has a thousand filed photos should
        // acknowledge that immediately, not on the next photo you deal with.
        checkAchievements()
    }

    /// Counterpart to `markDecided`: undo puts the photo back in the pool. The
    /// achievement dates stay — taking a badge back because of an undo would be
    /// petty, and the date is a record of a moment that really happened.
    private func undecide(_ item: SiftItem) {
        decidedIDs.remove(item.id)
        decidedCount = max(0, decidedCount - 1)
    }

    // MARK: - Shuffle (v0.9)

    func toggleShuffle() {
        guard shuffleMode else {
            enterShuffle()
            saveSettings()
            return
        }
        // Leaving early with work in the round: ask what to do with it rather
        // than silently dropping the user back into the ordered deck. Finished
        // rounds (deck empty) and empty rounds have nothing to ask about.
        if shuffleRoundDecisions > 0, !deck.isEmpty {
            showShuffleExitConfirm = true
            log("Shuffle · 这一轮还有 \(deck.count) 张没处理、已有 \(shuffleRoundDecisions) 条操作 → 先问怎么处理")
            return
        }
        exitShuffle()
        saveSettings()
    }

    /// 「继续整理」— the sheet's default: nothing happens, stay in the round.
    func cancelShuffleExit() {
        showShuffleExitConfirm = false
    }

    /// 「保留这一轮」— the round is over by the user's say-so, so this is where its
    /// buffered work gets written. Then the mode ends.
    func keepRoundAndExitShuffle() {
        let n = shuffleRoundDecisions
        finishShuffleRound()
        showShuffleExitConfirm = false
        exitShuffle()
        saveSettings()
        log("Shuffle · 保留这一轮的 \(n) 条操作后退出")
    }

    /// 「撤销这一轮」— put back what this round did, then leave.
    ///
    /// Since the round's classifications were buffered rather than written, this
    /// is a purely local operation: dropping the buffer *is* the undo. Nothing
    /// in the photo library has to be taken back, which is exactly why the round
    /// is buffered in the first place.
    func revertRoundAndExitShuffle() {
        let n = shuffleRoundDecisions
        revertShuffleRound()
        showShuffleExitConfirm = false
        exitShuffle()
        saveSettings()
        log("Shuffle · 撤销这一轮的 \(n) 条操作后退出")
    }

    /// Decisions this round made. Skips do not count — skipping is not an act.
    private var roundActions: [DeckAction] {
        let from = min(shuffleRoundStart, history.count)
        return history[from...].filter { if case .skip = $0 { return false }; return true }
    }

    var shuffleRoundDecisions: Int { roundActions.count }
    var shuffleRoundClassified: Int {
        roundActions.filter { if case .classify = $0 { return true }; return false }.count
    }
    var shuffleRoundDeleted: Int {
        roundActions.filter { if case .delete = $0 { return true }; return false }.count
    }

    /// Undo everything the current round did, quietly.
    ///
    /// Deliberately not a loop over `undo()`: that fires one return-to-front
    /// animation per card, and the deck is about to be rebuilt anyway. It also
    /// must stop at `shuffleRoundStart` — decisions made before shuffle mode was
    /// switched on are not this round's to take back.
    func revertShuffleRound() {
        // Nothing to un-write: this round's classifications were buffered, not
        // applied, so dropping the buffer IS the undo. That is the entire reason
        // the round is buffered.
        roundAssignments.removeAll()
        clearPendingRoundFile()

        let from = min(shuffleRoundStart, history.count)
        guard from < history.count else { return }
        let round = Array(history[from...]).reversed()
        history.removeSubrange(from...)

        var undone = 0
        for action in round {
            switch action {
            case .skip:
                break
            case .delete(let item):
                pendingDeletes.removeAll { $0.id == item.id }
                undecide(item)
                undone += 1
            case .classify(let item, let bucket):
                if let index = buckets.firstIndex(where: { $0.id == bucket }) {
                    buckets[index].count = max(0, buckets[index].count - 1)
                }
                bucketMembers[bucket]?.removeAll { $0.id == item.id }
                undecide(item)
                undone += 1
            }
        }
        forgetFrontForEntry()
        log("Shuffle · 回退这一轮的 \(undone) 条操作（本来就没写进图库）")
    }

    /// Deal a random twenty out of the photos still unfiled.
    ///
    /// The point is not "a random sample of everything", it is a **short,
    /// finishable list**: 19,000 photos is intimidating, twenty is a coffee
    /// break. The round is re-dealt when it runs out, so the mode keeps flowing
    /// instead of dead-ending after one batch.
    func enterShuffle() {
        if !shuffleMode { preShuffleDeck = deck }
        shuffleMode = true
        dealShuffle()
        if !shuffleIntroDismissed, !Self.suppressShuffleIntro { showShuffleIntro = true }
        let left = remainingUnfiled.count
        log("Shuffle · 抽出 \(deck.count) 张（未整理共 \(left) 张）")
    }

    /// Closing the explainer.
    ///
    /// Ticking the box is what makes it stop coming back: closing without
    /// ticking means "read it, but ask me again next time", which is what the
    /// label promises — so nothing is persisted unless the box was ticked.
    func closeShuffleIntro() {
        if skipShuffleIntro {
            shuffleIntroDismissed = true
            saveSettings()
            log("Shuffle · 说明勾了「不再显示」，以后不再弹")
        }
        showShuffleIntro = false
    }

    func exitShuffle() {
        shuffleMode = false
        // Back to the full ordered pool, minus everything decided in the meantime
        // — restoring the snapshot alone would resurrect the cards you just filed.
        deck = unfiledPool.filter { !decidedIDs.contains($0.id) }
        preShuffleDeck = []
        loadPreview()
        refreshUpcoming()
        log("Shuffle · 关闭，回到顺序模式（剩 \(deck.count) 张）")
    }

    /// Photos that were never in a category album and have not been decided now.
    private var remainingUnfiled: [SiftItem] {
        unfiledPool.filter { !decidedIDs.contains($0.id) }
    }

    private var remainingUnfiledCount: Int { remainingUnfiled.count }

    private func dealShuffle() {
        deck = Array(remainingUnfiled.shuffled().prefix(Self.shuffleSize))
        // Where this round starts in `history`, so an early exit can ask about
        // exactly this round's work — not the whole session's.
        shuffleRoundStart = history.count
        rememberFrontForEntry()
        loadPreview()
        refreshUpcoming()
    }

    /// After every decision, top the round back up.
    private func maybeRedealShuffle() {
        guard shuffleMode, deck.isEmpty else { return }
        // The round is over — this is where its buffered work finally lands.
        finishShuffleRound()
        if remainingUnfiled.isEmpty {
            log("Shuffle · 未整理的照片都过完了")
            return
        }
        dealShuffle()
        log("Shuffle · 这轮清空，又抽了 \(deck.count) 张")
    }

    /// The round finished, so its buffered classifications can be written.
    ///
    /// Called both when the twentieth card is dealt with and when the user
    /// leaves early having chosen to keep the round.
    func finishShuffleRound() {
        let pending = roundAssignments
        roundAssignments.removeAll()
        clearPendingRoundFile()
        guard !pending.isEmpty else { return }
        guard !dryRun else {
            log("[演练] Shuffle · 一轮做完，\(pending.count) 张分类本应写入专辑")
            return
        }
        writeAssignments(pending)
        log("Shuffle · 一轮做完，\(pending.count) 张分类一次性写入专辑")
    }

    /// Write a whole round in one transaction, grouped by album.
    ///
    /// One `performChanges` for the batch instead of one per key press: the
    /// round is a unit of work, and PhotoKit agrees. Album collections are
    /// resolved before the change block (fetching inside it is not allowed) and
    /// created inside it when missing.
    /// `done` is called on the main queue once PhotoKit has answered. The write
    /// test needs to know the transaction actually landed before it goes looking
    /// for the result.
    func writeAssignments(_ pending: [PendingAssignment], done: (() -> Void)? = nil) {
        let ids = pending.map(\.assetID)
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }

        let names = Array(Set(pending.map(\.albumName)))
        var existing: [String: PHAssetCollection] = [:]
        for name in names {
            if let album = existingAlbum(named: name) { existing[name] = album }
        }

        PHPhotoLibrary.shared().performChanges({
            for name in names {
                let request: PHAssetCollectionChangeRequest? = existing[name].flatMap {
                    PHAssetCollectionChangeRequest(for: $0)
                } ?? PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: name)
                let members = pending
                    .filter { $0.albumName == name }
                    .compactMap { assets[$0.assetID] }
                guard !members.isEmpty else { continue }
                request?.addAssets(members as NSArray)
            }
        }, completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log(success
                         ? "　↳ 本轮 \(pending.count) 张已归位（\(names.joined(separator: "/"))）"
                         : "　↳ 本轮写入失败：\(error?.localizedDescription ?? "未知错误")")
                done?()
            }
        })
    }

    // MARK: - Achievements (v0.9)

    /// `--achievement` pops a toast on launch so the announcement can be
    /// photographed; synthetic clicks cannot reach SwiftUI buttons here, and a
    /// toast that lasts two seconds cannot be caught any other way.
    static let forceAchievementFlag = CommandLine.arguments.contains("--achievement")

    private static let achievementDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `--shuffle` forces shuffle on at launch. Synthetic clicks cannot reach
    /// SwiftUI buttons in this environment, so the mode has to be drivable from
    /// the command line to be photographed.
    static let forceShuffleFlag = CommandLine.arguments.contains("--shuffle")

    /// `--shuffle` shows the shuffle deck; add `--shuffleintro` to also pop the
    /// explainer. The explainer is suppressed under a bare `--shuffle` so the
    /// existing recipe for photographing the shuffle *state* keeps working.
    static let suppressShuffleIntro =
        (forceShuffleFlag && !CommandLine.arguments.contains("--shuffleintro"))
        || shuffleExitFlag

    /// `--shuffleexit` walks straight into the early-exit prompt: enter shuffle,
    /// decide a few cards, then ask to leave. Same reason as `--shuffle`: no
    /// synthetic click can reach a SwiftUI button in this environment, so the
    /// state has to be reachable from the launch arguments to be photographed.
    static let shuffleExitFlag = CommandLine.arguments.contains("--shuffleexit")

    private func checkAchievements() {
        for achievement in Achievement.allCases where unlockedAchievements[achievement.id] == nil {
            // Threshold 0 is an EVENT, not a count: it belongs to `firstLaunch`
            // and is granted explicitly on the way in. Letting the counting loop
            // have it would hand out "初次见面" to any store that ever ran a
            // check — including the headless self-test.
            guard achievement.threshold > 0 else { continue }
            guard decidedCount >= achievement.threshold else { continue }
            unlock(achievement)
        }
    }

    private func unlock(_ achievement: Achievement) {
        // Recorded once, never rewritten: the date is part of the keepsake.
        let when = Date()
        unlockedAchievements[achievement.id] = when
        achievementQueue.append(achievement)
        saveSettings()
        log("🏅 成就「\(achievement.title)」· \(achievement.detail) · "
            + Self.achievementDateFormatter.string(from: when))
    }

    /// The first-launch badge, on the way in — nothing has to be organised first.
    func unlockFirstLaunch() {
        guard unlockedAchievements[Achievement.firstLaunch.id] == nil else { return }
        unlock(.firstLaunch)
    }

    func dismissAchievement() {
        guard !achievementQueue.isEmpty else { return }
        let gone = achievementQueue.removeFirst()
        log("成就提示收走 · \(gone.title) · 队列剩 \(achievementQueue.count)")
    }

    /// Verification entry point: queue a toast for the next undisplayed badge.
    func forceAchievementToast() {
        let next = Achievement.allCases.first { unlockedAchievements[$0.id] == nil }
            ?? Achievement.allCases.last!
        achievementQueue.append(next)
        log("🏅 强制弹出成就提示（--achievement）· \(next.title) · 队列 \(achievementQueue.count)")
    }

    /// Achievements in a stable order, with their unlock dates (nil = locked).
    var achievementBoard: [(achievement: Achievement, date: Date?)] {
        Achievement.allCases.map { ($0, unlockedAchievements[$0.id]) }
    }

    // MARK: - Photo library writes

    private func existingAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject
    }

    private func addToAlbum(_ asset: PHAsset, named name: String) {
        let existing = existingAlbum(named: name)
        PHPhotoLibrary.shared().performChanges({
            let request: PHAssetCollectionChangeRequest?
            if let existing {
                request = PHAssetCollectionChangeRequest(for: existing)
            } else {
                request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            }
            request?.addAssets([asset] as NSArray)
        }, completionHandler: { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.log("　↳ 已归入专辑「\(name)」\(existing == nil ? "（新建）" : "")")
                } else {
                    self.log("　↳ 归入失败：\(error?.localizedDescription ?? "未知错误")")
                }
            }
        })
    }

    /// True when this classification is still sitting in the round buffer, i.e.
    /// it has not reached the photo library yet.
    private func isBuffered(_ item: SiftItem) -> Bool {
        roundAssignments.contains { $0.assetID == item.id }
    }

    /// A round in flight is written to disk as it grows, so a quit or a crash
    /// cannot lose work the user never cancelled.
    ///
    /// Only in writing mode: under `--demo`/`--selftest` or in 演练模式 nothing
    /// would be applied anyway, so there is nothing worth protecting — and the
    /// self-test must never leave files in the user's support directory.
    private func persistPendingRound() {
        guard !dryRun, !Self.isDemo, !Self.isSelfTest else { return }
        guard let data = try? JSONEncoder().encode(roundAssignments) else { return }
        try? data.write(to: Self.pendingRoundURL)
    }

    private func clearPendingRoundFile() {
        guard !Self.isSelfTest else { return }
        try? FileManager.default.removeItem(at: Self.pendingRoundURL)
    }

    /// Apply a round that a quit or a crash interrupted.
    ///
    /// The user never cancelled it, so the work was wanted — dropping it would
    /// be the app silently losing twenty decisions.
    private func applyInterruptedRound() {
        guard let data = try? Data(contentsOf: Self.pendingRoundURL),
              let pending = try? JSONDecoder().decode([PendingAssignment].self, from: data),
              !pending.isEmpty else { return }
        clearPendingRoundFile()
        guard !dryRun else { return }
        writeAssignments(pending)
        log("Shuffle · 上次没做完的一轮，开机补写了 \(pending.count) 张分类")
    }

    private func removeFromAlbum(asset: PHAsset, albumName: String) {
        guard let album = existingAlbum(named: albumName) else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetCollectionChangeRequest(for: album)?.removeAssets([asset] as NSArray)
        }, completionHandler: nil)
    }

    // MARK: - Preview

    private func loadPreview() {
        previewRequests += 1
        refreshUpcoming()
        if let previous = imageRequest {
            PHImageManager.default().cancelImageRequest(previous)
            imageRequest = nil
        }
        guard let item = current else {
            preview = nil
            previewBusy = false
            flushPendingReturn(image: nil)
            return
        }
        // Demo mode: the "photo" is a generated NSImage, no PhotoKit involved.
        //
        // Delivered on the next runloop turn, exactly like the PhotoKit callback
        // below. Handing it over synchronously made the demo a liar: the deck
        // change and the return-flight setup landed in the same SwiftUI
        // transaction, so a whole class of one-frame flashes could never show up
        // here — only on real photos.
        if item.asset == nil {
            previewBusy = false
            // Clear it, exactly like the real path below does -- otherwise the
            // demo happily shows the previous photo during the gap and hides
            // the very bug we need it to reproduce.
            preview = nil
            let demo = item.demoImage
            DispatchQueue.main.async { [weak self] in
                guard let self, self.current?.id == item.id else { return }
                self.preview = demo
                self.flushPendingReturn(image: demo)
            }
            return
        }
        guard let asset = item.asset else { return }
        previewBusy = true
        // Drop the previous photo first: otherwise the newly revealed card shows
        // the photo you just dismissed until its own decode lands.
        preview = nil
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast

        imageRequest = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1600, height: 1600),
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, info in
            if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.previewBusy = false
                if let image {
                    self.preview = image
                    if self.previewDecodes < 3 {
                        self.previewDecodes += 1
                        self.log("预览解码 OK · \(Int(image.size.width))×\(Int(image.size.height)) · \(asset.localIdentifier.prefix(20))…")
                    }
                } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    self.log("⚠️ 预览解码返回空图 · \(asset.localIdentifier.prefix(20))…")
                }
                self.flushPendingReturn(image: image)
            }
        }
    }

    // MARK: - ⓘ Details (EXIF + location)

    func loadDetails() {
        guard let asset = current?.asset else {
            details = nil
            return
        }
        detailsLoading = true
        log("ⓘ 读取详情 · \(current?.label ?? "")")

        var base = PhotoDetails()
        base.created = asset.creationDate.map { Self.fullDate.string(from: $0) } ?? "无拍摄时间"
        base.dimensions = "\(asset.pixelWidth) × \(asset.pixelHeight)"
        base.isFavorite = asset.isFavorite
        base.source = Self.kindDescription(asset).isEmpty ? "普通照片" : Self.kindDescription(asset)
        if asset.location == nil {
            base.place = "这张照片没有位置信息"
        }
        details = base

        if let location = asset.location {
            base.coordinate = String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
            base.latitude = location.coordinate.latitude
            base.longitude = location.coordinate.longitude
            details?.coordinate = base.coordinate
            details?.latitude = base.latitude
            details?.longitude = base.longitude
            let targetID = asset.localIdentifier
            Self.geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
                DispatchQueue.main.async {
                    guard let self, self.current?.id == targetID else { return }
                    if let place = placemarks?.first {
                        let parts = [place.name, place.locality, place.administrativeArea, place.country]
                            .compactMap { $0 }
                        var seen = Set<String>()
                        let unique = parts.filter { seen.insert($0).inserted }
                        self.details?.place = unique.joined(separator: " · ")
                    } else {
                        self.details?.place = error == nil ? "未能解析出地名" : "地名查询失败（可能没网）"
                    }
                }
            }
        }

        if let previous = detailsRequest {
            PHImageManager.default().cancelImageRequest(previous)
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let targetID = asset.localIdentifier

        detailsRequest = PHImageManager.default().requestImageDataAndOrientation(
            for: asset, options: options
        ) { [weak self] data, _, _, _ in
            guard let data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                DispatchQueue.main.async {
                    guard let self, self.current?.id == targetID else { return }
                    self.detailsLoading = false
                }
                return
            }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

            DispatchQueue.main.async {
                guard let self, self.current?.id == targetID else { return }
                var updated = self.details ?? base
                let make = tiff[kCGImagePropertyTIFFMake] as? String
                let model = tiff[kCGImagePropertyTIFFModel] as? String
                let camera = [make, model].compactMap { $0 }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                updated.camera = camera.isEmpty ? "无" : camera
                updated.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? "无"

                var parts: [String] = []
                if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = iso.first {
                    parts.append("ISO \(first)")
                }
                if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
                    parts.append("f/\(String(format: "%.1f", aperture))")
                }
                if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double {
                    parts.append(Self.shutterText(exposure))
                }
                if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                    parts.append("\(String(format: "%.0f", focal))mm")
                }
                updated.exposure = parts.isEmpty ? "无" : parts.joined(separator: "   ")
                updated.fileSize = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                self.details = updated
                self.detailsLoading = false
            }
        }
    }

    private static func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return "\(String(format: "%g", seconds))s" }
        return "1/\(Int((1 / seconds).rounded()))s"
    }

    private static func sourceDescription(_ asset: PHAsset) -> String {
        kindDescription(asset)
    }

    /// 截屏 / 实况照片 / … 空字符串表示普通照片。也给卡片信息字段用。
    static func kindDescription(_ asset: PHAsset) -> String {
        var bits: [String] = []
        if asset.mediaSubtypes.contains(.photoScreenshot) { bits.append("截屏") }
        if asset.mediaSubtypes.contains(.photoLive) { bits.append("实况照片") }
        if asset.mediaSubtypes.contains(.photoPanorama) { bits.append("全景") }
        if asset.mediaSubtypes.contains(.photoHDR) { bits.append("HDR") }
        if asset.mediaSubtypes.contains(.photoDepthEffect) { bits.append("人像景深") }
        return bits.joined(separator: " · ")
    }

    private static let geocoder = CLGeocoder()

    // MARK: - Settings

    func saveSettings() {
        // `--selftest` exercises add/removeBucket, and those save. It must never
        // touch the USER's config — that is exactly how one test run left the real
        // file sitting at "0 categories".
        guard !Self.isSelfTest else { return }
        // Nor may `--demo`: loadDemoLibrary renames the buckets to the sample
        // names, so any save from a demo run (finishing the guide, toggling dark
        // mode, adding a category) would overwrite the real config with demo
        // data. A demo has to be side-effect free.
        guard !Self.isDemo else { return }
        let settings = AppSettings(bucketNames: nil,
                                   buckets: buckets,
                                   nextBucketID: nextBucketID,
                                   cardFields: cardFields.map(\.rawValue).sorted(),
                                   darkMode: darkMode,
                                   hasOnboarded: hasOnboarded,
                                   achievements: unlockedAchievements
                                       .mapValues { $0.timeIntervalSince1970 },
                                   shuffleMode: shuffleMode,
                                   shuffleIntroDismissed: shuffleIntroDismissed)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: Self.configURL)
            let names = buckets.isEmpty ? "（无）" : buckets.map(\.name).joined(separator: "/")
            log("已保存设置 · 分类 \(names)（\(buckets.count) 个） | "
                + "卡片信息 \(cardFields.map(\.title).sorted().joined(separator: "/")) | "
                + "外观 \(darkMode ? "暗色" : "亮色")")
        }
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: Self.configURL) else { return }

        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            apply(settings)
            log("载入设置 · 分类 \(buckets.map(\.name).joined(separator: "/"))（\(buckets.count) 个）")
            return
        }
        // v0.3 及更早：文件里只有一个纯字符串数组，装着分类名。
        if let names = try? JSONDecoder().decode([String].self, from: data) {
            buckets = names.enumerated().map { Bucket(id: $0.offset + 1, name: $0.element) }
            nextBucketID = names.count + 1
            // 写回新格式，否则旧文件会一直留在盘上，每次启动都走一次兼容分支。
            saveSettings()
            log("载入旧版配置（只有分类名），已升级并写回新格式")
        }
    }

    private func apply(_ settings: AppSettings) {
        if let list = settings.buckets {
            // 允许是空数组 —— 用户可能把分类全删光，0 个是合法状态。
            buckets = list
            nextBucketID = settings.nextBucketID ?? ((list.map(\.id).max() ?? 0) + 1)
        } else if let names = settings.bucketNames {
            // v0.6 及更早：固定 5 个，只有名字。
            buckets = names.enumerated().map { Bucket(id: $0.offset + 1, name: $0.element) }
            nextBucketID = names.count + 1
        }
        // 允许为空数组（用户主动全不勾选），只有文件不存在时才用默认值。
        cardFields = Set(settings.cardFields.compactMap { CardInfoField(rawValue: $0) })
        darkMode = settings.darkMode
        hasOnboarded = settings.hasOnboarded ?? false
        unlockedAchievements = (settings.achievements ?? [:])
            .compactMapValues { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        // Drop ids this build no longer knows about, so a renamed achievement
        // cannot leave a phantom entry in the panel.
        let known = Set(Achievement.allCases.map(\.id))
        unlockedAchievements = unlockedAchievements.filter { known.contains($0.key) }
        shuffleMode = (settings.shuffleMode ?? false) || Self.forceShuffleFlag
        shuffleIntroDismissed = settings.shuffleIntroDismissed ?? false
    }

    func toggleCardField(_ field: CardInfoField, on: Bool) {
        if on { cardFields.insert(field) } else { cardFields.remove(field) }
        saveSettings()
    }

    // MARK: - Appearance

    func applyAppearance() {
        NSApp.appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
    }

    func toggleDarkMode() {
        darkMode.toggle()
        applyAppearance()
        saveSettings()
        log("外观切换：\(darkMode ? "暗色" : "亮色")")
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInMaps() {
        guard let latitude = details?.latitude, let longitude = details?.longitude else { return }
        let coordinate = "\(latitude),\(longitude)"
        guard let encoded = coordinate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://maps.apple.com/?ll=\(encoded)&q=照片拍摄位置") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Thumbnails for the pending-delete list

    func loadDeleteThumbnails() {
        for item in pendingDeletes where deleteThumbnails[item.id] == nil {
            if let demo = item.demoImage {
                deleteThumbnails[item.id] = demo
                continue
            }
            guard let asset = item.asset else { continue }
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let key = item.id
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200),
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, _ in
                guard let image else { return }
                DispatchQueue.main.async { self?.deleteThumbnails[key] = image }
            }
        }
    }

    func clearPendingDeletes() {
        pendingDeletes.removeAll()
        deleteThumbnails.removeAll()
        log("已清空待删队列")
    }

    // MARK: - ⓘ details probe
    //
    // Verifies EXIF extraction and reverse geocoding against a real photo
    // without needing a click. Picks a photo that actually carries GPS.

    func runDetailsProbe() {
        note("=== details probe ===")
        if let index = deck.firstIndex(where: { $0.asset?.location != nil }) {
            let item = deck.remove(at: index)
            deck.insert(item, at: 0)
            note("probe: 选了第 \(index + 1) 张（带 GPS）当样本 · \(item.label)")
        } else {
            note("probe: 牌堆里没找到带 GPS 的照片，改用第一张测 EXIF")
        }
        loadPreview()
        loadDetails()

        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self else { return }
            guard let d = self.details else {
                self.note("probe: ❌ details 为 nil")
                return
            }
            self.note("probe 拍摄时间 : \(d.created)")
            self.note("probe 尺寸     : \(d.dimensions)")
            self.note("probe 文件大小 : \(d.fileSize)")
            self.note("probe 相机     : \(d.camera)")
            self.note("probe 镜头     : \(d.lens)")
            self.note("probe 曝光参数 : \(d.exposure)")
            self.note("probe 类型     : \(d.source)")
            self.note("probe 坐标     : \(d.coordinate ?? "（无）")")
            self.note("probe 地名     : \(d.place ?? "（无）")")

            let exifOK = d.camera != "—" && d.fileSize != "—"
            let geoOK = d.coordinate != nil ? (d.place != nil) : true
            self.note("probe RESULT: \(exifOK && geoOK ? "PASS" : "FAIL")"
                      + "（EXIF=\(exifOK ? "ok" : "缺") 位置=\(geoOK ? "ok" : "缺")）")
            self.note("=== details probe end ===")
        }
    }

    // MARK: - Self-test fixtures (no PHAsset, no photo library, no window)

    func seedForSelfTest(count: Int) {
        dryRun = true
        deck = (0..<count).map { index in
            SiftItem(id: "test-\(index)",
                     date: Date(timeIntervalSince1970: 1_760_000_000 - Double(index) * 3600),
                     pixelWidth: 1200,
                     pixelHeight: 1600,
                     kind: index % 4 == 0 ? "截屏" : "",
                     hasLocation: index % 3 == 0,
                     asset: nil)
        }
        totalCount = count
        history.removeAll()
        bucketMembers.removeAll()
        pendingDeletes.removeAll()
        flying.removeAll()
        returning.removeAll()
        for i in buckets.indices { buckets[i].count = 0 }
    }

    func bucketCount(_ number: Int) -> Int {
        buckets.first { $0.id == number }?.count ?? -1
    }

    func bucketMemberIDs(_ number: Int) -> [String] {
        (bucketMembers[number] ?? []).map(\.id)
    }

    /// Hand keyboard focus back to the sifter.
    ///
    /// Needs because SwiftUI gives a `TextField` first-responder status on
    /// launch: the album-name field editor captured every keystroke, so the
    /// whole keyboard spec appeared dead until the user clicked elsewhere.
    func refocus() {
        // `NSApp` is an implicitly-unwrapped optional and is nil under
        // `--selftest`, which has no NSApplication at all. `finishGuide()` calls
        // this, so without the guard one test path takes the whole run down with
        // a trap instead of a FAIL line.
        guard let app = NSApp else { return }
        app.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: - In-app key probe

    func runKeyProbe() {
        note("=== key probe ===")
        note("probe firstResponder=\(String(describing: NSApp.keyWindow?.firstResponder))")
        note("probe before: deck=\(deck.count) pending=\(pendingDeletes.count) buckets=\(buckets.map(\.count))")

        let sequence: [(UInt16, String, String)] = [
            (49, " ", "空格"), (126, "", "↑"), (126, "", "↑"),
            (18, "1", "1"), (20, "3", "3"), (23, "5", "5"), (123, "", "←"),
        ]
        note("probe sending: " + sequence.map(\.2).joined(separator: " "))

        for (code, chars, label) in sequence {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            ) else {
                note("probe: could not build event for \(label)")
                continue
            }
            NSApp.postEvent(event, atStart: false)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let counts = self.buckets.map(\.count)
            self.note("probe after: deck=\(self.deck.count) pending=\(self.pendingDeletes.count) "
                      + "buckets=\(counts) lastKey=\(self.lastKey)")
            // 空格(跳过,堆不缩) ↑(删) ↑(删) 1 3 5 (堆缩小3) ←(最后一张拉回最前)
            let pass = self.deck.count == self.totalCount - 5
                && self.pendingDeletes.count == 2
                && counts == [1, 0, 1, 0, 1]
            self.note(pass ? "probe RESULT: PASS" : "probe RESULT: FAIL")
            self.note("=== key probe end ===")
        }
    }

    // MARK: - Logging

    private func startRunLog() {
        let url = Self.runLogURL
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        logHandle?.truncateFile(atOffset: 0)
    }

    private func log(_ line: String) {
        let full = "\(Self.clock.string(from: Date()))  \(line)"
        logLines.append(full)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        writeToFile(full)
        // Under --selftest the action log would bury the PASS/FAIL lines.
        if !Self.isSelfTest { print(full) }
    }

    /// File-only tracing (never shown in the UI), for diagnosing the event path.
    func note(_ line: String) {
        writeToFile("\(Self.clock.string(from: Date()))  \(line)")
    }

    private func writeToFile(_ full: String) {
        guard let handle = logHandle, let data = (full + "\n").data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    // MARK: - Formatting

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm:ss"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    static func dateText(_ asset: PHAsset?) -> String {
        guard let date = asset?.creationDate else { return "无拍摄时间" }
        return day.string(from: date)
    }

    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized:    return "已授权（完整图库）"
        case .limited:       return "已授权（仅选定照片）"
        case .denied:        return "已拒绝"
        case .restricted:    return "受限"
        case .notDetermined: return "未决定"
        @unknown default:    return "未知"
        }
    }

    static func describe(_ asset: PHAsset) -> String {
        let when = asset.creationDate.map { day.string(from: $0) } ?? "无日期"
        return "\(when) · \(asset.pixelWidth)×\(asset.pixelHeight)"
    }
}
