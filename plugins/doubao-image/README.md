# doubao-image — generate images with the local Doubao app

> 面向：使用者 · 状态：stable · 最近核对：2026-09-20

Registers one tool, `generate_image`, that drives the **locally installed and
logged-in Doubao (豆包) desktop app** to produce a picture, saves the
full-resolution file, and sends it into the conversation.

```
plugins/doubao-image/
├── package.json          # type: module, dsh.bundle.patch, exports
├── cordis.patch.yml      # bundle patch: the loader row
├── lib/
│   ├── index.js          # cordis plugin: the generate_image tool
│   ├── doubao.mjs        # app launch, prompt submission, result harvest
│   ├── cdp.mjs           # dependency-free Chrome DevTools Protocol client
│   ├── watermark.mjs     # removes Doubao's own overlay, with a self-check
│   ├── image.mjs         # minimal PNG codec + raster helpers
│   └── generate.mjs      # CLI driver, for testing without spending a model turn
└── test/                 # node --test (no DSH, no app, no network)
```

## Install

```bash
# from npm
dsh plugin --profile web add dsh-plugin-doubao-image

# or from the repository root — the leading ./ matters: DSH anchors relative specs
# against your current directory, otherwise pnpm would resolve it inside the profile
dsh plugin --profile web add ./plugins/doubao-image
```

Then restart DSH (or reload the profile). The tool appears as `generate_image`.

## Use

```bash
# exercise the whole path without going through the model
node plugins/doubao-image/lib/generate.mjs \
  --prompt "一只戴黄铜护目镜的橘猫，坐在双翼飞机驾驶舱里" \
  --style "黏土质感 C4D 渲染，暖色夕阳光" \
  --out ~/Pictures/doubao
```

The tool takes `prompt` (required) plus `style`, `composition`, `aspect`,
`negative`, `count`, `dir`, and `reuseCurrentChat`.

## How it works, and why it is built this way

Doubao ships a **full Chromium** (`Contents/Helpers/Doubao Browser.app`), and its
launcher forwards unknown flags, so starting it with `--remote-debugging-port`
yields a real CDP endpoint. That is the whole reason this works without the
macOS Accessibility permission that `osascript` would need — which matters,
because that permission is not granted on this machine.

The findings each step depends on, all established by probing the running app:

| Step | What is actually true |
| --- | --- |
| Launch | Doubao holds a **singleton lock**. A normally-launched instance never opens the debug port, and launching again just forwards to it. The app must therefore be quit and restarted — the first call costs ~10–40 s. |
| Attach | `doubao-chat` is the real 1200×800 window. `doubao-launcher` is a 400×600 **sidebar that also accepts prompts** and renders results at 90 px, and `doubao-chat` is *additionally* served as an empty `<html>hello</html>` shell. Identification uses live window size plus the presence of the editor, never the URL alone. |
| Type | The box is `div.tiptap.ProseMirror[contenteditable=true]`. `execCommand('insertText')` goes through the same `beforeinput` path a keystroke does, so the app's own state and send button update. Assigning `innerText` would not. |
| Detect | The status sentence 「已生成 N 张候选图」 is the completion signal, not the image count — the grid mounts placeholders before the renders arrive. |
| Harvest | The picture in the grid is a `cpreview_wm1` render behind an overlay, and its full-size sibling `<img>` is a bare `data:image/svg+xml` **placeholder with no pixels**, so the bytes cannot be read from the grid. Instead the tool clicks each thumbnail to open the image viewer and uses the app's own `[data-testid=edit_image_download_button]`, which writes the file to `~/Downloads`; the tool then moves it to `dir`. |

`dsh-doctor`-style checks live in the unit tests: the output schema must stay in
sync with `execute`, because a tool that returns a value without a declared
schema is refused at registration and takes the **whole plugin tree — and every
DSH boot, DSH.app included — down with it**.

## The watermark

Doubao stamps 「豆包AI生成」 into the bottom-right of every saved picture. It is an
overlay the app composites on, not part of the artwork, which is what makes
removal a solved problem instead of an inpainting guess. All of this was
measured, not assumed:

| Property | Measurement |
| --- | --- |
| Position | Anchored to the bottom-right corner; a glyph mask from one image correlates with an unrelated image's corner at **NCC 0.949** (inverse control −0.949, exactly symmetric) |
| Scale | Proportional to the image's **short side**, not its width: 2048²→321×69 box, 1365×2048→214×46 box, both giving width/short ≈ 0.1567. Verified on a second sample per shape |
| Blend | Plain alpha composite `C = a·W + (1−a)·B`, fitted at **a = 0.638**, W = 234.4, RMS residual 6.3/255 |
| Soft edge | Glyph interiors measure a = 0.63 while the antialiased rim ramps to 0 — which is why a hard 0/1 mask left a visible outline |

Removal inverts the composite per pixel, and estimates the artwork behind the
mark by coarse-grid interpolation that excludes masked pixels. The output PNG is
encoded losslessly (round-trip delta verified 0).

**Self-check.** The `verifyOnFlat` helper turns "does it look clean?" into a
number: on a flat-background sample the artwork behind the mark is a constant, so
any residual offset inside the glyph area *is* the watermark that survived.
Measured on a flat 2048² sample: **residual 46.3 → 0.0 (100% removed)**. On a
photograph the same metric would be meaningless, so it detects a non-flat frame
(background IQR > 8) and says so instead of printing a flattering zero.

**Scope.** This targets this one overlay, at this one anchor, with this one
calibrated blend. It is not a general watermark remover. It exists for internal
reference material — animation reference, storyboards, internal review. Doubao's
official API (Volcengine Ark) returns images with no watermark at all, and that
is the right channel for anything published or commercial.

## Known limitations

- **Generation consumes the user's Doubao quota** (the app reports 「本次生成将
  消耗每日免费额度」). Exactly one generation is issued per call; if the plugin
  cannot confirm a submission it stops rather than retrying, because a blind
  retry is what once produced duplicate generations.
- **The app window is closed and reopened** on the first call, and Doubao must
  stay running-and-instrumented for the harvest to complete.
- The harvest depends on Doubao's own UI markup (`image-box-grid`,
  `edit_image_download_button`). A Doubao redesign breaks it; the selector
  surface is deliberately kept to those two names.
- The watermark pass only re-encodes PNG. Other formats are saved exactly as
  downloaded rather than silently recompressed.
