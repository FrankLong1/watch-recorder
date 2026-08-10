import SwiftUI
import WidgetKit

/// The watch app's control extension.
///
/// Controls arrived on watchOS 26; this bundle is what makes "WristMemo" appear
/// in Settings › Action Button and in Control Center on the watch itself.
@main
struct WristMemoControlsBundle: WidgetBundle {
    var body: some Widget {
        StartRecordingControl()
    }
}
