import Foundation

@main
struct ProgressModelChecks {
    static func main() {
        let decoded = TransferProgress(event: ["bytes": 10_000_000, "decoded_bytes": 50_000_000,
                                                "total_decoded_bytes": 100_000_000])
        precondition(decoded.fraction == 0.5 && decoded.estimated,
                     "Compressed wire bytes must not be divided by a decoded-size hint")
        let exact = TransferProgress(event: ["bytes": 5_000_000, "total_bytes": 20_000_000,
                                              "decoded_bytes": 90_000_000, "total_decoded_bytes": 100_000_000])
        precondition(exact.fraction == 0.25 && !exact.estimated,
                     "A known wire length takes precedence over the sender hint")
        precondition(TransferProgress(event: ["bytes": 1, "total_files": 1]).fraction == nil,
                     "Unknown single-file sizes need an activity indicator, not an invented percentage")
        precondition(TransferProgress(event: ["files_received": 3, "total_files": 10]).fraction == 0.3)
        precondition(TransferProgress(event: ["bytes": 30, "total_bytes": 20]).fraction! < 1,
                     "100% is reserved for confirmed completion")
        print("PASS: progress units, estimation, unknown size, file-count fallback, completion boundary")
    }
}
