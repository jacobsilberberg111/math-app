import Foundation

/// Tool definitions for code blocks: `code` (put a block on the page, optionally run it) and
/// `run_code` (run a block, or test a snippet off the page). Static, so every request sends the
/// same tools and the prompt cache stays warm.
enum CodeTools {
    static let stdinSchema: JSONValue = [
        "type": "array",
        "items": ["type": "string"],
        "description": "Program input: one string per input() call, in order (e.g. [\"Sam\", \"14\"]).",
    ]

    static let definitions: [JSONValue] = [
        TutorTools.tool("code",
             "Put a code block on the page: typed code with line numbers and syntax highlighting and, for Python, an output panel. Use it for short worked examples, a starter the student finishes, or NESA-style pseudocode (language \"pseudocode\", never run: keywords in capitals and indented blocks — BEGIN … END, IF … THEN … ELSE … ENDIF, WHILE … ENDWHILE, FOR i = 1 TO 10 STEP 1 … NEXT i (or ENDFOR), REPEAT … UNTIL, CASEWHERE x OF … OTHERWISE … ENDCASE, GET/INPUT and DISPLAY/OUTPUT, subprograms as BEGIN name(parameters) … END name; if the student's notes use a variant such as BEGIN SUBPROGRAM, follow theirs). Keep examples short (ideally under 20 lines), runnable and at the student's level. Don't paste a corrected copy of the student's program: point at their lines and ask instead. With run: true the Python runs first and its output is stored on the block and returned to you, so you never guess what it prints. The result gives every line's page y, so you can `annotate` a specific line afterwards.",
             TutorTools.object([
                ("page", TutorTools.page), ("x", TutorTools.x), ("y", TutorTools.y),
                ("width", TutorTools.prop("number", "Card width in points (default 560, min 300).")),
                ("language", TutorTools.enumProp(["python", "pseudocode"], "Default python.")),
                ("title", TutorTools.prop("string", "Optional short title shown on the card, e.g. \"Times tables\".")),
                ("stdin", stdinSchema),
                ("run", TutorTools.prop("boolean", "Python only: run it now and show the output on the block (default false).")),
                ("code", TutorTools.prop("string", "The code: \\n between lines, 4 spaces per indent level.")),
             ], required: ["code"])),

        TutorTools.tool("run_code",
             "Run Python and get back exactly what it prints, any error (traceback with the student's line numbers) and whether it was stopped for running over 10 seconds (an infinite loop). Give element_id to run a code block on the page (the student's or yours): its output is stored on the block, as if the student tapped Run. Or give code to test something without putting it on the page: check a fix, an edge case or an expected output before you tell the student. Always run code before claiming what it outputs or where it fails. input() reads the program input one line per call and echoes it like IDLE.",
             TutorTools.object([
                ("element_id", TutorTools.prop("string", "A Python code block on the page to run.")),
                ("code", TutorTools.prop("string", "Instead of element_id: Python to test off the page (the student doesn't see it).")),
                ("stdin", ["type": "array", "items": ["type": "string"],
                           "description": "Program input, one string per input() call. With element_id this replaces the block's own input for this run only, and the block keeps its last output."]),
             ], required: [])),
    ]
}
