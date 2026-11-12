# Margin

An iPad note-taking app for Apple Pencil, with a built-in Claude tutor that works **on the page** with you, for every subject you study. It writes in clean type (or handwriting, if you prefer), typesets math, draws graphs, real maps, charts, flowcharts and labelled diagrams, runs code, circles your mistakes, adds practice questions, and marks your answers live. Each subject gets its own specialist tutor, Ask menu, note templates and tools, built around studying for exams.

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

## Subjects

Each subject has a **kind**: Maths, Science, English, Geography, History, Computing Technology, PDHPE or Other. Pick it when you make the subject (**New Subject** in the sidebar, or **Edit Subject…** from a subject's context menu); subjects made before kinds existed are recognised from their names. The kind changes:

- **The tutor.** Its instructions get a specialist section for the subject and your year and school system (Settings → About you; NSW Year 9 by default, which adds NESA's key words and Stage 5 expectations). Science covers disease and the body's defences, working scientifically and practical reports. Geography uses BOLTSS, real data and the "general trend, example, anomaly" way of describing patterns. History works with sources, perspectives and TEEL extended responses. English gives teacher-style feedback without rewriting your work. Computing Technology reads and runs your code and teaches debugging. The section is fixed for a conversation (so it's cached); if you move a note to another subject, the tutor is told in the next turn.
- **The Ask menu.** Eight actions per subject, for example Diagram it, Flowchart it, Key terms, Exam question and Graph my data in Science; Map it and Climate graph in Geography; Analyse source and Timeline in History; Feedback, Techniques and Plan paragraph in English; Check my code, Find the bug and Trace table in Computing.
- **Templates.** A subject's page shows template cards, and they're also in the New Note menu: a Practical Report (aim, hypothesis, variables, risk assessment, method, results, discussion, conclusion), Concept Notes, a geography Case Study and Biome Profile, History Source Analysis and Event Notes, an English TEEL Paragraph and Text Study, a computing Code Lab and Desk Check, maths Worked Examples, plus Cornell Notes and a Blurt page for every subject. Headings are placed as your own typed text, so you can edit or move them.
- **Paper and Insert.** New notebooks start on the subject's paper (grid for maths, dots for computing, ruled otherwise), and the Insert menu puts the subject's tools first (Calculator in maths, Map and Climate Graph in geography, Code Block in computing). Every tool is still available in any note under **More Tools**.

**Exams.** Give a subject an exam date and title, and Home shows a countdown under **Exams coming up** (red in the last week). The tutor is told how many days are left. Each subject's page also has:
- **Quiz me:** a new note where the tutor sets six questions from what's in your notes in that subject (the typed text and the handwriting the iPad has recognised).
- **Blurt:** a blank page where you write everything you remember, then tap **Check my blurt**. The tutor ticks what's right, corrects what's wrong, and lists what you missed compared with your notes.
- **Plan revision:** a day-by-day plan up to the exam (or for two weeks) built from your notes' topics, with short active tasks and spaced repeats.

## Study agent and Canvas

Home has a **Study agent**: a chat that plans with you across all your subjects and reads your school's **Canvas**. Ask "What's due this week?", "Anything new from my teachers?", "How am I going?", or "Help me start my next assessment". It can:

- **Read Canvas (read-only):** your courses and current grades, what's due and overdue, assignments with their descriptions and rubrics, announcements, modules and pages, files (assessment notifications and worksheets as PDFs or images), marked work with teacher comments, and your inbox. It can't submit, post or change anything.
- **Work with the note tutors:**
  - **share_with_tutors** passes a short brief (an assessment's task and criteria, a pattern in teacher feedback) to every tutor, or to one subject's tutors. They see it in each turn as `<from_study_agent>`. You can review and delete briefs in Settings → Canvas.
  - **start_study_note** creates a note and opens it with its tutor already working on a detailed job the agent wrote.
  - It can also set a subject's exam date (Home shows the countdown) and remember things about you.

**Setting up Canvas.** The Canvas token lives on the tutor server, like the Claude key:
1. In Canvas, go to **Account → Settings → + New Access Token** and copy the token.
2. In Railway, add these to the **tutor-server** service's Variables:
   - `CANVAS_URL`: your school's Canvas address, for example `myschool.instructure.com`.
   - `CANVAS_TOKEN`: the token.
3. In the app, check it with **Settings → Canvas → Test Canvas connection**.

How the server handles Canvas:
- Requests go through `GET /canvas/api/v1/…`, which only allows GET requests to Canvas's API.
- Files download through `GET /canvas/file`, which follows Canvas's redirect without sending the token to the file host.
- `/canvas/status` reports whether Canvas is set up.

## Calculator (maths)

Maths notes have a calculator button in the toolbar (also **+ → Calculator**, and under **More Tools** in any note). It's an on-screen replica of the **Casio fx-82AU PLUS II**, the calculator NSW students use, built from Casio's manual so it behaves like the one you'll have in the exam:

- **Natural Display.** Fractions, mixed fractions, roots, ˣ√, powers, 10ˣ, eˣ, log□(□) and |□| are templates you type into, with the cursor moving through their boxes (▲▼ between numerator and denominator). Brackets left open are closed at the end, like the real thing.
- **Exact answers.** In MathO, results stay as fractions, surds such as 3+2√2 or √2⁄2, and multiples of π. sin 45° gives √2⁄2 and cos⁻¹ 0 in Rad gives π⁄2. **S⇔D** switches to the decimal, and **SHIFT S⇔D** switches between mixed and improper fractions.
- **Every COMP function.** Trig and inverse trig in Deg/Rad/Gra, the hyp menu, log/ln, x², x³, x⁻¹, x!, %, nPr, nCr, Pol/Rec (results go to X and Y), sexagesimal °'" input and display, DRG▶, Abs, Rnd, Ran#, RanInt#, GCD and LCM, ENG and ←ENG, and FACT, which factorises the answer into primes up to 997 and puts anything left in brackets, as the fx-82 does.
- **Casio's priority order.** For example, (−)2² = −4, and 1÷2π = 1÷(2π) because implied multiplication binds tighter.
- **Memory.** Ans, M with M+/M−, A–F, X and Y with STO/RCL, ▲▼ replay of past calculations, and CLR. Memory, setup and history are kept when you close the calculator or the app.
- **SETUP** (SHIFT MODE): MthIO (MathO or LineO), LineIO, Deg/Rad/Gra, Fix, Sci and Norm 1/2, ab/c or d/c, STAT frequency, decimal point or comma, and contrast. Defaults are the calculator's factory settings (MthIO-LineO, Deg, Norm 2).
- **STAT** (MODE 2): 1-VAR and all eight regressions (A+BX, _+CX², ln X, e^X, A•B^X, A•X^B, 1/X), with the statistics editor (X, Y and optional FREQ columns), and the Sum, Var, Reg and MinMax menus (n, x̄, σx, sx, Q1, med, Q3, A, B, C, r, x̂, ŷ…). Quartiles use the fx-82's halves method.
- **VERIF** (MODE 3): type an equation or inequality using the VERIFY menu (SHIFT 6), and = shows TRUE or FALSE.
- **Put it on the page.** The button next to ✕ adds the calculation on screen to the page as typeset math ("input = result"), in your pen colour.

Drag the calculator by its top edge. SHIFT AC switches it off. Math ERROR and Syntax ERROR work like the calculator: ◀ or ▶ takes you back to fix the expression. The key layout follows the fx-82AU PLUS II. Multi-statements (ALPHA x⁻¹ for ":") show only the last result.

## Maps, charts and climate graphs

Real data, never made-up numbers: the tutor chooses a map's region and dataset, and the app draws the outlines from bundled data and downloads the statistics itself.

- **Maps** (`map`, or **Insert → Map**): the world, a continent, Oceania, Australia or a single state, or any box of longitude and latitude. Layers: political, a **blank outline** to label yourself, **climate zones** (Köppen–Geiger 1991–2020, or just the A–E groups for biomes), or a **data layer** from 41 datasets (population density, GDP per capita, life expectancy, HDI, CO₂, forest cover, urbanisation, internet use, malaria, TB, HIV, measles vaccination, child mortality, undernourishment, safe water and more) from the World Bank or Our World in Data. Every map has BOLTSS: border, orientation (north arrow), legend, title, scale bar and source with its year. The tutor can add highlighted countries or states, markers (looked up by name) and arrows for migration or the spread of disease, and it's told how longitude and latitude map onto the page, so its annotations land on the right places.
- **Climate graphs** (`climate_graph`, or **Insert → Climate Graph**): type a town ("Dubbo, NSW", "Manaus") and get the standard rainfall columns and temperature line from 30 years of ERA5 reanalysis (Open-Meteo, 1991–2020 averages), with the annual total, temperature range and climate zone. Reanalysis is a 25 km grid, so it can read low for rainfall on very wet tropical coasts compared with a local weather station.
- **Charts** (`chart`): column, bar, line, scatter with a line of best fit, and pie, for your own experiment results or textbook data (with their source), or real World Bank / Our World in Data time series for up to six countries.

Maps and data download over the internet when they're made, then live in the note, so they work offline afterwards. Bundled data sources and licences are listed in `TutorNotes.swiftpm/Resources/README.md`.

## Diagrams and flowcharts

- **flowchart:** the tutor lists boxes and arrows, and the app lays them out: top to bottom for processes and algorithms (decision diamonds, Yes/No labels, loops drawn down the side), left to right for timelines, or round a circle for cycles like the water cycle.
- **find_diagram:** the tutor searches Wikimedia Commons for a real, freely licensed diagram or photo (the heart, a plant cell, a virus, an oxbow lake), places it with a credit line, and sees it with a page-coordinate grid so its labels land on the right parts.
- **label_diagram:** labels with leader lines in neat columns beside any picture: one the tutor found, a scan from your textbook or your own drawing. In **quiz mode** the labels become numbered blanks (answers hidden), printed labels can be covered up, and tapping **Check** on the quiz has the tutor mark it.

## Code blocks (Computing Technology)

**Insert → Code Block** (first in the menu for computing subjects, under More Tools elsewhere) adds a typed code card to the page: line numbers, syntax highlighting, long lines wrapped, and the last run's output under it (errors in red). Tap it for **Edit Code** or **Run**.

- **The editor:** Python or NESA-style pseudocode; no autocorrect or smart quotes; auto-indent after `:`; Tab, Shift-Tab, ⌘[ and ⌘]; a key bar with common symbols; a **Program input** box (one line per `input()` call, echoed like IDLE); **Run** (⌘R). **Ask Tutor** saves and asks why it isn't working, to explain it, check it or give a hint. Done is one undoable step.
- **Running Python:** Pyodide 0.29.5 (Python 3.13) in a hidden web view, inside a Web Worker so a stuck loop is stopped after 10 seconds (keeping what it printed). Tracebacks are cleaned up to just your lines. Python downloads about 12 MB the first time it starts, so that needs the internet; after that it's cached. Pseudocode is highlighted but not run.
- **The tutor** reads each block's code, line positions and last output, runs code before saying what it does, points at lines instead of rewriting your program, and makes trace tables and flowcharts for algorithms.

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

- **One-row toolbar:** back, title and undo; then the pen, highlighter, eraser, lasso and text tools with the tutor's **Ask** and **Hint**; then the current pen's three colour slots and thickness; then insert, record, **⋯ More** and the tutor. Tap the tool in use for its options (pen type, eraser kind). The **⋯** menu holds Pages, Find, Paper & Page Size, Export, and the Ruler, Snap Shapes and Draw with Finger switches. In narrow windows the colours fold into one button.
- **PencilKit ink** with Apple's low-latency rendering and palm rejection. Pens: ballpoint, fountain, pencil, monoline, crayon, watercolor, plus highlighter, stroke/pixel eraser, lasso, ruler.
- **Colours:** each tool keeps its own colour and width slots; tap a selected one to edit it. The palette has **favourites shared by every tool**, presets, a custom picker (with the system eyedropper), and an **Eyedropper** that picks a colour straight off the page.
- **Lasso:** circle ink, typed text, tutor writing, images or cards to select them. Drag to move, use the corner handle to resize and the top handle to rotate (ink and marks; typed items and images stay upright). The bar recolours, changes thickness, copies, cuts, duplicates and deletes. Copy and paste works between notes (tap an empty spot with the lasso, or **+ → Paste**), and into other apps as an image.
- **Convert handwriting:** lasso some writing and tap **To Text** (read on-device with Vision) or **To Math** (read as LaTeX by Claude Haiku over your tutor connection). You check and correct the result before it replaces the ink, and undo brings the ink back.
- **Draw-and-hold shape snapping:** sketch a shape and hold: lines snap to 0/45/90°, and circles, ellipses, rectangles and triangles snap clean. Keep moving after the snap to resize, or use the **− / +** bar that appears above the shape. Apple Pencil Pro gives haptic feedback on snap.
- **Apple Pencil:** double-tap opens the tutor's Ask menu where you're working (change it in Settings to follow the system setting, switch to the eraser, or go back to the previous tool). **Squeeze** (Pencil Pro) opens the tutor menu right where you're hovering. **Hover preview** shows the nib size and colour (M2 and later iPads).
- **Finger gestures:** fingers scroll and zoom while the pencil draws (finger drawing is optional). Two-finger tap undoes, three-finger tap redoes, and double-tap opens the Ask menu.
- **Palm rejection:** a hand resting on the page while you write doesn't scroll, zoom, tap or undo. A touch counts as your hand if it lands while the pencil is on or hovering over the glass, is already down when the pencil lands, or is palm-sized.
- **Continuous pages:** blank, ruled, narrow, grid, small grid, graph, dotted and Cornell paper in six colours. Pages are added automatically as you write near the bottom. The page navigator lets you jump to, insert, duplicate, clear and delete pages, and **drag pages to reorder them**. **Page size:** Letter, A4 or either in landscape (content that wouldn't fit a smaller page is scaled down to fit). Moving, resizing and clearing are undoable.
- **Find in note** (magnifying glass or ⌘F): searches typed text, the tutor's writing, question cards, tables and your **handwriting** (read on-device), highlights every match and jumps between them.
- **Text boxes** support Scribble. **Images** come from Photos. **PDF import** creates annotatable pages, either as a new note or appended to one.
- **Export and share:** PDF (vector elements, high-resolution ink), images (a PNG per page), or the whole note as a **.margin** file, through the share sheet (AirDrop, Files, Mail…), or **Print**. A .margin file opens in Margin from AirDrop or Files, or via **New Note → Import Note File…**, as a new note with its ink, pages, attachments and recordings (not the tutor chat).
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
| `map` / `climate_graph` / `chart` | Real-data maps with BOLTSS, real climate graphs for any town, and charts of experiment or real-world data. |
| `flowchart` | Flowcharts, process chains, timelines and cycles, laid out automatically. |
| `find_diagram` / `label_diagram` | A real diagram from Wikimedia Commons, then labels or a labelling quiz on any picture. |
| `code` / `run_code` | Places a Python or pseudocode block (and can run it), or runs one of yours or a quick test off the page. |
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
  Core/                      Foundation-only logic, unit-tested on Linux: subjects and templates, map projection and
                             layout, datasets, charts and climate data, flowchart and label layout, code highlighting,
                             wrapping and tracebacks, the Python runner page
  Resources/                 Bundled data (see Resources/README.md)
  Editor/                    Editor screen, toolbar, overlays, pages, practice, audio
  Library/                   Library and settings screens
  Demo/                      Scripted walkthrough used to record the demo video (-demo-script)
server/                      Railway relay that holds the API key (Node, no dependencies)
CoreTests/                   Unit tests for the platform-independent core (run.sh)
project.yml                  XcodeGen spec for a regular Xcode project (used by CI)
.github/workflows/           macOS CI: simulator build, unsigned .ipa, demo video, server tests
```

Run the core tests on a Mac or Linux machine with Swift installed: `./CoreTests/run.sh`.

CI also runs a **feature check** in the simulator (`-feature-check`): it writes on a fresh note and drives the lasso, conversion, find, page, export and colour features through their real code paths, failing the build if any check fails.

The demo video is recorded by launching the app with `-demo-script`. Student handwriting in it is synthesised and the tutor's turns are scripted tool calls (no network), played through the real executor, streaming previews and chat panel.

## Known gaps

- Not tested on a physical iPad yet (see the status note above).
- Freeform boards grow right and down only, up to 16,384 pt a side.
- "Undo the tutor" restores a past paper's scores and removes pages the tutor added, but topic progress already recorded from that marking stays.
- The lasso rotates ink and the tutor's marks; typed text, maths, images and cards move and resize but stay upright.
- Opening a .margin file straight from AirDrop or Files needs the Xcode build (the sideloaded .ipa). In Swift Playgrounds, use **Import Note File…**.
- The page map sent to the tutor gets long for pages with many strokes. Very dense pages may need tuning.
- Maps, data layers, climate graphs and Wikimedia diagrams need the internet when they're made, and Python needs it the first time it starts (about 12 MB).
- The subject tools (maps, Python, diagrams) are checked in the simulator by CI, but not yet on a real iPad.
- iCloud sync and collaboration aren't implemented. Notes are stored locally in the app's Documents folder.
- Anyone with the server's `APP_TOKEN` can spend your Claude credits, so keep it private and rotate it if it leaks. To give the app to other people, add per-user accounts to the server.
