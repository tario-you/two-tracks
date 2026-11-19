import AppKit

// `WisprFree --dictate FILE`, `--eval N` and `--probe FILE` run checks without the window (Eval.swift).
let arguments = CommandLine.arguments
if let path = CLI.value("--dictate") {
  Task { @MainActor in await CLI.dictate(path); Engine.shared.shutdown(); exit(0) }
  RunLoop.main.run()
} else if let n = CLI.value("--eval").flatMap(Int.init) {
  Task { @MainActor in await CLI.eval(n); Engine.shared.shutdown(); exit(0) }
  RunLoop.main.run()
} else if let path = CLI.value("--probe") {
  Task { await CLI.probe(path); Engine.shared.shutdown(); exit(0) }
  RunLoop.main.run()
} else {
  let app = NSApplication.shared
  let delegate = MainActor.assumeIsolated { App() }
  app.delegate = delegate
  app.run()
}
