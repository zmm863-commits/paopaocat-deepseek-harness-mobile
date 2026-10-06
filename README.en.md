# paopaocat deepseek harness-mobile

[中文](README.md) · [**English**](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

> DeepSeek Harness on your phone — the entire DSH runtime packed into Android, with the full capabilities and the full file system, all inside your own phone. Apart from the step that calls the model, it depends on no server.

<div align="center">
  <b style="font-size:1.15em;">The complete DSH in your pocket: works offline, one sentence gets you real files</b><br><br>
  <a href="https://github.com/zmm863-commits/paopaocat-deepseek-harness-mobile/releases"><img alt="GitHub Release" src="https://img.shields.io/github/v/release/zmm863-commits/paopaocat-deepseek-harness-mobile?label=Release" /></a>
  <a href="https://github.com/zmm863-commits/paopaocat-deepseek-harness-mobile/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/zmm863-commits/paopaocat-deepseek-harness-mobile" /></a>
  <a href="https://opensource.org/licenses/MIT"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg" /></a><br><br>
  <img alt="0.19 Settings · Chinese" src="screenshots/0.19-settings-zh.png" width="23%" />
  <img alt="0.19 Settings · English" src="screenshots/0.19-settings-en.png" width="23%" />
  <img alt="0.19 Settings · Japanese" src="screenshots/0.19-settings-ja.png" width="23%" />
  <img alt="0.19 Settings · Korean" src="screenshots/0.19-settings-ko.png" width="23%" />
</div>

## 📑 Table of Contents
- [✨ Feature Overview](#-feature-overview)
- [🚀 Installation](#-installation)
- [🖼️ Screenshots](#screenshots)
- [💬 Community](#contact-and-feedback)
- [🆕 Recent Updates](#-recent-updates)
- [⚠️ Known Limitations](#known-limitations)


## ✨ Feature Overview

> For an overview of this app's features, see the "Why These Are Advantages" and "12 built-in sessions" sections below.

## 🚀 Installation

DSH is an AI agent runtime that can run on your own machine: it reads and writes files, executes tasks, calls tools, and maintains multi-turn context.

What this app does is: **fit an entire DSH runtime into an Android application, unchanged** — it embeds the Node runtime and all dependencies (`libnode.so` 49MB + `dsh-runtime.zip` 157MB, kernel `@deepseek-ai/dsh 0.1.7-rc.2`), unpacks them into the app's private directory automatically on first launch, and from then on **runs completely offline** (it goes online only when talking to a model).

It is not a web wrapper, and it is not a remote desktop. Turn off the network, and its interface, history, and files are still there on your own phone.

- Package: `paopaocat-preview-0.21-arm64-v8a.apk` · 208.8MB · arm64-v8a · minSdk 24 · **versionCode 21 / versionName 0.0.21**
- Kernel: Flutter + Node · 321 experts / 22 divisions · **12 skills** (make-image / make-video / make-slides / code-tool / data-analysis / doc-digest / doc-processing / file-organize / sheet-cleanup / study-cards / translate-polish / weekly-report + android-exec-shim + rotate-proxy)
- Appearance: dark/light themes switch with one tap and persist across restarts; **the interface language can be switched (中文 / English / 日本語 / 한국어)**; custom color schemes are a placeholder description and will not switch to a state that does not exist
- Privacy: API Keys are stored only in the Android Keystore, sessions and outputs are in a private directory, and your confirmation is required before execution

## Installation

- A real arm64 device, with installation of unknown apps allowed
- On first launch after installation the runtime is unpacked (about 30 seconds), and it can be used offline after that
- arm64-v8a single-architecture package only; x86/armeabi devices are not compatible
- **No uninstalling needed to upgrade**: 0.19 and 0.14 are signed with the same certificate (debug certificate `7aaf4448…d3cc17`), the versionCode increases, and you can **install directly over the previous version, losing neither sessions / files / Keys**

```sh
# 校包体
sha256sum paopaocat-preview-0.21-arm64-v8a.apk
# expected: 0e70299155c8a8a61fb4641c003610bdf468bd9c1b962b0b32ea6c0ce887efd6
```

## Quick Start

1. **Set up a model**: Settings → choose DeepSeek official / Command / LongCat / MiMo (endpoints are pre-filled) → enter the Key → **Fetch models** (multi-select supported) → check the ones you want → **Test and save** (it really sends a minimal conversation, and only shows ready once it goes through); if you need to resist rate limits, you can create a **model rotation pool** (multiple models tried in order, automatically switching to the next on 429; see below for details)
2. **Start a session**: home page **Start new session** → type your request → watch the streaming echo, tool-call cards, and artifact cards; you can **interrupt / continue**
3. **Use experts and skills**: turn on the experts you need in the Expert Center (the toggle really writes to the runtime configuration) → go back to the session and state your request; you can also simply ask the model to "generate a skill for me"
4. **Make images / videos / PPTs**: tell the model "generate an image / make a video / make a PPT", and it will call `make-image.mjs` (text-to-image / image-to-image / multi-image composition, 1K-4K, 8 aspect ratios, currently free) / `make-video.mjs` (text-to-video / first-and-last frames, 4-12 seconds) / `make-pptx.mjs` (a real .pptx, cover + bullet points + notes) to produce **real files** in the workspace; if no Key is configured it reports an error in Chinese along with a registration URL
5. **Collect files**: session outputs automatically go into the **Library** → **Workspace**, with multiple directories in parallel; if you need them on a schedule, create a task (every day / weekdays / every week / once only) and it runs itself at that time (this depends on the persistent notification and, under the power-saving policies of some Chinese ROMs, may be marked "missed")
6. **Attachments and the 12 built-in sessions**: take a photo (system camera → private directory) / pick images and videos from the gallery / any file (give a real path and the model can read it) / voice (uses system recognition); the home page has **12 built-in sessions, each with one skill**, showing 4 at a time, and tapping **Shuffle** lets you see all 3 groups

**12 built-in sessions × 12 skills (tap Shuffle on the home page to see them all; tapping any one opens a session)**

| # | Session entry (home page) | Skill behind it | What it can do in one sentence |
|---|---|---|---|
| 1 | Generate an image | `make-image` | Text-to-image / image-to-image / multi-image composition, 1K-4K, 8 aspect ratios, Agnes free |
| 2 | Generate a video | `make-video` | Text-to-video / first-and-last frames, 4-12 seconds, asynchronous polling |
| 3 | Make a PPT | `make-slides` (`make-pptx.mjs`) | A real .pptx (16:9, cover + bullet points + notes) |
| 4 | Write a small tool | `code-tool` | A single self-contained .mjs, pure Node built-in modules, running successfully on the spot |
| 5 | Analyze data | `data-analysis` | Really computes over CSV/JSON, producing a Markdown report + offline HTML charts |
| 6 | Clean up a spreadsheet | `sheet-cleanup` | Deduplicates / normalizes formats / fills in fields / groups and aggregates a dirty CSV, saved as clean-*.csv |
| 7 | Speed-read long text | `doc-digest` | Compresses long text into a quick-read draft of key points / a timeline / key numbers |
| 8 | Process documents | `doc-processing` | Summarize / rewrite / correct / convert to Markdown/HTML, producing new files |
| 9 | Organize files | `file-organize` | Produces a plan for confirmation first, then archives / batch-renames, and can be rolled back |
| 10 | Make study cards | `study-cards` | Turns material into question-and-answer cards, producing Markdown + an importable CSV |
| 11 | Translate and polish | `translate-polish` | Chinese-English translation / polishing, producing a bilingual side-by-side Markdown |
| 12 | Write a weekly report | `weekly-report` | Scans the workspace for new/changed files and summarizes them into a weekly report with paths |

> The home page shows 4 at a time; tapping **Shuffle** switches a whole group, and tapping it 3 times shows all 12; each entry is already bound to its skill, so opening it starts a session with the context in place.

## 🆕 0.21 Update · Models are now split in two: Cloud models / On-device models

- **"Settings → Models" is renamed to "Cloud models"**: that section is about models reached through a vendor API, and the name now says so instead of blurring together with models running on the phone itself.
- **A new standalone section, "On-device models"**: everything about running models locally (download / import from a local file / start the service / benchmark) now lives there instead of being tucked into the cloud card.
- **One name everywhere**: both the entry and the page title now read "On-device models" (previously "端侧模型", a term easily mistaken for an input method or offline speech feature).
- **A real bug is fixed**: after starting the local service, it was **invisible in the session model picker** (the picker reads the App's own model store, while the local model had only been written into the DSH config). It now shows up as an **"On-device models"** group, like the rotation pool.
- **The "On-device models" page was rebuilt to match the App's own look**: the same glass cards / collapsible sections / entry rows (**one shared implementation**, the same one the Settings page uses), and only four font sizes (13 / 11 / 12 / 15) — the previous version invented its own scale, which looked glaring once the global text scale was applied.
- **"About" no longer has its title glued to the card**: the gap now matches every other section.

## 🕘 0.20 Update · Run large models locally on the phone (works offline)

- **Run large models locally on the phone (works offline)**: install a model file into the App and a `local` vendor shows up in DSH — inference runs entirely on the phone, so **airplane mode works**.
- **Two backends, switchable, with a one-tap benchmark**: GPU (Vulkan) by default, or switch back to CPU only; tap **Benchmark** to see this phone's generation speed (tok/s) and first-token latency.
- **Two ways to get a model**: ① download in-app (12 built-in model entries, the China main mirror measured at 4–5 MB/s, multi-source picking the fastest + resume); ② import a local file (cloud drive / WeChat / USB cable, **multi-select**, no storage permission needed).
- **Anything installed must pass verification**: the file size is checked, and once sha256 is filled in, every byte is verified; a file that fails is not registered as "installed".
- **Honest boundaries**: on-device inference needs **Android 9 or newer**; models that do not fit the RAM show the required GB; model files are not bundled (the App is still in the 200 MB range).

## 🕘 0.19 Update · Switchable interface language (Chinese / English / Japanese / Korean)

**A new "Language" item under "Settings → Appearance"**: four buttons — 中文 / English / 日本語 / 한국어 — and one tap switches the interface **immediately**, with the choice persisting across restarts.

- **Everything the app draws itself is available in all four languages**: the bottom navigation, the six settings sections, buttons, empty-state hints, built-in error explanations and suggested next steps — **738** pieces of interface text, each with English / Japanese / Korean translations
- **Content supplied by the DSH running on your computer stays in its original language**: session messages, skill names, the 321 experts, and backend errors are all sent back by the desktop side, and the app does not decide their language for it. This boundary is stated under "Appearance → Language"; it is not unfinished work
- **The language buttons are labelled in each language's own native name**: even when the interface has already switched to Japanese, a Korean user can spot 「한국어」 at a glance
- **The repository description and screenshots also come in four languages**: this document has [`English`](README.en.md) · [`日本語`](README.ja.md) · [`한국어`](README.ko.md) versions

See [`docs/changelog-0.21.md`](docs/changelog-0.21.md) for the itemized notes.

## 🆕 0.18 Update (0.15 → 0.18 · 25 items)

Package `paopaocat-preview-0.18-arm64-v8a.apk` · 188MB · **versionCode 18 / versionName 0.0.18**, signed with the same debug certificate as 0.14 (`7aaf4448…d3cc17`), **so it can be installed directly over the previous version without losing data**.
See [`docs/changelog-0.18.md`](docs/changelog-0.18.md) for the itemized notes; the summaries below are organized by version (the content comes from "Settings → About → Update notes" inside the app, `app/lib/data/changelog.dart`, item by item, with nothing added).

### 0.15 (11 items) · Building features

- **Voice input really works for the first time**: previously "hold to talk" only **started recording after you let go** — nothing at all was recorded during the whole time you were speaking into the phone, so it captured silence and necessarily failed, which meant that opening the microphone permission made no difference; now it starts listening on press and stops on release
- **Conversations can be copied**: long-press a user message or an assistant reply to select and copy it
- **Swipe left and right to switch pages** (Home / Experts / Library / Scheduled tasks / Settings); the outermost 24 pixels do not respond, so as not to fight with the system edge-back gesture
- **Sessions can be renamed**: long-press the session on the workspace page to give it a name (the name is stored only in this app; the ACP protocol has no rename feature and the DSH side is unaffected)
- **A new "Phone permissions" section**: shows whether microphone / location / gallery / notifications are currently granted, opens the system permission dialog with one tap, and gathers the entries for special permissions such as "access to all files" (Android has no "grant all permissions with one tap", and special permissions must be enabled on the system page yourself)
- **Images can really be understood now**: previously sending an image just handed its path to the model, and a text-only model could only reply "I can't see the image"; now there is a built-in **free vision chain** (no Key required) that automatically converts the image into a text description and then passes it to the model. ⚠️ Images are uploaded to a third-party service, so do not put sensitive content through this path
- **Files produced by a session are kept, and you know which session produced them**: previously, leaving a session and coming back left the artifact list empty
- **Long-session assistant** (the ＋ menu to the left of the input box): estimates how much of the current context has been used, and generates a "handover note" with one tap, inserting it into the input box so you can carry on in a fresh window
- **Switching to another page no longer interrupts an answer**: session processes are managed by the app as a whole, so if you go to the library or change something in settings, the answer being generated keeps running to completion; "session name (answering)" appears at the top of the home page, and tapping it takes you straight back to that session
- **Multiple sessions can be open at the same time**: while the previous one is still running, you can go back to the home page and start a new one, and they do not disturb each other
- The background grid lines were made brighter (they used to be at only 3.5% opacity, which is effectively invisible)

### 0.16 (6 items) · Fixes based on real-world feedback

- **Fixed "ask the model to generate a file, but it does not appear among the artifacts"**: two bugs overlapped — ① the rule for recognizing filenames **swallowed the leading `/` of an absolute path**, so the file was looked for as a relative path, was never found, and was silently dropped; ② the notification at the moment a tool **completed** no longer carried parameters, while the app had previously taken only the single field "command" from the **start** notification, so the target path of tools such as "write file" was lost that way. Both were fixed, and regression tests were added to lock them down
- **Removed the grid lines and brightened the background by one step**: there are no lines at all now, only a soft glow spreading faintly downward from the top, and the base color is one step brighter than the near-dead black it was (using near-black rather than dead black, and layering by brightness rather than applying textures)
- **The "Long-session assistant" panel is now an opaque solid color**: it used to be semi-transparent and blended with the content behind it, making the text hard to read
- **The settings page now collapses "Model / Phone permissions / File locations" into dropdowns**: they expand only when you tap the title (the arrow turns around), and once collapsed you can see a whole screen at once
- **Two more "stuck and still no sound" spots in voice were fixed**: ① when device-side recognition **reported an error synchronously**, it used to be returned directly as "nothing recognized"; now it **falls back automatically** to system recognition, the same as for "recognition failed"; ② when nothing is recognized it now also looks up the **device capabilities** and tells you, instead of a vague "nothing recognized"
- **A new "Voice input" self-check** (Settings → Phone permissions → Voice input): directly shows whether this phone has a usable recognition service, whether it supports on-device offline recognition, and how many apps can handle recognition

### 0.17 (3 items)

- **All six settings sections are collapsed into dropdowns** (Appearance / Model / Plugins / Phone permissions / File locations / About): on entering you see only six title rows, and only the row you tap expands
- **Every section name is bolder and larger**: with the content collapsed by default, the section row is the only visual anchor on this page, and text that is too small reads like "descriptive text" rather than a "heading"
- The expand arrow **turns around** when you tap it (rather than switching instantly), so you can tell at a glance whether it is currently collapsed or open

### 0.18 (5 items) · This release

- **Left/right swiping is now "the page follows your finger" instead of "jumping instantly"**: the page follows as you drag your finger, and on release it springs to the target page with inertia (with animation)
- **Fixed "you could only swipe twice to exit once you were on the last page"**: finger-following paging briefly also captured swipes at the very edge of the screen (which should belong to the system back gesture), with the result that swiping from the edge on the middle pages only changed pages; **now 32 pixels are left unresponsive on each side**, and swiping from the edge is still "back"
- **"About" is no longer collapsed into a dropdown; it stays open**: what it holds — the official account QR code, contact details and the like — is meant to be seen at a glance
- **"Rotation pool" is renamed "Model rotation pool" and becomes a separate section**: it used to be tucked inside "Model", where you had to expand Model and scroll down to find it; now it sits alongside "Model", so you know at a glance that such a thing exists and can expand it on its own
- The other five sections (Appearance / Model / Plugins / Phone permissions / File locations) remain dropdowns; the "About" section name uses the **same style** as theirs (bolder and larger), so it still looks like one group

### 0.14 and earlier

The 36 itemized notes for 0.14 are in [`docs/emergency-update-0.14.html`](docs/emergency-update-0.14.html) (all 36 listed item by item) and [`docs/preview.md`](docs/preview.md): generated files usable (1-5), artifacts are real files only (6), models and Keys (7-19), interface (20-26), sessions and daily use (27-34), voice (35-36, some not fully fixed).

> Why the local voice model is not bundled: the voice model shipped with DSH provides native libraries only for macOS/Linux/Windows, and Android bionic is not on the supported list; moreover the int8 model is 239MB, so putting it in the package is not realistic. The voice capability in 0.15–0.18 works through **the system recognition service + on-device offline recognition (Android 12+)**; if the voice self-check added in 0.16 shows "no usable speech recognition service", that means no recognition service is installed in your phone's system, and you need to install a voice-assistant type app yourself or switch to text input.

### Model rotation pool (binding several free models into one rate-limit-resistant model)

In the app, **Settings → Model rotation pool** (separate from "Model" and alongside it since 0.18) lets you **bind multiple models in order into one group** (for example, the free-quota models from various vendors) and then talk to them using **the group name as the model name**:

- How it works: a local `rotate-proxy.mjs` (pure Node built-in modules, no third-party dependencies) starts an OpenAI-compatible proxy on `127.0.0.1:39321` and tries the members one by one in group order; on **429 rate limiting / 500 / connection failure** it automatically moves to the next one, and the client sees only one successful response
- Stickiness: it remembers each group's **most recent successful member** (`lastGood`, in memory plus written back to the configuration), starts from it next time, and rotates onward on failure
- Exposed endpoints: `GET /health`, `GET /v1/models` (one model per group), `POST /v1/chat/completions` (matching either the group name or a member's real model name, and supporting prefix/suffix forms such as `rotate/cat`)
- Streaming limitation (an HTTP protocol constraint): it can switch members only while it has **not yet sent a single byte to the client**; once SSE piping has started it can no longer switch (at that point, a mid-stream disconnect can only end this response and log it)
- Typical use: put DeepSeek free, Qwen free, MiMo free and so on one after another into the same group; daily conversation goes through the group name, and quota/rate limiting is covered automatically, with no manual switching

## Known Limitations

- The persistent background notification depends on the system's power-saving policy; some Chinese ROMs still kill the process, and missed tasks are honestly marked "missed" (rather than pretending they ran)
- arm64-v8a single architecture only, 208.8MB for a single package
- Plugin installation is not open yet (the security validation and rollback mechanisms need to be finished first; the Settings → Plugins page says so honestly)
- The local voice model is not bundled (see the reason above); recognition quality depends on the system's offline models / recognition services

## Why These Are Advantages (the full feature set, with no weaknesses hidden)

| Dimension | Advantage |
|---|---|
| **A real local runtime** | Not a web wrapper or a remote desktop; `libnode.so` + `dsh-runtime.zip` are packed completely into the APK, and after the first unpack it works offline, with the interface / history / files all in a private directory |
| **The files are real** | The library offers dual mtime/directory views, the workspace is a real directory, multiple workspaces run in parallel without interfering with one another, artifacts pass a double threshold against fake files, and generated results render and share directly |
| **Attachments go through system-native paths** | Photo capture opens the system camera, the gallery provides images and videos, any file is given by its real path, and voice uses system recognition; there are no fake "upload successful" prompts, and whether something can be understood depends on the model's vision capability, which we state honestly |
| **321 experts really take effect** | The 22 division toggles are written to `$DSH_HOME/AGENTS.md` (the agent-instructions channel) and the model follows the persona; skills can be created new, or generated in conversation |
| **Scheduling is real scheduling** | Every day / weekdays / every week / once; at the scheduled time it runs through the same channel as a conversation, recording success/failure/missed, and never pretending it ran (depends on the persistent notification) |
| **The least trouble to connect a model** | 4 vendors' endpoints pre-filled, multi-select when fetching models, test-and-save through the real conversation channel, errors translated into Chinese with the next step, and switching models without losing the chat history |
| **A rotation pool that resists rate limits** | Several free models bound into one group; on 429/500/disconnect it automatically switches to the next, with `lastGood` stickiness so the next run starts from the last success; streaming can switch only before bytes are sent (this protocol constraint is stated honestly) |
| **Image / video / PPT generation** | One sentence yields real files: image generation (text-to-image / image-to-image / multi-image composition, 8 ratios / 1K-4K), video generation (text-to-video / first-and-last frames, 4-12 seconds), a real .pptx; `android-exec-shim` fills in the execution chain for phones that have no bash |
| **Privacy and control** | Keys are stored only in the Android Keystore and never enter logs or the command line; a confirmation dialog appears before execution (tool name + specific content); runtime logs export with one tap and Keys are redacted automatically |
| **A usable interface** | Dark and light themes switch with one tap and persist across restarts, the model panel goes two levels from vendor → model and takes effect with one tap, the top-right corner is unified as the workspace entry, the home page's 12 built-in sessions shuffle by group, the 320px-wide screen issue is fixed, and edge side-swipes require a second confirmation before exiting |
| **Installation and upgrades** | Over-the-top installation with a matching signature, so sessions / files / Keys are preserved; package naming is uniform as `paopaocat-preview-<version>-<abi>`; a single 208.8MB package (versionCode 21 / versionName 0.0.21), minSdk 24 |

## Screenshots

**The 0.19 interface · one page in four languages** (real rendered images exported from the Flutter rendering pipeline, not mockups)

| | | | |
|---|---|---|---|
| ![](screenshots/0.19-settings-zh.png) | ![](screenshots/0.19-settings-en.png) | ![](screenshots/0.19-settings-ja.png) | ![](screenshots/0.19-settings-ko.png) |
| Settings page · 中文 | Settings page · English | Settings page · 日本語 | Settings page · 한국어 |

*Dimensions: 1236×2745 (3x pixels). The language switch is in "Settings → Appearance"; the four languages are rendered by the same code, not stitched together.*

**The 0.18 interface** (retained for history)

| | | |
|---|---|---|
| ![](screenshots/0.18-settings-dark.png) | ![](screenshots/0.18-settings-light.png) | ![](screenshots/0.18-model-rotate-pool.png) |
| Settings page · Dark (six sections collapsed) | Settings page · Light | Model rotation pool · Expanded |

**Historical screenshots** (retained from 0.14 · taken on real devices)

| | | | |
|---|---|---|---|
| ![](screenshots/shot-01.jpg) | ![](screenshots/shot-02.jpg) | ![](screenshots/shot-03.jpg) | ![](screenshots/shot-04.jpg) |
| ![](screenshots/shot-05.jpg) | ![](screenshots/shot-06.jpg) | ![](screenshots/shot-07.jpg) | ![](screenshots/shot-08.jpg) |

*The 4 images above (plus 3 historical ones) reflect the current **0.19** interface; the 8 below are shots retained from real devices running 0.14, unretouched (exported from the 10 base64 images inside `紧急更新.html`, with 8 from the 720 series selected as store screenshots).*

## Contact and Feedback

- **Official account: paopaocat (ID: paopaocat888)** — scan the code to follow, **leave a comment right in the official account to discuss**, and send **888** in a private message to get the package download link
  - QR code: `screenshots/wechat_qr.png` · you can also scan it at the end of `docs/emergency-update-0.14.html` to follow
  - Good for: usage questions, feature suggestions, reproduction reports (lighter-weight than a GitHub Issue, and convenient for leaving a quick note from your phone)

- **GitHub Issues**: https://github.com/zmm863-commits/paopaocat-deepseek-harness-mobile/issues — for bugs, requests, and compatibility reports

## 🆕 Recent Updates

See [`docs/changelog-0.19.md`](docs/changelog-0.19.md) and [GitHub Releases](https://github.com/zmm863-commits/paopaocat-deepseek-harness-mobile/releases)

## Related

- Desktop version: `dshpack-017` (Win/macOS)
- **0.21 release notes: `docs/changelog-0.21.md` (models split into cloud / on-device)**
- 0.20 release notes: `docs/changelog-0.20.md` (running models locally on the phone, including boundaries and known limits)
- 0.19 release notes: `docs/changelog-0.19.md` (interface localized into four languages, including the boundary note)
- 0.18 release notes: `docs/changelog-0.18.md` (0.15–0.18 item by item, including upgrade and signing notes)
- Preview write-ups: `docs/preview.md` / `docs/emergency-update-0.14.html`
- Feedback: GitHub Issues + official account comments (two channels)

## License

MIT
