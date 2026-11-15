import CoreGraphics
import Foundation
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
}
