import SwiftUI

/// Settings → Canvas. Canvas is set up on the tutor server (Railway variables CANVAS_URL and
/// CANVAS_TOKEN), so the token never lives on the iPad; this shows whether it's working.
struct CanvasSettingsSection: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var briefs = AgentBriefStore.shared
    @State private var status: String?
    @State private var connected = false
    @State private var testing = false
    @State private var showHelp = false

    var body: some View {
        Section {
            HStack {
                Button(testing ? "Checking…" : "Test Canvas connection") { test() }
                    .disabled(testing)
                Spacer()
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(connected ? Color.green : Color.red)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(4)
                }
            }
            DisclosureGroup("How to set it up", isExpanded: $showHelp) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. In Canvas (Safari), open **Account → Settings**. Under **Approved Integrations**, tap **+ New Access Token**, name it \"Margin\" and **Generate Token**. Copy it: Canvas shows it once.")
                    Text("2. In Railway, open the **tutor-server** service → **Variables** and add:")
                    Text("    **CANVAS_URL**: your school's Canvas address, e.g. myschool.instructure.com")
                    Text("    **CANVAS_TOKEN**: the token you copied")
                    Text("3. Railway redeploys by itself. Then tap **Test Canvas connection**.")
                    Text("Some schools turn off student tokens. If there's no New Access Token button, ask your school.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(.vertical, 4)
            }
            if !briefs.briefs.isEmpty {
                NavigationLink {
                    AgentBriefsList()
                } label: {
                    LabeledContent("Shared with your tutors", value: "\(briefs.briefs.count)")
                }
            }
        } header: {
            Text("Canvas")
        } footer: {
            Text("The study agent on Home reads your courses, assignments, announcements, pages, files, marks and feedback through your tutor server, which keeps the Canvas token (like your Claude key). It can only read: it can't submit work, post or change anything. What it reads is sent to Claude when it answers you.")
        }
    }

    private func test() {
        guard let client = settings.canvasClient else {
            status = CanvasError.notTutorServer.message
            connected = false
            return
        }
        testing = true
        status = nil
        Task {
            do {
                let s = try await client.status()
                guard s.configured else { throw CanvasError.notConfigured }
                let me = try await client.profile()
                let courses = try await client.courses()
                status = "✓ \(me.name) · \(courses.count) course\(courses.count == 1 ? "" : "s") on \(s.host ?? "Canvas")"
                connected = true
                HomeAgent.shared.refreshCanvasStatus()
            } catch let e as CanvasError {
                status = e.message
                connected = false
            } catch {
                status = error.localizedDescription
                connected = false
            }
            testing = false
        }
    }
}

/// What the study agent has passed on to the note tutors, with delete.
struct AgentBriefsList: View {
    @ObservedObject private var store = AgentBriefStore.shared

    var body: some View {
        List {
            Section {
                ForEach(store.briefs.reversed()) { brief in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(brief.text).font(.subheadline)
                        Text("\(SubjectRegistry.subject(brief.subjectID)?.name ?? "All subjects") · \(brief.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { store.remove(brief) } }
                }
            } footer: {
                Text("The note tutors see these (for the note's subject, plus the ones for all subjects) when they help you.")
            }
            Section {
                Button("Clear All", role: .destructive) { store.clear() }
            }
        }
        .navigationTitle("Shared with tutors")
    }
}
