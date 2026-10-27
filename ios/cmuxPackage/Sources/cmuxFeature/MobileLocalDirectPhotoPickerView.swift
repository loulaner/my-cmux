import CmuxMobileShell
import PhotosUI
import SwiftUI

/// One picker item belongs to one captured import owner, not to a later directory or selection.
@MainActor
struct MobileLocalDirectPhotoPickerView: View {
    @Bindable var selection: MobileLocalDirectFileImportSession
    let isCurrent: () -> Bool
    @State private var item: PhotosPickerItem?

    var body: some View {
        Color.clear
            .photosPicker(isPresented: $selection.isPickerPresented,
                          selection: $item, matching: .images, preferredItemEncoding: .current)
            .onChange(of: item) { _, item in
                guard let item else { return }
                self.item = nil
                guard isCurrent() else { return }
                selection.select(load: {
                    guard let payload = try await item.loadTransferable(type: MobileLocalDirectPhotoTransfer.self) else {
                        throw MobileLocalDirectFileImportSession.Failure.unavailable
                    }
                    return payload.selection
                })
            }
    }
}
