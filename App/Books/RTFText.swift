import Foundation

/// Plockar ut texten ur en RTF-fil. Formatering (fetstil, typsnitt, färger) tas bort, stycken behålls.
/// Egen läsare i stället för NSAttributedString, som hör till huvudtråden och här körs i bakgrunden.
enum RTFText {

    /// Grupper som bara innehåller inställningar och aldrig text.
    private static let skippedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "headerl", "headerr",
        "footerl", "footerr", "footnote", "listtable", "listoverridetable", "rsidtbl", "generator",
        "xmlnstbl", "themedata", "colorschememapping", "datastore", "latentstyles", "filetbl", "revtbl",
    ]

    static func plainText(from data: Data) -> String {
        let bytes = [UInt8](data)
        var output = ""
        var pendingBytes: [UInt8] = []
        // Per grupp: om texten hoppas över, och hur många tecken som ska hoppas över efter \u.
        var skipStack: [Bool] = [false]
        var unicodeSkip = 1
        var skipAfterUnicode = 0
        var index = 0

        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            output += String(bytes: pendingBytes, encoding: .windowsCP1252)
                ?? String(bytes: pendingBytes, encoding: .isoLatin1) ?? ""
            pendingBytes.removeAll()
        }

        func emit(_ text: String) {
            guard skipStack.last != true else { return }
            flushBytes()
            output += text
        }

        func emitByte(_ byte: UInt8) {
            guard skipStack.last != true else { return }
            if skipAfterUnicode > 0 {
                skipAfterUnicode -= 1
                return
            }
            pendingBytes.append(byte)
        }

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x7B: // {
                skipStack.append(skipStack.last ?? false)
                index += 1
            case 0x7D: // }
                if skipStack.count > 1 {
                    skipStack.removeLast()
                }
                index += 1
            case 0x5C: // \
                index += 1
                guard index < bytes.count else { break }
                let next = bytes[index]
                if next == 0x27, index + 2 < bytes.count,
                   let value = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                    emitByte(value)
                    index += 3
                } else if next == 0x2A { // \* betyder att gruppen kan hoppas över
                    skipStack[skipStack.count - 1] = true
                    index += 1
                } else if isLetter(next) {
                    var end = index
                    while end < bytes.count, isLetter(bytes[end]) {
                        end += 1
                    }
                    let word = String(bytes: bytes[index..<end], encoding: .ascii) ?? ""
                    var numberEnd = end
                    if numberEnd < bytes.count, bytes[numberEnd] == 0x2D {
                        numberEnd += 1
                    }
                    while numberEnd < bytes.count, bytes[numberEnd] >= 0x30, bytes[numberEnd] <= 0x39 {
                        numberEnd += 1
                    }
                    let parameter = Int(String(bytes: bytes[end..<numberEnd], encoding: .ascii) ?? "")
                    index = numberEnd
                    if index < bytes.count, bytes[index] == 0x20 {
                        index += 1
                    }
                    if skippedDestinations.contains(word) {
                        skipStack[skipStack.count - 1] = true
                        continue
                    }
                    switch word {
                    case "par", "line", "sect", "page":
                        emit("\n")
                    case "tab":
                        emit("\t")
                    case "uc":
                        unicodeSkip = parameter ?? 1
                    case "u":
                        if var code = parameter {
                            if code < 0 {
                                code += 65_536
                            }
                            if let scalar = Unicode.Scalar(code) {
                                emit(String(Character(scalar)))
                            }
                            skipAfterUnicode = unicodeSkip
                        }
                    case "emdash":
                        emit("\u{2014}")
                    case "endash":
                        emit("\u{2013}")
                    case "lquote":
                        emit("\u{2018}")
                    case "rquote":
                        emit("\u{2019}")
                    case "ldblquote":
                        emit("\u{201C}")
                    case "rdblquote":
                        emit("\u{201D}")
                    case "bullet":
                        emit("\u{2022}")
                    default:
                        break
                    }
                } else {
                    // \\, \{ och \} är tecknen själva. \~ är hårt mellanslag.
                    if next == 0x7E {
                        emit("\u{00A0}")
                    } else if next == 0x2D {
                        emit("\u{00AD}")
                    } else if next == 0x5F {
                        emit("\u{2011}")
                    } else if next == 0x0A || next == 0x0D {
                        emit("\n")
                    } else {
                        emitByte(next)
                    }
                    index += 1
                }
            case 0x0A, 0x0D:
                index += 1
            default:
                emitByte(byte)
                index += 1
            }
        }
        flushBytes()
        return output
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}
