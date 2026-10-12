// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import Foundation
import AppKit

/// Headless check of the two things the user actually specified:
///   1. which key does what
///   2. what the deck does with it
///
/// Runs with no window, no photo library and no screen: `PhotoSift --selftest`.
enum SelfTest {

    private static var failures = 0
    private static var checks = 0

    private static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if condition {
            print("  PASS  \(label)")
        } else {
            failures += 1
            print("  FAIL  \(label)")
        }
    }

    static func run() -> Int32 {
        print("PhotoSift self-test")
        print("-------------------")

        mappingTests()
        deckTests()
        previewTests()
        cardInfoTests()
        cardLayoutTests()
        cardShapeTests()
        bucketTests()
        guideTests()
        v09Tests()
        undoTests()
        returnAnimationTests()
        invariantTests()
        commitGuardTests()

        print("-------------------")
        if failures == 0 {
            print("ALL \(checks) CHECKS PASSED")
            return 0
        }
        print("\(failures) of \(checks) CHECKS FAILED")
        return 1
    }

    // MARK: - 1. key mapping

    private static func mappingTests() {
        print("[key mapping]")
        check(key(49) == .ignore,                  "空格(49)        -> ignore（按要求删除空格键）")
        check(key(126) == .delete,                "上键(126)       -> delete")
        check(key(123) == .back,                  "左键(123)       -> back")
        check(key(125) == .next,                  "下键(125)       -> next")
        check(key(124) == .next,                  "右键(124)       -> next")
        check(key(18, "1") == .classify(1),       "数字 1          -> classify(1)")
        check(key(19, "2") == .classify(2),       "数字 2          -> classify(2)")
        check(key(20, "3") == .classify(3),       "数字 3          -> classify(3)")
        check(key(21, "4") == .classify(4),       "数字 4          -> classify(4)")
        check(key(23, "5") == .classify(5),       "数字 5          -> classify(5)")
        // v0.7：分类可到 10 个，键位扩到 1…9，第 10 个用 0。全部按**位置**算。
        check(key(22, "6") == .classify(6),       "数字 6          -> classify(6)")
        check(key(26, "7") == .classify(7),       "数字 7          -> classify(7)")
        check(key(28, "8") == .classify(8),       "数字 8          -> classify(8)")
        check(key(25, "9") == .classify(9),       "数字 9          -> classify(9)")
        check(key(29, "0") == .classify(10),      "数字 0          -> classify(10)（第 10 个分类）")
        check(key(36, "\r", cmd: true) == .commit, "⌘⏎             -> commit")
        check(key(6, "z", cmd: true) == .undo,    "⌘Z             -> undo")
        check(key(18, "1", cmd: true) == .ignore, "⌘1             -> ignore")
        check(key(18, "1", shift: true) == .ignore, "⇧1           -> ignore")
        check(key(48) == .ignore,                 "Tab             -> ignore")
    }

    private static func key(_ code: UInt16,
                            _ chars: String = "",
                            cmd: Bool = false,
                            shift: Bool = false) -> SiftCommand {
        PhotoStore.command(keyCode: code, characters: chars, isCommand: cmd, isShift: shift)
    }

    // MARK: - 2. deck: skip rotates to the bottom, only decisions shrink it

    private static func deckTests() {
        print("[牌堆：跳过 = 放回堆底，只有决定才缩小]")

        let store = PhotoStore()
        store.seedForSelfTest(count: 20)
        check(store.deck.count == 20, "载入 20 张")
        check(store.decidedCount == 0, "初始已处理 = 0")
        check(store.deck.first?.id == "test-0", "最前面是 test-0")

        store.perform(.next)
        check(store.deck.count == 20, "空格          -> 牌堆仍是 20 张（没被处理掉）")
        check(store.deck.first?.id == "test-1", "空格          -> 最前面变成 test-1")
        check(store.deck.last?.id == "test-0", "空格          -> test-0 掉到堆底")
        check(store.decidedCount == 0, "空格          -> 已处理仍为 0")

        store.perform(.next)
        check(store.deck.first?.id == "test-2", "空格 再来      -> 最前面 test-2")
        check(store.deck.last?.id == "test-1", "空格 再来      -> 堆底 test-1")
        check(store.decidedCount == 0, "空格 ×2       -> 已处理仍为 0")

        store.perform(.delete)
        check(store.deck.count == 19, "↑            -> 牌堆 20→19")
        check(store.pendingDeletes.count == 1, "↑            -> 待删 1 张")
        check(store.decidedCount == 1, "↑            -> 已处理 1")
        check(store.deck.last?.id == "test-1", "↑            -> 堆底那张不受影响")

        store.perform(.classify(3))
        check(store.deck.count == 18, "数字 3        -> 牌堆 19→18")
        check(store.bucketCount(3) == 1, "数字 3        -> 盒子3 = 1")
        check(store.bucketCount(1) == 0, "数字 3        -> 盒子1 未被误加")
        check(store.bucketMemberIDs(3) == ["test-3"], "数字 3        -> 记录下是哪张，供撤销用")

        store.perform(.classify(5))
        store.perform(.classify(5))
        check(store.bucketCount(5) == 2, "数字 5 ×2     -> 盒子5 = 2")
        check(store.deck.count == 16, "数字 5 ×2     -> 牌堆剩 16")
        check(store.decidedCount == 4, "累计          -> 已处理 4")

        print("[回退]")
        let before = store.deck.first?.id
        store.perform(.back)
        check(store.deck.count == 16, "←            -> 牌堆大小不变")
        check(store.deck.first?.id == "test-1", "←            -> 把堆底最近跳过的拉回最前")
        check(store.deck.first?.id != before, "←            -> 最前面确实换人了")
    }

    // MARK: - 2b. preview must be re-requested on every navigation
    //
    // This is the regression guard for the v0.2 bug where the deck advanced but
    // the shown photo never changed: the mutators updated `deck` but never asked
    // for a new image. The old self-test could not see it because its fixtures
    // had no asset at all, so `loadPreview` silently no-op'd.

    private static func previewTests() {
        print("[每次导航都要重新取图]")

        let store = PhotoStore()
        store.seedForSelfTest(count: 10)

        func expectNewPreview(step: String, _ body: () -> Void) {
            let before = store.previewRequests
            body()
            check(store.previewRequests == before + 1,
                  "\(step) -> 重新请求了预览图（\(before) → \(store.previewRequests)）")
        }

        expectNewPreview(step: "→ 跳过") { store.perform(.next) }
        expectNewPreview(step: "↑ 删除") { store.perform(.delete) }
        expectNewPreview(step: "数字 3") { store.perform(.classify(3)) }
        expectNewPreview(step: "← 回退") { store.perform(.back) }
        expectNewPreview(step: "⌘Z    ") { store.undo() }

        print("[快速连按不互相打断]")
        let rapid = PhotoStore()
        rapid.seedForSelfTest(count: 10)
        rapid.perform(.next)
        rapid.perform(.next)
        rapid.perform(.next)
        // 单槽实现只能留住最后一张，帧上就会看到前一段动画被截断。
        check(rapid.flying.count == 3, "连按三次 → -> 三张卡同时在飞（\(rapid.flying.count) 张）")
        check(Set(rapid.flying.map(\.id)).count == 3, "连按三次 → -> 三张是各自独立的对象")

        let mixed = PhotoStore()
        mixed.seedForSelfTest(count: 10)
        mixed.perform(.next)
        mixed.perform(.delete)
        mixed.perform(.classify(2))
        check(mixed.flying.count == 3, "跳过/删除/分类混着连按 -> 三个动画同时存在")
        check(mixed.flying.map(\.action) == [.skip, .delete, .classify(2)],
              "混合连按 -> 每个动画各自记住自己的方向")
    }

    // MARK: - 2c. which metadata shows under the card

    private static func cardInfoTests() {
        print("[一级页面的卡片信息可配置]")

        let item = SiftItem(id: "x",
                            date: Date(timeIntervalSince1970: 1_760_000_000),
                            pixelWidth: 1200,
                            pixelHeight: 1600,
                            kind: "截屏",
                            hasLocation: true,
                            asset: nil)

        check(PhotoStore().cardFields == [.date], "默认只勾「拍摄日期」")

        let dateOnly = item.caption(for: [.date])
        check(dateOnly.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#,
                             options: .regularExpression) != nil,
              "只勾日期 -> 就是一个日期（\(dateOnly)）")
        check(!dateOnly.contains("1200×1600"), "只勾日期 -> 不显示分辨率")

        check(item.caption(for: [.resolution]) == "1200×1600", "只勾分辨率 -> 只有分辨率")
        check(item.caption(for: [.kind]) == "截屏", "只勾类型 -> 只有类型")
        check(item.caption(for: [.location]) == "含位置", "只勾位置 -> 标出含位置")
        check(item.caption(for: [.date, .resolution]).contains("1200×1600"),
              "勾两个 -> 两个都出现，用 · 连接")
        check(item.caption(for: []) == " ", "一项都不勾 -> 标题为空")

        let plain = SiftItem(id: "y", date: nil, pixelWidth: 0, pixelHeight: 0,
                             kind: "", hasLocation: false, asset: nil)
        check(plain.caption(for: [.kind]) == " ", "普通照片勾类型 -> 不显示空字符串")
        check(plain.caption(for: [.location]) == " ", "没 GPS 勾位置 -> 不显示")

        print("[设置序列化 + 旧配置兼容]")
        // v0.6 格式：固定 5 个分类名，没有 id。
        let legacyShape = AppSettings(bucketNames: ["a", "b", "c", "d", "e"],
                                      buckets: nil, nextBucketID: nil,
                                      cardFields: ["date", "kind"],
                                      darkMode: true)
        if let data = try? JSONEncoder().encode(legacyShape),
           let back = try? JSONDecoder().decode(AppSettings.self, from: data) {
            check(back.bucketNames?.count == 5 && back.darkMode,
                  "v0.6 格式（只有分类名）能完整往返")
            check(back.cardFields == ["date", "kind"], "卡片信息字段能往返")
        } else {
            check(false, "设置序列化失败")
        }

        // v0.7 格式：带稳定 id 的完整列表。
        let currentShape = AppSettings(bucketNames: nil,
                                       buckets: [Bucket(id: 7, name: "工作", count: 3)],
                                       nextBucketID: 8,
                                       cardFields: [], darkMode: false)
        if let data = try? JSONEncoder().encode(currentShape),
           let back = try? JSONDecoder().decode(AppSettings.self, from: data) {
            check(back.buckets?.count == 1 && back.buckets?.first?.id == 7,
                  "v0.7 格式（带稳定 id）能完整往返")
            check(back.nextBucketID == 8, "nextBucketID 也持久化（删完再建不会撞 id）")
            check(back.buckets?.first?.count == 3, "分类里的张数保留")
        } else {
            check(false, "v0.7 设置序列化失败")
        }

        // v0.3 及更早的配置文件是个纯字符串数组，升级时不能读崩。
        if let legacy = try? JSONEncoder().encode(["1", "2", "3", "4", "5"]),
           let names = try? JSONDecoder().decode([String].self, from: legacy) {
            check(names.count == 5, "旧版（纯分类名数组）仍能解析，升级不会丢配置")
        } else {
            check(false, "旧版配置解析失败")
        }
    }

    // MARK: - 2d. the card hugs its photo (v0.5)
    //
    // v0.4 floated a small photo inside a fixed 700x620 frame: three nested
    // boxes ate the space and the photo read as a stamp on a grey mat. The box
    // is now derived from the photo's own aspect ratio. This locks that in.

    private static func cardLayoutTests() {
        print("[卡片贴着照片比例]")

        let stage = CGSize(width: 820, height: 500)

        func aspect(_ size: CGSize) -> CGFloat { size.width / size.height }

        // 竖图 1200x1600 (3:4) — 被高度限制
        let portrait = CardLayout.box(pixelWidth: 1200, pixelHeight: 1600, in: stage)
        check(abs(aspect(portrait) - 0.75) < 0.01,
              "竖图卡片比例 = 照片比例（\(String(format: "%.3f", aspect(portrait))) ≈ 0.750）")
        check(portrait.height <= stage.height - 27, "竖图卡片不超出舞台高度")
        check(portrait.width < stage.width - 55, "竖图卡片比舞台窄（受高度限制，不是被垫子撑满）")

        // 横图 1600x1200 (4:3)
        let landscape = CardLayout.box(pixelWidth: 1600, pixelHeight: 1200, in: stage)
        check(abs(aspect(landscape) - 4.0 / 3.0) < 0.01,
              "横图卡片比例 = 照片比例（\(String(format: "%.3f", aspect(landscape))) ≈ 1.333）")
        check(landscape.width <= stage.width - 55, "横图卡片不超出舞台宽度")

        // 极端长图：宽度有下限，宁可略微不贴比例也不能塌成一条线
        let banner = CardLayout.box(pixelWidth: 500, pixelHeight: 4000, in: stage)
        check(banner.width >= 60 && banner.height <= stage.height - 27,
              "极端长图 -> 宽度兜底 \(Int(banner.width))pt，不塌成 0")

        // 没有像素信息的老照片要退回 4:3，不能除零
        let unknown = CardLayout.box(pixelWidth: 0, pixelHeight: 0, in: stage)
        check(abs(aspect(unknown) - 4.0 / 3.0) < 0.01, "没有尺寸信息 -> 退回 4:3")

        // 信息栏在照片**外面**，而且宽度**固定**。它以前跟着照片宽度走，翻牌时
        // 一路跳（300 → 326 → 435 → 580 → 844）—— 唯一该稳定的东西反而在动。
        let slimCard = CardLayout.box(pixelWidth: 480, pixelHeight: 2400, in: stage)
        check(slimCard.width < 120, "1:5 窄图的卡片只有 \(Int(slimCard.width))pt 宽")
        check(CardLayout.infoWidth >= 300,
              "信息栏固定 \(Int(CardLayout.infoWidth))pt，够放日期 + 位置")
        check(CardLayout.infoWidth <= stage.width - 55,
              "信息栏不超出舞台宽度（舞台 \(Int(stage.width))pt 宽时）")
    }

    // MARK: - 2e. a card's shape follows its own photo, nothing else (v0.52)
    //
    // v0.5 drew the whole pile in the front card's shape. The moment a photo
    // stopped being the front one, its frame snapped to the NEXT photo's
    // proportions -- very visible during an undo. A card's box must be a
    // function of its own photo and nothing else.

    private static func cardShapeTests() {
        print("[卡片形状只取决于它自己那张照片]")

        let stage = CGSize(width: 820, height: 500)
        let portrait = CardLayout.box(pixelWidth: 1200, pixelHeight: 1600, in: stage)
        let landscape = CardLayout.box(pixelWidth: 1600, pixelHeight: 1200, in: stage)

        check(portrait != landscape,
              "竖图与横图的卡片形状确实不同（所以堆叠不能统一成一种形状）")
        check(CardLayout.box(pixelWidth: 1200, pixelHeight: 1600, in: stage) == portrait,
              "同一张照片的卡片形状可重现（与它排在第几张无关）")
        check(CardLayout.box(pixelWidth: 1600, pixelHeight: 1200, in: stage) == landscape,
              "横图的形状不随上下文变化")

        // 演示牌堆本身混了两种比例，这条断言才真的能触发形状变化
        let demo = DemoLibrary.items(count: 24)
        let aspects = Set(demo.map { $0.pixelWidth * 1000 / max(1, $0.pixelHeight) })
        check(aspects.count >= 2,
              "演示牌堆混了 \(aspects.count) 种比例，确实能触发形状变化")

        // 后面那张牌必须装得进前面那张的轮廓里，否则就是「托盘」
        let s1 = CardLayout.backScale(own: landscape, front: portrait, index: 1)
        check(landscape.width * s1 <= portrait.width + 0.5,
              "横图叠在竖图后面 -> 缩放后宽 \(Int(landscape.width * s1))pt ≤ 前面那张的 \(Int(portrait.width))pt")
        check(landscape.height * s1 <= portrait.height + 0.5,
              "横图叠在竖图后面 -> 高也不超出")

        let s2 = CardLayout.backScale(own: portrait, front: landscape, index: 1)
        check(portrait.width * s2 <= landscape.width + 0.5,
              "竖图叠在横图后面 -> 也不超出")

        // 同比例时不该被额外缩小，就是常规叠牌
        check(abs(CardLayout.backScale(own: portrait, front: portrait, index: 1) - 0.95) < 0.001,
              "前后同比例 -> 保持常规的 0.95，不会被多缩一刀")
        check(CardLayout.backScale(own: portrait, front: portrait, index: 0) == 1,
              "最前面那张永远不缩放")

        // 牌堆只画两张。第三张静止时看不见，动画途中却会从前面那张底下露边。
        let pile = PhotoStore()
        pile.seedForSelfTest(count: 9)
        check(pile.topCards.count == 2, "牌堆只画 2 张（得到 \(pile.topCards.count)）")
        pile.seedForSelfTest(count: 1)
        check(pile.topCards.count == 1, "只剩 1 张时不硬画第 2 张")

        // 换前排时，新前排必须从「它当后排时的大小」长起来。否则一帧之内弹到
        // 全尺寸 —— 实测窄图后面跟横图是 192pt → 587pt，3 倍。
        let narrow = CardLayout.box(pixelWidth: 1206, pixelHeight: 2622, in: stage)
        let wide = CardLayout.box(pixelWidth: 4032, pixelHeight: 3024, in: stage)
        let entry = CardLayout.backScale(own: wide, front: narrow, index: 1)
        check(entry < 0.4,
              "窄图后跟横图 -> 入场缩放只有 \(String(format: "%.3f", entry))，远小于 1")
        check(wide.width * entry <= narrow.width + 0.5,
              "入场宽度 \(Int(wide.width * entry))pt ≤ 原前排 \(Int(narrow.width))pt，衔接才连续")

        // store 侧：换前排要记住旧前排尺寸，而且牌堆的入场窗口必须**搭在飞行卡
        // 上**，不能用自己的定时器 —— 它的那一帧会被 SwiftUI 合并掉（实测过：
        // body 求值出 0.246，但一帧都没提交，于是牌堆直接跳到全尺寸）。
        let nav = PhotoStore()
        nav.seedForSelfTest(count: 5)
        nav.perform(.next)
        check(nav.previousFront != nil, "跳过 -> 记住旧前排尺寸（入场缩放要用）")
        check(nav.pileAtEntry, "跳过 -> 入场窗口内 pileAtEntry = true，牌堆停在入场尺寸")
        settle()
        check(!nav.pileAtEntry, "跳过 -> 飞行卡起飞后落到全尺寸，动画才有起点")

        // 撤回是从画外飞进来，没有「上一个尺寸」可长，必须是全尺寸起
        let backNav = PhotoStore()
        backNav.seedForSelfTest(count: 5)
        backNav.perform(.next)
        settle()
        backNav.perform(.back)
        check(!backNav.pileAtEntry && backNav.previousFront == nil,
              "← 撤回 -> 牌堆不做入场缩放（交给飞回来的那张卡）")
    }

    // MARK: - 2f. categories are user-managed now (v0.7)
    //
    // Keys address a POSITION, never an id. Ids stay put so deleting the 2nd of
    // five can't make two tiles both claim to be "3", but positions shift — and
    // that shift is exactly what the number keys and the classify flight use.

    private static func bucketTests() {
        print("[分类可增可删（0-10）]")

        let store = PhotoStore()
        store.seedForSelfTest(count: 12)
        check(store.buckets.count == 5, "默认 5 个分类")
        check(store.bucketPosition(id: store.buckets[0].id) == 1, "第一个分类的位置是 1")

        store.perform(.classify(1))
        check(store.bucketCount(store.buckets[0].id) == 1, "按 1 -> 进第 1 个分类")

        // 只有 5 个分类时，按 0（第 10 个）应该什么都不发生
        let before = store.deck.count
        store.perform(.classify(0))
        check(store.deck.count == before && store.buckets.count == 5,
              "只有 5 个分类时按 0（第 10 个）不生效、不崩")

        // 删中间那个：id 不重排，位置整体前移
        let firstID = store.buckets[0].id
        let lastID = store.buckets[4].id
        store.removeBucket(id: store.buckets[2].id)
        check(store.buckets.count == 4, "删一个 -> 4 个")
        check(store.buckets[0].id == firstID && store.buckets[3].id == lastID,
              "删的是中间那个，其余 id 一个没动")
        check(store.bucketPosition(id: lastID) == 4,
              "原来的第 5 个现在显示成 4（位置会前移）")
        check(Set(store.buckets.map(\.id)).count == store.buckets.count, "id 不重复")

        // 加满
        for _ in 0..<20 { store.addBucket() }
        check(store.buckets.count == PhotoStore.maxBuckets,
              "加满就停在 \(PhotoStore.maxBuckets) 个")
        check(!store.canAddBucket && !store.addBucket(), "到上限后再加无效")
        check(Set(store.buckets.map(\.id)).count == PhotoStore.maxBuckets, "10 个 id 全不重复")

        // 删光
        for bucket in store.buckets { store.removeBucket(id: bucket.id) }
        check(store.buckets.isEmpty, "可以一路删到 0 个")
        store.perform(.classify(1))
        check(store.buckets.isEmpty, "0 个分类时按数字键不崩、也不凭空建分类")

        print("[盒子宽度随分类数量自适应]")
        let stageWidth: CGFloat = 900
        let w1 = BoxLayout.tileWidth(count: 1, stageWidth: stageWidth)
        let w5 = BoxLayout.tileWidth(count: 5, stageWidth: stageWidth)
        let w10 = BoxLayout.tileWidth(count: 10, stageWidth: stageWidth)
        check(abs(w1 - BoxLayout.maxTileWidth) < 0.01,
              "1 个分类 -> 封顶 \(Int(w1))pt，不会撑成一整块面板")
        check(w1 > w5 && w5 > w10,
              "宽度随数量递减（\(Int(w1)) > \(Int(w5)) > \(Int(w10))）")
        check(w10 >= BoxLayout.minTileWidth,
              "10 个也不会细过 \(Int(BoxLayout.minTileWidth))pt")

        // 飞行动画的目标必须和盒子行走同一套算法，否则加删分类后会飞错位置
        let c1 = BoxLayout.tileCentreX(position: 1, count: 5, stageWidth: stageWidth)
        let c3 = BoxLayout.tileCentreX(position: 3, count: 5, stageWidth: stageWidth)
        let c5 = BoxLayout.tileCentreX(position: 5, count: 5, stageWidth: stageWidth)
        check(c1 < stageWidth / 2 && c5 > stageWidth / 2, "第 1 个在左半边、第 5 个在右半边")
        check(abs((c1 + c5) - stageWidth) < 0.5, "首尾两个关于中线对称")
        check(abs(c3 - stageWidth / 2) < 0.5, "正中间那个正好落在中线上")

        // 回归：自检会跑 add/removeBucket，而它们内部调 saveSettings —— 绝不能
        // 落到用户的真实配置上。曾经因此把真实配置文件清成 0 个分类，还顺手让
        // 演示模式启动即崩（它当时假定一定有 5 个）。
        let configPath = ("~/Library/Application Support/PhotoSift/categories.json" as NSString)
            .expandingTildeInPath
        func configStamp() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
        }
        let existedBefore = FileManager.default.fileExists(atPath: configPath)
        let stampBefore = configStamp()
        let probe = PhotoStore()
        probe.addBucket()
        if let first = probe.buckets.first { probe.removeBucket(id: first.id) }
        check(existedBefore == FileManager.default.fileExists(atPath: configPath)
              && stampBefore == configStamp(),
              "自检里的增删分类没有碰过用户真实配置")
    }

    // MARK: - 3. undo
    private static func undoTests() {
        print("[撤销]")

        let store = PhotoStore()
        store.seedForSelfTest(count: 20)
        store.perform(.next)        // test-0 -> bottom
        store.perform(.next)        // test-1 -> bottom
        store.perform(.delete)      // test-2 -> deletes
        store.perform(.classify(3)) // test-3 -> box 3
        store.perform(.classify(5)) // test-4 -> box 5

        // 20 - 3 个决定（删 1 张 + 收进盒子 2 张）= 17
        check(store.deck.count == 17, "前置：牌堆 17")

        store.undo()   // undo classify 5
        check(store.bucketCount(5) == 0, "⌘Z           -> 盒子5 回到 0")
        check(store.deck.count == 18, "⌘Z           -> 牌堆 17→18")
        check(store.deck.first?.id == "test-4", "⌘Z           -> 那张回到最前面")
        check(store.bucketMemberIDs(5).isEmpty, "⌘Z           -> 盒子5 成员表也清了")

        store.undo()   // undo classify 3
        check(store.bucketCount(3) == 0, "⌘Z 再来       -> 盒子3 回到 0")
        check(store.deck.first?.id == "test-3", "⌘Z 再来       -> test-3 回到最前面")

        store.undo()   // undo delete
        check(store.pendingDeletes.isEmpty, "⌘Z 再来       -> 待删清空")
        check(store.deck.first?.id == "test-2", "⌘Z 再来       -> 被删那张回到最前面")

        store.undo()   // undo skip (test-1, which sits at the bottom)
        store.undo()   // undo skip (test-0)
        check(store.deck.count == 20, "⌘Z ×2        -> 牌堆回到 20")
        check(store.deck.first?.id == "test-0", "⌘Z ×2        -> 回到最初的第一张")
        check(store.decidedCount == 0, "⌘Z 到底       -> 已处理归零")
        check(store.historyDepth == 0, "⌘Z 到底       -> 撤销栈也空了")

        store.undo()
        check(store.deck.count == 20, "再按 ⌘Z      -> 空栈不崩、状态不变")
    }

    /// The preview path delivers on the next runloop turn — demo mode included,
    /// on purpose (see `PhotoStore.loadPreview`). So a return flight is created a
    /// turn AFTER the deck changes. Drain that turn before asserting on it.
    private static func settle() {
        // 0.1s: comfortably past PhotoStore.launchDelay (0.03s), so the two-phase
        // flight/entry flags have definitely flipped by the time we look.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    // MARK: - 3b. undo must animate the card back IN

    private static func returnAnimationTests() {
        print("[撤回动画：卡片要飞回来]")

        let store = PhotoStore()
        store.seedForSelfTest(count: 10)

        store.perform(.next)          // 跳过
        store.undo()
        settle()
        check(store.returning.count == 1, "撤销「跳过」-> 生成一张飞回来的卡")
        check(store.returning.first?.action == .skip, "撤销「跳过」-> 从左边飞回来")
        check(store.returning.first?.item.id == "test-0", "飞回来的就是被撤销的那张")

        let deleteStore = PhotoStore()
        deleteStore.seedForSelfTest(count: 10)
        deleteStore.perform(.delete)
        deleteStore.undo()
        settle()
        check(deleteStore.returning.first?.action == .delete, "撤销「删除」-> 从上方飞回来")

        let classifyStore = PhotoStore()
        classifyStore.seedForSelfTest(count: 10)
        classifyStore.perform(.classify(3))
        classifyStore.undo()
        settle()
        check(classifyStore.returning.first?.action == .classify(3),
              "撤销「分类到盒子3」-> 从盒子3飞回来")

        let backStore = PhotoStore()
        backStore.seedForSelfTest(count: 10)
        backStore.perform(.back)
        settle()
        check(backStore.returning.count == 1, "← 回退也带动画")

        // 没有可撤销的东西时不应该凭空生成动画
        let idle = PhotoStore()
        idle.seedForSelfTest(count: 10)
        idle.undo()
        settle()
        check(idle.returning.isEmpty, "无可撤销时 -> 不产生动画")

        // 撤回的卡片要带上它自己的照片，而不是空着飞
        let demo = PhotoStore()
        demo.seedForSelfTest(count: 3)
        demo.deck[0].demoImage = NSImage(size: NSSize(width: 10, height: 10))
        demo.perform(.next)
        demo.undo()
        settle()
        check(demo.returning.first?.image != nil, "撤回的卡片带着照片飞回来，不是空卡")

        // 回归：牌堆状态比动画状态早一个 runloop 轮次更新。那一轮里前排必须
        // 已经藏起来了，否则会闪出一帧「撤回完成后的样子」—— 也就是前排已经
        // 换成撤回后的那张、但飞行动画还没开始。
        let gap = PhotoStore()
        gap.seedForSelfTest(count: 10)
        gap.perform(.next)
        settle()
        gap.undo()
        check(gap.isReturning,
              "撤销后立刻 isReturning = true（还没等解码）")
        check(gap.returning.isEmpty,
              "…这一刻飞行卡尚未生成 —— 正是要靠 isReturning 兜住的那一帧")
    }

    // MARK: - 4. invariants

    private static func invariantTests() {
        print("[不变量]")

        let store = PhotoStore()
        store.seedForSelfTest(count: 12)
        for _ in 0..<50 { store.perform(.next) }
        check(store.deck.count == 12, "连按 50 次空格 -> 牌堆一张都不会少（跳过不是处理）")
        check(store.decidedCount == 0, "连按 50 次空格 -> 已处理仍是 0")
        check(Set(store.deck.map(\.id)).count == 12, "连按 50 次空格 -> 没有重复或丢卡")

        let small = PhotoStore()
        small.seedForSelfTest(count: 1)
        small.perform(.next)
        check(small.deck.count == 1, "只有 1 张时跳过 -> 安全，不崩")
        check(small.deck.first?.id == "test-0", "只有 1 张时跳过 -> 还是它")

        let finish = PhotoStore()
        finish.seedForSelfTest(count: 3)
        finish.perform(.delete)
        finish.perform(.classify(1))
        finish.perform(.classify(2))
        check(finish.deck.isEmpty, "把每一张都决定掉 -> 牌堆空了")
        check(finish.allDone, "把每一张都决定掉 -> allDone = true")
        check(finish.decidedCount == 3, "把每一张都决定掉 -> 已处理 3")
        // 牌堆空了以后不能崩
        finish.perform(.next)
        finish.perform(.delete)
        finish.perform(.classify(1))
        check(finish.deck.isEmpty && finish.decidedCount == 3, "空牌堆继续按键 -> 安全，不越界")
    }

    // MARK: - 2g. the first-run guide (v0.8)
    //
    // The picker's whole job is turning albums into boxes so that the number
    // printed on a row is the number that actually works. That mapping is
    // invisible until the user is already pressing keys, so it gets pinned here.

    private static func guideTests() {
        print("[引导 · 相簿变分类]")

        let store = PhotoStore()
        store.seedForSelfTest(count: 6)
        store.libraryAlbums = [
            LibraryAlbum(id: "a1", name: "工作用图", count: 12),
            LibraryAlbum(id: "a2", name: "旅行",     count: 34),
            LibraryAlbum(id: "a3", name: "收藏",     count: 5),
        ]

        let fresh = PhotoStore()
        fresh.seedForSelfTest(count: 3)
        check(fresh.guideStep == nil, "刚构造出来时引导不显示")
        fresh.startGuide()
        check(fresh.guideStep == 0, "没走过引导 -> 打开第 1 页")
        fresh.advanceGuide()
        check(fresh.guideStep == 1, "继续 -> 第 2 页（相簿选择）")
        fresh.advanceGuide()
        check(fresh.guideStep == PhotoStore.guideLastStep,
              "再继续 -> 第 3 页（使用教程），说明单独占一页")
        check(PhotoStore.guideLastStep == 2, "引导一共 3 页")
        fresh.advanceGuide()
        check(fresh.guideStep == PhotoStore.guideLastStep,
              "最后一页再点「下一步」-> 停在原地，不会翻出一张空白页")

        // 编号跟点击顺序走：先点的那个先拿到 1，不管它在列表里排第几行。
        store.toggleGuideSelection("a3")
        store.toggleGuideSelection("a1")
        check(store.guidePosition(for: store.libraryAlbums[2]) == 1,
              "先勾第 3 行 -> 它拿 1（按点击顺序，不是列表顺序）")
        check(store.guidePosition(for: store.libraryAlbums[0]) == 2,
              "后勾第 1 行 -> 拿 2")
        check(store.guidePosition(for: store.libraryAlbums[1]) == nil,
              "没勾的那行不给编号")
        check(store.guidePickedCount == 2, "已选数量 = 2")

        store.toggleGuideSelection("a3")
        check(store.guidePosition(for: store.libraryAlbums[0]) == 1,
              "取消第 3 行 -> 剩下的补位成 1（编号不留洞）")
        store.toggleGuideSelection("a3")
        check(store.guidePosition(for: store.libraryAlbums[0]) == 1
              && store.guidePosition(for: store.libraryAlbums[2]) == 2,
              "重新勾第 3 行 -> 排到队尾拿 2，不抢回原来的 1")

        store.finishGuide()
        check(store.guideStep == nil, "完成后引导关闭")
        check(store.buckets.map(\.name) == ["工作用图", "收藏"],
              "分类名 = 勾中的相簿名，按点击顺序（得到 \(store.buckets.map(\.name))）")
        check(store.buckets.count == 2, "勾两个相簿 -> 两个盒子")
        check(Set(store.buckets.map(\.id)).count == 2, "新盒子的 id 不重复")

        store.perform(.classify(2))
        check(store.bucketCount(store.buckets[1].id) == 1,
              "按 2 -> 进第二个盒子「收藏」，数字键和引导里显示的一致")

        // 端到端：点选顺序 -> 桌面上的数字键到底落在哪个相簿。屏幕上写着 1 的
        // 那一行，就必须是 `1` 收进去的那个 —— 这是这次改动唯一的验收标准。
        let order = PhotoStore()
        order.seedForSelfTest(count: 3)
        order.libraryAlbums = [
            LibraryAlbum(id: "a1", name: "工作用图", count: 12),
            LibraryAlbum(id: "a2", name: "旅行",     count: 34),
            LibraryAlbum(id: "a3", name: "收藏",     count: 5),
        ]
        order.startGuide(force: true)
        order.toggleGuideSelection("a2")      // 列表第 2 行，先点
        order.toggleGuideSelection("a1")      // 列表第 1 行，后点
        check(order.guidePosition(for: order.libraryAlbums[1]) == 1,
              "先点「旅行」-> 它显示 1")
        check(order.guidePosition(for: order.libraryAlbums[0]) == 2,
              "后点「工作用图」-> 它显示 2")
        order.finishGuide()
        check(order.buckets.map(\.name) == ["旅行", "工作用图"],
              "盒子的顺序也是点击顺序（得到 \(order.buckets.map(\.name))）")
        order.perform(.classify(1))
        check(order.bucketCount(order.buckets[0].id) == 1,
              "按 1 -> 进的是先点的「旅行」，和引导里写的 1 一致")

        store.startGuide()
        check(store.guideStep == nil, "走过一遍之后不再自动弹")
        store.startGuide(force: true)
        check(store.guideStep == 0, "菜单里手动重跑 -> 照样打开")

        // 一个都不勾直接继续：不能把用户已有的分类清掉
        let keep = PhotoStore()
        keep.seedForSelfTest(count: 3)
        let before = keep.buckets.map(\.name)
        keep.startGuide(force: true)
        keep.finishGuide()
        check(keep.buckets.map(\.name) == before,
              "一个都不勾 -> 保留原分类（\(before.joined(separator: "/"))）")

        // 上限仍是 10
        let many = PhotoStore()
        many.seedForSelfTest(count: 3)
        many.libraryAlbums = (1...12).map {
            LibraryAlbum(id: "b\($0)", name: "相簿\($0)", count: $0)
        }
        many.startGuide(force: true)
        for album in many.libraryAlbums { many.toggleGuideSelection(album.id) }
        check(many.guidePickedCount == PhotoStore.maxBuckets,
              "勾超过 10 个 -> 停在 \(PhotoStore.maxBuckets) 个")
        many.finishGuide()
        check(many.buckets.map(\.name) == (1...10).map { "相簿\($0)" },
              "完成 -> 取列表前 10 个，顺序不乱")

        // 引导期间必须屏蔽快捷键：屏幕上不是牌堆，这时候按 ↑ 会给用户的
        // 真实照片打上删除标记。
        let guarded = PhotoStore()
        guarded.seedForSelfTest(count: 4)
        guarded.startGuide(force: true)
        let deckBefore = guarded.deck.count
        let handled = guarded.handleKey(keyEvent(126))   // ↑ = 标记删除
        check(!handled && guarded.pendingDeletes.isEmpty,
              "引导期间按 ↑ -> 不进删除队列，事件也不吞掉")
        check(guarded.deck.count == deckBefore, "引导期间按 ↑ -> 牌堆纹丝不动")

        // 演示模式也必须有缩略图，否则 --demo 截出来的相簿列表和真机不一样
        let demo = DemoLibrary.albums
        check(demo.allSatisfy { DemoLibrary.albumThumbnails[$0.id] != nil },
              "每个示例相簿都有缩略图（\(demo.count) 个）")
        check(DemoLibrary.albumThumbnails.values.allSatisfy {
                  $0.size.width >= PhotoStore.albumThumbSide * 2
              },
              "缩略图分辨率够 retina 用，放大不会糊")

        // 动效：每个时长都必须受 --slowmo 控制。0.3 秒的过渡用 ~100ms 的截图
        // 截不到，肉眼也看不出对不对 —— 没有慢放开关等于没法验证。
        print("[引导动效]")
        check(PhotoStore.guidePageDuration > 0 && PhotoStore.guideRevealDuration > 0
              && PhotoStore.guideRevealStagger > 0 && PhotoStore.guideRowStagger > 0,
              "引导的四个动效时长都是正数")
        check(PhotoStore.guideRowDelay(0) < PhotoStore.guideRowDelay(1),
              "靠前的行先到（错开生效）")
        check(PhotoStore.guideRowDelay(43) == PhotoStore.guideRowDelay(PhotoStore.guideRowStaggerCap),
              "行延迟在 \(PhotoStore.guideRowStaggerCap) 行后就封顶，43 行的库不会等到天荒地老")
        check(PhotoStore.guideRowStaggerCap < 40, "封顶值本身合理")

        let anim = PhotoStore()
        anim.seedForSelfTest(count: 3)
        anim.startGuide(force: true)
        check(!anim.guideRevealed, "引导打开时内容先处于「未入场」——否则没有东西可动")
        anim.revealGuide()
        check(!anim.guideRevealed, "revealGuide 同步先把状态推回未入场（不靠异步抢跑）")
        settle()
        check(anim.guideRevealed, "一个 tick 之后内容才入场")

        anim.advanceGuide()
        check(anim.guideStep == 1, "翻到第 2 页")
        check(!anim.guideRevealed, "翻页时先收起内容，让新一页重新播一遍入场")

        let eased = PhotoStore()
        eased.seedForSelfTest(count: 3)
        eased.startGuide(force: true)
        eased.finishGuide()
        check(eased.guideStep == nil && eased.buckets.count == 5,
              "点 ✓ 离场：引导关闭，分类不变")
    }

    // MARK: - 2h. v0.9: resumable pool, shuffle, achievements

    private static func v09Tests() {
        print("[已在分类相簿里的照片 → 直接算已整理]")

        let resumed = PhotoStore()
        resumed.seedForSelfTest(count: 50)
        let library = resumed.deck
        let filedIDs = Set(library.prefix(30).map(\.id))
        resumed.adoptFiledPhotos(ids: filedIDs, counts: [1: 30], library: library)

        check(resumed.deck.count == 20, "50 张里 30 张已在分类里 → 牌堆只剩 20 张")
        check(resumed.totalCount == 50, "总数还是整个图库的 50 张")
        check(resumed.decidedCount == 30, "那 30 张记进「已整理」")
        check(resumed.alreadyFiledCount == 30, "并且单独记一笔，好在设置里说明来源")
        check(resumed.deck.allSatisfy { !filedIDs.contains($0.id) },
              "已在分类里的一张都不会再出现")
        check(resumed.buckets.first?.count == 30, "盒子数改成「那个相簿里有多少张」")

        let untouched = PhotoStore()
        untouched.seedForSelfTest(count: 12)
        untouched.adoptFiledPhotos(ids: [], counts: [:], library: untouched.deck)
        check(untouched.deck.count == 12 && untouched.decidedCount == 0,
              "一张都没在分类里 → 牌堆是整个图库，已整理为 0")

        print("[Shuffle · 每次随机抽 20 张未整理]")

        let sh = PhotoStore()
        sh.seedForSelfTest(count: 100)
        let pool = sh.deck
        let poolIDs = Set(pool.map(\.id))
        sh.adoptFiledPhotos(ids: [], counts: [:], library: pool)

        sh.enterShuffle()
        check(sh.shuffleMode, "骰子按下 → 模式打开")
        check(sh.deck.count == PhotoStore.shuffleSize,
              "抽出的张数 = \(PhotoStore.shuffleSize)")
        check(Set(sh.deck.map(\.id)).count == PhotoStore.shuffleSize, "同一轮里不重复")
        check(sh.deck.allSatisfy { poolIDs.contains($0.id) }, "抽出来的都来自未整理的池子")

        sh.perform(.classify(1))
        sh.perform(.classify(1))
        sh.perform(.classify(1))
        check(sh.decidedCount == 3, "Shuffle 里分类也算已整理")
        check(sh.deck.count == 17, "这一轮还剩 17 张")

        sh.exitShuffle()
        check(!sh.shuffleMode, "再按一次 → 退出 Shuffle")
        check(sh.deck.count == 97, "回到顺序模式，剩 97 张（100 减去刚整理的 3 张）")

        let filedShuffle = PhotoStore()
        filedShuffle.seedForSelfTest(count: 60)
        let lib60 = filedShuffle.deck
        filedShuffle.adoptFiledPhotos(ids: Set(lib60.prefix(50).map(\.id)),
                                      counts: [:], library: lib60)
        filedShuffle.enterShuffle()
        check(filedShuffle.deck.count == 10,
              "只剩 10 张未整理时，Shuffle 就给 10 张，不凑数")

        print("[成就 · 首启 / 100 / 1000 / 10000]")

        let ach = PhotoStore()
        ach.seedForSelfTest(count: 150)
        ach.adoptFiledPhotos(ids: [], counts: [:], library: ach.deck)
        check(ach.unlockedAchievements.isEmpty, "一张都没整理时没有成就")

        for _ in 0..<99 { ach.perform(.classify(1)) }
        check(ach.unlockedAchievements[Achievement.hundred.id] == nil, "第 99 张还没解锁")

        ach.perform(.classify(1))
        check(ach.decidedCount == 100, "整理到第 100 张")
        check(ach.unlockedAchievements[Achievement.hundred.id] != nil, "解锁「一百张」")
        check(ach.unlockedAchievements[Achievement.thousand.id] == nil, "还没到 1000")
        let queued = ach.achievementQueue.count
        check(queued >= 1, "有提示排队等着弹")
        ach.dismissAchievement()
        check(ach.achievementQueue.count == queued - 1, "提示可以一条条消掉")

        let before = ach.unlockedAchievements[Achievement.hundred.id]
        ach.perform(.classify(1))
        check(ach.unlockedAchievements[Achievement.hundred.id] == before,
              "再整理一张不会覆盖已有成就的日期")

        ach.unlockFirstLaunch()
        check(ach.unlockedAchievements[Achievement.firstLaunch.id] != nil, "首启徽章")
        let count = ach.unlockedAchievements.count
        ach.unlockFirstLaunch()
        check(ach.unlockedAchievements.count == count, "重复触发不会重复记录")

        let big = PhotoStore()
        big.seedForSelfTest(count: 1200)
        let bigLib = big.deck
        big.adoptFiledPhotos(ids: Set(bigLib.prefix(1100).map(\.id)),
                             counts: [:], library: bigLib)
        check(big.unlockedAchievements[Achievement.thousand.id] != nil,
              "接手一个已有 1100 张在分类里的库 → 直接算 1000 达成")
        check(big.unlockedAchievements[Achievement.tenThousand.id] == nil,
              "但 10000 还差得远")
        check(big.deck.count == 100, "牌堆只剩没整理的那 100 张")

        let board = ach.achievementBoard
        check(board.count == Achievement.allCases.count, "成就面板列出全部 4 个")
        check(board.first?.achievement == .firstLaunch, "顺序稳定，首启在最前")
        check(Achievement.allCases.map(\.threshold) == [0, 100, 1000, 10000],
              "门槛就是 0 / 100 / 1000 / 10000")

        print("[Shuffle 说明弹窗]")

        let intro = PhotoStore()
        intro.seedForSelfTest(count: 60)
        intro.adoptFiledPhotos(ids: [], counts: [:], library: intro.deck)

        intro.enterShuffle()
        check(intro.showShuffleIntro, "第一次进 Shuffle → 弹说明")
        check(intro.shuffleMode, "说明弹着的同时，模式已经开着（牌已经换了）")

        intro.closeShuffleIntro()
        check(!intro.showShuffleIntro, "点「开始整理」→ 关闭")
        check(!intro.shuffleIntroDismissed, "没勾「不再显示」→ 不写这个设置")

        intro.exitShuffle()
        intro.enterShuffle()
        check(intro.showShuffleIntro, "没勾的话，下次进来还会弹")

        intro.skipShuffleIntro = true
        intro.closeShuffleIntro()
        check(intro.shuffleIntroDismissed, "勾了「不再显示」→ 记下来")
        check(!intro.showShuffleIntro, "同时关闭")

        intro.exitShuffle()
        intro.enterShuffle()
        check(!intro.showShuffleIntro, "勾过之后再进 Shuffle → 不弹了")
        check(intro.shuffleMode && intro.deck.count > 0, "但模式照常进（说明只是说明）")

        let fresh = PhotoStore()
        fresh.seedForSelfTest(count: 30)
        fresh.adoptFiledPhotos(ids: [], counts: [:], library: fresh.deck)
        check(!fresh.shuffleIntroDismissed, "全新用户默认没勾过 → 会弹")

        print("[Shuffle · 没做完就退出要问一句]")

        let ex = PhotoStore()
        ex.seedForSelfTest(count: 60)
        ex.adoptFiledPhotos(ids: [], counts: [:], library: ex.deck)
        // 顺序模式里先处理一张 —— 这张不属于任何 Shuffle 轮次
        ex.perform(.classify(1))
        let baseline = ex.decidedCount
        check(baseline == 1, "顺序模式里先整理 1 张")

        ex.shuffleIntroDismissed = true
        ex.enterShuffle()
        check(ex.shuffleRoundDecisions == 0, "刚开一轮时这一轮还没有操作")
        ex.toggleShuffle()
        check(!ex.showShuffleExitConfirm, "空轮次退出不用问")
        check(!ex.shuffleMode, "并且直接退出")
        ex.enterShuffle()

        ex.perform(.classify(1))
        ex.perform(.classify(2))
        ex.perform(.delete)
        check(ex.shuffleRoundClassified == 2, "这一轮分类 2 张")
        check(ex.shuffleRoundDeleted == 1, "这一轮标记删除 1 张")
        check(ex.shuffleRoundDecisions == 3, "合计 3 条")
        check(ex.pendingDeletes.count == 1, "删标记进了待删列表")

        ex.perform(.next)
        check(ex.shuffleRoundDecisions == 3, "跳过不算操作")

        check(!ex.deck.isEmpty, "这一轮还剩着牌")
        ex.toggleShuffle()
        check(ex.showShuffleExitConfirm, "没做完就退出 → 弹询问")
        check(ex.shuffleMode, "询问期间仍在 Shuffle 里")

        ex.cancelShuffleExit()
        check(!ex.showShuffleExitConfirm && ex.shuffleMode, "选「继续整理」→ 留在这一轮")
        check(ex.shuffleRoundDecisions == 3, "操作一条没少")

        ex.toggleShuffle()
        check(ex.showShuffleExitConfirm, "再按一次骰子又弹")
        ex.keepRoundAndExitShuffle()
        check(!ex.shuffleMode, "选「保留并退出」→ 退出")
        check(ex.decidedCount == baseline + 3, "这一轮 3 条保留")
        check(ex.pendingDeletes.count == 1, "删标记也还留着")

        let ex2 = PhotoStore()
        ex2.seedForSelfTest(count: 60)
        ex2.adoptFiledPhotos(ids: [], counts: [:], library: ex2.deck)
        ex2.perform(.classify(1))
        let base2 = ex2.decidedCount
        ex2.shuffleIntroDismissed = true
        ex2.enterShuffle()
        ex2.perform(.classify(2))
        ex2.perform(.classify(2))
        ex2.perform(.delete)
        check(ex2.decidedCount == base2 + 3, "这一轮处理了 3 张")
        let roundCards = ex2.shuffleRoundDecisions

        ex2.toggleShuffle()
        check(ex2.showShuffleExitConfirm, "提前退出 → 询问")
        ex2.revertRoundAndExitShuffle()
        check(!ex2.shuffleMode, "选「撤销这一轮」→ 撤销后退出")
        check(ex2.decidedCount == base2, "这一轮的 \(roundCards) 条全部回退")
        check(ex2.pendingDeletes.isEmpty, "删标记被收回")
        check(ex2.shuffleRoundDecisions == 0, "这一轮不再有操作")
        check(ex2.historyDepth == 1, "历史里只剩顺序模式那一条 —— 没误伤")
        check(ex2.deck.count == 59, "被回退的 3 张回到未整理池（60 − 1 张已整理）")

        let ex3 = PhotoStore()
        ex3.seedForSelfTest(count: 5)
        ex3.adoptFiledPhotos(ids: [], counts: [:], library: ex3.deck)
        ex3.shuffleIntroDismissed = true
        ex3.enterShuffle()
        check(ex3.shuffleRoundDecisions == 0 && ex3.deck.count == 5, "不足 20 张时一轮就 5 张")
        for _ in 0..<5 { ex3.perform(.classify(1)) }
        check(ex3.shuffleRoundDecisions == 5, "5 张全处理了")
        check(ex3.deck.isEmpty, "这一轮做完了")
        ex3.toggleShuffle()
        check(!ex3.showShuffleExitConfirm, "一轮做完再退出 → 不再问")
        check(!ex3.shuffleMode, "并且直接退出")

        print("[Shuffle · 一轮做完才写进图库]")

        let bf = PhotoStore()
        bf.seedForSelfTest(count: 30)
        bf.adoptFiledPhotos(ids: [], counts: [:], library: bf.deck)
        bf.shuffleIntroDismissed = true

        bf.perform(.classify(1))
        check(bf.roundAssignmentCount == 0, "顺序模式不缓冲，还是按键就写")

        bf.enterShuffle()
        bf.perform(.classify(1))
        bf.perform(.classify(2))
        bf.perform(.classify(2))
        check(bf.roundAssignmentCount == 3, "Shuffle 里 3 张分类进了待写缓冲")
        check(bf.shuffleRoundClassified == 3, "同时算作这一轮的操作")
        check(bf.buckets[0].count == 2, "盒子先按乐观值显示（1 张旧账 + 1 张本轮）")
        check(bf.decidedCount == 4, "已整理也立刻跟着走 —— 界面不等写入")

        bf.toggleShuffle()
        check(bf.showShuffleExitConfirm, "没做完就退出 → 询问")
        bf.revertRoundAndExitShuffle()
        check(bf.roundAssignmentCount == 0, "撤销 → 缓冲丢清（图库从头到尾没被碰过）")
        check(bf.decidedCount == 1, "只回退本轮那 3 张，顺序模式那张还在")
        check(bf.buckets[0].count == 1, "盒子回到本轮之前的数")

        let bf2 = PhotoStore()
        bf2.seedForSelfTest(count: 4)
        bf2.adoptFiledPhotos(ids: [], counts: [:], library: bf2.deck)
        bf2.shuffleIntroDismissed = true
        bf2.enterShuffle()
        check(bf2.deck.count == 4, "一轮 4 张（不足 20）")
        for _ in 0..<4 { bf2.perform(.classify(1)) }
        check(bf2.deck.isEmpty, "这一轮做完了")
        check(bf2.roundAssignmentCount == 0, "做完 → 缓冲已提交并清空")
        check(bf2.decidedCount == 4, "4 张都算已整理")

        let bf3 = PhotoStore()
        bf3.seedForSelfTest(count: 30)
        bf3.adoptFiledPhotos(ids: [], counts: [:], library: bf3.deck)
        bf3.shuffleIntroDismissed = true
        bf3.enterShuffle()
        bf3.perform(.classify(1))
        bf3.perform(.classify(1))
        check(bf3.roundAssignmentCount == 2, "本轮 2 张待写")
        bf3.toggleShuffle()
        bf3.keepRoundAndExitShuffle()
        check(bf3.roundAssignmentCount == 0, "选「保留并退出」→ 缓冲提交")
        check(bf3.decidedCount == 2, "2 张留下")

        let bf4 = PhotoStore()
        bf4.seedForSelfTest(count: 30)
        bf4.adoptFiledPhotos(ids: [], counts: [:], library: bf4.deck)
        bf4.shuffleIntroDismissed = true
        bf4.enterShuffle()
        bf4.perform(.classify(1))
        bf4.perform(.classify(1))
        check(bf4.roundAssignmentCount == 2, "两张待写")
        bf4.undo()
        check(bf4.roundAssignmentCount == 1, "⌘Z 把它从待写里拿掉，不是去图库移出")
        check(bf4.decidedCount == 1, "已整理跟着退回")
    }

    /// A synthetic key-down, just enough for `handleKey` to classify it.
    private static func keyEvent(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: keyCode)
            ?? NSEvent()
    }

    // MARK: - 5. the dry-run safety guard

    private static func commitGuardTests() {
        print("[演练模式守卫]")

        let store = PhotoStore()
        store.seedForSelfTest(count: 5)
        store.dryRun = true
        store.perform(.delete)
        store.perform(.delete)
        store.perform(.commit)

        check(store.pendingDeletes.count == 2, "演练模式 ⌘⏎  -> 待删队列保持 2 张，不提交")
        check(!store.committing, "演练模式 ⌘⏎  -> 未发起写库请求")

        let empty = PhotoStore()
        empty.seedForSelfTest(count: 5)
        empty.dryRun = false
        empty.perform(.commit)
        check(!empty.committing, "没有待删时 ⌘⏎ -> 不发请求")
    }
}
