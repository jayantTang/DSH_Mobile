"""M3 部署物的行为：Caddy 第二片段与迁表脚本。

钉住 DESIGN-20261015 的三个部署期前提：

1. 两个标记块互不干扰：mail 的 splicer 只动自己的标记块，relay 已插的
   片段原样保留；`remove` 只删 mail 的。
2. 片段内容与求值前提：更具体的 `handle /dsh-link/feedback/*`、
   `uri strip_prefix /dsh-link`、8788、有限超时（不是 DLP 那种 0）。
3. 迁表脚本：按列拷贝、幂等（OR REPLACE）、dry-run 零写入、源库只读
   （mode=ro 连接，写直接被 SQLite 拒绝）。

真实 Caddy 的求值次序（更具体路径优先）在部署后用真请求核对，本文件只钉片段与插入行为。
"""

from __future__ import annotations

import pathlib
import sqlite3
import subprocess
import sys

from store import Store, sha256_hex

HERE = pathlib.Path(__file__).resolve().parent
MAIL_DIR = HERE.parent
DEPLOY = MAIL_DIR / "deploy"
SPLICER = DEPLOY / "caddy_splice.py"
SNIPPET = DEPLOY / "Caddyfile.snippet"
MIGRATE = DEPLOY / "migrate_from_relay.py"

#: 一个已经装了 relay 片段的站点块（生产形状：relay 的标记块 + handle_path）。
CADDYFILE = """\
relay.example.com {
	# >>> dsh-relay managed block (managed by relay/deploy/deploy.sh) >>>
	handle_path /dsh-link/* {
		reverse_proxy 127.0.0.1:8787
	}
	# <<< dsh-relay managed block <<<

	handle /other/* {
		reverse_proxy 127.0.0.1:9999
	}
}
"""


def splice(*args: str) -> str:
    """跑 splicer：`insert <Caddyfile> <snippet> <site>` / `remove <Caddyfile>`。"""
    result = subprocess.run([sys.executable, str(SPLICER), *args],
                            capture_output=True, text=True, check=True)
    return result.stdout.strip()


def test_the_snippet_routes_feedback_to_the_mail_port():
    text = SNIPPET.read_text()
    assert "handle /dsh-link/feedback/* {" in text, "比 handle_path 更具体的路径"
    assert "uri strip_prefix /dsh-link" in text, "只剥 /dsh-link，保留 /feedback/*"
    assert "reverse_proxy 127.0.0.1:8788" in text
    assert "read_timeout 0" not in text and "write_timeout 0" not in text, \
        "信件是短 HTTP，不沿用 DLP 的无限超时"
    assert "header_up X-Forwarded-For {remote_host}" in text, "限流桶靠它分辨调用方"


def test_insert_and_remove_touch_only_the_mail_block(tmp_path):
    caddyfile = tmp_path / "Caddyfile"
    caddyfile.write_text(CADDYFILE)

    action = splice("insert", str(caddyfile), str(SNIPPET), "relay.example.com")
    assert action == "inserted"
    spliced = caddyfile.read_text()

    # mail 的标记块在，relay 的标记块原样在，两边互不吞。
    assert "# >>> dsh-mail managed block" in spliced
    assert "# >>> dsh-relay managed block" in spliced
    assert "reverse_proxy 127.0.0.1:8788" in spliced
    assert "reverse_proxy 127.0.0.1:8787" in spliced
    # 不许嵌进 relay 的标记块：mail 的 END 必须在 relay 的 BEGIN 之前——
    # 否则 relay 下次重部署（按自己的标记整段替换）会把 mail 的路由吞掉。
    assert spliced.index("# <<< dsh-mail managed block") < spliced.index("# >>> dsh-relay managed block")
    # 文件次序无关紧要（Caddy 按路径特异性选 handle），嵌套才是要防的；上面那条已钉住。

    # 幂等：再插一遍是 replaced，不是第二份。
    assert splice("insert", str(caddyfile), str(SNIPPET), "relay.example.com") == "replaced"
    assert caddyfile.read_text().count("# >>> dsh-mail managed block") == 1

    # remove 只删 mail 的块。
    assert splice("remove", str(caddyfile)) == "removed"
    after = caddyfile.read_text()
    assert "dsh-mail managed block" not in after
    assert "dsh-relay managed block" in after, "relay 的片段不许被动到"


def _relay_shaped_db(path: pathlib.Path) -> str:
    """搭一个"中转侧"库：4 张信件表 + 行。"""
    conn = sqlite3.connect(path)
    conn.executescript(
        "CREATE TABLE feedbackThreads (threadId TEXT PRIMARY KEY, ticketHash TEXT NOT NULL UNIQUE,"
        " accountId TEXT, deviceId TEXT, appVersion TEXT, deviceModel TEXT, systemVersion TEXT,"
        " createdAt INTEGER NOT NULL, lastMessageAt INTEGER NOT NULL, ownerReadAt INTEGER,"
        " userReadAt INTEGER, status TEXT NOT NULL DEFAULT 'open', clientRef TEXT UNIQUE,"
        " subject TEXT);"
        "CREATE TABLE feedbackMessages (messageId TEXT PRIMARY KEY, threadId TEXT NOT NULL,"
        " author TEXT NOT NULL, body TEXT NOT NULL, createdAt INTEGER NOT NULL,"
        " clientRef TEXT UNIQUE, format TEXT NOT NULL DEFAULT 'text');"
        "CREATE TABLE notices (noticeId TEXT PRIMARY KEY, subject TEXT, body TEXT NOT NULL,"
        " createdAt INTEGER NOT NULL, createdBy TEXT, format TEXT NOT NULL DEFAULT 'text');"
        "CREATE TABLE noticeDeliveries (noticeId TEXT NOT NULL, accountId TEXT NOT NULL,"
        " createdAt INTEGER NOT NULL, readAt INTEGER, PRIMARY KEY (noticeId, accountId));")
    conn.execute("INSERT INTO feedbackThreads(threadId, ticketHash, accountId, deviceId,"
                 " createdAt, lastMessageAt, status, subject)"
                 " VALUES('th_m', ?, 'acc_a', 'dev_a', 5, 6, 'replied', '迁移主题')",
                 (sha256_hex("fk_m"),))
    conn.execute("INSERT INTO feedbackMessages(messageId, threadId, author, body, createdAt)"
                 " VALUES('fm_1', 'th_m', 'user', '原文', 5)")
    conn.execute("INSERT INTO notices(noticeId, subject, body, createdAt, createdBy)"
                 " VALUES('nt_1', '通知', '正文', 7, 'admin.py')")
    conn.execute("INSERT INTO noticeDeliveries(noticeId, accountId, createdAt)"
                 " VALUES('nt_1', 'acc_a', 7)")
    conn.commit()
    conn.close()
    return str(path)


def test_migrate_copies_by_column_idempotently_and_never_touches_the_source(tmp_path):
    source = _relay_shaped_db(tmp_path / "state.db")
    target = str(tmp_path / "mail.db")
    # 目标库**不预建表**：迁表脚本自己建（切换顺序是先迁表、再上路由）。

    # dry-run：一个字都不写。
    dry = subprocess.run([sys.executable, str(MIGRATE), "--from", source, "--to", target,
                          "--dry-run"], capture_output=True, text=True, check=True)
    for table in ("feedbackThreads", "feedbackMessages", "notices", "noticeDeliveries"):
        assert f"{table}: 1 行" in dry.stdout, dry.stdout
    assert "预演" in dry.stdout
    assert Store(target).feedback_thread("th_m", sha256_hex("fk_m")) is None, "dry-run 不许写"

    # 真跑：按列拷进去，凭据哈希可用。
    run = subprocess.run([sys.executable, str(MIGRATE), "--from", source, "--to", target],
                         capture_output=True, text=True, check=True)
    assert "源库未做任何改动" in run.stdout
    store = Store(target)
    try:
        thread = store.feedback_thread("th_m", sha256_hex("fk_m"))
        assert thread is not None and thread["subject"] == "迁移主题"
        assert thread["accountId"] == "acc_a"
        assert [row["noticeId"] for row in store.notices_for_account("acc_a")] == ["nt_1"]
    finally:
        store.close()

    # 幂等：再跑一遍行数不翻倍。
    subprocess.run([sys.executable, str(MIGRATE), "--from", source, "--to", target],
                   capture_output=True, text=True, check=True)
    conn = sqlite3.connect(target)
    counts = {table: conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
              for table in ("feedbackThreads", "feedbackMessages", "notices",
                            "noticeDeliveries")}
    conn.close()
    assert counts == {"feedbackThreads": 1, "feedbackMessages": 1, "notices": 1,
                      "noticeDeliveries": 1}

    # 源库是只读连接：直接验证 SQLite 拒绝写入。
    ro = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    try:
        ro.execute("DELETE FROM feedbackThreads")
        raised = False
    except sqlite3.OperationalError:
        raised = True
    finally:
        ro.close()
    assert raised, "源库必须以只读方式打开"
