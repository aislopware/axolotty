import Darwin
@testable import AxMacUI
import Testing

/// What a pane's ended bar says, from the code the host reports (a shell's: 128 + signal).
@Suite("Ended bar")
struct EndedBarTests {
    @Test(arguments: [
        (Int32(-1), "Couldn’t start"), (0, "Exited with code 0"), (1, "Exited with code 1"),
        (128, "Exited with code 128"), (130, "Stopped with ⌃C"), (131, "Quit with ⌃\\"), (137, "Killed"),
        (143, "Terminated"), (139, "Crashed: segmentation fault"), (133, "Crashed: trap"), (157, "Ended by signal 29"),
        (160, "Exited with code 160"), (255, "Exited with code 255"),
    ])
    func aCodeIsSaidAsWhatEndedTheProgram(code: Int32, words: String) {
        #expect(EndedBar.describe(code) == words)
    }
}
