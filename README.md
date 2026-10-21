# Tutor Notes

An iPad note-taking app for Apple Pencil, with a built-in Claude tutor that works **on the page** with you. It writes in its own handwriting, typesets math, draws graphs and diagrams, circles your mistakes, adds practice questions, and marks your answers live.

> **Status: v1, unverified build.** The app was written in a Linux environment with no iOS SDK. All the platform-independent logic is unit-tested (see `CoreTests/`), and the UIKit, PencilKit and SwiftUI code was reviewed against the iOS 17 SDK, but it has **not** been compiled in Xcode yet. Expect a few small fixes on the first build. Send the compiler errors back and they can be fixed quickly.

## Running it

You need an iPad on iPadOS 17 or later, an Apple Pencil, and an [Anthropic API key](https://console.anthropic.com/settings/keys).

**Option A: Swift Playgrounds on the iPad (no Mac needed)**
1. Put the `TutorNotes.swiftpm` folder on the iPad (iCloud Drive, AirDrop or the Files app).
2. Open it in Swift Playgrounds 4.5 or later and tap ▶︎ to run. Use the app menu to install it to the Home Screen.

**Option B: Xcode on a Mac**
1. Open `TutorNotes.swiftpm` in Xcode 16 or later.
2. Select your iPad as the run destination, choose your team under Signing (Playgrounds-style packages show it in the app settings), and run.

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

## The notes side

- **PencilKit ink** with Apple's low-latency rendering and palm rejection. Pens: ballpoint, fountain, pencil, monoline, crayon, watercolor, plus highlighter, stroke/pixel eraser, lasso, ruler.
- **Favourite colours and widths** per tool, Notability-style. Tap a selected swatch or width to edit it.
- **Draw-and-hold shape snapping:** lines snap to 0/45/90°, and circles, ellipses, rectangles and triangles snap clean. Keep moving after the snap to resize. Apple Pencil Pro gives haptic feedback on snap.
- **Apple Pencil:** double-tap follows your system setting (eraser, previous tool, palette) or can open the tutor. **Squeeze** (Pencil Pro) opens the tutor menu right where you're hovering. **Hover preview** shows the nib size and colour (M2 and later iPads).
- **Finger gestures:** fingers scroll and zoom while the pencil draws (finger drawing is optional). Two-finger tap undoes, three-finger tap redoes, and double-tap returns to fit-width.
- **Continuous pages:** blank, ruled, narrow, grid, small grid, graph, dotted and Cornell paper in six colours. Pages are added automatically as you write near the bottom. The page navigator lets you jump to, insert, duplicate and delete pages.
- **Text boxes** support Scribble. **Images** come from Photos. **PDF import** creates annotatable pages, either as a new note or appended to one. **PDF export** renders vector elements with high-resolution ink.
- **Audio recording synced to ink:** during playback, strokes appear as they were written, and tapping a stroke jumps the audio to that moment.
- **Library:** subjects with colours, thumbnails, sort, move, duplicate. **Search** covers titles and handwriting, which Vision recognises on-device.

## The tutor side

Default model is **Claude Sonnet 5.5**. Switch to Opus 5.5, Haiku 5.5 or Fable 5.1, and set the thinking depth (Quick / Balanced / Deep / Max), from the tutor panel header.

**It acts on the canvas through tools:**

| Tool | What it does on the page |
|---|---|
| `write` | Handwritten text with inline `$LaTeX$`. It **streams onto the page live** as the model generates it. |
| `write_math` | Typeset multi-line working, aligned on `=` (fractions, roots, powers, integrals, sums, limits, matrices, cases, vectors…). |
| `graph` | Cartesian planes: functions in x, points, segments and vectors, dashed asymptotes, shaded areas, blank planes to sketch on, and updates to existing graphs. |
| `number_line` | Inequalities, intervals, open and closed points. |
| `table` | Tables of values. Cells can contain math. |
| `draw` | Freehand pen strokes for geometry and diagrams, with labels. |
| `annotate` | Teacher marks: circle, underline, box, arrow, highlight, strike, bracket, tick, cross, ?, ★, plus a short label. |
| `add_question` / `mark` | Practice cards with an answer space and a hidden answer key. Marks are ticks and crosses with scores and comments. |
| `move` / `edit` / `delete` / `erase_ink` / `add_page` / `clear_marks` | The same edits a person can make to the page. |
| `focus` | Scrolls you to something and pulses it, with a speech bubble. |
| `remember` | Saves a durable note about you (misconceptions, goals). You can review it in Settings. |

**What makes it feel present:**
- A glowing **tutor cursor** glides across the page and follows its pen as it writes. A status pill shows what it's doing ("Marking up your work…").
- **Watching mode:** when you pause writing, it glances at the new work and decides whether to step in. It might circle a slip, mark a finished answer, or say nothing. You can set the involvement to Quiet, Balanced or Hands-on.
- **Ask anywhere:** the **Ask** tool lets you drag around or tap any working to get a quick menu (Check, Hint, Next step, Explain, Full solution, Graph it, Similar question, Ask…). A long-press or select on any item gives the same menu, and so does squeezing the pencil.
- **Stuck detection:** "Stuck on Q2? Get a hint" appears if you stop on a question. Stored hints reveal instantly and cost nothing.
- **Avoids your writing:** it's told where your ink and the free space are, and anything it places is nudged away from your work.
- **Undo the tutor:** every turn can be reverted in one tap. Normal undo works too.
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

## Known gaps

- Not compiled in Xcode yet (see the status note above).
- Lasso selects ink only. Typed and tutor elements are selected with the Select tool or a long-press.
- The page map sent to the tutor gets long for pages with many strokes. Very dense pages may need tuning.
- iCloud sync and collaboration aren't implemented. Notes are stored locally in the app's Documents folder.
- Anyone with the server's `APP_TOKEN` can spend your Claude credits, so keep it private and rotate it if it leaks. To give the app to other people, add per-user accounts to the server.
