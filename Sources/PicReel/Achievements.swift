// Copyright (C) 2026 MageAilurus
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PicReel —— 键盘驱动的 Mac 照片整理工具

import SwiftUI

/// A local achievement. No account, no network: the whole point is that the
/// milestones are yours and the dates are real.
///
/// The thresholds are about *photos organised*, which includes the ones already
/// sitting in your category albums when the app starts — those were organised by
/// you too, just in an earlier session. Without that, someone resuming a 1,200
/// photo job would be told they had organised nothing.
enum Achievement: String, CaseIterable, Codable, Identifiable {
    case firstLaunch
    case hundred
    case thousand
    case tenThousand

    var id: String { rawValue }

    /// Photos needed. 0 = it fires on the first run.
    var threshold: Int {
        switch self {
        case .firstLaunch:  return 0
        case .hundred:      return 100
        case .thousand:     return 1_000
        case .tenThousand:  return 10_000
        }
    }

    var title: String {
        switch self {
        case .firstLaunch:  return "初次见面"
        case .hundred:      return "一百张"
        case .thousand:     return "一千张"
        case .tenThousand:  return "一万张"
        }
    }

    var detail: String {
        switch self {
        case .firstLaunch:  return "第一次打开 PicReel"
        case .hundred:      return "整理满 100 张"
        case .thousand:     return "整理满 1,000 张"
        case .tenThousand:  return "整理满 10,000 张"
        }
    }

    /// The glyph inside the badge.
    var symbol: String {
        switch self {
        case .firstLaunch:  return "sparkles"
        case .hundred:      return "leaf.fill"
        case .thousand:     return "flame.fill"
        case .tenThousand:  return "crown.fill"
        }
    }

    /// Ring colours, so the four badges read as a set rather than four stickers.
    var ring: [Color] {
        switch self {
        case .firstLaunch:  return [Color(red: 0.42, green: 0.45, blue: 0.95),
                                    Color(red: 0.62, green: 0.42, blue: 0.95)]
        case .hundred:      return [Color(red: 0.72, green: 0.45, blue: 0.30),
                                    Color(red: 0.85, green: 0.62, blue: 0.32)]
        case .thousand:     return [Color(red: 0.62, green: 0.66, blue: 0.72),
                                    Color(red: 0.86, green: 0.89, blue: 0.94)]
        case .tenThousand:  return [Color(red: 0.86, green: 0.68, blue: 0.18),
                                    Color(red: 0.99, green: 0.87, blue: 0.40)]
        }
    }
}

/// A small medal: gradient ring, tinted disc, glyph. Drawn rather than shipped
/// as an asset so it picks up the app's own palette and stays sharp at any size.
struct AchievementBadge: View {
    let achievement: Achievement
    let unlockedAt: Date?
    var size: CGFloat = 54

    private var isUnlocked: Bool { unlockedAt != nil }

    var body: some View {
        ZStack {
            Circle()
                .fill(isUnlocked
                      ? LinearGradient(colors: achievement.ring,
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                      : LinearGradient(colors: [Color.gray.opacity(0.35),
                                                Color.gray.opacity(0.22)],
                                       startPoint: .top, endPoint: .bottom))

            Circle()
                .fill(Color.black.opacity(0.18))
                .padding(size * 0.11)

            Image(systemName: achievement.symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(isUnlocked ? Color.white : Color.white.opacity(0.55))
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)

            // Locked badges get a quiet "not yet" tick instead of a colour.
            if !isUnlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(size * 0.05)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .offset(x: size * 0.3, y: size * 0.3)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: isUnlocked ? achievement.ring[0].opacity(0.35) : .clear,
                radius: 6, y: 2)
    }
}
