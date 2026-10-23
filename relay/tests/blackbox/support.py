"""黑盒用例共用的客户端与断言工具。

这里出现的每一项都必须是**实现外部可观察**的：HTTP 状态码与 JSON、WebSocket
帧与关闭码、超时。任何"读一下中转内部状态"的写法都会让这套用例失去语言无关性，
因此本模块（以及整个 blackbox 目录）不 import 中转内部模块。

约定：

* 每个请求、每次读帧都有超时。挂死必须表现成失败，而不是把整轮时间吃掉。
* 错误信封只有一种形状：``{"ok": false, "error": {"code": ..., "message": ...}}``
  （部分端点会多一个 ``error.details``，用例不依赖它的具体内容）。
* 帧读取允许乱序：WebSocket 是异步通道，一帧 ``hostStatus`` 可以合法地插在
  两步之间；``FrameReader`` 会把没被消费的帧留着给下一步。
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any, Callable

import aiohttp
from aiohttp import WSMsgType

#: 单次请求/单帧读取的上限。超过就当失败——不要用"多等一会"掩盖挂死。
DEFAULT_TIMEOUT_S = 5.0
#: 等关闭帧的上限（关闭是异步的，读到 CLOSE 才算拿到关闭码）。
CLOSE_TIMEOUT_S = 5.0
#: "这段时间内不该有帧"的观察窗口。
SILENCE_WINDOW_S = 1.0

#: 探针类用例要给人看的结论行（收尾时由 conftest 打印，`-q` 下也看得见）。
PROBE_NOTES: list[str] = []


class FrameTimeout(AssertionError):
    """在限定时间内没有等到期望的帧。"""


class HttpResponse:
    """一次 HTTP 应答：状态码、原文、解析后的 JSON、原始字节。

    ``raw`` 是正文原样字节，给文件通道用（``/files/down`` 的正文不是文本）；
    ``text`` 仍按 UTF-8 解码得到，第一批用例照旧读它。``headers`` 的键大小写
    与实现发出来的一致，比较时用 ``header()`` 做大小写不敏感查找。
    """

    def __init__(self, method: str, path: str, status: int, text: str,
                 headers: dict[str, str], raw: bytes = b"") -> None:
        self.method = method
        self.path = path
        self.status = status
        self.text = text
        self.headers = headers
        self.raw = raw

    def __repr__(self) -> str:
        return f"<{self.method} {self.path} -> {self.status}>"

    def json(self) -> Any:
        return json.loads(self.text)

    @property
    def error_code(self) -> str | None:
        try:
            return self.json()["error"]["code"]
        except (ValueError, KeyError, TypeError):
            return None


class Client:
    """HTTP/WS 客户端。只认 base URL，不认实现。"""

    def __init__(self, base_url: str, *, timeout: float = DEFAULT_TIMEOUT_S) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._session: aiohttp.ClientSession | None = None

    async def __aenter__(self) -> "Client":
        self._session = aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=self.timeout))
        return self

    async def __aexit__(self, *_exc: Any) -> None:
        if self._session is not None:
            await self._session.close()
            self._session = None

    @property
    def session(self) -> aiohttp.ClientSession:
        if self._session is None:
            raise RuntimeError("Client 必须先在 async with 里打开")
        return self._session

    async def request(self, method: str, path: str, *, token: str | None = None,
                      json_body: Any = None, params: dict[str, Any] | None = None,
                      headers: dict[str, str] | None = None, data: Any = None,
                      timeout: float | None = None) -> HttpResponse:
        """发一次请求。

        ``data`` 给非 JSON 正文（文件上传、坏 JSON 探针）；``timeout`` 只覆盖
        这一次请求——大文件不该被默认的 5 秒掐掉。
        """
        merged = dict(headers or {})
        if token:
            merged["Authorization"] = f"Bearer {token}"
        deadline = {} if timeout is None else {"timeout": aiohttp.ClientTimeout(total=timeout)}
        async with self.session.request(
                method, self.base_url + path, json=json_body, params=params, data=data,
                headers=merged, **deadline) as response:
            raw = await response.read()
            return HttpResponse(method, path, response.status,
                                raw.decode("utf-8", "replace"), dict(response.headers), raw)

    async def get(self, path: str, **kwargs: Any) -> HttpResponse:
        return await self.request("GET", path, **kwargs)

    async def post(self, path: str, **kwargs: Any) -> HttpResponse:
        return await self.request("POST", path, **kwargs)

    async def put(self, path: str, **kwargs: Any) -> HttpResponse:
        return await self.request("PUT", path, **kwargs)

    async def ws(self, path: str, *, token: str | None = None,
                 subprotocols: list[str] | None = None) -> aiohttp.ClientWebSocketResponse:
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        return await self.session.ws_connect(
            self.base_url + path, headers=headers, protocols=subprotocols)


# ── 错误信封 ────────────────────────────────────────────────────────────────


def assert_error_envelope(response: HttpResponse, *, status: int, code: str) -> dict:
    """断言状态码、错误信封形状与错误码；返回解析后的响应体。

    形状固定为 ``{"ok": false, "error": {"code": <str>, "message": <str>}}``。
    ``error.details`` 可以有，但它的内容不属于契约。
    """
    assert response.status == status, (
        f"{response.method} {response.path} 期望 {status}，实际 {response.status}："
        f"{response.text[:300]}")
    payload = response.json()
    assert isinstance(payload, dict), f"响应不是 JSON 对象：{response.text[:300]}"
    assert payload.get("ok") is False, f"错误响应的 ok 必须为 false：{payload}"
    error = payload.get("error")
    assert isinstance(error, dict), f"缺少 error 对象：{payload}"
    assert isinstance(error.get("code"), str) and error["code"], f"error.code 非法：{error}"
    assert isinstance(error.get("message"), str) and error["message"], \
        f"error.message 非法：{error}"
    assert error["code"] == code, f"期望错误码 {code}，实际 {error['code']}"
    return payload


def header(response: HttpResponse, name: str) -> str | None:
    """按名字取响应头，大小写不敏感（``dict`` 会保留实现发出来的原始大小写）。"""
    wanted = name.lower()
    for key, value in response.headers.items():
        if key.lower() == wanted:
            return value
    return None


# ── WebSocket ───────────────────────────────────────────────────────────────


async def read_frame(ws: aiohttp.ClientWebSocketResponse, *, timeout: float = DEFAULT_TIMEOUT_S,
                     what: str = "帧") -> dict:
    """读一帧文本并解析成对象。超时、非文本、非 JSON 都算失败。"""
    try:
        message = await asyncio.wait_for(ws.receive(), timeout)
    except (asyncio.TimeoutError, TimeoutError) as error:
        raise FrameTimeout(f"{timeout}s 内没有等到{what}") from error
    assert message.type is WSMsgType.TEXT, f"期望文本帧，收到 {message.type}: {message!r}"
    try:
        frame = json.loads(message.data)
    except ValueError as error:
        raise AssertionError(f"{what}不是 JSON：{message.data[:200]}") from error
    assert isinstance(frame, dict), f"{what}不是 JSON 对象：{frame!r}"
    return frame


async def read_close(ws: aiohttp.ClientWebSocketResponse, *,
                     timeout: float = CLOSE_TIMEOUT_S) -> int:
    """读到关闭帧，返回关闭码。``ws.close_code`` 只有在收到 CLOSE 后才可靠。"""
    try:
        message = await asyncio.wait_for(ws.receive(), timeout)
    except (asyncio.TimeoutError, TimeoutError) as error:
        raise FrameTimeout(f"{timeout}s 内没有等到关闭帧") from error
    assert message.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED), \
        f"期望关闭帧，收到 {message.type}: {message!r}"
    return int(ws.close_code or 0)


async def wait_close_code(ws: aiohttp.ClientWebSocketResponse, *,
                          timeout: float = CLOSE_TIMEOUT_S) -> int:
    """一直读，直到关闭帧；期间收到的业务帧被丢弃。"""
    try:
        async with asyncio.timeout(timeout):
            while True:
                message = await ws.receive()
                if message.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED):
                    return int(ws.close_code or 0)
                assert message.type is not WSMsgType.ERROR, f"连接异常：{ws.exception()}"
    except TimeoutError as error:
        raise FrameTimeout(f"{timeout}s 内没有等到关闭帧") from error


async def expect_silence(ws: aiohttp.ClientWebSocketResponse, *,
                         seconds: float = SILENCE_WINDOW_S) -> None:
    """断言这段时间内没有帧到达（用于"不该通知写入者"这类否定断言）。"""
    try:
        message = await asyncio.wait_for(ws.receive(), seconds)
    except (asyncio.TimeoutError, TimeoutError):
        return
    raise AssertionError(f"这段时间内不该有帧，却收到了 {message.type}: {message.data!r}")


def is_frame(frame: dict, kind: str) -> bool:
    return frame.get("t") == kind


def is_frame_kind(kind: str) -> Callable[[dict], bool]:
    """给 ``FrameReader.until`` 用的判定函数：帧的 ``t`` 是否等于 ``kind``。"""
    return lambda frame: frame.get("t") == kind


def frame_field(frame: dict, path: str) -> Any:
    """取 ``"info.online"`` 这类点分字段，缺失时给 None（用于给出更好的失败信息）。"""
    value: Any = frame
    for part in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(part)
    return value


class FrameReader:
    """记住没被消费的帧，允许断言顺序与到达顺序不同。

    隧道是异步的：一帧 ``hostStatus`` 完全可以插在"连接设备"与"设备转发"两步之间。
    凡是没有匹配上当前断言的帧都留在缓冲里，交给下一个断言。
    """

    def __init__(self, ws: aiohttp.ClientWebSocketResponse) -> None:
        self.ws = ws
        self.buffer: list[dict] = []
        self.seen: list[dict] = []

    def __repr__(self) -> str:
        return " | ".join(json.dumps(frame, ensure_ascii=False)[:160]
                          for frame in self.seen[-5:])

    def take(self, predicate: Callable[[dict], bool]) -> dict | None:
        for index, frame in enumerate(self.buffer):
            if predicate(frame):
                return self.buffer.pop(index)
        return None

    async def next(self, *, timeout: float = DEFAULT_TIMEOUT_S) -> dict:
        frame = await read_frame(self.ws, timeout=timeout)
        self.seen.append(frame)
        return frame

    async def until(self, predicate: Callable[[dict], bool], *,
                    timeout: float = DEFAULT_TIMEOUT_S) -> dict:
        buffered = self.take(predicate)
        if buffered is not None:
            return buffered
        try:
            async with asyncio.timeout(timeout):
                while True:
                    frame = await self.next(timeout=timeout)
                    if predicate(frame):
                        return frame
                    self.buffer.append(frame)
        except TimeoutError as error:
            raise FrameTimeout(
                f"{timeout}s 内没有等到期望的帧；已收到：{self!r}") from error

    async def quiet(self, *, seconds: float = SILENCE_WINDOW_S) -> None:
        """排空一段时间，收到的帧全部留着。"""
        deadline = asyncio.get_running_loop().time() + seconds
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                return
            try:
                frame = await self.next(timeout=remaining)
            except FrameTimeout:
                return
            self.buffer.append(frame)


async def ws_handshake_status(client: Client, path: str, *,
                              token: str | None = None,
                              subprotocols: list[str] | None = None) -> int:
    """尝试一次 WS 握手；被拒时返回 HTTP 状态码，成功返回 0（并关闭连接）。"""
    try:
        ws = await client.ws(path, token=token, subprotocols=subprotocols)
    except aiohttp.WSServerHandshakeError as error:
        return error.status
    await ws.close()
    return 0


# ── 账号、电脑、设备：只走 ADMIN_CMD 与 HTTP ────────────────────────────────


@dataclass(frozen=True)
class Tenant:
    """一个账户与它的一台"电脑"（agent）。"""

    account_id: str
    agent_id: str
    agent_secret: str
    name: str

    @property
    def agent_token(self) -> str:
        return self.agent_secret


@dataclass(frozen=True)
class Device:
    """一次成功认领的结果。"""

    device_id: str
    device_token: str
    account_id: str
    agent_id: str
    reused: bool

    @property
    def token(self) -> str:
        return self.device_token


async def enroll(client: Client, admin: Callable[..., Any], *,
                 name: str = "BLACKBOX-Mac") -> Tenant:
    """走真实的自助登记：ADMIN_CMD 铸邀请码 → ``POST /agents/enroll``。"""
    invite = admin("invite-mint", "--ttl-seconds", "600", "--note", "blackbox")
    response = await client.post("/agents/enroll",
                                 json_body={"inviteCode": invite["code"], "name": name})
    assert response.status == 200, f"登记失败：{response.status} {response.text[:300]}"
    body = response.json()
    return Tenant(account_id=body["accountId"], agent_id=body["agentId"],
                  agent_secret=body["agentSecret"], name=body["agentName"])


async def mint_pair_code(client: Client, tenant: Tenant) -> dict:
    """用电脑自己的凭据铸一枚配对码（持久码，默认不会过期）。"""
    response = await client.post("/pair/code", json_body={}, token=tenant.agent_token)
    assert response.status == 200, f"铸码失败：{response.status} {response.text[:300]}"
    return response.json()


async def pair_device(client: Client, tenant: Tenant, *, name: str = "BLACKBOX-iPhone",
                      device_key: str | None = None) -> Device:
    """铸码 → 认领 → 得到设备令牌（App 的配对路径）。"""
    minted = await mint_pair_code(client, tenant)
    payload: dict[str, Any] = {"pairCode": minted["code"], "deviceName": name,
                               "deviceModel": "iPhone17,1", "appVersion": "9.9.9"}
    if device_key:
        payload["deviceKey"] = device_key
    response = await client.post("/pair/claim", json_body=payload)
    assert response.status == 200, f"认领失败：{response.status} {response.text[:300]}"
    body = response.json()
    return Device(device_id=body["deviceId"], device_token=body["deviceToken"],
                  account_id=body["accountId"], agent_id=body["agentId"],
                  reused=bool(body.get("reused")))


async def claim_code(client: Client, code: str, *, name: str = "BLACKBOX-iPhone",
                     device_key: str | None = None) -> HttpResponse:
    payload: dict[str, Any] = {"pairCode": code, "deviceName": name}
    if device_key:
        payload["deviceKey"] = device_key
    return await client.post("/pair/claim", json_body=payload)


def agent_socket_path(tenant: Tenant) -> str:
    return f"/link/agent?agentId={tenant.agent_id}"


def device_socket_path(device: Device) -> str:
    return f"/link/device?agentId={device.agent_id}"
