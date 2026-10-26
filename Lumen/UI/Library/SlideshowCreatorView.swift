import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Builds a looping video wallpaper from still images.
struct SlideshowCreatorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var images: [URL] = []
    @State private var title = "Slideshow"
    @State private var secondsPerImage = 8.0
    @State private var transition = 1.5
    @State private var motion = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Slideshow").font(.title2.weight(.semibold))
            Text("Lumen renders your images into a seamlessly looping video, with crossfades and a slow pan and zoom. Your originals aren't changed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Name", text: $title)
                LabeledContent("Images") {
                    HStack {
                        Text(images.isEmpty ? "None chosen" : "\(images.count) image\(images.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseImages)
                    }
                }
                LabeledContent("Each image") {
                    HStack {
                        Slider(value: $secondsPerImage, in: 3...30, step: 1).frame(width: 200)
                        Text("\(Int(secondsPerImage)) s").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Crossfade") {
                    HStack {
                        Slider(value: $transition, in: 0...4, step: 0.5).frame(width: 200)
                        Text(String(format: "%.1f s", transition)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Slow pan and zoom", isOn: $motion)
                LabeledContent("Length") {
                    Text(Format.time(secondsPerImage * Double(images.count))).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    var options = MediaGenerator.SlideshowOptions()
                    options.secondsPerImage = secondsPerImage
                    options.transition = transition
                    options.motion = motion
                    options.size = outputSize
                    model.createSlideshow(from: images, options: options, title: title)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(images.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose the images for the slideshow. They play in name order."
        guard panel.runModal() == .OK else { return }
        images = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The main display's resolution, capped at 4K to keep rendering quick.
    private var outputSize: CGSize {
        guard let display = model.displayManager.displays.first(where: \.isMain) ?? model.displayManager.displays.first else {
            return CGSize(width: 2560, height: 1440)
        }
        let width = Double(display.pixelWidth), height = Double(display.pixelHeight)
        let scale = min(1, 3840 / max(width, height))
        return CGSize(width: width * scale, height: height * scale)
    }
}
