#!/bin/bash
# Compile the production editor/media code into an isolated native UI probe.
# Usage: scripts/probe-video-editor.sh /path/to/synthetic-fixture.mp4 [--audio-merge] [--normal]
# Saves replace only the private copy printed below; the input is untouched.
# Uploads and capture are disabled. Other app services are minimal stubs.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /absolute/path/to/synthetic-fixture.mp4 [--audio-merge] [--normal]" >&2
  exit 2
fi
probe_source="$1"
shift
probe_conditions=(-D OFFLINE -D VIDEO_EDITOR_PROBE)
probe_audio_merge=false
for option in "$@"; do
  case "$option" in
    --audio-merge) probe_audio_merge=true ;;
    --normal) probe_conditions=(-D MACSHOT_UI_PROBE -D VIDEO_EDITOR_PROBE) ;;
    *) echo "Unknown probe option: $option" >&2; exit 2 ;;
  esac
done
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/macshot-source-editor-probe.XXXXXX")
probe_bundle="$probe_directory/SourceEditorProbe.app"
mkdir -p "$probe_bundle/Contents/MacOS"
cp "$probe_source" "$probe_directory/input.mp4"
cat > "$probe_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.macshot.source-editor-probe</string>
<key>CFBundleName</key><string>Source Editor Probe</string>
<key>CFBundleExecutable</key><string>SourceEditorProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
if [[ $probe_audio_merge == true ]]; then
  /usr/libexec/PlistBuddy -c 'Add :AudioMergeProbe bool true' "$probe_bundle/Contents/Info.plist"
fi
sources=(
  macshot/Capture/AudioTrackMixer.swift
  macshot/Capture/CancellableRenderQueue.swift
  macshot/Capture/CameraPlacementTrack.swift
  macshot/Capture/CursorMotion.swift
  macshot/Capture/CursorTelemetry.swift
  macshot/Capture/EffectsVideoCompositor.swift
  macshot/Capture/GIFEncoder.swift
  macshot/Capture/GIFExporter.swift
  macshot/Capture/KeystrokeTimeline.swift
  macshot/Capture/MediaExportPump.swift
  macshot/Capture/PreparedVideoSource.swift
  macshot/Capture/RecordingSessionStore.swift
  macshot/Capture/SafeNumerics.swift
  macshot/Capture/SampleBufferTiming.swift
  macshot/Capture/VideoCameraRecorder.swift
  macshot/Capture/VideoCaptionTranscriber.swift
  macshot/Capture/VideoCompositionBuilder.swift
  macshot/Capture/VideoCompositionRendering.swift
  macshot/Capture/VideoEffectSnapshot.swift
  macshot/Capture/VideoEncodingSettings.swift
  macshot/Capture/VideoExportEncodingPlan.swift
  macshot/Capture/VideoExportJob.swift
  macshot/Capture/VideoFrameCadence.swift
  macshot/Capture/VideoRenderGeometry.swift
  macshot/Capture/VideoSceneBuilder.swift
  macshot/Capture/VideoSceneGeometry.swift
  macshot/Capture/VideoSceneRenderer.swift
  macshot/Capture/VideoTextRasterizer.swift
  macshot/Capture/VideoTimelineMapping.swift
  macshot/Capture/VideoTranscoder.swift
  macshot/Model/LenientDecoding.swift
  macshot/Model/VideoCensorSegment.swift
  macshot/Model/VideoCutSegment.swift
  macshot/Model/VideoFreezeSegment.swift
  macshot/Model/VideoProject.swift
  macshot/Model/VideoSpeedSegment.swift
  macshot/Model/VideoTextSegment.swift
  macshot/Model/VideoZoomSegment.swift
  macshot/Services/ApplicationTerminationCoordinator.swift
  macshot/Services/AtomicMediaSave.swift
  macshot/Services/BeautifyRenderer.swift
  macshot/Services/EditorCommandShortcutManager.swift
  macshot/Services/FilenameSanitizer.swift
  macshot/Services/KeyboardShortcutMatcher.swift
  macshot/Services/MediaExportCoordinator.swift
  macshot/Services/VideoSourceSnapshot.swift
  macshot/UI/Editor/Video/VideoEditorChrome.swift
  macshot/UI/Editor/Video/VideoEditorDocument.swift
  macshot/UI/Editor/Video/VideoEditorExporter.swift
  macshot/UI/Editor/Video/VideoEditorPlayback.swift
  macshot/UI/Editor/Video/VideoEditorStyle.swift
  macshot/UI/Editor/Video/VideoInspectorView.swift
  macshot/UI/Editor/Video/VideoRenderPlanner.swift
  macshot/UI/Editor/Video/VideoStageView.swift
  macshot/UI/Editor/Video/VideoTimelineView.swift
  macshot/UI/Editor/VideoEditorWindowController.swift
  macshot/UI/Editor/VideoEditorWindowController+Export.swift
  macshot/UI/Popover/ColorPickerView.swift
  macshot/UI/Popover/PopoverHelper.swift
  macshot/UI/Tools/ScopedUndoTextView.swift
  macshot/UI/Windows/MediaExportProgressController.swift
  macshot/UI/Windows/AudioMergeController.swift
)
swiftc -O -swift-version 5 -default-isolation MainActor "${probe_conditions[@]}" -parse-as-library   "${sources[@]}" scripts/probe-video-editor.swift   -o "$probe_bundle/Contents/MacOS/SourceEditorProbe" > "$probe_directory/build.log" 2>&1 || {
    cat "$probe_directory/build.log" >&2
    exit 1
  }
echo "Probe artifacts: $probe_directory"
echo "Saving in this editor replaces only: $probe_directory/input.mp4"
"$probe_bundle/Contents/MacOS/SourceEditorProbe" > "$probe_directory/runtime.log" 2>&1
