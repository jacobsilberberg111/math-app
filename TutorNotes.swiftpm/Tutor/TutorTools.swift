import Foundation

/// The tutor's hands: every canvas action it can take, as Claude tool definitions.
///
/// The set is fixed for the whole conversation (changing tools mid-conversation would break
/// the prompt cache and preserved thinking). Tools that stream long text list their position
/// properties first so the canvas can start writing before the text has finished generating.
enum TutorTools {
    static let colorEnum: JSONValue = .array(["red", "blue", "green", "purple", "orange", "black", "teal", "pink", "gray"].map { .string($0) })

    static func prop(_ type: String, _ description: String) -> JSONValue {
        ["type": .string(type), "description": .string(description)]
    }

    static func enumProp(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
    }

    static func object(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (k, v) in properties { props[k] = v }
        return ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })]
    }

    static func tool(_ name: String, _ description: String, _ schema: JSONValue) -> JSONValue {
        // Eager input streaming lets text appear on the page as it is generated; inputs are
        // validated client-side before anything is committed.
        ["name": .string(name), "description": .string(description), "input_schema": schema, "eager_input_streaming": true]
    }

    static let page = prop("integer", "Page number (1-based). Use pages.count + 1 to start a new page.")
    static let x = prop("number", "Left edge in page points (0–816).")
    static let y = prop("number", "Top edge in page points (0 at the top of the page).")
    static let color: JSONValue = ["type": "string", "enum": colorEnum, "description": "Ink colour."]

    static let definitions: JSONValue = .array([
        tool("write",
             "Write on the page in your handwriting: explanations, hints, encouragement, short working, labels. Inline math goes in $...$ as LaTeX (e.g. \"so $x = \\\\frac{3}{2}$\"). Your writing appears on the canvas live as you produce it. Keep each block short (one idea); use several calls for longer explanations. Avoid writing over the student's ink.",
             object([
                ("page", page), ("x", x), ("y", y),
                ("width", prop("number", "Wrap width in points (default 360, max 736).")),
                ("style", enumProp(["handwriting", "typed", "heading", "note", "sticky"], "handwriting (default) for normal tutor writing; heading for titles; note for a side remark with an accent bar; sticky for a sticky note.")),
                ("color", color),
                ("size", enumProp(["small", "medium", "large"], "Text size (default medium).")),
                ("text", prop("string", "What to write. Use \\n for new lines and $...$ for math.")),
             ], required: ["page", "x", "y", "text"])),

        tool("write_math",
             "Typeset display math: equations and multi-step algebra, one LaTeX line per entry, automatically aligned on the first = (or <, ≤, ...). Prefer this over `write` for working that is mostly math. Supports \\frac, \\sqrt, ^, _, \\int, \\sum, \\lim, \\left( \\right), matrices (pmatrix), cases, \\vec, \\overline, Greek letters, \\color{red}{...}.",
             object([
                ("page", page), ("x", x), ("y", y),
                ("size", enumProp(["small", "medium", "large"], "Default medium.")),
                ("color", color),
                ("lines", ["type": "array", "items": ["type": "string"], "description": "LaTeX lines, without $ delimiters."]),
             ], required: ["page", "x", "y", "lines"])),

        tool("draw",
             "Draw freehand ink with your pen: diagrams, geometry figures, triangles, vectors, arrows connecting ideas, sketches of curves. Points are page coordinates and get smoothed into natural pen strokes (set closed for polygons). For accurate function graphs use `graph` instead.",
             object([
                ("page", page),
                ("strokes", ["type": "array", "description": "Each stroke is one pen movement.",
                             "items": object([
                                ("points", ["type": "array", "description": "[[x, y], ...] in page points.",
                                            "items": ["type": "array", "items": ["type": "number"]]]),
                                ("closed", prop("boolean", "Join the last point back to the first.")),
                                ("sharp", prop("boolean", "Keep straight segments and corners (no smoothing), e.g. for triangles.")),
                             ], required: ["points"])]),
                ("color", color),
                ("width", prop("number", "Pen width 1–10 (default 2.5).")),
                ("style", enumProp(["pen", "highlighter"], "Default pen.")),
                ("labels", ["type": "array", "description": "Short labels placed at points, e.g. vertex names or side lengths. Math allowed with $...$.",
                            "items": object([("x", prop("number", "x")), ("y", prop("number", "y")), ("text", prop("string", "Label"))], required: ["x", "y", "text"])]),
             ], required: ["page", "strokes"])),

        tool("annotate",
             "Mark up the student's work like a teacher with a red pen: circle, underline, box, arrow, highlight, strike, bracket, tick, cross, question mark or star. Give the target rectangle tightly around the content (x, y, width, height) — or from/to points for an arrow. Add a very short label when useful (\"sign error\", \"check this\"). Prefer this over `draw` for marking up.",
             object([
                ("page", page),
                ("mark", enumProp(["circle", "underline", "box", "arrow", "highlight", "strike", "bracket", "tick", "cross", "question", "star"], "Kind of mark.")),
                ("x", x), ("y", y),
                ("width", prop("number", "Target width.")),
                ("height", prop("number", "Target height.")),
                ("from_x", prop("number", "Arrow start x.")), ("from_y", prop("number", "Arrow start y.")),
                ("to_x", prop("number", "Arrow tip x.")), ("to_y", prop("number", "Arrow tip y.")),
                ("color", color),
                ("label", prop("string", "Optional short note written beside the mark.")),
             ], required: ["page", "mark"])),

        tool("graph",
             "Create (or update) a Cartesian plane with axes, grid and numbered ticks. Functions are expressions in x such as \"x^2 - 3x + 2\", \"2sin(x)\", \"1/(x-1)\", \"e^(-x)\", \"\\\\sqrt{x}\", \"|x|\". Add points, segments/vectors, dashed guide lines (asymptotes x=a or y=b) and shaded regions (area under/between curves). Leave functions empty for a blank plane the student can sketch on. To add to an existing graph pass graph_id with just the new items.",
             object([
                ("graph_id", prop("string", "Existing graph element id to update.")),
                ("page", page), ("x", x), ("y", y),
                ("width", prop("number", "Default 440.")), ("height", prop("number", "Default 340.")),
                ("x_min", prop("number", "Default -10.")), ("x_max", prop("number", "Default 10.")),
                ("y_min", prop("number", "Default -10.")), ("y_max", prop("number", "Default 10.")),
                ("x_step", prop("number", "Tick spacing on x (optional).")), ("y_step", prop("number", "Tick spacing on y (optional).")),
                ("grid", prop("boolean", "Show grid lines (default true).")),
                ("title", prop("string", "Optional title; math allowed with $...$.")),
                ("x_label", prop("string", "Default x.")), ("y_label", prop("string", "Default y.")),
                ("functions", ["type": "array", "items": object([
                    ("expression", prop("string", "Expression in x.")), ("label", prop("string", "Legend label, e.g. $y=x^2$.")),
                    ("color", color), ("dashed", prop("boolean", "Dashed curve.")),
                    ("domain_min", prop("number", "Only draw for x ≥ this.")), ("domain_max", prop("number", "Only draw for x ≤ this.")),
                ], required: ["expression"])]),
                ("points", ["type": "array", "items": object([
                    ("x", prop("number", "x")), ("y", prop("number", "y")), ("label", prop("string", "e.g. A(2, 3)")),
                    ("color", color), ("open", prop("boolean", "Hollow point.")),
                ], required: ["x", "y"])]),
                ("segments", ["type": "array", "items": object([
                    ("x1", prop("number", "x1")), ("y1", prop("number", "y1")), ("x2", prop("number", "x2")), ("y2", prop("number", "y2")),
                    ("color", color), ("dashed", prop("boolean", "Dashed.")), ("arrow", prop("boolean", "Arrow head at (x2, y2), for vectors.")),
                    ("label", prop("string", "Label at the midpoint.")),
                ], required: ["x1", "y1", "x2", "y2"])]),
                ("guides", ["type": "array", "description": "Dashed reference lines: give x for x = a, or y for y = b.", "items": object([
                    ("x", prop("number", "Vertical line x = this.")), ("y", prop("number", "Horizontal line y = this.")),
                    ("color", color), ("label", prop("string", "Label.")),
                ], required: [])]),
                ("shade", ["type": "array", "description": "Shaded regions between upper and lower expressions (omit one to use the x-axis) for x in [from, to].", "items": object([
                    ("upper", prop("string", "Upper boundary expression.")), ("lower", prop("string", "Lower boundary expression.")),
                    ("from", prop("number", "Start x.")), ("to", prop("number", "End x.")), ("color", color),
                ], required: ["from", "to"])]),
             ], required: [])),

        tool("number_line",
             "Draw a number line with ticks, labelled points (open/closed circles) and intervals — for inequalities, ordering numbers, fractions and negatives.",
             object([
                ("page", page), ("x", x), ("y", y),
                ("width", prop("number", "Default 520.")),
                ("min", prop("number", "Smallest value.")), ("max", prop("number", "Largest value.")),
                ("step", prop("number", "Tick spacing (default 1).")),
                ("label_every", prop("integer", "Label every nth tick (default 1).")),
                ("points", ["type": "array", "items": object([
                    ("value", prop("number", "Position.")), ("label", prop("string", "Label.")),
                    ("open", prop("boolean", "Open circle.")), ("color", color),
                ], required: ["value"])]),
                ("intervals", ["type": "array", "items": object([
                    ("from", prop("number", "Start (omit for −∞).")), ("to", prop("number", "End (omit for +∞).")),
                    ("open_start", prop("boolean", "Open at start.")), ("open_end", prop("boolean", "Open at end.")), ("color", color),
                ], required: [])]),
                ("color", color),
             ], required: ["page", "min", "max"])),

        tool("table",
             "Draw a table (values tables, frequency tables, comparisons). Cells may contain $math$.",
             object([
                ("page", page), ("x", x), ("y", y),
                ("width", prop("number", "Maximum width (default fits content).")),
                ("rows", ["type": "array", "items": ["type": "array", "items": ["type": "string"]], "description": "Rows of cell strings."]),
                ("header", prop("boolean", "First row is a header (default true).")),
             ], required: ["page", "rows"])),

        tool("add_question",
             "Add a practice question card with an answer space for the student to write in. It is placed automatically in free space (or on a new page). The answer key, worked solution and hint are hidden from the student — keep them accurate; they are used for marking and reveals.",
             object([
                ("prompt", prop("string", "The question as the student will see it. Math in $...$.")),
                ("marks", prop("integer", "Marks available (default 1).")),
                ("answer_space", prop("number", "Height of the answer area in points (default 200; use 300+ for multi-step working, 360 if they need to sketch).")),
                ("answer", prop("string", "Final answer (hidden).")),
                ("solution", prop("string", "Concise worked solution (hidden). Math in $...$.")),
                ("hint", prop("string", "A first hint that doesn't give the answer away (hidden until requested).")),
                ("topic", prop("string", "Topic tag.")),
                ("difficulty", enumProp(["easy", "medium", "hard", "exam"], "Difficulty.")),
                ("page", prop("integer", "Optional page to place it on.")),
                ("y", prop("number", "Optional top y on that page.")),
                ("new_page", prop("boolean", "Start a new page for this question.")),
             ], required: ["prompt", "answer", "solution"])),

        tool("mark",
             "Mark a question or a piece of work with a red/green pen tick, cross or partial mark, record the result, and optionally write a brief comment. For question cards pass question (its number) and the mark is placed automatically; otherwise give page, x and y for where the mark goes.",
             object([
                ("question", prop("integer", "Question number (e.g. 2 for Q2).")),
                ("page", page), ("x", prop("number", "Mark position x.")), ("y", prop("number", "Mark position y.")),
                ("verdict", enumProp(["correct", "incorrect", "partial"], "Result.")),
                ("score", prop("string", "e.g. \"2/3\".")),
                ("comment", prop("string", "Very short feedback written next to the mark. Math in $...$.")),
             ], required: ["verdict"])),

        tool("move",
             "Move an element (yours or the student's text/image/graph) to a new position.",
             object([("element_id", prop("string", "Element id, e.g. e12.")), ("page", page), ("x", x), ("y", y)],
                    required: ["element_id", "x", "y"])),

        tool("edit",
             "Change the content of one of your text, math or question elements (fix a typo, update a hint).",
             object([
                ("element_id", prop("string", "Element id.")),
                ("text", prop("string", "New text (for text elements or a question prompt).")),
                ("lines", ["type": "array", "items": ["type": "string"], "description": "New LaTeX lines (math elements)."]),
                ("color", color),
             ], required: ["element_id"])),

        tool("delete",
             "Delete elements. Delete your own marks freely; delete the student's elements only when they ask.",
             object([("element_ids", ["type": "array", "items": ["type": "string"], "description": "Ids to delete."])],
                    required: ["element_ids"])),

        tool("erase_ink",
             "Erase the student's handwriting inside a rectangle. Only when the student explicitly asks you to erase or clean up.",
             object([("page", page), ("x", x), ("y", y), ("width", prop("number", "Width.")), ("height", prop("number", "Height."))],
                    required: ["page", "x", "y", "width", "height"])),

        tool("add_page",
             "Add a blank page (for example before a new set of questions or a fresh worked example). Returns its page number.",
             object([
                ("after_page", prop("integer", "Insert after this page (default: at the end).")),
                ("paper", enumProp(["blank", "ruled", "grid", "dots", "graph"], "Paper style (default: same as the note).")),
             ], required: [])),

        tool("focus",
             "Draw the student's attention to a region: scrolls their view there and pulses it, with an optional short speech bubble (\"Look at the sign here\").",
             object([("page", page), ("x", x), ("y", y), ("width", prop("number", "Width.")), ("height", prop("number", "Height.")),
                     ("message", prop("string", "Optional short bubble text."))],
                    required: ["page", "x", "y", "width", "height"])),

        tool("clear_marks",
             "Remove your own writing and marks (never the student's) from one page, or from the whole note if page is omitted.",
             object([("page", page)], required: [])),

        tool("remember",
             "Save one short, durable note about this student for future sessions — a misconception, a strength, a preference, a goal. Use sparingly; don't store things that only matter today.",
             object([("note", prop("string", "The note, one sentence."))], required: ["note"])),
    ])

    /// Tools whose text streams onto the canvas while it is generated.
    static let liveTools: Set<String> = ["write", "write_math"]
}
