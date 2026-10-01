// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit

struct ImagePickerController: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    /// UIImagePickerController's built-in square crop is clunky — callers that crop themselves pass `false`.
    var allowsEditing: Bool = true
    let onPick: (UIImage) -> Void
    let onCancel: () -> Void

    init(
        sourceType: UIImagePickerController.SourceType = .photoLibrary,
        allowsEditing: Bool = true,
        onPick: @escaping (UIImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sourceType = sourceType
        self.allowsEditing = allowsEditing
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        switch sourceType {
        case .photoLibrary, .savedPhotosAlbum:
            makePhotoLibraryPicker(context: context)
        default:
            makeCameraPicker(context: context)
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private func makePhotoLibraryPicker(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    private func makeCameraPicker(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.allowsEditing = allowsEditing
        picker.delegate = context.coordinator
        return picker
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, PHPickerViewControllerDelegate {
        let onPick: (UIImage) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let edited = info[.editedImage] as? UIImage {
                onPick(edited)
            } else if let original = info[.originalImage] as? UIImage {
                onPick(original)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
            picker.dismiss(animated: true)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                onCancel()
                picker.dismiss(animated: true)
                return
            }

            guard provider.canLoadObject(ofClass: UIImage.self) else {
                onCancel()
                picker.dismiss(animated: true)
                return
            }

            provider.loadObject(ofClass: UIImage.self) { [onPick, onCancel, weak picker] object, _ in
                DispatchQueue.main.async {
                    if let image = object as? UIImage {
                        onPick(image)
                    } else {
                        onCancel()
                    }
                    picker?.dismiss(animated: true)
                }
            }
        }
    }
}
#endif
