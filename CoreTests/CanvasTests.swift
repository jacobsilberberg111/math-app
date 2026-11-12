import Foundation

/// The Canvas client's parsing and text formatting (no network).
func runCanvasTests() {
    // Pagination links, as the tutor server rewrites them (relative to the server).
    let server = URL(string: "https://tutor-server-production.up.railway.app")!
    let link = #"</canvas/api/v1/courses?page=1&per_page=50>; rel="current",</canvas/api/v1/courses?page=2&per_page=50>; rel="next", </canvas/api/v1/courses?page=5&per_page=50>; rel="last""#
    check(CanvasClient.nextLink(link, relativeTo: server)?.absoluteString == "https://tutor-server-production.up.railway.app/canvas/api/v1/courses?page=2&per_page=50", "next link")
    check(CanvasClient.nextLink(#"</canvas/api/v1/a?page=1>; rel="current""#, relativeTo: server) == nil, "no next link")
    check(CanvasClient.nextLink(nil, relativeTo: server) == nil, "no header")

    // Telling the server's own errors from Canvas's.
    check(CanvasClient.error(status: 401, body: Data(#"{"type":"error","error":{"type":"authentication_error"}}"#.utf8)) == .serverRejected, "relay token rejected")
    check(CanvasClient.error(status: 401, body: Data(#"{"errors":[{"message":"Invalid access token."}]}"#.utf8)) == .unauthorized, "Canvas token rejected")
    check(CanvasClient.error(status: 503, body: Data(#"{"type":"error","error":{"type":"canvas_not_configured"}}"#.utf8)) == .notConfigured, "Canvas not set up")
    check(CanvasClient.error(status: 503, body: Data()) == .http(503), "other 503")

    // HTML to text.
    let html = "<h2>Task&nbsp;3</h2><p>Write a <strong>300&ndash;400 word</strong> response.</p><ul><li>Use two sources</li><li>Cite them</li></ul><script>alert(1)</script><p>Don&#39;t forget &#x2019;quotes&#8217;</p>"
    let plain = CanvasText.plain(html)
    check(plain.contains("Task 3") && plain.contains("300–400 word response."), "headings and entities")
    check(plain.contains("• Use two sources") && plain.contains("• Cite them"), "list items")
    check(!plain.contains("alert") && !plain.contains("<"), "scripts and tags removed")
    check(plain.contains("Don't forget ’quotes’"), "numeric entities")
    check(CanvasText.plain(nil) == "", "nil html")

    // Due dates relative to now, in a fixed time zone.
    let tz = TimeZone(identifier: "Australia/Sydney")!
    let now = CanvasText.date("2026-11-12T01:00:00Z")!  // 12:00 pm Thu 12 Nov in Sydney
    check(CanvasText.when("2026-11-15T12:59:00Z", now: now, timeZone: tz) == "Sun 15 Nov 11:59 pm (in 3 days)", "due in 3 days: \(CanvasText.when("2026-11-15T12:59:00Z", now: now, timeZone: tz))")
    check(CanvasText.when("2026-11-12T23:00:00Z", now: now, timeZone: tz).hasSuffix("(tomorrow)"), "tomorrow")
    check(CanvasText.when("2026-11-10T01:00:00Z", now: now, timeZone: tz).hasSuffix("(2 days ago)"), "past")
    check(CanvasText.when(nil, now: now) == "no due date", "no date")
    check(CanvasText.date("2026-11-15T12:59:00.123Z") != nil, "fractional seconds")

    // Decoding the shapes Canvas sends.
    let courseJSON = #"[{"id": 1234, "name": "Year 9 Mathematics", "course_code": "9MAT", "enrollments": [{"type": "student", "computed_current_score": 87.5, "computed_current_grade": "B+"}], "term": {"name": "2026"}}, {"id": 99, "access_restricted_by_date": true}]"#
    let courses = try? JSONDecoder().decode([CanvasCourse].self, from: Data(courseJSON.utf8))
    check(courses?.count == 2, "courses decode")
    if let c = courses?.first {
        check(CanvasText.course(c) == "• [course 1234] Year 9 Mathematics (9MAT) — current grade B+ 87.5%", "course line: \(CanvasText.course(c))")
    }
    let assignmentJSON = #"{"id": 55, "name": "Task 3: Research", "due_at": "2026-11-15T12:59:00Z", "points_possible": 40, "course_id": 1234, "submission_types": ["online_upload"], "description": "<p>Research a <em>local</em> issue.</p>", "submission": {"workflow_state": "unsubmitted", "missing": false}, "rubric": [{"description": "Research", "points": 20, "ratings": [{"description": "Thorough", "points": 20}, {"description": "Limited", "points": 5}]}]}"#
    if let a = try? JSONDecoder().decode(CanvasAssignment.self, from: Data(assignmentJSON.utf8)) {
        let line = CanvasText.assignmentLine(a, courseName: "Maths", now: now)
        check(line.contains("[assignment 55, course 1234] Task 3: Research — Maths — due Sun 15 Nov") && line.hasSuffix("40 pts — not submitted"), "assignment line: \(line)")
        let detail = CanvasText.assignmentDetail(a, now: now)
        check(detail.contains("Research a local issue.") && detail.contains("– Research (20 pts)") && detail.contains("· 5: Limited"), "assignment detail with rubric")
    } else {
        check(false, "assignment decodes")
    }
    let graded = CanvasAssignment(id: 1, name: "Quiz", pointsPossible: 10, submission: CanvasSubmission(workflowState: "graded", score: 8.5, grade: "85%"))
    check(CanvasText.submissionStatus(graded) == "marked 8.5/10 (85%)", "marked status")
    let missing = CanvasAssignment(id: 2, submission: CanvasSubmission(missing: true))
    check(CanvasText.submissionStatus(missing) == "MISSING", "missing status")
    let fileJSON = #"{"id": 7, "display_name": "Task 3 notification.pdf", "content-type": "application/pdf", "size": 120000, "url": "https://s.instructure.com/files/7/download?verifier=abc"}"#
    let file = try? JSONDecoder().decode(CanvasFile.self, from: Data(fileJSON.utf8))
    check(file?.contentType == "application/pdf" && file?.displayName == "Task 3 notification.pdf", "file decodes")
    check(CanvasText.truncated(String(repeating: "a", count: 20), 10) == "aaaaaaaaaa… [cut]", "truncation")
}
