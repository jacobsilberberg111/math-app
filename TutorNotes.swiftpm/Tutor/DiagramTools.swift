import Foundation

/// Tool definitions for flowcharts, labelled diagrams and finding real diagrams.
enum DiagramTools {
    typealias T = TutorTools

    static let definitions: [JSONValue] = [
        T.tool("flowchart",
               "Draw a flowchart or process diagram; boxes and arrows are laid out for you. Use for processes and sequences (stimulus → response, the immune response, how a disease spreads), algorithms (decision diamonds with Yes/No arrows, loops back), causes and consequences, timelines (direction right), cycles (direction cycle: water cycle, carbon cycle, life cycles) and essay plans. Keep box text short (under about eight words; $math$ allowed). It's placed in free space near x, y and scaled to fit; the result gives each box's position so you can annotate it.",
               T.object([
                ("page", T.page), ("x", T.x), ("y", T.y),
                ("title", T.prop("string", "Optional title above the chart.")),
                ("direction", T.enumProp(["down", "right", "cycle"], "down (default) for processes and algorithms; right for timelines and chains; cycle to arrange stages round a circle.")),
                ("nodes", ["type": "array", "description": "The boxes, in flow order.",
                           "items": T.object([
                            ("id", T.prop("string", "Short unique id used by edges, e.g. \"start\", \"q1\".")),
                            ("text", T.prop("string", "What the box says.")),
                            ("shape", T.enumProp(["process", "decision", "terminal", "io", "note", "circle"], "process (default) a step; decision a yes/no question (diamond); terminal start/end; io input/output; note plain text; circle a stage in a cycle.")),
                            ("color", T.color),
                           ], required: ["id", "text"])]),
                ("edges", ["type": "array", "description": "Arrows. For direction cycle, omit to join each stage to the next and the last back to the first.",
                           "items": T.object([
                            ("from", T.prop("string", "Node id the arrow starts at.")),
                            ("to", T.prop("string", "Node id it points to.")),
                            ("label", T.prop("string", "Optional short label, e.g. \"Yes\", \"No\", \"causes\".")),
                           ], required: ["from", "to"])]),
                ("max_width", T.prop("number", "Largest width in points (default fits the page).")),
               ], required: ["nodes"])),

        T.tool("find_diagram",
               "Find a real, freely licensed diagram or photo on Wikimedia Commons (cells, organs, body systems, pathogens, apparatus, landforms, maps of historical events, artworks…) and place it on the page with a credit line. The result includes the image with a page-coordinate grid drawn over it, so you can point at its parts accurately with label_diagram or annotate. Search with plain English nouns (\"human heart diagram\", \"animal cell diagram\", \"neuron structure\", \"oxbow lake formation\"); add \"unlabelled\" or \"blank\" when you want to label it yourself or make a labelling quiz. If the image isn't right, delete it and call again with pick (another candidate from the list) or a better query.",
               T.object([
                ("query", T.prop("string", "What to search for.")),
                ("pick", T.prop("integer", "Which candidate from a previous search's list to use (1-based). Default: the best match.")),
                ("page", T.page), ("x", T.x), ("y", T.y),
                ("width", T.prop("number", "Width on the page (default 380, max 600).")),
               ], required: ["query"])),

        T.tool("label_diagram",
               "Label parts of a picture or diagram with neat labels and leader lines. Give each label the exact page point it should touch (read it from the image's grid or the page snapshot); labels are arranged in columns beside the picture for you, without overlapping. With quiz true the labels become numbered blanks for the student to fill in (answers hidden, kept for marking), and cover hides labels already printed on the picture. To reveal answers on an existing quiz, pass its element id as labels_id with reveal.",
               T.object([
                ("element_id", T.prop("string", "The image (or other element) being labelled. Or give page, x, y, width, height for a region of the page.")),
                ("page", T.page), ("x", T.x), ("y", T.y),
                ("width", T.prop("number", "Region width (when there's no element_id).")),
                ("height", T.prop("number", "Region height (when there's no element_id).")),
                ("labels", ["type": "array", "description": "One per part.",
                            "items": T.object([
                                ("text", T.prop("string", "The label (in a quiz, the hidden answer).")),
                                ("x", T.prop("number", "Page x of the point on the part.")),
                                ("y", T.prop("number", "Page y of the point on the part.")),
                            ], required: ["text", "x", "y"])]),
                ("quiz", T.prop("boolean", "Numbered blanks instead of labels (default false).")),
                ("cover", ["type": "array", "description": "Page rectangles to paint over (labels printed on the picture).",
                           "items": T.object([("x", T.prop("number", "x")), ("y", T.prop("number", "y")),
                                              ("width", T.prop("number", "Width")), ("height", T.prop("number", "Height"))],
                                             required: ["x", "y", "width", "height"])]),
                ("title", T.prop("string", "Optional title above the picture.")),
                ("color", T.color),
                ("labels_id", T.prop("string", "An existing labels element, to reveal answers.")),
                ("reveal", ["type": "array", "items": ["type": "integer"], "description": "Blank numbers to reveal (with labels_id); empty for all."]),
               ], required: [])),
    ]
}
