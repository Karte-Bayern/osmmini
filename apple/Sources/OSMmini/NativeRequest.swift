import COSMmini
import Darwin
import Foundation

// Encode the native envelope directly instead of serializing model values to
// JSON, decoding them into Foundation dictionaries, then encoding them again.
struct NativeRequest: Encodable, Sendable {
  let action: String
  var engine: UInt64? = nil
  var path: String? = nil
  var importOptions: ImportOptions? = nil
  var query: String? = nil
  var limit: Int? = nil
  var route: RouteRequest? = nil
  var z: Int? = nil
  var x: Int? = nil
  var y: Int? = nil

  enum CodingKeys: String, CodingKey {
    case action, engine, path, query, limit, route, z, x, y
    case importOptions = "import"
  }
}

enum NativeJSONBuffer {
  // The C ABI returns malloc-owned UTF-8. Transfer ownership to Data so that
  // JSONDecoder can read the same bytes without a String and a second buffer.
  // The deallocator may run on any thread; OSMminiFree only calls libc free.
  static func take(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
    guard let pointer else { throw OSMminiError.invalidResponse }
    return Data(
      bytesNoCopy: pointer, count: strlen(pointer),
      deallocator: .custom { buffer, _ in
        OSMminiFree(buffer.assumingMemoryBound(to: CChar.self))
      })
  }
}
