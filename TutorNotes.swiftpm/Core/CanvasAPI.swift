import Foundation

// A read-only client for the Canvas LMS REST API, used by the Home study agent. Requests go
// through the tutor server, which holds the school's Canvas address and the student's access
// token; only the text the agent reads is passed on to Claude, never the token.

enum CanvasError: Error, Equatable {
    case notConfigured
    case notTutorServer
    case serverRejected
    case unauthorized
    case forbidden
    case notFound
    case http(Int)
    case network(String)
    case decoding
    case tooLarge

    var message: String {
        switch self {
        case .notConfigured: return "Canvas isn't set up on your tutor server yet. In Railway, add CANVAS_URL (your school's Canvas address) and CANVAS_TOKEN (an access token from Canvas → Account → Settings) to the service's Variables."
        case .notTutorServer: return "Canvas works through your tutor server. Switch Settings → Claude connection to Tutor server."
        case .serverRejected: return "The tutor server didn't accept the app's access token."
        case .unauthorized: return "Canvas didn't accept CANVAS_TOKEN. Make a new access token in Canvas and update it in Railway."
        case .forbidden: return "Canvas says you don't have access to that."
        case .notFound: return "Canvas couldn't find that."
        case .http(let code): return "Canvas returned an error (\(code))."
        case .network(let m): return "Couldn't reach Canvas: \(m)"
        case .decoding: return "Canvas sent something unexpected."
        case .tooLarge: return "That file is too big to read here."
        }
    }
}

// MARK: - Models (only the fields we use)

struct CanvasProfile: Decodable, Equatable {
    var id: Int64
    var name: String
    var shortName: String?
    var timeZone: String?

    enum CodingKeys: String, CodingKey { case id, name, shortName = "short_name", timeZone = "time_zone" }
}

struct CanvasEnrollment: Decodable, Equatable {
    var type: String?
    var computedCurrentScore: Double?
    var computedCurrentGrade: String?

    enum CodingKeys: String, CodingKey {
        case type
        case computedCurrentScore = "computed_current_score"
        case computedCurrentGrade = "computed_current_grade"
    }
}

struct CanvasTerm: Decodable, Equatable { var name: String? }

struct CanvasCourse: Decodable, Equatable {
    var id: Int64
    var name: String?
    var courseCode: String?
    var enrollments: [CanvasEnrollment]?
    var term: CanvasTerm?
    var accessRestrictedByDate: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, enrollments, term
        case courseCode = "course_code"
        case accessRestrictedByDate = "access_restricted_by_date"
    }
}

struct CanvasSubmission: Decodable, Equatable {
    var workflowState: String?
    var submittedAt: String?
    var gradedAt: String?
    var score: Double?
    var grade: String?
    var late: Bool?
    var missing: Bool?
    var excused: Bool?
    var assignmentID: Int64?
    var assignment: CanvasAssignmentStub?
    var submissionComments: [CanvasComment]?

    enum CodingKeys: String, CodingKey {
        case score, grade, late, missing, excused, assignment
        case workflowState = "workflow_state"
        case submittedAt = "submitted_at"
        case gradedAt = "graded_at"
        case assignmentID = "assignment_id"
        case submissionComments = "submission_comments"
    }
}

/// The assignment fields included alongside a submission.
struct CanvasAssignmentStub: Decodable, Equatable {
    var id: Int64
    var name: String?
    var pointsPossible: Double?
    var dueAt: String?

    enum CodingKeys: String, CodingKey { case id, name, pointsPossible = "points_possible", dueAt = "due_at" }
}

struct CanvasComment: Decodable, Equatable {
    var authorName: String?
    var comment: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey { case comment, authorName = "author_name", createdAt = "created_at" }
}

struct CanvasRubricRating: Decodable, Equatable {
    var description: String?
    var points: Double?
}

struct CanvasRubricCriterion: Decodable, Equatable {
    var description: String?
    var longDescription: String?
    var points: Double?
    var ratings: [CanvasRubricRating]?

    enum CodingKeys: String, CodingKey { case description, points, ratings, longDescription = "long_description" }
}

struct CanvasAssignment: Decodable, Equatable {
    var id: Int64
    var name: String?
    var description: String?
    var dueAt: String?
    var unlockAt: String?
    var lockAt: String?
    var pointsPossible: Double?
    var courseID: Int64?
    var htmlURL: String?
    var submissionTypes: [String]?
    var submission: CanvasSubmission?
    var rubric: [CanvasRubricCriterion]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, submission, rubric
        case dueAt = "due_at"
        case unlockAt = "unlock_at"
        case lockAt = "lock_at"
        case pointsPossible = "points_possible"
        case courseID = "course_id"
        case htmlURL = "html_url"
        case submissionTypes = "submission_types"
    }
}

struct CanvasTodoItem: Decodable, Equatable {
    var type: String?
    var contextName: String?
    var courseID: Int64?
    var assignment: CanvasAssignment?

    enum CodingKeys: String, CodingKey { case type, assignment, contextName = "context_name", courseID = "course_id" }
}

struct CanvasAnnouncement: Decodable, Equatable {
    var id: Int64
    var title: String?
    var message: String?
    var postedAt: String?
    var contextCode: String?
    var author: CanvasAuthor?

    enum CodingKeys: String, CodingKey { case id, title, message, author, postedAt = "posted_at", contextCode = "context_code" }
}

struct CanvasAuthor: Decodable, Equatable {
    var displayName: String?
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}

struct CanvasModuleItem: Decodable, Equatable {
    var id: Int64
    var title: String?
    var type: String?
    var pageURL: String?
    var contentID: Int64?

    enum CodingKeys: String, CodingKey { case id, title, type, pageURL = "page_url", contentID = "content_id" }
}

struct CanvasModule: Decodable, Equatable {
    var id: Int64
    var name: String?
    var items: [CanvasModuleItem]?
}

struct CanvasPage: Decodable, Equatable {
    var url: String?
    var title: String?
    var body: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey { case url, title, body, updatedAt = "updated_at" }
}

struct CanvasFile: Decodable, Equatable {
    var id: Int64
    var displayName: String?
    var filename: String?
    var size: Int?
    var url: String?
    var contentType: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, filename, size, url
        case displayName = "display_name"
        case contentType = "content-type"
        case updatedAt = "updated_at"
    }
}

struct CanvasEvent: Decodable, Equatable {
    var title: String?
    var startAt: String?
    var contextName: String?
    var description: String?
    var assignment: CanvasAssignment?

    enum CodingKeys: String, CodingKey { case title, description, assignment, startAt = "start_at", contextName = "context_name" }
}

struct CanvasConversation: Decodable, Equatable {
    var id: Int64
    var subject: String?
    var lastMessage: String?
    var lastMessageAt: String?
    var contextName: String?

    enum CodingKeys: String, CodingKey {
        case id, subject
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
        case contextName = "context_name"
    }
}

// MARK: - Client

/// Talks to Canvas through the tutor server (GET /canvas/api/v1/…), which holds the Canvas
/// address and token (CANVAS_URL, CANVAS_TOKEN on Railway) and only allows reading.
struct CanvasClient {
    let serverURL: URL
    private let appToken: String
    private let session: URLSession

    /// Pages of results followed per list (Canvas pages hold up to 100 items).
    static let maxPages = 6

    init(serverURL: URL, appToken: String, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.appToken = appToken
        self.session = session
    }

    /// The "next" URL from a Link header, relative to the server: </canvas/api/v1/…&page=2>; rel="next".
    static func nextLink(_ header: String?, relativeTo base: URL) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\"" }) else { continue }
            let link = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard !link.isEmpty else { return nil }
            return URL(string: link, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    private func url(_ path: String, _ query: [(String, String)] = [], api: Bool = true) -> URL? {
        guard var c = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        c.path = prefix + "/canvas" + (api ? "/api/v1" : "") + path
        c.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url
    }

    private func send(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        // The app token only ever goes to the tutor server.
        guard url.host == serverURL.host else { throw CanvasError.forbidden }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "GET"
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw CanvasError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CanvasError.decoding }
        if (200..<300).contains(http.statusCode) { return (data, http) }
        throw CanvasClient.error(status: http.statusCode, body: data)
    }

    static func error(status: Int, body: Data) -> CanvasError {
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        switch status {
        case 401: return text.contains("authentication_error") ? .serverRejected : .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 413: return .tooLarge
        case 503 where text.contains("canvas_not_configured"): return .notConfigured
        default: return .http(status)
        }
    }

    func get<T: Decodable>(_ path: String, _ query: [(String, String)] = [], as type: T.Type = T.self) async throws -> T {
        guard let u = url(path, query) else { throw CanvasError.notConfigured }
        let (data, _) = try await send(u)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw CanvasError.decoding }
    }

    /// A list endpoint, following "next" links for up to `maxPages` pages.
    func list<T: Decodable>(_ path: String, _ query: [(String, String)] = [], as type: T.Type = T.self) async throws -> [T] {
        guard var next = url(path, query + [("per_page", "50")]) else { throw CanvasError.notConfigured }
        var all: [T] = []
        for _ in 0..<CanvasClient.maxPages {
            let (data, http) = try await send(next)
            do { all += try JSONDecoder().decode([T].self, from: data) } catch { throw CanvasError.decoding }
            guard let n = CanvasClient.nextLink(http.value(forHTTPHeaderField: "Link"), relativeTo: serverURL) else { break }
            next = n
        }
        return all
    }

    struct Status: Decodable, Equatable {
        var configured: Bool
        var host: String?
    }

    /// Whether the server has Canvas set up, and for which site.
    func status() async throws -> Status {
        guard let u = url("/status", api: false) else { throw CanvasError.notConfigured }
        let (data, _) = try await send(u)
        do { return try JSONDecoder().decode(Status.self, from: data) } catch { throw CanvasError.decoding }
    }

    // MARK: Endpoints

    func profile() async throws -> CanvasProfile { try await get("/users/self/profile") }

    func courses() async throws -> [CanvasCourse] {
        let all: [CanvasCourse] = try await list("/courses", [("enrollment_state", "active"), ("include[]", "total_scores"), ("include[]", "term")])
        return all.filter { $0.accessRestrictedByDate != true && $0.name != nil }
    }

    /// bucket: upcoming, future, past, overdue, undated, ungraded, unsubmitted (nil for all).
    func assignments(course: Int64, bucket: String?) async throws -> [CanvasAssignment] {
        var q: [(String, String)] = [("include[]", "submission"), ("order_by", "due_at")]
        if let bucket { q.append(("bucket", bucket)) }
        return try await list("/courses/\(course)/assignments", q)
    }

    func assignment(course: Int64, id: Int64) async throws -> CanvasAssignment {
        try await get("/courses/\(course)/assignments/\(id)", [("include[]", "submission")])
    }

    func todo() async throws -> [CanvasTodoItem] { try await list("/users/self/todo") }

    func missingSubmissions() async throws -> [CanvasAssignment] {
        try await list("/users/self/missing_submissions", [("filter[]", "submittable")])
    }

    func upcomingEvents() async throws -> [CanvasEvent] { try await get("/users/self/upcoming_events") }

    func announcements(courses: [Int64], since: Date) async throws -> [CanvasAnnouncement] {
        guard !courses.isEmpty else { return [] }
        let f = ISO8601DateFormatter()
        var q = courses.map { ("context_codes[]", "course_\($0)") }
        q.append(("start_date", f.string(from: since)))
        q.append(("end_date", f.string(from: Date().addingTimeInterval(86_400))))
        return try await list("/announcements", q)
    }

    func modules(course: Int64) async throws -> [CanvasModule] {
        try await list("/courses/\(course)/modules", [("include[]", "items")])
    }

    func pages(course: Int64, search: String?) async throws -> [CanvasPage] {
        var q: [(String, String)] = [("sort", "updated_at"), ("order", "desc")]
        if let search, !search.isEmpty { q.append(("search_term", search)) }
        return try await list("/courses/\(course)/pages", q)
    }

    func page(course: Int64, url pageURL: String) async throws -> CanvasPage {
        let escaped = pageURL.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? pageURL
        return try await get("/courses/\(course)/pages/\(escaped)")
    }

    func frontPage(course: Int64) async throws -> CanvasPage { try await get("/courses/\(course)/front_page") }

    func files(course: Int64, search: String?) async throws -> [CanvasFile] {
        var q: [(String, String)] = [("sort", "updated_at"), ("order", "desc")]
        if let search, search.count >= 2 { q.append(("search_term", search)) }
        return try await list("/courses/\(course)/files", q)
    }

    func file(id: Int64) async throws -> CanvasFile { try await get("/files/\(id)") }

    /// Downloads a file's contents through the server (which follows Canvas's redirect to the
    /// file host without passing the Canvas token on).
    func download(_ file: CanvasFile, maxBytes: Int = 25_000_000) async throws -> Data {
        if let size = file.size, size > maxBytes { throw CanvasError.tooLarge }
        guard let s = file.url, !s.isEmpty, let u = url("/file", [("url", s)], api: false) else { throw CanvasError.notFound }
        let (data, _) = try await send(u)
        guard data.count <= maxBytes else { throw CanvasError.tooLarge }
        return data
    }

    /// Recently graded work in a course, with teacher comments.
    func recentFeedback(course: Int64) async throws -> [CanvasSubmission] {
        try await list("/courses/\(course)/students/submissions", [
            ("student_ids[]", "self"), ("include[]", "assignment"), ("include[]", "submission_comments"),
            ("order", "graded_at"), ("order_direction", "descending"),
        ])
    }

    func inbox() async throws -> [CanvasConversation] {
        try await get("/conversations", [("per_page", "20")])
    }
}

// MARK: - Text for the agent

/// Compact, readable text from Canvas data, for tool results.
enum CanvasText {
    /// Canvas HTML (pages, assignment descriptions, announcements) as plain text.
    static func plain(_ html: String?) -> String {
        guard var s = html, !s.isEmpty else { return "" }
        for tag in ["script", "style"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|tr|ul|ol|table|blockquote)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</t[dh]>", with: " | ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&ndash;": "–", "&mdash;": "—", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Numeric entities: &#8217; and &#x2019;
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let u = Unicode.Scalar(code) { out.unicodeScalars.append(u) }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression) }
        var result: [String] = []
        for line in lines {
            if line.isEmpty && (result.last?.isEmpty ?? true) { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func truncated(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "… [cut]"
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    /// "Mon 17 Nov 11:59 pm (in 5 days)" in the iPad's time zone.
    static func when(_ iso: String?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let d = date(iso) else { return "no due date" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.timeZone = timeZone
        f.dateFormat = "EEE d MMM h:mm a"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        let rel: String
        switch days {
        case 0: rel = d < now ? "today, passed" : "today"
        case 1: rel = "tomorrow"
        case -1: rel = "yesterday"
        case let n where n > 1: rel = "in \(n) days"
        default: rel = "\(-days) days ago"
        }
        return "\(f.string(from: d)) (\(rel))"
    }

    static func score(_ x: Double?) -> String {
        guard let x else { return "–" }
        return x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
    }

    static func course(_ c: CanvasCourse) -> String {
        var s = "• [course \(c.id)] \(c.name ?? "Untitled")"
        if let code = c.courseCode, code != c.name { s += " (\(code))" }
        if let e = c.enrollments?.first(where: { $0.type == "student" || $0.type == "StudentEnrollment" }) ?? c.enrollments?.first,
           e.computedCurrentScore != nil || e.computedCurrentGrade != nil {
            s += " — current grade \(e.computedCurrentGrade ?? "") \(e.computedCurrentScore.map { score($0) + "%" } ?? "")".replacingOccurrences(of: "  ", with: " ")
        }
        return s
    }

    static func submissionStatus(_ a: CanvasAssignment) -> String {
        guard let sub = a.submission else { return "" }
        if sub.excused == true { return "excused" }
        if let score = sub.score, sub.workflowState == "graded" {
            return "marked \(CanvasText.score(score))/\(CanvasText.score(a.pointsPossible))" + (sub.grade.map { " (\($0))" } ?? "")
        }
        if sub.missing == true { return "MISSING" }
        if sub.submittedAt != nil { return sub.late == true ? "submitted late" : "submitted" }
        return "not submitted"
    }

    static func assignmentLine(_ a: CanvasAssignment, courseName: String? = nil, now: Date = Date()) -> String {
        var s = "• [assignment \(a.id)"
        if let c = a.courseID { s += ", course \(c)" }
        s += "] \(a.name ?? "Untitled")"
        if let courseName { s += " — \(courseName)" }
        s += " — due \(when(a.dueAt, now: now))"
        if let p = a.pointsPossible, p > 0 { s += " — \(score(p)) pts" }
        let status = submissionStatus(a)
        if !status.isEmpty { s += " — \(status)" }
        return s
    }

    static func assignmentDetail(_ a: CanvasAssignment, now: Date = Date()) -> String {
        var out = [assignmentLine(a, now: now)]
        if let types = a.submissionTypes, !types.isEmpty { out.append("Submit as: " + types.joined(separator: ", ")) }
        if let unlock = a.unlockAt { out.append("Opens: \(when(unlock, now: now))") }
        if let lock = a.lockAt { out.append("Closes: \(when(lock, now: now))") }
        let desc = plain(a.description)
        if !desc.isEmpty { out.append("Description:\n" + truncated(desc, 6000)) }
        if let rubric = a.rubric, !rubric.isEmpty {
            out.append("Rubric:")
            for c in rubric {
                var line = "– \(c.description ?? "Criterion") (\(score(c.points)) pts)"
                if let long = c.longDescription, !long.isEmpty { line += ": \(plain(long))" }
                out.append(line)
                for r in c.ratings ?? [] { out.append("    · \(score(r.points)): \(r.description ?? "")") }
            }
        }
        return out.joined(separator: "\n")
    }
}
