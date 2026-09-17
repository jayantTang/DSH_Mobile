# dsh-plugin-send-image

**Lets the agent put a picture into the conversation.** A screenshot, the
clipboard, or a file — the host normalizes and persists the bytes, every DSH
client renders it inline, and the user can open it full screen.

Why a plugin is needed at all: DSH's model adapters declare **text-only output**,
so the agent cannot emit an image in its answer, and the attachment service is
read-only for clients. The one channel that carries bytes in is a prompt, and
that is what this plugin uses — into the session that is already talking.

```
plugins/send-image/
├── package.json          # type: module, dsh.bundle.patch
├── cordis.patch.yml      # bundle patch: the loader row
├── lib/index.js          # cordis plugin: registers the send_image tool
└── test/                 # node --test, 14 tests (no DSH, no network)
```

The tool is a thin, testable shell around
[`skills/send-image/send-image.mjs`](https://github.com/jayantTang/DSH_Mobile/blob/main/skills/send-image/send-image.mjs),
which does the actual capture and upload. That script also works standalone, so
the same capability is available with the plugin uninstalled:

```bash
node skills/send-image/send-image.mjs --screenshot
node skills/send-image/send-image.mjs --file ./out/render.png --caption "渲染结果"
node skills/send-image/send-image.mjs --clipboard        # needs pngpaste
```

## Install

```bash
dsh plugin --profile web add dsh-plugin-send-image
```

Then restart DSH (or reload the profile). From a checkout a relative spec works
too — the leading `./` matters, because DSH anchors it against your current
directory instead of resolving it inside the profile:

```bash
dsh plugin --profile web add ./plugins/send-image
```

## Use

The agent calls `send_image`. Exactly one source per call:

| Argument | Meaning |
| --- | --- |
| `file` | Path to an image (absolute, or relative to the working directory) |
| `screenshot` | `true` captures the whole screen — the picture contains everything on it |
| `clipboard` | `true` sends the image on the clipboard (needs `pngpaste`) |
| `caption` | Text shown with the picture |

Passing none or several is a readable tool error rather than a schema failure:
source exclusivity is a runtime rule here, so the model is told what to fix.

## Test

```bash
cd plugins/send-image && npm test    # 14 tests, zero dependencies
```

MIT.
