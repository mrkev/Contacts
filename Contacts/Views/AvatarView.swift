import SwiftUI

/// Contact photo, or a monogram on a tinted background when there's no photo.
struct AvatarView: View {
    var contactID: String
    var initials: String
    var isOrganization = false
    var hasImage: Bool
    var size: CGFloat = 32
    /// Full-resolution image data, when the caller already has it (e.g. the detail card).
    var imageData: Data?

    @Environment(ContactsModel.self) private var model
    @State private var thumbnail: Image?

    var body: some View {
        ZStack {
            if let image = imageData.flatMap({ Image(imageData: $0) }) ?? thumbnail {
                image.resizable().scaledToFill()
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
        .task(id: TaskKey(id: contactID, hasImage: hasImage, revision: model.revision)) {
            guard hasImage, imageData == nil else {
                thumbnail = nil
                return
            }
            thumbnail = ThumbnailCache.shared.cachedImage(for: contactID)
            if thumbnail == nil {
                thumbnail = await ThumbnailCache.shared.image(for: contactID)
            }
        }
    }

    private var monogram: some View {
        Circle()
            .fill(LinearGradient(colors: [Self.tint(for: contactID).opacity(0.75), Self.tint(for: contactID)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                if isOrganization || initials.isEmpty {
                    Image(systemName: isOrganization ? "building.2.fill" : "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.white)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                }
            }
    }

    private struct TaskKey: Hashable {
        var id: String
        var hasImage: Bool
        var revision: Int
    }

    private static let palette: [Color] = [.gray, .blue, .indigo, .purple, .pink, .orange, .teal, .green, .brown]

    /// Stable per-contact color (Swift's `hashValue` is randomized per launch, so sum scalars instead).
    static func tint(for id: String) -> Color {
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}

extension AvatarView {
    init(_ summary: ContactSummary, size: CGFloat = 32) {
        self.init(contactID: summary.id, initials: summary.initials, isOrganization: summary.isOrganization,
                  hasImage: summary.hasImage, size: size)
    }
}
