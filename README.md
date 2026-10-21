# Margin

An iPad note-taking app for Apple Pencil, with a built-in Claude tutor that works **on the page** with you. It writes in clean type (or handwriting, if you prefer), typesets math, draws graphs and diagrams, circles your mistakes, adds practice questions, and marks your answers live.

> **Status: v1.** It builds cleanly in CI with Xcode 26.6, for the iPad simulator and as a Release device build. The platform-independent logic is unit-tested (see `CoreTests/`), and a scripted walkthrough runs the real canvas and tutor pipeline in the simulator to record the demo video. It hasn't been tested on a physical iPad with an Apple Pencil yet, so Pencil-specific behaviour (pressure, hover, squeeze, palm rejection) is unverified on hardware.

## Running it

You need an iPad on iPadOS 17 or later, an Apple Pencil, and an [Anthropic API key](https://console.anthropic.com/settings/keys).

**Option A: Swift Playgrounds on the iPad (no Mac needed)**
1. Put the `TutorNotes.swiftpm` folder on the iPad (iCloud Drive, AirDrop or the Files app).
2. Open it in Swift Playgrounds 4.5 or later and tap ▶︎ to run. Use the app menu to install it to the Home Screen.

**Option B: Xcode on a Mac**
1. Open `TutorNotes.swiftpm` in Xcode 16 or later.
2. Select your iPad as the run destination, choose your team under Signing (Playgrounds-style packages show it in the app settings), and run.

**Option C: sideload the CI build**
1. In GitHub, open **Actions → iOS Build**, run it (or open the latest run), and download the `TutorNotes-unsigned-ipa` artifact.
2. Unzip it and sideload `TutorNotes-unsigned.ipa` with Sideloadly or AltStore. They sign it with your Apple ID. With a free Apple ID the app stops opening after 7 days and needs re-signing; a paid developer account lasts a year.

On first launch, connect the tutor: either your **tutor server** (recommended, see below) or your own API key.

## Deploy the tutor server on Railway

The `server/` folder is a small relay that keeps your Claude API key on the server. The app only holds an access token for it.

1. In Railway, create a project, choose **Deploy from GitHub repo**, and pick this repo. Railway builds the root `Dockerfile` and uses `railway.json`, which sets the health check to `/health`.
2. Under **Variables**, add:
   - `ANTHROPIC_API_KEY`: your Claude API key.
   - `APP_TOKEN`: a long random secret, for example the output of `openssl rand -hex 32`.
   - Optional: `ALLOWED_MODELS`, such as `claude-sonnet-5-5,claude-haiku-5-5`, to limit which models the app can use.
   - Optional: `RATE_LIMIT_PER_MINUTE` (default 60) and `MAX_BODY_MB` (default 40).
3. Under **Networking**, generate a public domain, such as `tutor-notes-production.up.railway.app`.
4. Open `https://<your-domain>/health`. It should show `"configured": true`.
5. In the app, go to **Settings → Claude connection → Tutor server**. Enter the domain and the same `APP_TOKEN`, then tap **Test connection**.

The server streams responses straight through, relays file uploads, cancels Claude requests when you press Stop, and rejects anything without the token. Run its tests with `cd server && npm test`; they use a mock of the Claude API, so no key is needed.

## Home

The app opens on **Home**:
- **Quick actions:** start a notebook, a freeform board, a question for the tutor, a past paper, a scan, or a PDF import.
- **Jump back in:** the note you were last in.
- **Recent notes**, and **questions waiting for an answer**.
- **Flashcards due** today.
- **Your topics:** weak and strong topics, with a one-tap "practise my weak spots".
- **Study streak** and time studied this week.

Press and hold the back button in a note to jump straight to another recent note.

## Freeform boards

A board is one big sheet instead of pages. It opens at actual size and grows to the right and downward as you write. The top-left corner is fixed, so boards don't extend up or left.
- Switch its **lines** (blank, ruled, narrow, grid, small grid, dots, graph) and paper colour from the top bar.
- Zoom out to see everything with **Show Whole Board**.
- Circle working with **Ask**, or use the **floating tutor bar**: type, or tap the mic and talk. The tutor answers in a card above the bar and works on the board where you're looking.

## Past papers

Tap **Past Paper** on Home and add the paper and its mark scheme, as PDFs or scanned with the camera. Then pick a time limit, or leave it untimed.
- **Setup:** your tutor reads both files and maps every question: its label, page, marks and topic. The mark scheme is attached but hidden from you unless you ask for a solution.
- **While you work:** the bar under the toolbar shows the clock, the question on screen and your running score.
  - **Mark** checks that question against the scheme. You get ticks where marks are earned, notes where they're lost, and the score in the margin.
  - The question list lets you jump between questions.
- **Exam conditions:** a timed paper keeps the tutor quiet until you finish or ask.
- **Finish:** everything left unmarked gets marked, and a **results page** is added: score, time, per-question table, what went well, what to review, and next steps.

Any note with imported PDF pages can be turned into a past paper from the **+** menu. Sending the paper and mark scheme to Claude adds about 1,500–3,000 tokens per page to the conversation. They're uploaded once with the Files API and cached after that. Very long papers (more than 100 pages) exceed the API's PDF limit.

## Study tools

- **Scan:** the system document camera turns worksheets and textbook pages into pages you can write on. Use it from Home, the **+** menu, or the tutor's attach menu (as reference material).
- **Flashcards:** ask the tutor, or use **Ask → Flashcards** on some working, and it adds cards to a spaced-repetition deck. Review cards from Home: tap to flip, then rate Again / Hard / Good / Easy. Each button shows when you'll see the card next.
- **Progress:** every marked question card and past-paper question is recorded by topic. Home shows your weakest and strongest topics (recent attempts count more), and the tutor is told what you've found hard lately.

## The notes side

- **PencilKit ink** with Apple's low-latency rendering and palm rejection. Pens: ballpoint, fountain, pencil, monoline, crayon, watercolor, plus highlighter, stroke/pixel eraser, lasso, ruler.
- **Favourite colours and widths** per tool, Notability-style. Tap a selected swatch or width to edit it.
- **Draw-and-hold shape snapping:** sketch a shape and hold: lines snap to 0/45/90°, and circles, ellipses, rectangles and triangles snap clean. Keep moving after the snap to resize, or use the **− / +** bar that appears above the shape. Apple Pencil Pro gives haptic feedback on snap.
- **Apple Pencil:** double-tap opens the tutor's Ask menu where you're working (change it in Settings to follow the system setting, switch to the eraser, or go back to the previous tool). **Squeeze** (Pencil Pro) opens the tutor menu right where you're hovering. **Hover preview** shows the nib size and colour (M2 and later iPads).
- **Finger gestures:** fingers scroll and zoom while the pencil draws (finger drawing is optional). Two-finger tap undoes, three-finger tap redoes, and double-tap opens the Ask menu.
- **Palm rejection:** a hand resting on the page while you write doesn't scroll, zoom, tap or undo. A touch counts as your hand if it lands while the pencil is on or hovering over the glass, is already down when the pencil lands, or is palm-sized.
- **Continuous pages:** blank, ruled, narrow, grid, small grid, graph, dotted and Cornell paper in six colours. Pages are added automatically as you write near the bottom. The page navigator lets you jump to, insert, duplicate and delete pages.
- **Text boxes** support Scribble. **Images** come from Photos. **PDF import** creates annotatable pages, either as a new note or appended to one. **PDF export** renders vector elements with high-resolution ink.
- **Audio recording synced to ink:** during playback, strokes appear as they were written, and tapping a stroke jumps the audio to that moment.
- **Library:** subjects with colours, thumbnails, sort, move, duplicate. **Search** covers titles and handwriting, which Vision recognises on-device.

## The tutor side

Default model is **Claude Sonnet 5.5**. Switch to Opus 5.5, Haiku 5.5 or Fable 5.1, and set the thinking depth (Quick / Balanced / Deep / Max), from the tutor panel header.

**It acts on the canvas through tools:**

| Tool | What it does on the page |
|---|---|
| `write` | Text with inline `$LaTeX$`, in clean San Francisco type by default or handwriting (Settings → Tutor's writing). It **streams onto the page live** as the model generates it. |
| `write_math` | Typeset multi-line working, aligned on `=` (fractions, roots, powers, integrals, sums, limits, matrices, cases, vectors…). |
| `graph` | Cartesian planes: functions in x, points, segments and vectors, dashed asymptotes, shaded areas, blank planes to sketch on, and updates to existing graphs. |
| `number_line` | Inequalities, intervals, open and closed points. |
| `table` | Tables of values. Cells can contain math. |
| `geometry` | Triangles and other polygons with side, angle and vertex labels placed automatically: angle labels inside the angle beside an arc or right-angle square, side labels beside their side, equal-side ticks. |
| `draw` | Freehand pen strokes for diagrams and sketches, with labels. |
| `annotate` | Teacher marks: circle, underline, box, arrow, highlight, strike, bracket, tick, cross, ?, ★, plus a short label. |
| `add_question` / `mark` | Practice cards with an answer space and a hidden answer key. Marks are ticks and crosses with scores and comments. |
| `move` / `edit` / `delete` / `erase_ink` / `add_page` / `clear_marks` | The same edits a person can make to the page. |
| `focus` | Scrolls you to something and pulses it, with a speech bubble. |
| `remember` | Saves a durable note about you (misconceptions, goals). You can review it in Settings. |
| `make_flashcards` | Adds cards to your spaced-repetition deck. |
| `outline_paper` / `score_paper` / `paper_summary` | Past papers: maps the questions, records each question's marks (with the score in the margin), and writes the results page. |

**What makes it feel present:**
- A glowing **tutor cursor** glides across the page and follows its pen as it writes. A status pill shows what it's doing ("Marking up your work…").
- **Watching mode (off by default):** the tutor only looks at your page when you ask. Turn on **Settings → Watch while I work** and, when you pause writing, it glances at the new work and decides whether to step in. You can set the involvement to Quiet, Balanced or Hands-on.
- **Ask anywhere:** the **Ask** tool lets you drag around or tap any working to get a quick menu (Check, Hint, Next step, Explain, Full solution, Graph it, Similar question, Ask…). A long-press or select on any item gives the same menu, and so does squeezing the pencil.
- **Hint button:** next to Ask in the toolbar. One tap gets a small nudge written beside your latest working (or the question's stored hint, free and instant), never the answer. On a past paper the tutor also looks at the question you're on.
- **Stuck detection:** "Stuck on Q2? Get a hint" appears if you stop on a question. Stored hints reveal instantly and cost nothing.
- **Avoids your writing:** it's told where your ink and the free space are, and anything it places is nudged away from your work.
- **Undo the tutor:** every turn can be reverted in one tap. Normal undo works too.
- **Work with its marks:** the eraser rubs out the tutor's writing, marks and labels. Tap one with a finger to select it, then drag to move it or use the bar to ask about it, edit it, duplicate or delete it.
- **Attachments:** PDFs, images and text (worksheets, textbook pages, mark schemes) are uploaded once through the Files API and used as context.
- **Voice:** dictate questions and optionally have feedback read aloud.

**Under the hood:**
- The client is raw HTTPS with SSE streaming, since there's no official Swift SDK. Tool inputs use `eager_input_streaming` so text can be drawn before generation finishes, and each input is validated strictly before it's applied.
- Each turn sends a 1 px = 1 pt snapshot of the visible pages with a faint coordinate grid, a sharper crop of any selected region, and a text map of the page: ink regions, every element with its id and frame, free space, and questions with their hidden answers.
- History is append-only and thinking blocks are echoed back verbatim, so the prompt cache stays warm and preserved thinking stays valid. The system prompt and tools are identical for every request, so the cache is shared across notes and watching glances.
- Refusals and the server-side fallback (`fallbacks: "default"`) are handled. A declined turn is rolled back from both the canvas and the history.

**Cost:** each turn sends one or two page images, roughly 1–1.5k tokens each. With Sonnet 5.5 a typical turn should cost about a cent or two. Watching glances are short single requests, and you can run them on Haiku 5.5 in Settings to make them cheaper still. Treat these figures as estimates.

## Project layout

```
TutorNotes.swiftpm/
  Package.swift              Swift Playgrounds / Xcode app manifest (iPad, iOS 17+)
  App/                       App entry, settings
  Model/                     Notes, pages, elements, storage, library
  Canvas/                    PencilKit canvas controller, input, shape snapping, tutor visuals
  Rendering/                 Paper, elements, math/text layout, snapshots, PDF export, OCR
  Math/                      LaTeX parser + typesetter, graph expression engine
  Tutor/                     Claude client, tools, executor, context, engine, chat panel
  Editor/                    Editor screen, toolbar, overlays, pages, practice, audio
  Library/                   Library and settings screens
  Demo/                      Scripted walkthrough used to record the demo video (-demo-script)
server/                      Railway relay that holds the API key (Node, no dependencies)
CoreTests/                   Unit tests for the platform-independent core (run.sh)
project.yml                  XcodeGen spec for a regular Xcode project (used by CI)
.github/workflows/           macOS CI: simulator build, unsigned .ipa, demo video, server tests
```

Run the core tests on a Mac or Linux machine with Swift installed: `./CoreTests/run.sh`.

The demo video is recorded by launching the app with `-demo-script`. Student handwriting in it is synthesised and the tutor's turns are scripted tool calls (no network), played through the real executor, streaming previews and chat panel.

## Known gaps

- Not tested on a physical iPad yet (see the status note above).
- Freeform boards grow right and down only, up to 16,384 pt a side.
- "Undo the tutor" restores a past paper's scores and removes pages the tutor added, but topic progress already recorded from that marking stays.
- Lasso selects ink only. Typed and tutor elements are selected with the Select tool or a long-press.
- The page map sent to the tutor gets long for pages with many strokes. Very dense pages may need tuning.
- iCloud sync and collaboration aren't implemented. Notes are stored locally in the app's Documents folder.
- Anyone with the server's `APP_TOKEN` can spend your Claude credits, so keep it private and rotate it if it leaks. To give the app to other people, add per-user accounts to the server.
