"""用本机 Chrome 的登录态在仓库里建 issue —— 不接触账号密码。

为什么这么绕：Agent 手上只有 SSH key，没有 GitHub token，而建 issue 必须走 API 或网页。
好在你本机 Chrome 里已经有 GitHub 登录态，于是用 Playwright 打开**你自己的**用户数据目录，
以你已登录的身份把表单填好并提交。不做任何登录动作，也不读 cookie。

跑法（必须保证 Chrome 没在运行，Chrome 是单例 profile）：

    python3 scripts/dev/gh-issue.py --repo jayantTang/DSH_Mobile \
        --title "..." --body-file /tmp/dsh-issue.md --dry-run
    python3 scripts/dev/gh-issue.py ... --submit
"""

import argparse
import pathlib
import re
import sys

from playwright.sync_api import sync_playwright

DEFAULT_PROFILE = pathlib.Path.home() / "Library/Application Support/Google/Chrome"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--title", required=True)
    parser.add_argument("--body-file", required=True)
    parser.add_argument("--profile", default=str(DEFAULT_PROFILE))
    parser.add_argument("--submit", action="store_true", help="不传则只填表并截图，不点提交")
    parser.add_argument("--shot", default="/tmp/gh-issue.png")
    args = parser.parse_args()

    body = pathlib.Path(args.body_file).read_text()

    with sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(
            user_data_dir=args.profile,
            headless=False,          # 有头：用你真实的登录态，也让过程可见
            viewport={"width": 1280, "height": 1000},
            args=["--no-first-run", "--no-default-browser-check"],
        )
        page = context.pages[0] if context.pages else context.new_page()
        url = f"https://github.com/{args.repo}/issues/new"
        page.goto(url, wait_until="domcontentloaded", timeout=60_000)

        # 已登录才有这个表单；没有就说明会话不在，直接说清楚而不是硬猜。
        if not page.locator("input[name='issue[title]']").count():
            print("NOT_LOGGED_IN: 打开 %s 没有看到新建 issue 的表单" % url)
            print("页面标题:", page.title())
            page.screenshot(path=args.shot, full_page=False)
            context.close()
            return 2

        page.fill("input[name='issue[title]']", args.title)
        # 正文是 markdown 文本框（支持粘贴）；用 fill 会逐字符触发自动补全，直接设值更快更稳。
        page.evaluate(
            """(text) => {
                const box = document.querySelector("textarea[name='issue[body]']");
                box.focus();
                box.value = text;
                box.dispatchEvent(new Event('input', { bubbles: true }));
            }""",
            body,
        )
        page.wait_for_timeout(500)
        page.screenshot(path=args.shot, full_page=False)

        if not args.submit:
            print("DRY_RUN: 表单已填好，截图 %s（没有点提交）" % args.shot)
            print("标题:", args.title)
            print("正文长度:", len(body))
            context.close()
            return 0

        page.click("button:has-text('Create')")
        page.wait_for_load_state("domcontentloaded", timeout=60_000)
        page.wait_for_timeout(1500)
        final = page.url
        match = re.search(rf"https://github\.com/{re.escape(args.repo)}/issues/\d+", final)
        page.screenshot(path=args.shot, full_page=False)
        if match:
            print("CREATED:", match.group(0))
            context.close()
            return 0
        print("UNKNOWN: 提交后停在", final, "（截图", args.shot, "）")
        context.close()
        return 3


if __name__ == "__main__":
    sys.exit(main())
