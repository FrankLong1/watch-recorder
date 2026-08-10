import Foundation
import Testing

@Suite("MemoDelivery")
struct MemoDeliveryTests {

    @Test("metadata round-trips its watch-generated identity")
    func metadataRoundTrip() {
        let id = UUID()
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = MemoDelivery.metadata(id: id, recordedAt: recordedAt, duration: 12.5)

        #expect(MemoDelivery.decodeMetadata(metadata) == .init(
            id: id,
            recordedAt: recordedAt,
            duration: 12.5
        ))
    }

    @Test("malformed metadata is rejected instead of receiving a new identity")
    func malformedMetadataIsRejected() {
        #expect(MemoDelivery.decodeMetadata([
            "id": "not-a-uuid",
            "createdAt": 1_700_000_000.0,
            "duration": 10.0
        ]) == nil)
        #expect(MemoDelivery.decodeMetadata([
            "id": UUID().uuidString,
            "createdAt": 1_700_000_000.0
        ]) == nil)
    }

    @Test("only the exact ingest receipt acknowledges an upload")
    func exactIngestReceipt() {
        #expect(MemoDelivery.isIngestReceipt(status: 204))
        #expect(!MemoDelivery.isIngestReceipt(status: 200))
        #expect(!MemoDelivery.isIngestReceipt(status: 201))
        #expect(!MemoDelivery.isIngestReceipt(status: nil))
    }
}
