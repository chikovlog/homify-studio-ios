import SwiftUI
import HomifyCore

/// Context toolbar: clip tools when a clip is selected, add-media tools
/// otherwise. Fixed height so switching modes never relayouts the editor.
struct EditorToolbar: View {
    @ObservedObject var vm: EditorViewModel
    let addFromPhotos: () -> Void
    let addFromFiles: (TrackKind) -> Void
    let showAudio: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let clip = vm.selectedClip, let track = vm.selectedTrack {
                    ToolButton(title: "Split", icon: "scissors", action: vm.split)
                        .disabled(track.isLocked)
                    ToolButton(title: "Volume", icon: "speaker.wave.2", action: showAudio)
                        .disabled(track.isLocked || vm.project.mediaAsset(clip.mediaID)?.hasAudio != true)
                    ToolButton(title: "Duplicate", icon: "plus.square.on.square", action: vm.duplicateSelected)
                        .disabled(track.isLocked)
                    ToolButton(title: "Delete", icon: "trash", role: .destructive, action: vm.deleteSelected)
                        .disabled(track.isLocked)
                    ToolButton(title: "Done", icon: "checkmark") { vm.selectedClipID = nil }
                } else {
                    ToolButton(title: "Photos", icon: "photo.on.rectangle", action: addFromPhotos)
                    ToolButton(title: "Files", icon: "folder") { addFromFiles(.main) }
                    ToolButton(title: "Audio", icon: "music.note") { addFromFiles(.audio) }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 66)
        .background(Color(white: 0.09))
    }
}

struct ToolButton: View {
    let title: String
    let icon: String
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 19, weight: .regular))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(width: 62, height: 54)
            .contentShape(Rectangle())
        }
        .foregroundStyle(role == .destructive ? Color.red : Color.white)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// Volume and equal-power fade controls for the selected clip.
struct AudioPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Audio").font(.headline)
            if let clip = vm.selectedClip {
                sliderRow("Volume", value: clip.volume, range: 0...2, format: { "\(Int(($0 * 100).rounded()))%" }) { v in
                    { (c: inout Clip) in c.volume = v }
                }
                let maxFade = max(0.1, min(10, clip.duration.seconds))
                sliderRow("Fade in", value: clip.fadeIn.seconds, range: 0...maxFade, format: { String(format: "%.1fs", $0) }) { v in
                    { (c: inout Clip) in c.fadeIn = Time(seconds: v) }
                }
                sliderRow("Fade out", value: clip.fadeOut.seconds, range: 0...maxFade, format: { String(format: "%.1fs", $0) }) { v in
                    { (c: inout Clip) in c.fadeOut = Time(seconds: v) }
                }
            } else {
                Text("Select a clip first.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .preferredColorScheme(.dark)
    }

    private func sliderRow(_ title: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String,
                           edit: @escaping (Double) -> (inout Clip) -> Void) -> some View {
        AudioSliderRow(title: title, value: value, range: range, format: format) { phase, v in
            vm.editClipAudio(phase, edit(v))
        }
    }
}

private struct AudioSliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onEdit: (EditorViewModel.SliderPhase, Double) -> Void
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(format(value)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { onEdit(editing ? .changed : .began, $0); editing = true }),
                   in: range) { isEditing in
                if !isEditing {
                    onEdit(.ended, value)
                    editing = false
                }
            }
        }
    }
}
