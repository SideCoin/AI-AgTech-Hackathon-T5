import SwiftUI
import UIKit

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var triggerCapture: Bool
    var onImagePicked: (UIImage) -> Void
    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator

        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.showsCameraControls = false
        } else {
            picker.sourceType = .photoLibrary
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        if triggerCapture && !context.coordinator.hasQueuedCapture {
            context.coordinator.hasQueuedCapture = true

            DispatchQueue.main.async {
                self.triggerCapture = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if uiViewController.sourceType == .camera {
                    uiViewController.takePicture()
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        var hasQueuedCapture = false

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let pickedImage = info[.originalImage] as? UIImage
            parent.presentationMode.wrappedValue.dismiss()

            // Let the camera fully tear down its audio session before we claim it for
            // speech recognition — otherwise the AVAudioSession activation races and the
            // voice-note tap silently fails, leaving an empty note.
            if let pickedImage {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [parent] in
                    parent.onImagePicked(pickedImage)
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
