import SDL2
import Foundation

enum Glyphs {
    static let glyphs: [Character: [Int]] = [
            "×":[0,0,17,10,4,10,17],
            "/":[1,2,2,4,8,8,16], "_":[0,0,0,0,0,0,31], "+":[0,4,4,31,4,4,0],
            "[":[14,8,8,8,8,8,14], "]":[14,2,2,2,2,2,14], "(":[2,4,8,8,8,4,2], ")":[8,4,2,2,2,4,8],
            ",":[0,0,0,0,0,4,8], "'":[4,4,8,0,0,0,0],
            "=":[0,0,31,0,31,0,0], "<":[2,4,8,16,8,4,2], ">":[8,4,2,1,2,4,8],
            "%":[17,2,4,4,8,16,17], "!":[4,4,4,4,4,0,4],
            "*":[0,21,14,31,14,21,0], "#":[10,31,10,10,31,10,0],
            "A":[ 14,17,17,31,17,17,17], "B":[30,17,17,30,17,17,30], "C":[15,16,16,16,16,16,15], "D":[30,17,17,17,17,17,30], "E":[31,16,16,30,16,16,31], "F":[31,16,16,30,16,16,16], "G":[15,16,16,23,17,17,15], "H":[17,17,17,31,17,17,17], "I":[31,4,4,4,4,4,31], "J":[7,2,2,2,18,18,12], "K":[17,18,20,24,20,18,17], "L":[16,16,16,16,16,16,31], "M":[17,27,21,21,17,17,17], "N":[17,25,21,19,17,17,17], "O":[14,17,17,17,17,17,14], "P":[30,17,17,30,16,16,16], "Q":[14,17,17,17,21,18,13], "R":[30,17,17,30,20,18,17], "S":[15,16,16,14,1,1,30], "T":[31,4,4,4,4,4,4], "U":[17,17,17,17,17,17,14], "V":[17,17,17,17,17,10,4], "W":[17,17,17,21,21,21,10], "X":[17,17,10,4,10,17,17], "Y":[17,17,10,4,4,4,4], "Z":[31,1,2,4,8,16,31], "0":[14,17,19,21,25,17,14], "1":[4,12,4,4,4,4,14], "2":[14,17,1,2,4,8,31], "3":[30,1,1,14,1,1,30], "4":[2,6,10,18,31,2,2], "5":[31,16,16,30,1,1,30], "6":[14,16,16,30,17,17,14], "7":[31,1,2,4,8,8,8], "8":[14,17,17,14,17,17,14], "9":[14,17,17,15,1,1,14], " ":[0,0,0,0,0,0,0], "-":[0,0,0,31,0,0,0], ":":[0,4,0,0,4,0,0], ".":[0,0,0,0,0,6,6]
        ]
    static func rows(for char: Character) -> [Int] {
        glyphs[char] ?? [14,17,1,2,4,0,4]
    }
}

struct SDLBox {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var rect: SDL_Rect { SDL_Rect(x: Int32(x), y: Int32(y), w: Int32(width), h: Int32(height)) }
    func contains(_ x: Int, _ y: Int) -> Bool {
        x >= self.x && x < self.x + width && y >= self.y && y < self.y + height
    }
    func intersecting(_ other: SDLBox) -> SDLBox {
        let left = max(x, other.x), top = max(y, other.y)
        return SDLBox(x: left, y: top, width: max(0, min(x + width, other.x + other.width) - left), height: max(0, min(y + height, other.y + other.height) - top))
    }
}

struct SDLControl {
    let id: String
    let box: SDLBox
    let hitBox: SDLBox
    let field: Bool
    let enabled: Bool
}

/// Character offsets keep pasted Unicode safe, even with the small built-in bitmap font.
struct SDLTextEditor {
    let id: String
    var text: String
    var cursor: Int
    var anchor: Int
    var selection: Range<Int> { min(cursor, anchor)..<max(cursor, anchor) }
    init(id: String, text: String) {
        self.id = id
        self.text = text
        cursor = text.count
        anchor = 0
    }
    mutating func insert(_ value: String) {
        var chars = Array(text)
        let inserted = Array(value.filter { !$0.isNewline && !($0.asciiValue.map { $0 < 32 } ?? false) })
        chars.replaceSubrange(selection, with: inserted)
        cursor = selection.lowerBound + inserted.count
        anchor = cursor
        text = String(chars.prefix(512))
        cursor = min(cursor, text.count)
        anchor = cursor
    }
    mutating func move(to position: Int, selecting: Bool = false) {
        cursor = min(text.count, max(0, position))
        if !selecting { anchor = cursor }
    }
    mutating func delete(backward: Bool) {
        if selection.isEmpty {
            if backward { anchor = max(0, cursor - 1) }
            else { anchor = min(text.count, cursor + 1) }
        }
        insert("")
    }
    var selectedText: String { String(Array(text)[selection]) }
    func visibleStart(capacity: Int) -> Int { max(0, cursor - max(1, capacity) + 1) }
}

func wrappedSDLLines(_ text: String, columns: Int) -> [String] {
    let width = max(1, columns)
    return text.replacingOccurrences(of: "…", with: "...").replacingOccurrences(of: "•", with: "*").replacingOccurrences(of: "—", with: "-").split(separator: "\n", omittingEmptySubsequences: false).flatMap { paragraph -> [String] in
        var lines: [String] = []
        var line = ""
        for word in paragraph.split(separator: " ") {
            if !line.isEmpty && line.count + word.count + 1 > width { lines.append(line); line = "" }
            var remainder = String(word)
            while remainder.count > width {
                if !line.isEmpty { lines.append(line); line = "" }
                lines.append(String(remainder.prefix(width)))
                remainder = String(remainder.dropFirst(width))
            }
            if !remainder.isEmpty { line += (line.isEmpty ? "" : " ") + remainder }
        }
        lines.append(line)
        return lines
    }
}
