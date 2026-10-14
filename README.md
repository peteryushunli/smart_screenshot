# smart_screenshot

Smart Screenshot will eventually rename new macOS screenshots so you can recognize them in Finder.

**Milestone 1** is a command-line tool that only *proposes* descriptive filenames for screenshots you
already have, so filename quality can be evaluated first. It never renames, moves, modifies, or deletes
any file. Folder watching, renaming, a background service, and a GUI are out of scope for this milestone.

```
Screenshot 2026-10-07 at 14.32.05.png  →  Python missing pandas module — 2026-10-07 143205.png
```

## Requirements

- Runs on macOS 13 or later.
- Building needs a Swift 6.1 or later toolchain (Xcode 16.3 or later). It was developed and tested with
  Xcode 27 (Swift 6.4) on macOS 26.
- No third-party packages. The tool uses Apple Vision for OCR, ImageIO for decoding, and URLSession for
  the optional Gemini provider. It does not need Apple Intelligence or Foundation Models.

## Build and test

```bash
swift build
```

```bash
swift test
```

The tests draw synthetic screenshots at run time and run real Vision OCR on them. All Gemini traffic is
mocked, so the tests need no API key or network access, and no real screenshots are committed.

## Usage

```bash
swift run smart-screenshot propose "/path/to/samples" --provider local
```

```bash
swift run smart-screenshot propose "/path/to/samples" --provider gemini
```

```bash
swift run smart-screenshot propose "/path/to/samples" --provider gemini --format json
```

| Argument | Meaning |
| --- | --- |
| `<path>` | One image, or a folder. For a folder, only its immediate children are processed, in Finder-like name order (`Shot 2` before `Shot 10`). Hidden files and subfolders are skipped. |
| `--provider local` | On-device OCR plus a heading heuristic. Makes no network requests. This is the default. |
| `--provider gemini` | On-device OCR, then the extracted text and layout (never the image) go to the Gemini API. Requires `GEMINI_API_KEY`. |
| `--format text` / `json` | Human-readable report (default) or a single JSON document on stdout. |
| `--model <code>` | Gemini model code. Defaults to `gemini-2.5-flash-lite`. Only valid with `--provider gemini`. |

Supported inputs are PNG, JPEG, and HEIC/HEIF files that macOS can decode. Each file is handled on its own,
so a corrupt or unreadable file is reported as `error` and the rest of the batch continues.

`swift run -q` hides build progress. For piping JSON, build once and call the binary directly:

```bash
swift build -c release
```

```bash
.build/release/smart-screenshot propose ~/Desktop --format json > proposals.json
```

### Try it on your own screenshots

macOS saves screenshots to the Desktop unless you changed it (check **Screenshot › Options**). Copy a few
into a scratch folder first if you like. The tool only reads them either way. Use `cp -p` so the creation
times used for timestamps are preserved.

```bash
mkdir -p ~/screenshot-samples && cp -p ~/Desktop/Screenshot*.png ~/screenshot-samples/
```

```bash
swift run -q smart-screenshot propose ~/screenshot-samples --provider local
```

```bash
swift run -q smart-screenshot propose ~/screenshot-samples --provider gemini --format json
```

### Text output

```
Smart Screenshot 0.1.0 — proposed names only; no files are renamed or modified.
Provider:   local (heuristic) — on-device OCR heading heuristic (not an AI summary); makes no network requests
Input:      /Users/you/screenshot-samples (4 images; 1 other entry ignored)
Timestamps: file creation time, an approximation of capture time

[1/4] article.heic
  status:   proposed
  proposed: How to Configure Swift Package Manager — 2026-10-07 120046.heic
  provider: local (heuristic)

[2/4] corrupt.png
  status:   error — could not decode the image (corrupt file or a format this Mac cannot read)
  proposed: corrupt.png (unchanged)
  provider: local (heuristic)

[3/4] Screenshot 2026-10-07 at 9.05.11.png
  status:   skipped — no prominent heading found in the OCR text
  proposed: Screenshot 2026-10-07 at 9.05.11.png (unchanged)
  provider: local (heuristic)

[4/4] Screenshot 2026-10-07 at 10.00.00.png
  status:   skipped — no readable text found; text-free screenshots are not named by this prototype
  proposed: Screenshot 2026-10-07 at 10.00.00.png (unchanged)
  provider: local (heuristic)

4 files: 1 proposed, 2 skipped, 1 error. No files were modified.
```

With `--provider gemini`, each `provider:` line also shows the model and the tokens used, and a total is
printed at the end.

### JSON output

The JSON report carries the same information. Every result has the same keys, and absent values are `null`.
This example shows a Gemini result with illustrative token counts, reformatted for brevity:

```json
{
  "files_modified": false,
  "input": { "ignored_entry_count": 0, "image_count": 1, "kind": "file", "path": "/Users/you/a.png" },
  "provider": {
    "description": "OCR runs on-device; extracted text and layout (never image pixels) are sent to the Gemini API",
    "id": "gemini",
    "kind": "language-model",
    "model": "gemini-2.5-flash-lite",
    "sends_text_off_device": true
  },
  "results": [
    {
      "ocr_line_count": 5,
      "original_filename": "a.png",
      "proposed_filename": "Python missing pandas module — 2026-10-07 143205.png",
      "provider": "gemini",
      "reason": null,
      "status": "proposed",
      "timestamp": "2026-10-07T14:32:05+08:00",
      "timestamp_source": "file-creation-time",
      "title": "Python missing pandas module",
      "usage": { "output_tokens": 9, "prompt_tokens": 512, "total_tokens": 521 }
    }
  ],
  "summary": { "errors": 0, "proposed": 1, "skipped": 0, "total": 1, "usage": { "output_tokens": 9, "prompt_tokens": 512, "total_tokens": 521 } },
  "timestamp_note": "Timestamps use file creation time, an approximation of capture time.",
  "tool": "smart-screenshot",
  "version": "0.1.0"
}
```

| `status` | Meaning | `proposed_filename` |
| --- | --- | --- |
| `proposed` | A new name is suggested. | The suggestion. |
| `skipped` | Not enough useful evidence. | The original name, unchanged. |
| `error` | The file could not be processed (unsupported, undecodable, provider or network failure). | The original name, unchanged. |

`usage` holds the token counts Gemini reports: `prompt_tokens`, `output_tokens`, `total_tokens`, and
`thoughts_tokens` for models that think. It is `null` for the local provider and for requests that never
got an answer.

Exit status: `0` when every file was proposed or skipped, `1` when at least one file failed (the others
were still processed), and `2` for invalid usage or configuration, such as a missing API key. In that case
nothing is processed, and JSON mode prints `{"error": {"kind": …, "message": …}}`.

## Local OCR versus cloud text processing

| | `--provider local` | `--provider gemini` |
| --- | --- | --- |
| OCR | Apple Vision, on this Mac | Apple Vision, on this Mac |
| Network | None | HTTPS to `generativelanguage.googleapis.com` |
| What leaves the Mac | Nothing | OCR text with likely secrets redacted, each line's position, relative size, and OCR confidence, and the image's pixel dimensions |
| Never sent | — | Image pixels, filenames, folder paths |
| How the title is made | A heuristic copies one visually prominent OCR line, such as a page heading, verbatim. **This is not an AI summary.** | The model writes a short title from the OCR text. The title is then sanitized and checked locally. |

Before Gemini sees anything, OCR text is redacted on the Mac. Email addresses, phone numbers, long digit
sequences (card, account, ID numbers), labelled passwords and tokens (`Password: …`), long random-looking
strings such as API keys, and URL query strings become placeholders such as `[email]`. Redaction is
best-effort pattern matching. Any other text visible in a screenshot can still be sent, so use `local` for
screenshots you do not want processed in the cloud.

## Gemini setup

1. Create a key in Google AI Studio at <https://aistudio.google.com/apikey>. Since May 28, 2026, new AI
   Studio keys are created as "auth keys", and the Gemini API rejects unrestricted standard keys. Restrict an
   older key to the Gemini API in AI Studio if requests are refused.
2. Provide the key through the environment, never in repository files. The tool reads only `GEMINI_API_KEY`.
   It sends the key in the `x-goog-api-key` header (never in a URL) and never prints or logs it.

   ```bash
   export GEMINI_API_KEY="paste-your-key-here"
   ```

   To keep the key in the macOS Keychain instead of a shell profile, store it once (with `-w` last,
   `security` prompts for the key so it stays out of shell history):

   ```bash
   security add-generic-password -a "$USER" -s gemini-api-key -w
   ```

   Then load it in each shell where you run the tool:

   ```bash
   export GEMINI_API_KEY="$(security find-generic-password -a "$USER" -s gemini-api-key -w)"
   ```

3. Model availability. The default is `gemini-2.5-flash-lite`. As of October 2026, Google limits 2.5 models
   to keys that have used them before and recommends `gemini-3.5-flash-lite` for new projects. If you get
   HTTP 403 or 404, try:

   ```bash
   swift run -q smart-screenshot propose ~/screenshot-samples --provider gemini --model gemini-3.5-flash-lite
   ```

If `GEMINI_API_KEY` is missing, the tool exits with a configuration error before reading any image.

### Request details

These were checked on 2026-10-07 against the generateContent API reference
(<https://ai.google.dev/api/generate-content>), the model, thinking, and troubleshooting guides, and the
request mapping in Google's google-genai SDK (v2.28.0).

- `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`.
- Structured output uses `generationConfig.responseMimeType: "application/json"` with
  `generationConfig.responseJsonSchema`, the same fields Google's SDK sends to the Gemini API. The schema
  allows exactly two outcomes: `{"outcome": "title", "title": "…"}` or
  `{"outcome": "insufficient_information", "title": ""}`. Anything else is reported as a malformed response.
  The reference also lists a newer `responseFormat` field. The tool does not use it, because Google's SDK
  does not send it to the Gemini API and it could not be verified live.
- The system instruction treats OCR text as untrusted data, including any instructions that appear inside a
  screenshot. OCR lines are sent as JSON strings so screenshot text cannot break out of the data block.
- Input is bounded to 150 lines and 8,000 characters of OCR text per screenshot (300 per line). When a
  screenshot has more, prominent lines (likely headings) are kept first. Output is bounded by
  `maxOutputTokens: 512`.
- Each attempt times out after 30 seconds, with at most 3 attempts per screenshot. Only HTTP 408, 429, and
  5xx responses and transient network errors are retried, with exponential backoff (about 1 s, then 2 s,
  plus jitter). A server-suggested delay (`Retry-After` or `RetryInfo`) is honored up to 20 seconds;
  longer waits, such as an exhausted daily quota, fail that file instead. Screenshots are processed one at
  a time.
- No `temperature` or `thinkingConfig` is sent. `gemini-2.5-flash-lite` does not think by default, and
  Google recommends the default temperature for Gemini 3 models, so `--model` overrides keep working.
- The model's self-reported confidence is never used. Instead, a model title must share at least one
  distinctive word (or, for Chinese, Japanese, and Korean, a two-character run) with the OCR text.
  Otherwise the file is skipped as possibly invented.

## Filename policy

Proposed names have the form `<title> — <yyyy-MM-dd HHmmss>.<original extension>`.

- **Title:** a short description of the main visible subject plus a distinguishing detail, about 3–7
  words. It must not guess why the screenshot was taken or add facts that are not in the text.
- **Not generic:** titles made only of words like "screenshot", "webpage", "window", "app", or "settings"
  are rejected, and framing such as "Screenshot of …" is removed.
- **Safe single filename:** `/ \ : * ? " < > |`, control characters, and invisible formatting characters
  (including bidirectional overrides that can disguise a name) are removed. A name never starts with a dot
  or hyphen. Readable Unicode, including accents, CJK, and emoji, is kept and normalized to NFC.
- **Length:** the title is capped at 80 characters, cut at a word boundary when possible, and the whole name
  stays within APFS's 255-byte limit.
- **No credentials or incidental identifiers:** the same patterns that are redacted before upload are
  removed from titles.
- **Extension:** preserved exactly, including case (`.PNG` stays `.PNG`).
- **Timestamp:** taken from the file's creation time and formatted in the Mac's time zone. This
  approximates capture time, because macOS writes a screenshot when it is taken. Copying with tools that
  do not preserve dates (for example `cp` without `-p`) resets it. If a volume does not record creation
  time, the modification time is used, and the JSON says so in `timestamp_source`.
- **Missing evidence:** if there is no readable text, the provider reports insufficient information, or
  the title fails any check above, the original filename is kept and the file is reported as `skipped`.

## Limitations

- **Text-free screenshots are outside this prototype's reliable naming capability.** Neither provider
  looks at image pixels, so photos, illustrations, unlabeled charts, maps without labels, games, and video
  frames are skipped with "no readable text found". This is deliberate: there is no evidence to name them
  from without image understanding.
- The local heuristic only names screenshots with a visually prominent heading, at least 1.5× the median
  text height. Uniform text, as in terminals, code editors, chats, and spreadsheets, is usually skipped
  rather than guessed. Gemini handles these better.
- OCR errors carry through. For example, Vision can read `analyze.py` as `analyze•py`.
- Proposals are not checked for collisions with each other or with existing files. The renaming milestone
  must handle that.
- Redaction and grounding are pattern-based safety nets, not guarantees.
- Gemini integration is covered by tests with mocked HTTP responses. It still needs a live run with a real
  key. Screenshots are sent one at a time, so large batches on a free-tier key can hit rate limits; those
  files are reported as errors after bounded retries.

## Code layout

```
Sources/SmartScreenshotCore/
  OCR/          VisionTextRecognizer → RecognizedDocument (per line: text, normalized box, OCR confidence)
  Naming/       NamingProvider protocol, LocalHeadingProvider, GeminiNamingProvider, GeminiWireFormat, HTTPTransport
  Filenames/    TitleSanitizer and TitlePolicy, SensitiveText, FilenameFormatter and FileTimestamp
  Proposal/     InputCollector (what to process), ProposalRunner (one file at a time, failures isolated)
  CLI/          CommandLineParser, SmartScreenshotCLI (orchestration), ReportRendering (text and JSON)
Sources/smart-screenshot/main.swift    thin executable entry point
Tests/SmartScreenshotCoreTests/        Swift Testing suites, synthetic image drawing, and test doubles
```

A new naming backend implements one method of `NamingProvider`, which receives OCR text and layout
(`RecognizedDocument`) and returns either a raw title or an insufficient-information outcome. OCR, title
sanitizing, validation, and filename formatting stay shared.
