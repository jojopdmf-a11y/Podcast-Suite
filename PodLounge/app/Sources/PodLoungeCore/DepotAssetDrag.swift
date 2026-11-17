import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Private pasteboard type for a depot row. The app's Info.plist exports it.
    /// A generic `public.json` type is not used: the system does not treat it as
    /// this app's drag, so a lane can miss the drop.
    public static let podLoungeDepotAsset = UTType(
        exportedAs: "com.cougarcalc.podlounge.depot-asset",
        conformingTo: .data
    )
}

/// The id of one depot file, carried from the depot list onto a TheCut lane.
public struct DepotAssetDrag: Codable, Transferable, Equatable, Sendable {
    public var assetID: String

    public init(assetID: String) {
        self.assetID = assetID
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .podLoungeDepotAsset)
        ProxyRepresentation { drag in
            drag.assetID
        } importing: { assetID in
            DepotAssetDrag(assetID: assetID)
        }
    }

    /// JSON payload written onto the drag pasteboard.
    public func encodedPayload() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Reads the JSON payload, or a plain asset-id string from the proxy form.
    public static func assetID(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(DepotAssetDrag.self, from: data) {
            let id = decoded.assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty == false { return id }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("{") || trimmed.contains("\n") || trimmed.contains("\0") {
            return nil
        }
        return trimmed
    }

    /// Item the depot row gives to `.onDrag`. The bytes are stored on the provider
    /// so a lane can read them during the drop, without a second load pass.
    public func itemProvider() -> NSItemProvider {
        let data = (try? encodedPayload()) ?? Data(assetID.utf8)
        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.podLoungeDepotAsset.identifier)
    }

    /// Seconds from the left edge of a lane. `dropX` is in that lane's coordinates.
    public static func timelineSeconds(dropX: CGFloat, pixelsPerSecond: CGFloat) -> Double {
        guard pixelsPerSecond > 0 else { return 0 }
        return max(0, Double(dropX / pixelsPerSecond))
    }
}
