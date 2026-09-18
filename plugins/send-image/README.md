# dsh-plugin-send-image

**Lets the agent put a picture into the conversation.** A screenshot, the
clipboard, or a file — the host normalizes and persists the bytes, every DSH
client renders it inline, and the user can open it full screen.

Why a plugin is needed at all: DSH's model adapters declare **text-only output**,
so the agent cannot emit an image in its answer. The bytes reach the client
through the Host's attachment service (`ctx.attachments.saveImage`, which
normalizes and persists them) and the returned reference rides on this tool's
**result**, as an image content block — so every client draws the picture inside
the agent's own turn.

Submitting it as a prompt instead — which is what this plugin used to do — is
wrong twice over: a prompt is a **user message**, so the picture looked like
something the user had sent, and it **started a turn**, so the agent answered its
own screenshot. `send-image.mjs --via-prompt` keeps that path for a client that
cannot render tool-result images; nothing here uses it.

```
plugins/send-image/
├── package.json          # type: module, dsh.bundle.patch
├── cordis.patch.yml      # bundle patch: the loader row
├── lib/index.js          # cordis plugin: registers the send_image tool
└── test/                 # node --test, 19 tests (no DSH, no network)
```

The tool is a thin shell around
[`skills/send-image/send-image.mjs`](https://github.com/jayantTang/DSH_Mobile/blob/main/skills/send-image/send-image.mjs),
which owns the capture quirks (`screencapture`, `pngpaste`, the screen-recording
permission message) and prints one JSON descriptor. Standalone it only
*prepares* — the publishing half needs the Host context this plugin has:

```bash
node skills/send-image/send-image.mjs --screenshot        # prints the descriptor
node skills/send-image/send-image.mjs --file ./out/render.png
node skills/send-image/send-image.mjs --clipboard         # needs pngpaste
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
