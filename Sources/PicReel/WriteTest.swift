// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import Foundation
import Photos
import AppKit

private final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// End-to-end exercise of the write path, using ONLY things this test creates:
/// a generated test image and a test album. No pre-existing photo in the
/// user's library is read, moved, or deleted.
///
/// The final step deliberately goes through the app's real delete path
/// (`pendingDeletes` -> `commit()`), because the whole point of the design is
/// that N queued photos produce exactly ONE system confirmation dialog.
extension PhotoStore {

    static let testAlbumName = "PicReel 测试专辑"

    func runWriteTest() {
        note("=== 写库测试开始 ===")
        note("只操作一张自生成测试图 + 一个测试专辑；你图库里已有的照片一张都不碰。")

        let imageURL = Self.supportDir.appendingPathComponent("photosift-test-image.png")
        guard Self.makeTestImage(at: imageURL) else {
            note("❌ 测试图生成失败，中止")
            return
        }
        note("1/8 测试图已生成（900×900 PNG）")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.writeTestChain(imageURL: imageURL)
        }
    }

    /// Runs off the main thread: every PhotoKit change is awaited with a
    /// semaphore so the log reads as a linear transcript.
    private func writeTestChain(imageURL: URL) {
        let albumName = Self.testAlbumName

        // --- step 0: clear leftovers from a previous aborted run ------------
        if let stale = albumNamed(albumName) {
            note("0/8 发现上次残留的测试专辑，先清掉")
            _ = performChangesSync(label: "清理残留专辑") {
                PHAssetCollectionChangeRequest.deleteAssetCollections([stale] as NSArray)
            }
        }

        // --- step 2: import the generated image ----------------------------
        let createdID = Box<String>()
        let ok2 = performChangesSync(label: "导入测试图") {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: imageURL, options: nil)
            createdID.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard ok2, let assetID = createdID.value else {
            note("❌ 2/8 导入失败，中止")
            return
        }
        note("2/8 导入测试图 → OK（新资源 id \(assetID.prefix(24))…）")

        // --- step 3: read it back ------------------------------------------
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard fetched.count == 1, let asset = fetched.firstObject else {
            note("❌ 3/8 回读新建资源失败")
            return
        }
        note("3/8 回读新建资源 → OK（\(asset.pixelWidth)×\(asset.pixelHeight)）")

        // --- step 4: create the album and put the photo in it ---------------
        let createdAlbumID = Box<String>()
        let ok4 = performChangesSync(label: "建专辑并放入") {
            let albumRequest = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: albumName)
            albumRequest.addAssets([asset] as NSArray)
            createdAlbumID.value = albumRequest.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard ok4 else {
            note("❌ 4/8 建专辑/放入失败，中止")
            return
        }
        note("4/8 新建专辑「\(albumName)」并放入照片 → OK")

        // --- step 4b: the v0.9 batch path (a whole shuffle round in one go) ---
        //
        // Shuffle buffers a round and writes it in ONE transaction at the end,
        // grouped by album. That is new code and this is the only place it can
        // actually be exercised against a real library.
        let secondAlbumName = "PicReel 测试专辑 B"
        if let stale = albumNamed(secondAlbumName) {
            _ = performChangesSync(label: "清理残留专辑 B") {
                PHAssetCollectionChangeRequest.deleteAssetCollections([stale] as NSArray)
            }
        }
        let batch = [PendingAssignment(assetID: assetID, albumName: albumName),
                     PendingAssignment(assetID: assetID, albumName: albumName),
                     PendingAssignment(assetID: assetID, albumName: secondAlbumName)]
        let batchLanded = DispatchSemaphore(value: 0)
        writeAssignments(batch) { batchLanded.signal() }
        if batchLanded.wait(timeout: .now() + 20) == .timedOut {
            note("❌ 4b/8 批量写入超时，没等到 PhotoKit 回调")
        }
        let inA = albumNamed(albumName).map { albumContains($0, assetID) } ?? false
        let inB = albumNamed(secondAlbumName).map { albumContains($0, assetID) } ?? false
        note("4b/8 一轮批量写入（3 条待写、含重复项、跨 2 个专辑）→ "
             + (inA && inB ? "OK，两个专辑都收到了" : "❌ A=\(inA) B=\(inB)"))

        // --- step 5: verify membership by reading the album back ------------
        guard let album = albumNamed(albumName) else {
            note("❌ 5/8 回读专辑失败")
            return
        }
        let members = PHAsset.fetchAssets(in: album, options: nil)
        var contains = false
        members.enumerateObjects { candidate, _, _ in
            if candidate.localIdentifier == assetID { contains = true }
        }
        let memberCount = members.count
        let membershipNote = contains
            ? "OK，专辑里确实有这张（共 \(memberCount) 张）"
            : "❌ 专辑里没有这张"
        note("5/8 回读专辑 → \(membershipNote)")
        guard contains else { return }

        // --- step 6: remove it from the album -------------------------------
        let ok6 = performChangesSync(label: "从专辑移出") {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets([asset] as NSArray)
        }
        let afterRemoval = PHAsset.fetchAssets(in: albumNamed(albumName) ?? album, options: nil)
        note("6/8 从专辑移出 → \(ok6 ? "OK" : "❌ 失败")（专辑现在剩 \(afterRemoval.count) 张）")

        // --- step 7: delete the album ---------------------------------------
        let ok7 = performChangesSync(label: "删除测试专辑") {
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        }
        let stillThere = albumNamed(albumName) != nil
        note("7/8 删除测试专辑 → \(ok7 && !stillThere ? "OK，专辑已消失" : "❌ 专辑仍在")")

        // --- step 7b: delete the second album too ---------------------------
        var ok7b = true
        if let second = albumNamed(secondAlbumName) {
            ok7b = performChangesSync(label: "删除测试专辑 B") {
                PHAssetCollectionChangeRequest.deleteAssetCollections([second] as NSArray)
            }
        }
        note("7b/8 删除测试专辑 B → \(ok7b && albumNamed(secondAlbumName) == nil ? "OK" : "❌ 仍在")")

        // --- final: clean up the test image via the REAL delete path --------
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.note("—— 收尾：把测试图本身删掉，走 App 真实的删除路径 ——")
            self.note("它会弹一次系统确认框（因为待删队列里就 1 张，所以只弹一次）。请在弹窗里点「删除」。")
            self.dryRun = false
            self.pendingDeletes = [SiftItem.from(asset)]
            self.commit()
        }
    }

    // MARK: - helpers

    private func albumNamed(_ name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject
    }

    private func albumContains(_ album: PHAssetCollection, _ assetID: String) -> Bool {
        let members = PHAsset.fetchAssets(in: album, options: nil)
        var found = false
        members.enumerateObjects { candidate, _, _ in
            if candidate.localIdentifier == assetID { found = true }
        }
        return found
    }

    /// Run one change block and block until PhotoKit reports back.
    /// Must not be called on the main thread.
    private func performChangesSync(label: String, _ body: @escaping () -> Void) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Box<Bool>()
        let message = Box<String>()
        PHPhotoLibrary.shared().performChanges(body, completionHandler: { ok, error in
            result.value = ok
            message.value = error?.localizedDescription
            semaphore.signal()
        })
        semaphore.wait()
        if result.value != true {
            note("   ⚠️ \(label) 返回失败：\(message.value ?? "未知错误")")
        }
        return result.value ?? false
    }

    static func makeTestImage(at url: URL) -> Bool {
        let size = NSSize(width: 900, height: 900)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 60, y: 60, width: 780, height: 780)).fill()
        NSColor.systemIndigo.setFill()
        NSBezierPath(rect: NSRect(x: 80, y: 80, width: 740, height: 740)).fill()

        let lines = ["PhotoSift", "测试图", "可安全删除"]
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: index == 0 ? 84 : 62),
                .foregroundColor: NSColor.white,
            ]
            let text = line as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (900 - textSize.width) / 2,
                                  y: 620 - CGFloat(index) * 150),
                      withAttributes: attributes)
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
