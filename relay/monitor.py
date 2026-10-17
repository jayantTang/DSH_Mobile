"""异常与"反复断开"的监控：按类别去重、限量，写进告警队列等投递。

为什么有这个模块（2026-10-17 事故）：

    中转把每一帧发给手机前都要按 UTF-8 数字节计费。连接器送来的一帧里有一个被切开
    的 emoji（落单的 UTF-16 代理项），`text.encode("utf-8")` 抛异常，整个 agent 链路
    随之断开；手机重连再被同一帧打死，于是永远停在"连接中"。24 小时里这件事发生了
    143 次、连接器断了 702 次，**一条告警都没有**——直到用户自己发来反馈。运维是
    从 systemd 日志里翻出来的。

所以这里的判据不是"有没有异常"，而是"**有没有出现过我们没见过的异常**"：

    新类别 → 立刻上报；同类别的后续出现只累计次数，默认 24 小时内不再打扰。
    抖动（同一台电脑在窗口内反复断开）算一个类别，同一个窗口只报一次。

三条硬约束（它跑在转发进程里，不能变成负担）：

1. **热路径零开销**：只有异常栈、agent 断开、修好坏字符这三个时刻会被调用。中间件
   就是一个 ``try/except``，日志/序列化都在 except 分支里发生。
2. **绝不抛出**：所有写入都包了 ``try/except``，监控坏掉最多少一条告警，不能让请求
   或转发跟着失败。
3. **不写正文**：告警里只有类别、位置、次数、上下文片段；用户内容不进运维通道。

投递不在这里：本模块只把告警追加到 ``<alert_dir>/alerts.jsonl``，由独立的
``alert-dispatch.py``（systemd timer）取走并投到我们的信箱。中转进程因此不必持有
任何发信凭据，发信失败也不会影响它。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import traceback
from collections import deque
from typing import Any, Callable

from aiohttp import web

import store as store_module

#: 队列文件的自我上限。超过就停止追加（只留日志），免得磁盘被一条重复异常写满。
MAX_QUEUE_BYTES = 4 * 1024 * 1024

#: 落盘状态文件的版本。改结构时递增，读到不认识的版本就当没有状态重来。
STATE_VERSION = 1


def _default_logger() -> logging.Logger:
    return logging.getLogger("relay.monitor")


class IncidentMonitor:
    """按类别去重的告警收集器（见模块文档）。

    ``alert_dir`` 为空 = 关闭：所有方法退化成空操作。测试与"没配告警"的部署都走这条
    路，行为与没有本模块时逐字一致。
    """

    def __init__(self, *, alert_dir: str | os.PathLike[str] | None = None,
                 logger: logging.Logger | None = None,
                 clock: Callable[[], float] = time.time,
                 renotify_after_s: float = 86_400.0,
                 max_alerts_per_hour: int = 6,
                 max_alerts_per_day: int = 40,
                 flap_window_s: float = 300.0,
                 flap_threshold: int = 5,
                 surrogate_samples_per_day: int = 20) -> None:
        self.logger = logger or _default_logger()
        self.clock = clock
        self.alert_dir = str(alert_dir) if alert_dir else ""
        self.renotify_after_s = max(0.0, float(renotify_after_s))
        self.max_alerts_per_hour = max(1, int(max_alerts_per_hour))
        self.max_alerts_per_day = max(1, int(max_alerts_per_day))
        self.flap_window_s = max(1.0, float(flap_window_s))
        self.flap_threshold = max(1, int(flap_threshold))
        self.surrogate_samples_per_day = max(0, int(surrogate_samples_per_day))

        self._seen: dict[str, dict[str, Any]] = {}
        self._alert_times: deque[float] = deque()
        self._suppressed = 0
        self._flaps: dict[str, deque[float]] = {}
        self._flap_reported: dict[str, float] = {}
        self._surrogate_samples: dict[int, int] = {}
        self._state_dirty = False

        if self.enabled:
            self._load_state()

    # ── 配置 ────────────────────────────────────────────────────────────────

    @property
    def enabled(self) -> bool:
        return bool(self.alert_dir)

    @property
    def queue_path(self) -> str:
        return os.path.join(self.alert_dir, "alerts.jsonl")

    @property
    def state_path(self) -> str:
        return os.path.join(self.alert_dir, "state.json")

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None,
                 logger: logging.Logger | None = None) -> "IncidentMonitor":
        """按环境变量配置。``DLP_ALERT_DIR`` 缺省 = 关闭。"""
        source = os.environ if env is None else env

        def number(name: str, default: float) -> float:
            raw = source.get(name)
            if raw is None or str(raw).strip() == "":
                return default
            try:
                return float(raw)
            except ValueError:
                return default

        return cls(
            alert_dir=source.get("DLP_ALERT_DIR") or None,
            logger=logger,
            renotify_after_s=number("DLP_ALERT_RENOTIFY_HOURS", 24.0) * 3600.0,
            max_alerts_per_hour=int(number("DLP_ALERT_MAX_PER_HOUR", 6)),
            max_alerts_per_day=int(number("DLP_ALERT_MAX_PER_DAY", 40)),
            flap_window_s=number("DLP_ALERT_FLAP_WINDOW_S", 300.0),
            flap_threshold=int(number("DLP_ALERT_FLAP_THRESHOLD", 5)),
            surrogate_samples_per_day=int(number("DLP_ALERT_SURROGATE_SAMPLES", 20)),
        )

    def describe(self) -> dict[str, Any]:
        """给启动日志那一行用（值都是运维口径，不含用户数据）。"""
        if not self.enabled:
            return {"enabled": False}
        return {
            "enabled": True,
            "alertDir": self.alert_dir,
            "renotifyHours": round(self.renotify_after_s / 3600.0, 2),
            "maxPerHour": self.max_alerts_per_hour,
            "maxPerDay": self.max_alerts_per_day,
            "flapWindowSeconds": self.flap_window_s,
            "flapThreshold": self.flap_threshold,
            "knownCategories": len(self._seen),
        }

    # ── 取数入口（都是热路径上的"顺便"，必须便宜且不抛）────────────────────

    def note_exception(self, error: BaseException, *, path: str = "",
                       source: str = "http") -> None:
        """一个没被处理的异常。同类型 + 同一处代码 = 同一类别。"""
        if not self.enabled:
            return
        try:
            key, place, summary = _classify_exception(error)
            frames = traceback.extract_tb(error.__traceback__) if error.__traceback__ else []
            tail = [f"{os.path.basename(f.filename)}:{f.lineno} {f.name}" for f in frames[-4:]]
            self._record(
                key,
                kind="exception",
                title=f"中转异常：{type(error).__name__} @ {place}",
                summary=f"{path or source} → {summary}",
                details={"source": source, "path": path, "place": place,
                         "frames": " ← ".join(reversed(tail))},
            )
        except Exception:  # noqa: BLE001 - 监控自己不许抛
            self.logger.debug("relay: monitor failed to note an exception", exc_info=True)

    def note_agent_disconnect(self, agent_id: str, *, name: str = "") -> None:
        """一条 agent 链路断了。窗口内断够次数才算"抖"，同一窗口只报一次。

        "同一窗口"由类别键带窗口序号保证：过了这个窗口再抖，算一次新事件，所以要再
        报一次；而类别去重本身仍然管"同窗口内不重复"。
        """
        if not self.enabled:
            return
        try:
            now = self.clock()
            window = self._flaps.setdefault(agent_id, deque())
            window.append(now)
            while window and now - window[0] > self.flap_window_s:
                window.popleft()
            if len(window) < self.flap_threshold:
                return
            reported = self._flap_reported.get(agent_id)
            if reported is not None and now - reported < self.flap_window_s:
                return
            self._flap_reported[agent_id] = now
            prefix = f"flap:{agent_id}:"
            key = f"{prefix}{int(now // self.flap_window_s)}"
            # 上一个窗口的类别键留着没有意义（同一台电脑的旧抖动已经报过），顺手清掉，
            # 免得状态文件随运行时间无限增长。
            for stale in [known for known in self._seen if known.startswith(prefix) and known != key]:
                self._seen.pop(stale, None)
            self._record(
                key,
                kind="flap",
                title="连接器反复断开",
                summary=(f"{name or 'agent'}（{agent_id}）在 {int(self.flap_window_s)} 秒内"
                         f"断开 {len(window)} 次"),
                details={"agentId": agent_id, "name": name,
                         "windowSeconds": int(self.flap_window_s),
                         "disconnectsInWindow": len(window)},
            )
        except Exception:  # noqa: BLE001 - 监控自己不许抛
            self.logger.debug("relay: monitor failed to note a disconnect", exc_info=True)

    def note_unpaired_surrogates(self, *, agent_id: str, device_id: str,
                                 frame_type: str, damage: Any) -> None:
        """转发路径刚修好一个落单代理项。这是定位上游根因的取样点。

        详情每次都要（落盘日志里已经有），但**进告警的样本按天限量**：坏字符可能每分钟
        来一次，抽样够看形态，不必每条都推给人。
        """
        if not self.enabled:
            return
        try:
            day = store_module.local_day(self.clock())
            taken = self._surrogate_samples.get(day, 0)
            # 只依赖 `as_details()`：位置、帧尾余量这些字段从同一份数据里取，
            # 摘要与详情就不可能各说各话。
            shape = damage.as_details()
            details = {"agentId": agent_id, "deviceId": device_id,
                       "frameType": frame_type, **shape}
            if taken < self.surrogate_samples_per_day:
                self._surrogate_samples[day] = taken + 1
                details["sample"] = f"{taken + 1}/{self.surrogate_samples_per_day}"
            else:
                details = {"agentId": agent_id, "deviceId": device_id,
                           "frameType": frame_type, "sampled": False}
            self._record(
                "surrogate:unpaired",
                kind="corrupt-frame",
                title="上游送来了带落单代理项（被切开的 emoji）的帧",
                summary=(f"来自 {agent_id} 的 {frame_type} 帧，已用 U+FFFD 修好并转发；"
                         f"坏字符位置 {shape.get('firstIndex')}/{shape.get('totalChars')}"
                         f"（帧尾还剩 {shape.get('trailingChars')} 字符）"),
                details=details,
            )
        except Exception:  # noqa: BLE001 - 监控自己不许抛
            self.logger.debug("relay: monitor failed to note a surrogate", exc_info=True)

    # ── 判定与落盘 ──────────────────────────────────────────────────────────

    def _record(self, key: str, *, kind: str, title: str, summary: str,
                details: dict[str, Any]) -> None:
        now = self.clock()
        entry = self._seen.get(key)
        if entry is None:
            entry = {"count": 0, "firstTs": now, "lastTs": now, "alertedTs": 0.0}
            self._seen[key] = entry
            novel = True
        else:
            novel = now - float(entry.get("alertedTs") or 0.0) >= self.renotify_after_s
        entry["count"] = int(entry.get("count", 0)) + 1
        entry["lastTs"] = now
        self._state_dirty = True

        if not novel:
            # 已知类别、还在静默期：只累计。库里那份计数就是"这类还在发生"的证据。
            return
        if not self._allow_now(now):
            self._suppressed += 1
            return

        entry["alertedTs"] = now
        self._append({
            "ts": int(now),
            "key": key,
            "kind": kind,
            "title": title,
            "summary": summary,
            "details": details,
            "count": int(entry["count"]),
            "occurrencesInWindow": int(entry["count"]),
            "suppressedSinceLastAlert": self._suppressed,
            "newCategory": int(entry["count"]) == 1,
        })
        self._suppressed = 0
        self._save_state()

    def _allow_now(self, now: float) -> bool:
        """一小时与一天的条数上限。超了只计数，避免告警洪水。"""
        while self._alert_times and now - self._alert_times[0] > 86_400.0:
            self._alert_times.popleft()
        in_last_hour = sum(1 for ts in self._alert_times if now - ts <= 3600.0)
        if in_last_hour >= self.max_alerts_per_hour:
            return False
        if len(self._alert_times) >= self.max_alerts_per_day:
            return False
        self._alert_times.append(now)
        return True

    def _append(self, record: dict[str, Any]) -> None:
        try:
            os.makedirs(self.alert_dir, exist_ok=True)
            path = self.queue_path
            try:
                if os.path.getsize(path) > MAX_QUEUE_BYTES:
                    self.logger.warning("relay: alert queue is full (%s); dropping one record",
                                        path)
                    return
            except OSError:
                pass
            line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
            self.logger.warning("relay: incident queued (%s): %s", record["key"], record["summary"])
        except Exception:  # noqa: BLE001 - 监控自己不许抛
            self.logger.warning("relay: could not write the alert queue", exc_info=True)

    # ── 状态文件（重启后不重复报同一类别）──────────────────────────────────

    def _load_state(self) -> None:
        try:
            with open(self.state_path, encoding="utf-8") as handle:
                state = json.load(handle)
        except (OSError, ValueError):
            return
        if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
            return
        seen = state.get("categories")
        if isinstance(seen, dict):
            for key, entry in seen.items():
                if isinstance(entry, dict):
                    self._seen[str(key)] = entry
        samples = state.get("surrogateSamples")
        if isinstance(samples, dict):
            for day, count in samples.items():
                try:
                    self._surrogate_samples[int(day)] = int(count)
                except (TypeError, ValueError):
                    continue

    def _save_state(self) -> None:
        if not self.enabled:
            return
        try:
            os.makedirs(self.alert_dir, exist_ok=True)
            payload = {
                "version": STATE_VERSION,
                "savedAt": int(self.clock()),
                "categories": self._seen,
                "surrogateSamples": {str(k): v for k, v in self._surrogate_samples.items()},
            }
            temporary = self.state_path + ".tmp"
            with open(temporary, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
            os.replace(temporary, self.state_path)
            self._state_dirty = False
        except Exception:  # noqa: BLE001 - 监控自己不许抛
            self.logger.debug("relay: could not save the alert state", exc_info=True)

    def flush(self) -> None:
        """周期调用：把计数落盘。没变化就不写。"""
        if self._state_dirty:
            self._save_state()

    def save_state(self) -> None:
        """无条件落盘（关停时用）。"""
        if self.enabled:
            self._save_state()


def _classify_exception(error: BaseException) -> tuple[str, str, str]:
    """``(类别键, 代码位置, 一行摘要)``。

    类别键用"异常类型 + 最内层代码位置"：同一种错误在同一个地方再次发生算同一类，
    换一处代码就是一个新类别——这正是想被告知的事（这次的事故就属于"从没见过的
    类别"）。
    """
    frames = traceback.extract_tb(error.__traceback__) if error.__traceback__ else []
    place = f"{os.path.basename(frames[-1].filename)}:{frames[-1].lineno}" if frames else "?"
    kind = f"{type(error).__module__}.{type(error).__name__}"
    summary = f"{type(error).__name__}: {error}"[:300].replace("\n", " ")
    return f"exc:{kind}@{place}", place, summary


def middleware(monitor: IncidentMonitor) -> Callable[..., Any]:
    """aiohttp 中间件：把没被处理的异常送进监控，然后照原样抛出。

    只加一个 ``try/except``：正常请求路径上等于没有开销（异常分支里才有日志与序列化）。
    """

    @web.middleware
    async def incident_middleware(request: web.Request, handler: Callable[..., Any]) -> Any:
        try:
            return await handler(request)
        except (web.HTTPException, asyncio.CancelledError):
            raise
        except Exception as error:  # noqa: BLE001 - 记完就抛，交给 aiohttp
            monitor.note_exception(error, path=request.path, source="http")
            raise

    return incident_middleware
