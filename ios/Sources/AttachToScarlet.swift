import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// "Share" — Ido hands Scarlet a document or snaps a photo. The file uploads
/// to the backend (op=doc_upload), and Scarlet is told about it via ambient
/// focus + a spoken nudge so she can call analyze_document server-side. This
/// file is fully self-contained: the round button, the three pickers (camera,
/// photo library, files), the downscale/JPEG plumbing and the upload call.

// MARK: - Entry point

/// RoundControl-style circular button (same 62pt sizing/colors as TalkView's
/// controls row — replicated here on purpose so RoundControl stays untouched).
/// Drop `AttachToScarletButton(convo: convo)` into TalkView's HStack.
struct AttachToScarletButton: View {
    @ObservedObject var convo: Conversation

    @State private var showChooser = false
    @State private var showCamera = false
    /// Photo-library and Files pickers share ONE sheet — two `.sheet(isPresented:)`
    /// on one view crash Mac Catalyst. Camera stays a separate fullScreenCover.
    enum AttachPick: Identifiable {
        case photos, files
        var id: String { self == .photos ? "photos" : "files" }
    }
    @State private var attachPick: AttachPick?
    @State private var uploading = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    private let scarletRose = Color(red: 1, green: 0.35, blue: 0.42)

    var body: some View {
        Button {
            guard !uploading else { return }
            showChooser = true
        } label: {
            VStack(spacing: 3) {
                if uploading {
                    ProgressView()
                        .tint(.white)
                        .frame(height: 22)
                } else {
                    Image(systemName: "plus").font(.system(size: 18))
                }
                Text("Share").font(.system(size: 9, weight: .semibold)).tracking(0.5)
            }
            .frame(width: 62, height: 62)
            .foregroundStyle(.white)
            .background(.white.opacity(0.07), in: Circle())
            .overlay(Circle().stroke(uploading ? scarletRose.opacity(0.55)
                                               : .white.opacity(0.16), lineWidth: 1))
        }
        .disabled(uploading)
        .confirmationDialog("Share with Scarlet", isPresented: $showChooser,
                            titleVisibility: .visible) {
            Button("Camera") {
                // Simulator (and camera-less devices): fall through to the
                // photo library instead of presenting a dead picker.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = true
                } else {
                    attachPick = .photos
                }
            }
            Button("Photo Library") { attachPick = .photos }
            Button("Files") { attachPick = .files }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showCamera) {
            AttachCameraPicker { image in
                showCamera = false
                handlePickedImage(image, source: "camera")
            }
            .ignoresSafeArea()
        }
        .sheet(item: $attachPick) { pick in
            switch pick {
            case .photos:
                AttachPhotoPicker { image in
                    attachPick = nil
                    handlePickedImage(image, source: "photos")
                }
                .ignoresSafeArea()
            case .files:
                AttachDocumentPicker { url in
                    attachPick = nil
                    handlePickedFile(url)
                }
                .ignoresSafeArea()
            }
        }
        .alert("Couldn't share", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: picked-content handlers

    /// Camera / photo library: downscale (longest side 2048px) → JPEG 0.85.
    private func handlePickedImage(_ image: UIImage?, source: String) {
        guard let image else { return }   // cancelled
        guard let jpeg = AttachToScarletButton.downscaledJPEG(image) else {
            fail("Couldn't read that photo — try another one.")
            return
        }
        let stamp = AttachToScarletButton.stampFormatter.string(from: Date())
        upload(filename: "photo-\(stamp).jpg", mime: "image/jpeg",
               data: jpeg, source: source, kindWord: "photo")
    }

    /// Files app: read the copied file (security-scoped, belt-and-suspenders
    /// even with asCopy) and map its extension to a MIME type.
    private func handlePickedFile(_ url: URL?) {
        guard let url else { return }   // cancelled
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fail("Couldn't read that file — try again.")
            return
        }
        let filename = url.lastPathComponent.isEmpty ? "document" : url.lastPathComponent
        let mime = AttachToScarletButton.mime(forFilename: filename)
        upload(filename: filename, mime: mime, data: data, source: "files",
               kindWord: AttachToScarletButton.kindWord(forMime: mime))
    }

    // MARK: upload flow

    private func upload(filename: String, mime: String, data: Data,
                        source: String, kindWord: String) {
        guard !uploading else { return }
        guard data.count <= 15 * 1024 * 1024 else {
            fail("Too large — up to 15MB")
            return
        }
        uploading = true
        Task { @MainActor in
            do {
                let title = try await AttachToScarletButton.uploadRequest(
                    filename: filename, mime: mime,
                    contentB64: data.base64EncodedString(), source: source)
                // Ambient focus: sticks even if the conversation isn't live
                // yet — a later connect replays it.
                convo.setFocus("[FOCUS] Ido just shared a document with you: \(title) (\(kindWord)). Use analyze_document to read it — it is ALREADY uploaded; do not ask him to send it again.")
                // Spoken acknowledgement. ensureLive:true wakes the session if
                // she's asleep and queues this so it lands the moment the socket
                // is live — otherwise a photo shared from an idle Talk screen
                // uploads but she never says a word about it (the old no-op).
                convo.sendSystemNudge("[SYSTEM] Ido just uploaded \(title). Acknowledge in a few words that you have it and ask what he'd like you to do with it — unless he already told you, in which case call analyze_document now.", ensureLive: true)
            } catch let error as AttachUploadError {
                alertMessage = error.text
                showAlert = true
            } catch {
                alertMessage = "Upload failed — check your connection and try again."
                showAlert = true
            }
            uploading = false
        }
    }

    private func fail(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: plumbing — the op rides the QUERY STRING (app-wide convention:
    // the server dispatches on ?op=...); the JSON body carries the params.
    // Mirrors LibraryModel.request, standalone so no other file changes.

    private struct AttachUploadError: Error {
        let text: String
    }

    private static func uploadRequest(filename: String, mime: String,
                                      contentB64: String, source: String) async throws -> String {
        var comps = URLComponents(url: AppConfig.appAPIURL, resolvingAgainstBaseURL: false)!
        var qItems = comps.queryItems ?? []
        qItems.append(URLQueryItem(name: "op", value: "doc_upload"))
        comps.queryItems = qItems
        var req = URLRequest(url: comps.url ?? AppConfig.appAPIURL)
        req.httpMethod = "POST"
        req.setValue(TokenStore.token ?? "", forHTTPHeaderField: "x-scarlet-token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "filename": filename,
            "mime": mime,
            "content_b64": contentB64,
            "source": source,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let httpOK: Bool = {
            guard let http = resp as? HTTPURLResponse else { return true }
            return (200...299).contains(http.statusCode)
        }()
        guard httpOK, (obj?["ok"] as? Bool) == true else {
            // Surface the server's own message (e.g. its 413-style too-large
            // error) when there is one; otherwise a short generic line.
            if let serverText = obj?["error"] as? String, !serverText.isEmpty {
                throw AttachUploadError(text: serverText)
            }
            throw AttachUploadError(text: "The upload was rejected — try again.")
        }
        let title = (obj?["title"] as? String) ?? filename
        return title.isEmpty ? filename : title
    }

    // MARK: helpers

    /// Longest side capped at 2048 pixels (UIGraphicsImageRenderer at scale 1
    /// so points == pixels), then JPEG at 0.85.
    static func downscaledJPEG(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 2048
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        var source = image
        if longest > maxSide, longest > 0 {
            let ratio = maxSide / longest
            let newSize = CGSize(width: max(1, floor(pixelWidth * ratio)),
                                 height: max(1, floor(pixelHeight * ratio)))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            source = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return source.jpegData(compressionQuality: 0.85)
    }

    static func mime(forFilename name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }

    /// The human word for the focus line: "\(title) (\(kindWord))".
    static func kindWord(forMime mime: String) -> String {
        switch mime {
        case "application/pdf": return "PDF"
        case "image/jpeg", "image/png": return "image"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return "Word document"
        case "text/plain": return "text file"
        case "text/csv": return "CSV file"
        default: return "file"
        }
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

// MARK: - Camera (UIImagePickerController, .camera)

/// Full-screen camera. Calls back with the captured image, or nil on cancel;
/// the caller closes the cover either way.
struct AttachCameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

// MARK: - Photo library (PHPickerViewController, single image)

struct AttachPhotoPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                onFinish(nil)
                return
            }
            let done = onFinish
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async {
                    done(object as? UIImage)
                }
            }
        }
    }
}

// MARK: - Files (UIDocumentPickerViewController)

struct AttachDocumentPicker: UIViewControllerRepresentable {
    var onFinish: (URL?) -> Void

    /// PDF, images, plain text, CSV, and .docx. Built via compactMap so a
    /// platform missing the docx UTType degrades instead of crashing.
    static var contentTypes: [UTType] {
        let wanted: [UTType?] = [
            .pdf,
            .image,
            .plainText,
            .commaSeparatedText,
            UTType("org.openxmlformats.wordprocessingml.document"),
        ]
        return wanted.compactMap { $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onFinish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(nil)
        }
    }
}
