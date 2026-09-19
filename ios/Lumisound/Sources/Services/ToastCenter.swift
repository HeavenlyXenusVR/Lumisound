import SwiftUI

// MARK: - ToastCategory

/// Broad categories for app-wide toast notifications. Each maps to a default
/// icon/tint so callers usually only need to pass a message + category —
/// `icon` can still be overridden per-toast for more specific feedback
/// (e.g. a heart for favorites).
enum ToastCategory {
    case success
    case error
    case warning
    case info
    case download

    var defaultIcon: String {
        switch self {
        case .success:  return "checkmark.circle.fill"
        case .error:    return "xmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .info:     return "info.circle.fill"
        case .download: return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success:  return AppTheme.success
        case .error:    return AppTheme.error
        case .warning:  return AppTheme.warning
        case .info:     return AppTheme.dynamicAccent
        case .download: return AppTheme.dynamicAccent
        }
    }
}

// MARK: - ToastItem

struct ToastItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let category: ToastCategory
    let icon: String?
    /// How long this toast stays up. The default suits the short confirmations
    /// most toasts are ("Added to playlist"), which the user already knows the
    /// meaning of because they just acted. A message they did NOT ask for and
    /// have never seen before — an Aria announcement — has to be read from
    /// scratch, and 2.5s is not enough time to do that and look up from
    /// whatever they were doing.
    let duration: TimeInterval

    static func == (lhs: ToastItem, rhs: ToastItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ToastCenter

/// App-wide toast notification queue. Any service or view can call
/// `ToastCenter.shared.show(...)` without needing an `@EnvironmentObject` —
/// `ToastOverlay` (mounted once in `ContentView`) observes the shared
/// instance and renders whichever toast is currently `current`.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: ToastItem?

    private var queue: [ToastItem] = []
    private var dismissTask: Task<Void, Never>?

    private init() {}

    static let defaultDuration: TimeInterval = 2.5

    /// Enqueues a toast. If one is already showing, this one waits its turn.
    func show(_ message: String,
              category: ToastCategory = .info,
              icon: String? = nil,
              duration: TimeInterval = ToastCenter.defaultDuration) {
        let item = ToastItem(message: message, category: category, icon: icon, duration: duration)
        queue.append(item)
        if current == nil {
            advance()
        }
    }

    private func advance() {
        dismissTask?.cancel()
        guard !queue.isEmpty else {
            current = nil
            return
        }
        let item = queue.removeFirst()
        current = item
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(item.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            advance()
        }
    }
}

// MARK: - ToastOverlay

/// Renders `ToastCenter.shared.current`, if any. Mounted once near the root
/// of the view hierarchy (ContentView) so any screen can trigger a toast.
struct ToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        if let item = center.current {
            HStack(spacing: 8) {
                Image(systemName: item.icon ?? item.category.defaultIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.category.tint)
                Text(item.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .adaptiveGlass(in: Capsule(), fallback: .regularMaterial)
            .overlay(
                Capsule()
                    .strokeBorder(item.category.tint.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(item.id)
        }
    }
}
