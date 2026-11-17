// Prints the metadata Apple's frameworks read from a movie (as Photos, Finder and Maps see it). Used by suite.py.
import AVFoundation
let a = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let sem = DispatchSemaphore(value: 0)
Task {
  let md = try await a.load(.metadata)
  for i in md { let k = i.identifier?.rawValue ?? "?"; let v = try? await i.load(.stringValue); print(k, v ?? "-") }
  let cd = try await a.load(.creationDate); print("creationDate:", (try? await cd?.load(.dateValue)).map{"\($0!)"} ?? "nil")
  let tr = try await a.load(.tracks); print("tracks:", tr.map{$0.mediaType.rawValue})
  sem.signal()
}
sem.wait()
