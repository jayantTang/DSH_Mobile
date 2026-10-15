"""mail → 中转的内部接口客户端（DESIGN-20261015 I-1）。

中转在 loopback 上暴露 ``POST /internal/tokens/resolve``：mail 拿设备令牌换
账号/设备归属。这是拆分后两个服务之间**唯一**的运行时调用，方向固定
（mail 依赖中转，中转不反向调用 mail）。

失败语义与中转侧的既有降级一致：网络错误、超时、非 200、404 一律返回
``None`` = 按匿名处理。匿名凭据（`fk_` ticket）的校验在 mail 自己的库里，
完全不经过这里——中转不在，匿名提信/取件照样工作。
"""

from __future__ import annotations

import logging
from typing import Any

import aiohttp

LOGGER = logging.getLogger("mail.internal")

#: 默认打中转的 loopback 直连地址（生产：127.0.0.1:8787，与 dsh-relay.service 一致）。
DEFAULT_RELAY_INTERNAL_URL = "http://127.0.0.1:8787"


class RelayIdentityResolver:
    """`app["resolve_device"]` 的生产实现：短超时、失败即匿名。

    ``ClientSession`` 惰性建在**事件循环里**（aiohttp 的要求），服务停时由
    :meth:`aclose` 收掉。
    """

    def __init__(self, base_url: str = DEFAULT_RELAY_INTERNAL_URL, timeout_s: float = 2.0):
        self._base_url = base_url.rstrip("/")
        self._timeout_s = timeout_s
        self._session: aiohttp.ClientSession | None = None

    async def __call__(self, token: str) -> dict[str, Any] | None:
        url = f"{self._base_url}/internal/tokens/resolve"
        try:
            if self._session is None or self._session.closed:
                self._session = aiohttp.ClientSession(
                    timeout=aiohttp.ClientTimeout(total=self._timeout_s))
            async with self._session.post(url, json={"token": token}) as response:
                if response.status != 200:
                    # 404 = 未知/撤销/过期：与"解析不到"同义，不是错误。
                    if response.status != 404:
                        LOGGER.warning("mail: token resolve returned %d", response.status)
                    return None
                device = await response.json()
                if not isinstance(device, dict) or not device.get("deviceId"):
                    return None
                return device
        except (aiohttp.ClientError, TimeoutError, OSError) as error:
            # 中转不在（部署中/挂了）：降级匿名，不重试——一次请求一次判定，
            # 用户下一次调用自然会再试。
            LOGGER.warning("mail: token resolve failed (%s); treating as anonymous", error)
            return None

    async def aclose(self) -> None:
        if self._session is not None and not self._session.closed:
            await self._session.close()
        self._session = None
