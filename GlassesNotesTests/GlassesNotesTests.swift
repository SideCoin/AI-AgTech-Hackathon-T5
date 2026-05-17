//
//  GlassesNotesTests.swift
//  GlassesNotesTests
//
//  Created by Shizun Yang on 5/15/26.
//

import Testing
@testable import GlassesNotes

struct GlassesNotesTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func endNoteStripsPhraseCaseInsensitively() {
        let raw = "There is some leaf damage on row three End Note"
        let cleaned = raw.replacingOccurrences(
            of: "end note",
            with: "",
            options: .caseInsensitive
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cleaned == "There is some leaf damage on row three")
    }
}
