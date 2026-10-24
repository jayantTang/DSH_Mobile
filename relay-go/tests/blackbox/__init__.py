"""黑盒测试基座（阶段 1，第一批）。

这一层只通过 HTTP、WebSocket、子进程与 `ADMIN_CMD` 与被测实现交互，
**不 import** 中转的任何内部模块，因此换别的实现只需要改
`RELAY_CMD` / `ADMIN_CMD`。
启动方式见 ``README.md``。
"""
