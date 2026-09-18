---
name: dsh-restart
description: 让本机 DSH 自己重启，并在重启后把当前会话叫醒——改了插件、skill 或连接器之后不必再要求用户手动退出重开 DSH。重启会中断当前回合，随后由 worker 提交一条「继续」提示把 agent 唤醒，过程写在 ~/.dsh/restart/。
whenToUse: 当你改了 plugins/、skills/、页面配置或连接器代码，而这些只在 DSH 启动时加载、必须重启才生效时；或用户说"重启一下 DSH""让改动生效"而你不想让他跑到电脑前操作时。注意：重启是真的重启（后端进程被杀掉再拉起），当前回合会中断。
---

# 自己重启 DSH

**用途**：插件、skill、连接器都是 **DSH 启动时**读取的。改完之后不重启 = 没生效，而
以前这需要用户跑到电脑前「退出 DSH 再打开」。这个 skill 把这件事变成一条命令，
并且**重启完会把你叫醒**——你不用在电脑旁边。

## 怎么用

```bash
node scripts/dev/dsh-restart.mjs --resume "继续刚才那件事：<下一步要做什么>"
# 或者（package.json 里已登记）
npm run restart -- --resume "继续…"
```

- `--delay <秒>`：重启前等多久，默认 3 秒。**把工具结果送回客户端需要时间**，
  所以要让 agent 的最后一条消息先落地，就给大一点（例如 `--delay 20`）。
- `--dry-run`：只打印计划（从 `~/.dsh/desktop-shell/endpoint.json` 读到的 pid/端口、
  要唤醒的会话、worker 路径），不真的重启。
- `--session <id>`：默认取 `$DSH_SESSION_ID`（工具进程里通常都有）。

## 它做了什么

1. 前台脚本写一份 `~/.dsh/restart/state.json`（谁、哪个会话、什么提示、日志路径），
   然后 `spawn(detached: true).unref()` 拉起 **worker**——这个进程必须活得比它要杀的
   后端更久，否则没人把它拉起来。
2. worker 等 `--delay` 秒 → `SIGTERM` 后端（8 秒不退就 `SIGKILL`）。
   当前回合在这里中断，**这是预期**。
3. 等新后端：DSH.app 通常会自己把后端拉起来（它是父进程）；没起来就 `open -a DSH`；
   还不起来就自己 `dsh web --no-open --port 0` 兜底。判据是 `endpoint.json` 出现了一个
   **新的 pid**，否则可能把刚杀掉的进程当成新的。
4. 用 endpoint 里的 token 换 cookie，往记录的会话提交一条提示（`requestId` 以 `restart-`
   开头，便于在转写里认出这是自动唤醒而不是用户说的话）。

## 重启之后

重启后的第一轮是被那条提示唤醒的，**先读这两样再继续干活**：

- `~/.dsh/restart/state.json`：`status` 走到 `resumed` 就说明一切正常；
  `failed` / `up-resume-failed` 各有原因可查。
- `~/.dsh/restart/worker.log`：逐步时间线（停了哪个 pid、谁拉起的新后端、第几次唤醒成功）。

## 注意

- **是真的重启**：用户的手机端会短暂断线（LinkCarrier 会自动重连），正在跑的其他会话
  回合也会被打断。要挑一个没有别的活在跑的时刻做。
- **当前回合一定会断**：别在重启前做一半的事，把「下一步」写进 `--resume`。
- 唤醒提示会以**用户消息**的形式出现在转写里——这是有意为之：那是 agent 唯一能被
  叫醒的通道。它带了 `restart-` 前缀，必要时可以在转写里区分。
- worker 的兜底会自己起一个 `dsh web`；如果 DSH.app 随后又拉起一个，两者都会写
  `endpoint.json`，客户端按最后写入的那个走（日志里能看到这种情况）。
