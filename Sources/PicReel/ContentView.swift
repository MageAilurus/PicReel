// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import SwiftUI
import AppKit

/// All colours are semantic AppKit colours, so the whole UI follows the
/// light/dark switch without a second palette.
private enum Palette {
    static let ink      = Color(nsColor: .labelColor)
    static let sub      = Color(nsColor: .secondaryLabelColor)
    static let faint    = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)

    /// Dark mode is deliberately darker than the system window grey: the photo is
    /// the only thing that should glow, so the chrome drops to near black and the
    /// boxes sit just above it.
    static let canvas = adaptive(light: .windowBackgroundColor,
                                 dark: NSColor(white: 0.075, alpha: 1))
    static let panel  = adaptive(light: .controlBackgroundColor,
                                 dark: NSColor(white: 0.128, alpha: 1))
    /// Boxes are a touch lighter than the panel so they still read as objects.
    static let tile   = adaptive(light: .controlBackgroundColor,
                                 dark: NSColor(white: 0.185, alpha: 1))

    /// The photo's backing. Deliberately NOT `underPageBackgroundColor`: that
    /// reads ~0.82 grey in light mode, which made the photo look grubby.
    static let mat = adaptive(light: NSColor(white: 0.965, alpha: 1),
                              dark: NSColor(white: 0.15, alpha: 1))

    /// Brand gradient for the logo mark and the wordmark.
    static let brandLight = [Color(red: 0.36, green: 0.38, blue: 0.90),
                             Color(red: 0.62, green: 0.36, blue: 0.90)]
    static let brandDark  = [Color(red: 0.60, green: 0.64, blue: 1.00),
                             Color(red: 0.82, green: 0.62, blue: 1.00)]

    /// The macOS traffic lights sit over our own bar (the title bar is hidden),
    /// but they only occupy the top ~17pt — the row below them starts at ~34pt,
    /// so no leading reservation is needed. Kept documented because the old
    /// logo, which shared their row, did need one.

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

struct ContentView: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.colorScheme) private var colorScheme

    private var brandColors: [Color] {
        colorScheme == .dark ? Palette.brandDark : Palette.brandLight
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                hairline
                cardStage
                hairline
                boxRow
            }
            .background(Palette.canvas)

            // Unlock announcements sit above the deck but below the guide.
            if let achievement = store.achievementQueue.first {
                AchievementToast(achievement: achievement)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }

            // The guide covers everything. On a first launch there is nothing
            // behind it worth showing, and it has to hide the deck anyway: the
            // shortcut keys are switched off while it is up, so revealing a card
            // the user cannot act on would just be confusing.
            if store.guideStep != nil {
                GuideView(store: store)
                    // Dropping the guide (✓ on the last page) reveals the deck
                    // instead of snapping to it.
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
                    .zIndex(2)
            }
        }
        .frame(minWidth: 880, minHeight: 660)
        .onAppear { store.refocus() }
        // Auto-dismiss the announcement. `.task(id:)` re-runs when the next
        // queued badge arrives, so each one gets its own few seconds.
        //
        // The sleep must NOT be `try?`: `.task` is cancelled whenever SwiftUI
        // rebuilds this view, and `try?` swallows the CancellationError and falls
        // straight through to the dismissal — which made the toast vanish in the
        // same millisecond it was queued.
        .task(id: store.achievementQueue.first?.id) {
            let shown = store.achievementQueue.first?.id
            guard shown != nil else { return }
            do { try await Task.sleep(nanoseconds: 3_200_000_000) } catch { return }
            // Only dismiss the badge this task was scheduled for.
            if store.achievementQueue.first?.id == shown { store.dismissAchievement() }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82),
                   value: store.achievementQueue.first?.id)
        .sheet(isPresented: $store.showCategories) { CategorySheet(store: store) }
        .sheet(isPresented: $store.showTrash)      { TrashSheet(store: store) }
        .sheet(isPresented: $store.showSettings)   { SettingsSheet(store: store) }
        .sheet(isPresented: $store.showShuffleIntro) { ShuffleIntroSheet(store: store) }
        .sheet(isPresented: $store.showShuffleExitConfirm) { ShuffleExitSheet(store: store) }
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }

    // MARK: - Top bar (doubles as the window's drag handle)

    private var topBar: some View {
        HStack(spacing: 10) {
            // No traffic-light inset here. The old logo needed one because it sat
            // in the title-bar row; the dice lives a full row lower (measured on
            // screen: lights at y≈5–17pt, this row at y≈34–62pt), so the 78pt
            // was pure dead space — 33pt past where the window's own controls
            // end. Dropping it also lines the button up with the box row below.
            shuffleButton

            Text(store.progressText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.sub)

            // 模式提示紧跟左侧进度，不再飘到右边
            modeBadge

            Spacer()

            circleButton("tag", help: "分类") { store.showCategories = true }
            trashButton
            circleButton("gearshape", help: "设置与快捷键") { store.showSettings = true }
            circleButton(store.darkMode ? "sun.max" : "moon",
                         help: store.darkMode ? "切换到亮色" : "切换到暗色") {
                store.toggleDarkMode()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Palette.panel)
    }

    /// The dice. Filled in while shuffle is on, so the mode is visible at a
    /// glance rather than only in the progress text.
    private var shuffleButton: some View {
        Button {
            store.toggleShuffle()
        } label: {
            Image(systemName: "die.face.5.fill")
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background {
                    if store.shuffleMode {
                        Circle().fill(LinearGradient(colors: brandColors,
                                                     startPoint: .top, endPoint: .bottom))
                    } else {
                        Circle().fill(Color.primary.opacity(0.07))
                    }
                }
                .foregroundStyle(store.shuffleMode ? Color.white : Palette.sub)
        }
        .buttonStyle(.plain)
        .help(store.shuffleMode ? "退出 Shuffle，回到顺序" : "Shuffle · 随机抽 20 张未整理")
    }

    private var modeBadge: some View {
        Group {
            if PhotoStore.isDemo {
                badge("演示模式 · 示例图", color: Color(red: 0.20, green: 0.42, blue: 0.72),
                      background: Color(red: 0.87, green: 0.92, blue: 0.99))
            } else if store.dryRun {
                badge("演练模式 · 不写入", color: Color(red: 0.62, green: 0.42, blue: 0.05),
                      background: Color(red: 0.99, green: 0.93, blue: 0.78))
            } else {
                badge("写入模式 · 会改图库", color: Color(red: 0.70, green: 0.12, blue: 0.12),
                      background: Color(red: 1.0, green: 0.87, blue: 0.87))
            }
        }
    }

    private func badge(_ text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }

    private func circleButton(_ symbol: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.sub)
        .help(help)
    }

    private var trashButton: some View {
        Button {
            store.loadDeleteThumbnails()
            store.showTrash = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07), in: Circle())
                if !store.pendingDeletes.isEmpty {
                    Text("\(store.pendingDeletes.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color(red: 0.86, green: 0.24, blue: 0.24), in: Capsule())
                        .offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.sub)
        .help("待删除（⌘⏎ 提交）")
        .accessibilityLabel(store.pendingDeletes.isEmpty
                            ? "待删除，空"
                            : "待删除，\(store.pendingDeletes.count) 张")
    }

    // MARK: - Card stage

    private var cardStage: some View {
        GeometryReader { geo in
            // The info bar is a row of its OWN under the cards. That is the whole
            // point: the card can then be nothing but the photo, and a 1:4
            // portrait no longer squeezes its own info space down to nothing.
            let cardArea = CGSize(width: geo.size.width,
                                  height: max(140, geo.size.height
                                              - CardLayout.infoHeight - CardLayout.infoGap))
            let frontBox = cardBox(for: store.topCards.first, in: cardArea)

            VStack(spacing: CardLayout.infoGap) {
                ZStack {
                    // 整摞牌一起缩放：新前排从「它当后排时的大小」长到全尺寸。
                    // 必须整摞一起缩 —— 后排是按前排**最终**轮廓算的，只让前排自己
                    // 长的话，前排动画途中比最终小，后排就会从两侧露出来。
                    ZStack {
                        // Each card keeps ITS OWN shape. Sharing the front card's
                        // box meant a photo's frame snapped to the next photo's
                        // proportions the moment it stopped being the front one.
                        ForEach(Array(store.topCards.enumerated().reversed()), id: \.element.id) { index, item in
                            let box = cardBox(for: item, in: cardArea)

                            CardFace(
                                // Front card falls back to its own prefetched
                                // thumbnail: the full-size decode lands a beat
                                // later, and in that beat a blank card (or the
                                // photo you just left) used to flash through.
                                image: (index == 0 ? store.preview : nil)
                                       ?? store.upcomingImages[item.id],
                                showsSpinner: index == 0,
                                elevated: index == 0,
                                box: box)
                                .scaleEffect(CardLayout.backScale(own: box, front: frontBox, index: index))
                                .offset(y: CGFloat(index) * 12)
                                // 只有「退回牌堆」的方向才做动画。
                                //
                                // 前排那张**不能**做缩放动画：后面那张的缩放是按住
                                // 前排「最终尺寸」算的，而前排动画途中比最终小，后排就
                                // 会比前排宽出来 —— 那正是动画过程中露边的原因。
                                .animation(index == 0 ? nil
                                                      : .easeOut(duration: PhotoStore.flightDuration),
                                           value: index)
                                // 撤销时把顶牌藏起来，让「飞回来」的那张独占画面。
                                // 用 isReturning 而不是 returning：牌堆状态比动画状态
                                // 早一个 runloop 轮次更新，只看 returning 会漏那一帧。
                                .opacity(index == 0
                                         ? (store.isReturning ? 0 : 1)
                                         : 0.7)
                        }
                    }
                    .scaleEffect(pileScale(in: cardArea))
                    // 这里**故意不加** .animation(value: ...)：牌堆进入入场尺寸的那
                    // 一帧必须瞬移（要和上一帧的渲染尺寸严丝合缝），只有之后「长回
                    // 全尺寸」那一下才该动。动画由 store 里起飞时的 withAnimation 给。

                    // Every in-flight card animates independently, so hammering the
                    // arrow keys no longer truncates the previous flight.
                    ForEach(store.flying) { flying in
                        CardFace(image: flying.image,
                                 showsSpinner: false,
                                 elevated: true,
                                 box: cardBox(for: flying.item, in: cardArea))
                            .offset(flying.launched ? flightOffset(flying.action, in: geo.size) : .zero)
                            .rotationEffect(.degrees(flying.launched ? flightRotation(flying.action) : 0))
                            .scaleEffect(flying.launched ? 0.68 : 1)
                            .opacity(flying.launched ? 0 : 1)
                            .animation(.easeIn(duration: PhotoStore.flightDuration), value: flying.launched)
                            .allowsHitTesting(false)
                    }

                    // Undo: the card flies back IN from wherever it went. No scale
                    // change here -- growing from 0.68 read as the photo "flashing
                    // smaller" before it settled.
                    ForEach(store.returning) { card in
                        CardFace(image: card.image,
                                 showsSpinner: false,
                                 elevated: true,
                                 box: cardBox(for: card.item, in: cardArea))
                            .offset(card.landed ? .zero : flightOffset(card.action, in: geo.size))
                            .rotationEffect(.degrees(card.landed ? 0 : flightRotation(card.action)))
                            .animation(.easeOut(duration: PhotoStore.flightDuration), value: card.landed)
                            .allowsHitTesting(false)
                    }

                    if store.totalCount == 0 {
                        emptyState
                    } else if store.allDone {
                        doneState
                    }
                }
                .frame(width: geo.size.width, height: cardArea.height)

                if let front = store.topCards.first {
                    InfoBar(item: front,
                            width: min(CardLayout.infoWidth, geo.size.width - 56),
                            store: store)
                } else {
                    Spacer().frame(height: CardLayout.infoHeight)
                }
            }
        }
        .padding(.vertical, 10)
        .background(Palette.canvas)
        .contentShape(Rectangle())
        .onTapGesture { store.refocus() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38))
            Text("图库里没有照片").font(.system(size: 14))
            if store.authStatus == .denied || store.authStatus == .restricted {
                Button("打开系统设置") { store.openPrivacySettings() }
            }
        }
        .foregroundStyle(Palette.faint)
    }

    private var doneState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color(red: 0.2, green: 0.62, blue: 0.35))
            Text("全部处理完了").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("共 \(store.totalCount) 张 · 待删 \(store.pendingDeletes.count) 张")
                .font(.system(size: 12)).foregroundStyle(Palette.sub)
            if !store.pendingDeletes.isEmpty {
                Button("提交删除 ⌘⏎") { store.commit() }
            }
        }
    }

    /// The card IS the photo: its box is derived from the photo's own aspect
    /// ratio, so there is no dead mat around the image and no third frame.
    private func cardBox(for item: SiftItem?, in stage: CGSize) -> CGSize {
        CardLayout.box(pixelWidth: item?.pixelWidth ?? 0,
                       pixelHeight: item?.pixelHeight ?? 0,
                       in: stage)
    }

    /// The pile's starting scale for the moment the front card changes hands.
    ///
    /// The incoming photo was sitting behind, shrunk to fit inside the previous
    /// front card's footprint, so it has to grow from exactly that size. Handing
    /// it over at full size instead pops it 3–4x in a single frame when the new
    /// photo is wide and the old one was narrow.
    private func pileScale(in stage: CGSize) -> CGFloat {
        guard store.pileAtEntry, let previous = store.previousFront else { return 1 }
        let incoming = cardBox(for: store.topCards.first, in: stage)
        let previousBox = CardLayout.box(pixelWidth: previous.width,
                                         pixelHeight: previous.height,
                                         in: stage)
        return CardLayout.backScale(own: incoming, front: previousBox, index: 1)
    }

    private func flightOffset(_ action: CardAction, in size: CGSize) -> CGSize {
        switch action {
        case .skip:
            return CGSize(width: -size.width * 0.72, height: 26)
        case .delete:
            return CGSize(width: 0, height: -size.height * 1.15)
        case .classify(let bucketID):
            // Ask BoxLayout where that tile actually sits. Hard-coding the row
            // arithmetic here is how a card ends up flying to where the boxes
            // used to be after a category is added or removed.
            let position = store.bucketPosition(id: bucketID) ?? 1
            let centreX = BoxLayout.tileCentreX(position: position,
                                                count: store.buckets.count,
                                                stageWidth: size.width)
            // 19pt past the row's centre: landing dead-centre reads as stopping
            // short of the box rather than going into it.
            return CGSize(width: centreX - size.width / 2,
                          height: size.height / 2 + BoxLayout.rowHeight / 2 + 19)
        }
    }

    private func flightRotation(_ action: CardAction) -> Double {
        switch action {
        case .skip:     return -15
        case .delete:   return 5
        case .classify: return 0
        }
    }

    // MARK: - Boxes

    private var boxRow: some View {
        GeometryReader { geo in
            ZStack {
                if store.buckets.isEmpty {
                    addFirstBucketTile
                } else {
                    HStack(spacing: BoxLayout.spacing) {
                        ForEach(Array(store.buckets.enumerated()), id: \.element.id) { index, bucket in
                            BoxTile(bucket: bucket,
                                    position: index + 1,
                                    pulsing: store.pulsingBucket == bucket.id)
                                .frame(width: BoxLayout.tileWidth(count: store.buckets.count,
                                                                 stageWidth: geo.size.width),
                                       height: BoxLayout.rowHeight - 26)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.classify(bucket.id)
                                    store.refocus()
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, BoxLayout.horizontalPadding)
            .padding(.vertical, 13)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: BoxLayout.rowHeight)
        .background(Palette.panel)
    }

    /// 0 categories: one dashed tile. Adding the first one also opens the sheet,
    /// since a brand-new category always needs a name.
    private var addFirstBucketTile: some View {
        Button {
            if store.addBucket() { store.showCategories = true }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                Text("添加第一个分类").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Palette.sub)
            .frame(width: 200, height: BoxLayout.rowHeight - 26)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.tile)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Palette.hairline)
            )
        }
        .buttonStyle(.plain)
        .help("点这里添加第一个分类（最多 \(PhotoStore.maxBuckets) 个）")
    }
}

// MARK: - Card

/// Just the photo. The info bar is a separate view (`InfoBar`) that lives outside
/// the card, so a narrow photo can't squeeze the date out of existence.
private struct CardFace: View {
    /// Passed in explicitly rather than read from the store: the flying card
    /// must keep showing the photo it was launched with.
    let image: NSImage?
    let showsSpinner: Bool
    let elevated: Bool
    let box: CGSize

    var body: some View {
        ZStack {
            Palette.mat
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if showsSpinner {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: box.width, height: box.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(elevated ? 0.15 : 0.05),
                radius: elevated ? 16 : 5,
                y: elevated ? 7 : 2)
    }
}

/// The photo's info bar. Deliberately a sibling of the card rather than a strip
/// inside it: the card is exactly the photo, so on a 1:4 portrait an inside
/// caption would be ~90pt wide — nowhere to put a date, let alone a location.
/// Out here it just stays at a usable width.
private struct InfoBar: View {
    let item: SiftItem
    let width: CGFloat
    @ObservedObject var store: PhotoStore

    var body: some View {
        // Text centred in the bar, ⓘ floating at the trailing edge.
        ZStack {
            Text(item.caption(for: store.cardFields))
                .font(.system(size: 12))
                .foregroundStyle(Palette.sub)
                .lineLimit(1)
                .truncationMode(.middle)
                // Keep clear of the ⓘ so a long caption can't slide under it.
                .padding(.horizontal, 34)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer(minLength: 0)
                Button {
                    store.loadDetails()
                    store.showDetails = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.sub)
                }
                .buttonStyle(.plain)
                .help("查看这张照片的详细信息（EXIF、位置）")
                .popover(isPresented: $store.showDetails, arrowEdge: .bottom) {
                    DetailsPanel(store: store)
                }
            }
        }
        // Pill: the bar is only `infoHeight` tall, so the ends are fully round.
        // Inset a little more than the radius so the ⓘ clears the curve.
        .padding(.horizontal, 18)
        .frame(width: width, height: CardLayout.infoHeight)
        .background(Capsule().fill(Palette.panel))
        .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
    }
}

// MARK: - Details panel

private struct DetailsPanel: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("照片详情").font(.system(size: 13, weight: .semibold))
                if store.detailsLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer()
            }
            .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                row("拍摄时间", store.details?.created)
                row("尺寸", store.details?.dimensions)
                row("文件大小", store.details?.fileSize)
                row("相机", store.details?.camera)
                row("镜头", store.details?.lens)
                row("曝光参数", store.details?.exposure)
                row("类型", store.details?.source)
            }
            .padding(.vertical, 11)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("位置")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.sub)
                if let place = store.details?.place {
                    Text(place).font(.system(size: 12)).foregroundStyle(Palette.ink)
                }
                if let coordinate = store.details?.coordinate {
                    HStack(spacing: 8) {
                        Text(coordinate)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.sub)
                        Button("在地图中打开") { store.openInMaps() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
            .padding(.top, 11)
        }
        .padding(14)
        .frame(width: 350)
    }

    /// Titles used to be `tertiaryLabelColor` at 11pt, which was hard to read.
    /// Now secondary + medium weight.
    private func row(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.sub)
                .frame(width: 66, alignment: .leading)
            Text(value ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Storage box

private struct BoxTile: View {
    let bucket: Bucket
    /// 1-based slot in the row. This — not `bucket.id` — is what the badge shows
    /// and what the number keys map to.
    let position: Int
    let pulsing: Bool

    @Environment(\.colorScheme) private var colorScheme

    private static let tints: [Color] = [
        Color(red: 0.98, green: 0.90, blue: 0.88),
        Color(red: 0.98, green: 0.95, blue: 0.85),
        Color(red: 0.90, green: 0.96, blue: 0.89),
        Color(red: 0.89, green: 0.94, blue: 0.99),
        Color(red: 0.94, green: 0.91, blue: 0.99),
    ]

    /// Saturated siblings of `tints`, worn by the number badge. In dark mode the
    /// box itself goes flat — five dimmed pastels all muddle into the same grey —
    /// so the badge is what carries "which box is which".
    private static let vividTints: [Color] = [
        Color(red: 0.86, green: 0.34, blue: 0.45),
        Color(red: 0.85, green: 0.58, blue: 0.15),
        Color(red: 0.24, green: 0.63, blue: 0.38),
        Color(red: 0.24, green: 0.50, blue: 0.89),
        Color(red: 0.53, green: 0.35, blue: 0.86),
    ]

    private var vivid: Color {
        Self.vividTints[(position - 1) % Self.vividTints.count]
    }

    private var tint: Color {
        let base = Self.tints[(position - 1) % Self.tints.count]
        // Dark mode: a flat surface, NOT a dimmed pastel. The colour moves to the
        // badge, which is small enough to be vivid without glaring.
        return colorScheme == .dark ? Palette.tile : base
    }

    private var badgeFill: Color {
        colorScheme == .dark ? vivid : Palette.panel
    }

    private var badgeInk: Color {
        colorScheme == .dark ? Color.white : Palette.ink
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(position)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(badgeInk)
                    .frame(width: 20, height: 20)
                    .background(badgeFill, in: Circle())
                Spacer()
                Text("\(bucket.count)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)

            Spacer(minLength: 0)

            Image(systemName: "shippingbox.fill")
                .font(.system(size: 19))
                .foregroundStyle(Palette.sub.opacity(0.65))

            Text(bucket.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.85))
                .lineLimit(1)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(pulsing ? Palette.ink.opacity(0.35) : Palette.hairline,
                        lineWidth: pulsing ? 2.5 : 1)
        )
        .scaleEffect(pulsing ? 1.05 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.52), value: pulsing)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 4, y: 2)
        .help("点一下也能把当前照片放进这个盒子（快捷键 \(bucket.id)）")
    }
}

// MARK: - Secondary panels

private struct PanelHeader: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.faint)
            }
            Spacer()
            Button("完成", action: onClose).keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

private struct CategorySheet: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "分类",
                        subtitle: "键位 1…9，第十个用 0。改名后回车保存；图库里没有同名专辑会自动新建。",
                        onClose: { store.saveSettings(); store.showCategories = false })
            Divider()

            if store.buckets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "shippingbox").font(.system(size: 28))
                    Text("还没有分类").font(.system(size: 13))
                    Text("添加后按 1 就能把照片放进去").font(.system(size: 11))
                }
                .foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($store.buckets) { $bucket in
                            row(bucket: $bucket)
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            HStack(spacing: 10) {
                Button {
                    store.addBucket()
                } label: {
                    Label("添加分类", systemImage: "plus")
                }
                .disabled(!store.canAddBucket)

                Text("\(store.buckets.count) / \(PhotoStore.maxBuckets)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.faint)

                Spacer()

                if !store.canAddBucket {
                    Text("已达上限").font(.system(size: 11)).foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 470, height: 440)
        .background(Palette.panel)
    }

    private func row(bucket: Binding<Bucket>) -> some View {
        let position = store.bucketPosition(id: bucket.wrappedValue.id) ?? 0
        return HStack(spacing: 10) {
            Text("\(position)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))

            TextField("专辑名", text: bucket.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { store.saveSettings() }

            Text("\(bucket.wrappedValue.count) 张")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.faint)
                .frame(width: 54, alignment: .trailing)

            Button {
                store.removeBucket(id: bucket.wrappedValue.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.sub)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help(bucket.wrappedValue.count > 0
                  ? "删除「\(bucket.wrappedValue.name)」。里面 \(bucket.wrappedValue.count) 条的记录会丢弃，图库里的照片不动。"
                  : "删除「\(bucket.wrappedValue.name)」")
        }
    }
}

private struct TrashSheet: View {
    @ObservedObject var store: PhotoStore

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "待删除",
                        subtitle: "⌘⏎ 一次提交，系统只弹一个确认框。30 天内在「最近删除」可恢复。",
                        onClose: { store.showTrash = false })
            Divider()

            if store.pendingDeletes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 30))
                    Text("队列是空的").font(.system(size: 13))
                    Text("按 ↑ 把照片丢进来").font(.system(size: 11))
                }
                .foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.pendingDeletes) { item in
                            VStack(spacing: 4) {
                                ZStack {
                                    Palette.mat
                                    if let thumb = store.deleteThumbnails[item.id] {
                                        Image(nsImage: thumb)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    }
                                }
                                .frame(height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(item.label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Palette.faint)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 320)
            }

            Divider()
            HStack(spacing: 10) {
                Text("共 \(store.pendingDeletes.count) 张")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.sub)
                Spacer()
                Button("清空队列") { store.clearPendingDeletes() }
                    .disabled(store.pendingDeletes.isEmpty)
                Button("提交删除 ⌘⏎") { store.commit() }
                    .disabled(store.pendingDeletes.isEmpty || store.committing)
            }
            .controlSize(.regular)
            .padding(16)
        }
        .frame(width: 460)
        .background(Palette.panel)
    }
}

private struct SettingsSheet: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "设置",
                        subtitle: "照片始终留在系统图库里，PicReel 只做归类和删除。",
                        onClose: { store.showSettings = false })
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    section("外观") {
                        Toggle("暗色模式", isOn: Binding(
                            get: { store.darkMode },
                            set: { _ in store.toggleDarkMode() }
                        ))
                        .toggleStyle(.switch)
                        .font(.system(size: 13))
                    }

                    Divider()

                    section("一级页面卡片下方显示哪些信息") {
                        ForEach(CardInfoField.allCases) { field in
                            Toggle(isOn: Binding(
                                get: { store.cardFields.contains(field) },
                                set: { store.toggleCardField(field, on: $0) }
                            )) {
                                HStack(spacing: 8) {
                                    Text(field.title).font(.system(size: 13))
                                    Text(field.hint)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Palette.faint)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        Text(store.cardFields.isEmpty ? "当前一项都不显示，卡片下方会是空的。" : " ")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.faint)
                    }

                    Divider()

                    section("写入") {
                        Toggle("演练模式（分类与删除都不写入图库）", isOn: $store.dryRun)
                            .toggleStyle(.switch)
                            .font(.system(size: 13))
                            .disabled(PhotoStore.isDemo)
                    }

                    Divider()

                    section("成就") {
                        Text("已整理 \(store.decidedCount) 张"
                             + (store.alreadyFiledCount > 0
                                ? "（其中 \(store.alreadyFiledCount) 张启动时就已在分类相簿里）" : ""))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)

                        HStack(alignment: .top, spacing: 14) {
                            ForEach(store.achievementBoard, id: \.achievement.id) { row in
                                VStack(spacing: 6) {
                                    AchievementBadge(achievement: row.achievement,
                                                     unlockedAt: row.date, size: 52)
                                    Text(row.achievement.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(row.date == nil ? Palette.faint : Palette.ink)
                                    Text(row.date.map { Self.day.string(from: $0) }
                                         ?? "还差 \(max(0, row.achievement.threshold - store.decidedCount)) 张")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Palette.faint)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.top, 6)
                    }

                    Divider()

                    section("快捷键") {
                        ForEach(Self.keys, id: \.0) { key, description in
                            HStack(alignment: .top, spacing: 10) {
                                Text(key)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Palette.ink)
                                    .frame(width: 52, alignment: .leading)
                                Text(description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("跳过的照片会回到牌堆底部，之后还会再出现；只有删除和分类会让牌堆变小，所以牌堆空 = 每一张都做了决定。")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 470, height: 520)
        .background(Palette.panel)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.sub)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let keys: [(String, String)] = [
        ("→ / ↓", "跳过 —— 滑到堆底，之后还会出现"),
        ("↑", "标记删除（进垃圾桶）"),
        ("1-9 / 0", "收进对应分类（第 10 个用 0；写入图库同名专辑）"),
        ("←", "把上一张拉回最前面"),
        ("⌘Z", "撤销上一步（卡片会飞回来）"),
        ("⌘⏎", "提交删除（弹一次确认框）"),
        ("Esc", "从输入框切回快捷键"),
    ]
}

// MARK: - First-run guide

/// Two pages, shown over everything on a first launch and again from the
/// menu-bar item (`startGuide(force:)`).
///
/// Page 1 says what this is. Page 2 is the part that matters: it lists the
/// user's own albums and lets them tick which ones become the category boxes.
/// The badge on a ticked row is the number that row will answer to — computed
/// from the CURRENT ticks, so nothing on screen ever advertises a shortcut
/// that will not work.
///
/// Boxes map to albums by NAME. That is free: the write path already resolves
/// "which album does box n go into" with `existingAlbum(named:)`, so naming the
/// box after the album is the whole wiring.
private struct GuideView: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.colorScheme) private var colorScheme

    private var brandColors: [Color] {
        colorScheme == .dark ? Palette.brandDark : Palette.brandLight
    }

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            // 0 = 欢迎, 1 = 选相簿, 2 = 使用教程（最后一页，见 `guideLastStep`）。
            switch store.guideStep ?? 0 {
            case 0:
                welcomePage
                    .transition(pagePush)
                    .onAppear { store.revealGuide() }
            case 1:
                albumPage
                    .transition(pagePush)
                    .onAppear { store.revealGuide() }
            default:
                keysPage
                    .transition(pagePush)
                    .onAppear { store.revealGuide() }
            }
        }
    }

    /// Pages push in from the trailing edge and leave to the leading one — the
    /// same direction the round `>` button points.
    private var pagePush: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }

    // MARK: Page 1 — what is this

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            appIcon(size: 104)
                .scaleEffect(store.guideRevealed ? 1 : 0.9)
                .modifier(GuideArrival(store: store, step: 0))
                .animation(.spring(response: PhotoStore.guideRevealDuration * 1.2,
                                   dampingFraction: 0.72),
                           value: store.guideRevealed)

            Text("PicReel")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: brandColors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
                .padding(.top, 26)
                .modifier(GuideArrival(store: store, step: 1))

            Text("只用一根手指整理相册")
                .font(.system(size: 15))
                .foregroundStyle(Palette.sub)
                .padding(.top, 14)
                .modifier(GuideArrival(store: store, step: 2))

            Spacer(minLength: 0)

            HStack {
                Spacer()
                roundAdvance("chevron.right", help: "下一步") {
                    store.advanceGuide()
                }
                .modifier(GuideArrival(store: store, step: 3))
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
    }

    // MARK: Page 2 — pick the albums that become boxes

    private var albumPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选相簿当分类盒子")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.ink)
                .modifier(GuideArrival(store: store, step: 0))

            Text(subtitleText)
                .font(.system(size: 13))
                .foregroundStyle(Palette.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 18)
                .modifier(GuideArrival(store: store, step: 1))

            albumList
                .modifier(GuideArrival(store: store, step: 2))

            HStack(spacing: 12) {
                Text("已选 \(store.guidePickedCount) / \(PhotoStore.maxBuckets)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.guidePickedCount == 0 ? Palette.faint : Palette.sub)
                    // Numbers change under the user's finger as they tick rows;
                    // a small spring makes the change legible instead of a jump.
                    .animation(.spring(response: 0.3, dampingFraction: 0.7),
                               value: store.guidePickedCount)
                Spacer()
                roundAdvance("chevron.right", help: "下一步：使用教程") {
                    store.advanceGuide()
                }
            }
            .padding(.top, 16)
            .modifier(GuideArrival(store: store, step: 3))
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
    }

    private var subtitleText: String {
        if store.libraryAlbums.isEmpty {
            return "没读到相簿。可以先跳过 —— 之后在顶栏的分类面板里随时能加。"
        }
        return "勾上常用的相簿，它们会成为底部的盒子。"
             + "左边圆点里的数字就是快捷键，按点击先后编号：先点的那个按 1，下一个按 2（第 10 个按 0）。"
             + "一个都不勾也行，直接点右下角继续，会保留现在的分类。"
    }

    // MARK: Page 3 — the keys

    /// The controls, drawn as key caps.
    ///
    /// A guide that explains a keyboard in prose asks the user to translate
    /// ("标记删除是 ↑") — a picture of the key they are about to press does not.
    /// The glyph is the literal printing on the cap; the label under it is the
    /// shortest phrase that names the action.
    ///
    /// `⌘Z` is deliberately absent: undo is a global shortcut every Mac user
    /// already knows, and a cap spent on it would push the keys that are *not*
    /// guessable out of the row. The full map (including `Esc` and the tenth
    /// box's `0`) stays in 设置与快捷键 and on page 2.
    private static let guideKeys: [GuideKey] = [
        GuideKey(glyph: "→ ↓",  label: "跳过"),
        GuideKey(glyph: "↑",    label: "标记删除"),
        GuideKey(glyph: "1–9",  label: "收进分类"),
        GuideKey(glyph: "←",    label: "拉回上一张"),
        GuideKey(glyph: "⌘⏎",   label: "提交删除"),
    ]

    private var keysPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("使用教程")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.ink)
                .modifier(GuideArrival(store: store, step: 0))

            // No blurb on this page: the caps are the explanation. A sentence
            // above them only pushes them down and gives the eye something else
            // to read first.
            Spacer(minLength: 12)

            keyGrid
                .modifier(GuideArrival(store: store, step: 1))

            Spacer(minLength: 12)

            HStack {
                Spacer()
                roundAdvance("checkmark", help: "开始使用") {
                    store.finishGuide()
                }
            }
            .modifier(GuideArrival(store: store, step: 2))
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
    }

    /// One row of square caps, centred on the page and in the middle of the
    /// space between the header and the button. Square and identically sized —
    /// that is what makes a row of them read as a keyboard rather than as five
    /// boxes — which means the block is only as wide as its caps and the labels
    /// under them are ragged; centring is what stops that looking accidental.
    private var keyGrid: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(Self.guideKeys) { key in
                KeyCap(glyph: key.glyph, label: key.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var albumList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(store.libraryAlbums.enumerated()), id: \.element.id) { index, album in
                    albumRow(album, index: index)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func albumRow(_ album: LibraryAlbum, index: Int) -> some View {
        let position = store.guidePosition(for: album)
        let picked = position != nil
        let full = !picked && store.guidePickedCount >= PhotoStore.maxBuckets

        return Button {
            store.toggleGuideSelection(album.id)
        } label: {
            HStack(spacing: 12) {
                // The badge IS the shortcut number, or a dash when the row is
                // not ticked — never a number the user cannot press.
                Text(position.map(Self.keyLabel) ?? "–")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(picked ? Color.white : Palette.faint)
                    .frame(width: 26, height: 26)
                    .background {
                        if picked {
                            Circle().fill(LinearGradient(colors: brandColors,
                                                         startPoint: .top,
                                                         endPoint: .bottom))
                        } else {
                            Circle().strokeBorder(Palette.hairline, lineWidth: 1)
                        }
                    }
                    // Ticking pops the badge; unticking settles it back.
                    .scaleEffect(picked ? 1 : 0.88)
                    .animation(.spring(response: 0.3, dampingFraction: 0.55), value: picked)

                // A preview of what is actually in there. A name alone does not
                // tell you whether 「存档」 holds screenshots or holiday photos.
                Group {
                    if let thumb = store.albumThumbnails[album.id] {
                        Image(nsImage: thumb)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        // Placeholder for "not fetched yet" and for genuinely
                        // empty albums — the frame is fixed either way, so rows
                        // do not reflow when the image lands.
                        Rectangle().fill(Palette.hairline.opacity(0.35))
                    }
                }
                .frame(width: PhotoStore.albumThumbSide, height: PhotoStore.albumThumbSide)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 0.5)
                }
                .animation(.easeOut(duration: 0.25), value: store.albumThumbnails[album.id] != nil)

                Text(album.name)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(album.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint)

                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(picked ? brandColors[0] : Palette.hairline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(picked ? Palette.tile : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .opacity(full ? 0.4 : 1)
            // Ticks and un-ticks ease rather than snap.
            .animation(.easeOut(duration: 0.2), value: picked)
        }
        .buttonStyle(.plain)
        .disabled(full)
        // Arrives last of all, and staggered: the list assembles top-down.
        .modifier(GuideRowArrival(store: store, index: index))
    }

    // MARK: Shared bits

    /// The 10th box answers to `0`, because that is the key that reaches it.
    private static func keyLabel(_ position: Int) -> String {
        position == PhotoStore.maxBuckets ? "0" : "\(position)"
    }

    /// Round, brand-filled, one glyph — the same shape language as the top-bar
    /// buttons, just big enough to be the only thing to press on the page.
    private func roundAdvance(_ symbol: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: brandColors,
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing),
                            in: Circle())
                .shadow(color: brandColors[0].opacity(0.35), radius: 10, y: 4)
        }
        // Press feedback without `@State` (which CLT's SDK cannot compile):
        // SwiftUI drives `isPressed` for us.
        .buttonStyle(RoundPushStyle())
        .help(help)
    }

    /// The app's own icon, big. Same source as the top-bar mark, so the guide,
    /// the window and the Dock all show one logo.
    private func appIcon(size: CGFloat) -> some View {
        Group {
            if let icon = NSImage.appIconFull {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: brandColors,
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
            }
        }
    }
}

// MARK: - Key caps

/// One instruction on the guide's 使用教程 page: the glyph printed on the cap and the
/// shortest phrase that names what pressing it does. `glyph` doubles as the
/// identity — no two caps in the table are the same key.
private struct GuideKey: Identifiable {
    let glyph: String
    let label: String
    var id: String { glyph }
}

/// One key of the guide's instruction page, drawn so it reads as a physical key:
/// a lit face sitting on a darker edge that peeks out below it.
///
/// The size is **pinned**, not left to the layout. A `RoundedRectangle` fills
/// whatever it is offered, so a cap built as bare shapes inside a `ZStack`
/// reports a flexible height and, laid out as the last stretchy child of a
/// column, stretches to fill it — the first build of this page drew six tall
/// white slabs instead of keys. `.frame(width:height:)` on the glyph gives the
/// background a definite size to fill, and every cap is the same size because
/// that is what makes a row of them read as a keyboard.
///
/// The colours are spelled out per appearance rather than taken from the
/// semantic palette — a key cap is not window chrome, and the system's greys
/// made both modes look flat. Light mode is a white cap on a grey edge; dark
/// mode is a raised tile on the canvas.
private struct KeyCap: View {
    let glyph: String
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    /// Square, like a real keyboard key — one side for every cap in the row.
    private static let side: CGFloat = 86

    var body: some View {
        VStack(spacing: 10) {
            Text(glyph)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .frame(width: Self.side, height: Self.side)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(edge)
                            .offset(y: 3)
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(face)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Palette.hairline, lineWidth: 0.8)
                            )
                    }
                )
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.sub)
                .fixedSize()
        }
        .frame(width: Self.side)
    }

    private var face: LinearGradient {
        LinearGradient(colors: colorScheme == .dark
                       ? [Color(nsColor: NSColor(white: 0.27, alpha: 1)),
                          Color(nsColor: NSColor(white: 0.19, alpha: 1))]
                       : [Color(nsColor: NSColor(white: 1.00, alpha: 1)),
                          Color(nsColor: NSColor(white: 0.92, alpha: 1))],
                       startPoint: .top, endPoint: .bottom)
    }

    private var edge: Color {
        Color(nsColor: colorScheme == .dark ? NSColor(white: 0.09, alpha: 1)
                                            : NSColor(white: 0.78, alpha: 1))
    }
}

// MARK: - Shuffle explainer

/// Shuffle swaps the whole deck under you — twenty random photos instead of the
/// order you were working through — so the first time it happens it says what
/// it just did, instead of leaving you wondering why the card changed.
///
/// The「不再显示此提示」tick is only written when it is actually ticked: closing
/// without ticking means "read it, ask me again next time", which is what the
/// label says.
private struct ShuffleIntroSheet: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.colorScheme) private var colorScheme

    private var brandColors: [Color] {
        colorScheme == .dark ? Palette.brandDark : Palette.brandLight
    }

    /// Just the three points, no glosses: three short lines read at a glance,
    /// which is the whole job of this sheet.
    private static let notes: [(String, String)] = [
        ("die.face.5.fill", "随机抽 20 张"),
        ("arrow.triangle.2.circlepath", "过完自动再抽"),
        ("arrow.uturn.backward", "随时可以退出"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "die.face.5.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle().fill(LinearGradient(colors: brandColors,
                                                     startPoint: .top, endPoint: .bottom))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shuffle 模式").font(.system(size: 15, weight: .semibold))
                    Text("把「一大堆」变成「一小撮」")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 18)

            // Three across, not three stacked. With the glosses gone, stacked
            // rows read as unfinished text with a hole to the right of each one;
            // a 3-up strip reads as a list of three points.
            HStack(alignment: .top, spacing: 10) {
                ForEach(Self.notes, id: \.0) { symbol, title in
                    VStack(spacing: 7) {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(brandColors[0])
                            .frame(width: 36, height: 36)
                            .background {
                                Circle().fill(brandColors[0].opacity(0.13))
                            }
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 18)

            Divider()

            HStack {
                Toggle("不再显示此提示", isOn: $store.skipShuffleIntro)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer(minLength: 12)
                Button {
                    store.closeShuffleIntro()
                } label: {
                    Text("开始整理")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background {
                            Capsule().fill(LinearGradient(colors: brandColors,
                                                          startPoint: .leading,
                                                          endPoint: .trailing))
                        }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 440)
        .background(Palette.panel)
    }
}

// MARK: - Leaving shuffle early

/// Shown when the dice is pressed again before the round is finished and the
/// round has work in it.
///
/// Three answers, and the middle one is the one that needs saying out loud: a
/// classification reaches the photo library the moment the key is pressed, so
/// "don't keep it" cannot mean merely forgetting it here — it has to mean taking
/// the photo back out of the album. The sheet states which of those is true in
/// the current mode instead of leaving the user to guess.
private struct ShuffleExitSheet: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.colorScheme) private var colorScheme

    private var brandColors: [Color] {
        colorScheme == .dark ? Palette.brandDark : Palette.brandLight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("这一轮还没做完")
                .font(.system(size: 15, weight: .semibold))

            Text("20 张里还剩 \(store.deck.count) 张没处理，你已经处理了 \(store.shuffleRoundDecisions) 张。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 20) {
                tally("分类", store.shuffleRoundClassified, tint: brandColors[0])
                tally("标记删除", store.shuffleRoundDeleted,
                      tint: Color(red: 0.78, green: 0.22, blue: 0.22))
                Spacer(minLength: 0)
            }
            .padding(.top, 12)

            Text(store.dryRun
                 ? "演练模式：本来就不会写进「照片」App。"
                 : "本轮还没写进「照片」App，做完 20 张才一起写。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Divider().padding(.top, 16)

            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Button("撤销这一轮") { store.revertRoundAndExitShuffle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.78, green: 0.22, blue: 0.22))
                Button("保留并退出") { store.keepRoundAndExitShuffle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.sub)
                Button {
                    store.cancelShuffleExit()
                } label: {
                    Text("继续整理")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(LinearGradient(colors: brandColors,
                                                          startPoint: .leading,
                                                          endPoint: .trailing))
                        }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 460)
        .background(Palette.panel)
    }

    private func tally(_ label: String, _ count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(count > 0 ? tint : Palette.faint)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.sub)
        }
    }
}

// MARK: - Achievement announcement

/// The unlock announcement.
///
/// Slides down over the top of the deck, sits for a few seconds, leaves. The
/// store queues these, so crossing two thresholds at once — which is exactly
/// what happens when you resume a library that already has a thousand filed
/// photos — gives each badge its own moment instead of flashing only the last.
///
/// Lives in this file because `Palette` is private to it.
struct AchievementToast: View {
    let achievement: Achievement

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AchievementBadge(achievement: achievement, unlockedAt: Date(), size: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text("成就达成")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.sub)
                    Text(achievement.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    Text(achievement.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.sub)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.stamp.string(from: Date()))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.sub)
                    Text("已记录")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.20), radius: 20, y: 8)
            .padding(.horizontal, 24)
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        // Never eats a click: it is an announcement, not a dialog.
        .allowsHitTesting(false)
    }
}

// MARK: - Guide animation

/// Fades a piece of the guide in from slightly below, one step behind the piece
/// before it, so a page assembles instead of appearing all at once.
///
/// Driven by `store.guideRevealed` rather than local `@State` — CLT's SDK cannot
/// compile `@State` (see the `macos-app-clt-only` skill), and it also means the
/// entrance can be reset from outside the view when the page changes.
private struct GuideArrival: ViewModifier {
    @ObservedObject var store: PhotoStore
    let step: Int

    func body(content: Content) -> some View {
        content
            .opacity(store.guideRevealed ? 1 : 0)
            .offset(y: store.guideRevealed ? 0 : 14)
            .animation(.easeOut(duration: PhotoStore.guideRevealDuration)
                        .delay(PhotoStore.guideDelay(step)),
                       value: store.guideRevealed)
    }
}

/// Album rows: same idea, tighter, and with the delay **capped** so a 43-album
/// library does not leave the bottom rows invisible for over a second.
private struct GuideRowArrival: ViewModifier {
    @ObservedObject var store: PhotoStore
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(store.guideRevealed ? 1 : 0)
            .offset(x: store.guideRevealed ? 0 : -16)
            .animation(.easeOut(duration: PhotoStore.guideRevealDuration * 0.7)
                        .delay(PhotoStore.guideRowDelay(index)),
                       value: store.guideRevealed)
    }
}

/// Squash on press. A `ButtonStyle` gets `isPressed` handed to it, which is the
/// only press feedback available without `@State`.
private struct RoundPushStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

extension NSImage {
    /// The app's own icon, at full resolution.
    ///
    /// `NSApp.applicationIconImage` hands back an image whose best
    /// representation is often the 32×32 slice of the .icns. That is fine at
    /// 25pt in the top bar, but the guide draws it at 104pt and it comes out
    /// visibly mushy. Reading the .icns straight off disk gets every size in it,
    /// so the big draw picks a sharp one.
    static var appIconFull: NSImage? {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            return image
        }
        return NSApp?.applicationIconImage
    }
}
