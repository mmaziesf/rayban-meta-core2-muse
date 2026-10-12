import CoreMedia
import Foundation

/// Turns DAT `.hvc1` sample buffers (length-prefixed HEVC NAL units) into an
/// Annex B byte stream the PC can decode with ffmpeg. Keyframes carry the
/// VPS/SPS/PPS so the PC decoder can start or recover at any keyframe.
///
/// `.hvc1` is used because DAT keeps delivering compressed frames while the
/// phone is locked, whereas `.raw` pauses in the background (DAT iOS issue #55).
enum HEVCPacketizer {
  private static let startCode: [UInt8] = [0, 0, 0, 1]

  static func annexB(from sampleBuffer: CMSampleBuffer) -> (data: Data, isKeyframe: Bool)? {
    guard
      let block = CMSampleBufferGetDataBuffer(sampleBuffer),
      let format = CMSampleBufferGetFormatDescription(sampleBuffer)
    else { return nil }

    var parameterSetCount = 0
    var nalLengthSize: Int32 = 4
    guard
      CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        format,
        parameterSetIndex: 0,
        parameterSetPointerOut: nil,
        parameterSetSizeOut: nil,
        parameterSetCountOut: &parameterSetCount,
        nalUnitHeaderLengthOut: &nalLengthSize
      ) == noErr
    else { return nil }

    let length = CMBlockBufferGetDataLength(block)
    var bytes = [UInt8](repeating: 0, count: length)
    guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr
    else { return nil }

    var units = Data(capacity: length + 64)
    var isKeyframe = false
    let prefix = Int(nalLengthSize)
    var offset = 0
    while offset + prefix <= length {
      var unitLength = 0
      for i in 0..<prefix { unitLength = (unitLength << 8) | Int(bytes[offset + i]) }
      offset += prefix
      guard unitLength > 0, offset + unitLength <= length else { break }
      // HEVC NAL header: forbidden_zero_bit(1) | nal_unit_type(6) | ...; 16...21 are IRAP (key) pictures.
      let unitType = (bytes[offset] >> 1) & 0x3F
      if (16...21).contains(unitType) { isKeyframe = true }
      units.append(contentsOf: startCode)
      units.append(contentsOf: bytes[offset..<(offset + unitLength)])
      offset += unitLength
    }
    guard !units.isEmpty else { return nil }

    var out = Data(capacity: units.count + 256)
    if isKeyframe {
      for index in 0..<parameterSetCount {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
          format,
          parameterSetIndex: index,
          parameterSetPointerOut: &pointer,
          parameterSetSizeOut: &size,
          parameterSetCountOut: nil,
          nalUnitHeaderLengthOut: nil
        ) == noErr, let pointer {
          out.append(contentsOf: startCode)
          out.append(pointer, count: size)
        }
      }
    }
    out.append(units)
    return (out, isKeyframe)
  }
}
