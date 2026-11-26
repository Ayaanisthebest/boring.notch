//
//  NotificationAnimationCatalog.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

struct NotchNotificationItem: Identifiable {
    let id: String
    var appName: String
    var title: String
    var body: String
    var icon: NSImage?
    var bundleIdentifier: String?

    static var sample: NotchNotificationItem {
        let icon = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.MobileSMS")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        return NotchNotificationItem(
            id: "preview-\(UUID().uuidString)",
            appName: "Messages",
            title: "Jordan",
            body: "Dinner at 7 still good?",
            icon: icon,
            bundleIdentifier: "com.apple.MobileSMS"
        )
    }
}

enum NotchNotificationPhase: Equatable {
    case resting
    case compact
    case expanded
}

@MainActor
final class NotchNotificationPresenter: ObservableObject {
    static let shared = NotchNotificationPresenter()

    @Published private(set) var current: NotchNotificationItem?
    @Published private(set) var history: [NotchNotificationItem] = []
    @Published private(set) var style: NotchNotificationStyle = Defaults[.notchNotificationStyle]
    @Published private(set) var phase: NotchNotificationPhase = .resting
    @Published private(set) var isPresenting = false

    var occupiesNotch: Bool {
        isPresenting || phase != .resting
    }

    private var queue: [NotchNotificationItem] = []
    private var task: Task<Void, Never>?
    private var generation = 0

    func present(_ item: NotchNotificationItem) {
        remember(item)
        if isPresenting {
            if queue.count < 8, !queue.contains(where: { $0.id == item.id }) {
                queue.append(item)
            }
            return
        }
        begin(item)
    }

    func presentExisting(_ items: [NotchNotificationItem]) {
        for item in items {
            remember(item)
        }
        guard let newest = items.first else { return }
        present(newest)
    }

    func record(_ items: [NotchNotificationItem]) {
        for item in items.reversed() {
            remember(item)
        }
    }

    func activate(_ item: NotchNotificationItem) {
        NotificationCenterMonitor.shared.openNotification(
            id: item.id,
            appName: item.appName,
            bundleIdentifier: item.bundleIdentifier
        )
        history.removeAll { $0.id == item.id }
        queue.removeAll { $0.id == item.id }
        guard current?.id == item.id else { return }
        generation += 1
        task?.cancel()
        phase = .resting
        isPresenting = false
        current = nil
        if !queue.isEmpty {
            begin(queue.removeFirst())
        }
    }

    private func remember(_ item: NotchNotificationItem) {
        history.removeAll { $0.id == item.id }
        history.insert(item, at: 0)
        if history.count > 20 {
            history = Array(history.prefix(20))
        }
    }

    func preview() {
        generation += 1
        queue.removeAll()
        task?.cancel()
        isPresenting = false
        phase = .resting
        begin(.sample)
    }

    private func begin(_ item: NotchNotificationItem) {
        generation += 1
        let token = generation
        isPresenting = true
        current = item
        style = Defaults[.notchNotificationStyle]
        phase = .resting
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(token: token)
        }
    }

    private func run(token: Int) async {
        try? await Task.sleep(for: .milliseconds(30))
        guard token == generation, !Task.isCancelled else { return }
        phase = style == .twoStage ? .compact : .expanded

        let expanded = min(9.0, 4.0 + Double(current?.body.count ?? 0) / 90.0)
        switch style {
        case .twoStage:
            try? await Task.sleep(for: .milliseconds(900))
            guard token == generation, !Task.isCancelled else { return }
            phase = .expanded
            try? await Task.sleep(for: .seconds(expanded))
        case .dropCard:
            try? await Task.sleep(for: .seconds(expanded))
        }

        guard token == generation, !Task.isCancelled else { return }
        phase = .resting
        try? await Task.sleep(for: .milliseconds(550))
        guard token == generation, !Task.isCancelled else { return }

        if queue.isEmpty {
            isPresenting = false
            current = nil
        } else {
            let next = queue.removeFirst()
            isPresenting = false
            begin(next)
        }
    }
}

/// Notification content on the real notch. The camera housing stays centered and empty:
/// compact content sits in wings beside it, expanded content sits underneath it.
struct LiveNotificationView: View {
    @ObservedObject var presenter: NotchNotificationPresenter
    var housingWidth: CGFloat
    var housingHeight: CGFloat
    var maxContentWidth: CGFloat

    private let wing: CGFloat = 56
    private let maxBodyLines = 8

    private var deadZone: CGFloat { housingWidth + 8 }
    private var cardWidth: CGFloat { min(maxContentWidth, 520) }
    private var textWidth: CGFloat { max(80, cardWidth - 74) }

    private var size: CGSize {
        switch presenter.phase {
        case .resting:
            return CGSize(width: max(0, housingWidth - 20), height: housingHeight)
        case .compact:
            return CGSize(width: deadZone + wing * 2, height: housingHeight)
        case .expanded:
            return CGSize(width: cardWidth, height: expandedHeight)
        }
    }

    private var expandedHeight: CGFloat {
        let titleLines: CGFloat = (presenter.current?.title.count ?? 0) > 36 ? 2 : 1
        let height = housingHeight + 18 + titleLines * 18 + measuredBodyHeight + 16
        return min(height, windowSize.height - 24)
    }

    private var measuredBodyHeight: CGFloat {
        let body = presenter.current?.body ?? ""
        guard !body.isEmpty else { return 0 }
        let bounds = (body as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5)]
        )
        let line: CGFloat = 16
        return min(CGFloat(maxBodyLines) * line, max(line, ceil(bounds.height)))
    }

    var body: some View {
        let item = presenter.current

        ZStack(alignment: .top) {
            compactWings(item)
                .opacity(presenter.phase == .compact ? 1 : 0)
                .blur(radius: presenter.phase == .compact ? 0 : 6)
                .animation(
                    presenter.phase == .compact
                        ? .easeOut(duration: 0.28).delay(0.12)
                        : .easeIn(duration: 0.14),
                    value: presenter.phase
                )

            expandedContent(item)
                .opacity(presenter.phase == .expanded ? 1 : 0)
                .blur(radius: presenter.phase == .expanded ? 0 : 10)
                .scaleEffect(presenter.phase == .expanded ? 1 : 0.92, anchor: .top)
                .animation(
                    presenter.phase == .expanded
                        ? .spring(response: 0.42, dampingFraction: 0.86).delay(0.14)
                        : .easeIn(duration: 0.16),
                    value: presenter.phase
                )
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }

    private func compactWings(_ item: NotchNotificationItem?) -> some View {
        HStack(spacing: 0) {
            Group {
                if let item {
                    notificationIcon(item, side: max(0, min(20, housingHeight - 12)))
                }
            }
            .frame(width: wing)

            Color.clear.frame(width: deadZone)

            Text(item?.appName ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .frame(width: wing)
        }
        .frame(height: housingHeight)
        .fixedSize()
    }

    private func expandedContent(_ item: NotchNotificationItem?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let item {
                notificationIcon(item, side: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item?.title ?? "")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(item?.appName ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                if let body = item?.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(maxBodyLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, housingHeight + 4)
        .frame(width: cardWidth, alignment: .leading)
    }

    @ViewBuilder
    private func notificationIcon(_ item: NotchNotificationItem, side: CGFloat) -> some View {
        if let icon = item.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
        } else {
            Image(systemName: "bell.fill")
                .font(.system(size: max(8, side * 0.48), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
        }
    }
}

struct NotificationHistoryList: View {
    @ObservedObject private var presenter = NotchNotificationPresenter.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 4)

                ForEach(presenter.history) { item in
                    Button {
                        presenter.activate(item)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            historyIcon(item)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title.isEmpty ? item.appName : item.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(item.body.isEmpty ? item.appName : item.body)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(4)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func historyIcon(_ item: NotchNotificationItem) -> some View {
        if let icon = item.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "bell.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
        }
    }
}
