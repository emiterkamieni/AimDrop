import Foundation

@main
struct ProgressModelChecks {
    static func main() {
        L10n.configure(.english)
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
        let progress = TransferProgress(event: ["bytes": 1_500_000, "total_bytes": 2_000_000, "files_received": 0, "total_files": 1])
        precondition(progress.text == "Received 1.5 MB of 2 MB · 0 of 1 file")
        precondition(!progress.text.contains("%") && !decoded.text.contains("%"))
        precondition(TransferSummary.describe(names: ["photo.jpg", "clip.mov", "notes.txt"]) == "1 photo, 1 video and 1 file")
        precondition(TransferSummary.files(0) == "0 files" && TransferSummary.files(1) == "1 file")
        L10n.configure(.polish)
        precondition(progress.text == "Odebrano 1,5 MB z 2 MB · 0 z 1 pliku")
        precondition(TransferSummary.describe(names: ["photo.jpg", "clip.mov", "notes.txt"]) == "1 zdjęcie, 1 wideo i 1 plik")
        let counts = [0, 1, 2, 5, 12, 21, 22, 101, 112]
        let expected = ["0 plików", "1 plik", "2 pliki", "5 plików", "12 plików", "21 plików", "22 pliki", "101 plików", "112 plików"]
        precondition(counts.map { TransferSummary.files($0) } == expected)
        precondition(!progress.text.contains("%"))
        print("PASS: progress units, estimation, unknown size, file-count fallback, completion boundary")
        print("PASS: live language switch, localized byte counts, English/Polish summaries and count grammar, no visible percentages")
    }
}
