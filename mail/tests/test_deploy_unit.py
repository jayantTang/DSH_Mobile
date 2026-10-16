"""systemd 单元的渲染：`MAIL_TEAM_ACCOUNT` 开关的组合（2026-10-17 事故后补）。

事故：2026-10-17 01:47 的一次 `mail/deploy/deploy.sh` 没有导出
`DSH_MAIL_TEAM_ACCOUNT`，脚本用"未设置 = 空"渲染了单元，团队的开关当场关掉；
而线程的团队绑定是库里的列，不归开关管——owner 的 App 于是把用户的来信显示在
「已发送」里。修复是两条规矩，本文件逐条钉：

1. **没显式给就不动那一行**：沿用已装单元里的现值（首次安装 = 空）。
2. **给了就按给的来**，包括显式给空（关闭）与脏值（拒绝部署，不写半个文件）。

渲染走 `deploy.sh --render-unit <path>` 这条旁路：与部署路径**同一份函数**，
但不需要 root、不碰 systemd 与 Caddy，所以能在单测里跑。
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess

import pytest

MAIL_DIR = pathlib.Path(__file__).resolve().parents[1]
DEPLOY = MAIL_DIR / "deploy" / "deploy.sh"
TEMPLATE = MAIL_DIR / "deploy" / "dsh-mail.service"

BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="bash is not installed")


def render(tmp_path: pathlib.Path, *, env: dict[str, str] | None = None,
           installed: str | None = None, out_name: str = "rendered.service",
           port: str | None = None):
    """跑一次渲染，返回 (结果, 输出文件, 渲染出的开关值)。"""
    existing = tmp_path / "installed.service"
    if installed is not None:
        existing.write_text(installed)
    out = tmp_path / out_name
    environment = {"PATH": "/usr/bin:/bin:/usr/local/bin", "DSH_MAIL_EXISTING_UNIT": str(existing)}
    if port is not None:
        environment["DSH_MAIL_PORT"] = port
    environment.update(env or {})
    result = subprocess.run([BASH, str(DEPLOY), "--render-unit", str(out)],
                            capture_output=True, text=True, env=environment)
    return result, out


def team_line(path: pathlib.Path) -> str:
    lines = [line for line in path.read_text().splitlines()
             if line.startswith("Environment=MAIL_TEAM_ACCOUNT=")]
    assert len(lines) == 1, lines
    return lines[0].split("=", 2)[2]


def test_the_template_ships_with_the_switch_off():
    assert "Environment=MAIL_TEAM_ACCOUNT=\n" in TEMPLATE.read_text()
    assert "Environment=MAIL_PORT=8788\n" in TEMPLATE.read_text()


def test_an_explicit_value_is_written_verbatim(tmp_path):
    result, out = render(tmp_path, env={"DSH_MAIL_TEAM_ACCOUNT": "acc_team"},
                         installed="[Service]\nEnvironment=MAIL_TEAM_ACCOUNT=acc_old\n")
    assert result.returncode == 0, result.stderr
    assert team_line(out) == "acc_team", "显式给值压过已装单元"
    assert "MAIL_TEAM_ACCOUNT=acc_team" in result.stdout, "部署日志要说清结果"


def test_without_the_variable_the_installed_value_survives(tmp_path):
    """事故回归：不导出变量的部署**不许**把开关清掉。"""
    result, out = render(tmp_path, installed="[Service]\nEnvironment=MAIL_TEAM_ACCOUNT=acc_team\n")
    assert result.returncode == 0, result.stderr
    assert team_line(out) == "acc_team"
    assert "keeping the installed value (acc_team)" in result.stderr, "日志要说明是沿用的"


def test_a_first_install_without_the_variable_stays_off(tmp_path):
    result, out = render(tmp_path)
    assert result.returncode == 0, result.stderr
    assert team_line(out) == ""
    assert "team inbox stays off" in result.stderr


def test_an_explicit_empty_value_turns_the_switch_off(tmp_path):
    """要关就显式给空——别靠"忘导出"来关。"""
    result, out = render(tmp_path, env={"DSH_MAIL_TEAM_ACCOUNT": ""},
                         installed="[Service]\nEnvironment=MAIL_TEAM_ACCOUNT=acc_team\n")
    assert result.returncode == 0, result.stderr
    assert team_line(out) == ""
    assert "<empty: team inbox off>" in result.stdout


@pytest.mark.parametrize("value", ["acc team", "acc_team;rm -rf /", "acc_team\nEnvironment=PATH=/x",
                                   "acc/team", "$(whoami)", "acc`id`"])
def test_a_dirty_value_is_refused_before_anything_is_written(tmp_path, value):
    result, out = render(tmp_path, env={"DSH_MAIL_TEAM_ACCOUNT": value})
    assert result.returncode != 0, "脏值必须拒部署"
    assert "not an account id" in result.stderr
    assert not out.exists(), "拒部署时不留下半个单元"


def test_the_port_is_substituted_into_both_places(tmp_path):
    result, out = render(tmp_path, port="8799")
    assert result.returncode == 0, result.stderr
    text = out.read_text()
    assert "Environment=MAIL_PORT=8799" in text
    assert "--port 8799" in text
    assert "8788" not in text, "端口不许残留默认值"


def test_a_template_without_the_switch_line_is_refused(tmp_path):
    """模板漂移（那一行被改成带值/删掉）时宁可拒渲染，也不要静默写出开关关掉的单元。"""
    fake = tmp_path / "dsh-mail.service"
    fake.write_text(TEMPLATE.read_text().replace("Environment=MAIL_TEAM_ACCOUNT=\n",
                                                 "Environment=MAIL_TEAM_ACCOUNT=acc_stale\n"))
    deploy = tmp_path / "deploy.sh"
    deploy.write_text(DEPLOY.read_text().replace('UNIT_TEMPLATE="$SRC_DIR/deploy/dsh-mail.service"',
                                                 f'UNIT_TEMPLATE="{fake}"'))
    out = tmp_path / "out.service"
    result = subprocess.run([BASH, str(deploy), "--render-unit", str(out)],
                            capture_output=True, text=True,
                            env={"PATH": "/usr/bin:/bin:/usr/local/bin",
                                 "DSH_MAIL_TEAM_ACCOUNT": "acc_team"})
    assert result.returncode != 0
    assert "no empty MAIL_TEAM_ACCOUNT line" in result.stderr
    assert not out.exists()
