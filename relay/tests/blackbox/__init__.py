"""黑盒测试基座（阶段 1，第一批）。

这一层只通过 HTTP、WebSocket、子进程与 `ADMIN_CMD` 与被测实现交互，
**不 import** `relay` / `store` / `hub` / `api` / `dlp` 等内部模块，
因此同一套用例既跑现在的 Python 中转，也能跑将来的 Go 二进制。
启动方式见 ``README.md``。
"""
