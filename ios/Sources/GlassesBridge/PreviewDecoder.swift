import CoreImage
import CoreMedia
import UIKit
import VideoToolbox
import os

/// Decodes `.hvc1` frames for the on-phone preview and for the Core2 (the PC
/// gets the compressed stream). Mirrors the CameraAccess sample's
/// VideoFrameDecoder: software decode (hardware decoding isn't allowed in the
/// background), restart on format change, wait for a keyframe after a reset.
final class PreviewDecoder: Sendable {
  private struct State {
    var session: VTDecompressionSession?
    var format: CMFormatDescription?
    var awaitingKeyframe = true
  }

  private let state = OSAllocatedUnfairLock(uncheckedState: State())
  private let context = CIContext()

  /// Call when frames stop being fed (app backgrounded) so decoding resumes at a keyframe.
  func reset() {
    state.withLockUnchecked { $0.awaitingKeyframe = true }
  }

  /// Every frame must be decoded (HEVC frames reference earlier ones); each
  /// decoded frame goes to `latest` if given, and only frames with `wantImage`
  /// are converted to a UIImage.
  func decode(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool, wantImage: Bool, latest: LatestFrame? = nil) -> UIImage? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

    let session: VTDecompressionSession? = state.withLockUnchecked { s in
      if let current = s.format, !CMFormatDescriptionEqual(current, otherFormatDescription: format) {
        if let old = s.session { VTDecompressionSessionInvalidate(old) }
        s.session = nil
        s.format = nil
      }
      if s.session == nil {
        let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var created: VTDecompressionSession?
        VTDecompressionSessionCreate(
          allocator: kCFAllocatorDefault,
          formatDescription: format,
          decoderSpecification: spec,
          imageBufferAttributes: attributes,
          outputCallback: nil,
          decompressionSessionOut: &created
        )
        s.session = created
        s.format = format
        s.awaitingKeyframe = true
      }
      if s.awaitingKeyframe {
        guard isKeyframe else { return nil }
        s.awaitingKeyframe = false
      }
      return s.session
    }
    guard let session else { return nil }

    nonisolated(unsafe) var pixelBuffer: CVPixelBuffer?
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) {
      status, _, imageBuffer, _, _ in
      if status == noErr { pixelBuffer = imageBuffer }
    }
    guard status == noErr, let pixelBuffer else {
      state.withLockUnchecked { $0.awaitingKeyframe = true }
      return nil
    }
    latest?.update(pixelBuffer)
    guard wantImage else { return nil }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
