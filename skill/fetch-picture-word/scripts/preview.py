#!/usr/bin/env python3
"""Local preview server for the fetch-picture-word dialog.

Serves ``assets/`` and exposes one OCR endpoint that shells out to
``scripts/ocr.ps1`` (the OCR engine built into Windows).  Browsers only grant
secure-context features -- region capture through ``getDisplayMedia`` and direct
clipboard reads -- to http(s) origins, which is the reason this page is not just
opened from disk.

    python scripts/preview.py            # http://127.0.0.1:8765, opens a browser
    python scripts/preview.py --no-browser --port 9100

Python 3.8+, standard library only.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
ASSETS_DIR = SKILL_DIR / "assets"
REFERENCES_DIR = SKILL_DIR / "references"
OCR_SCRIPT = SKILL_DIR / "scripts" / "ocr.ps1"

# images shipped with the skill, usable for a quick self-test (`--sample` or
# `?sample=NAME` on the page URL)
SAMPLES = (
    "sample-chat.png",
    "sample-receipt.png",
    "sample-latin-table.png",
    "sample-tiny-text.png",
)

MAX_UPLOAD = 32 * 1024 * 1024
OCR_TIMEOUT = 120


def find_powershell() -> str:
    """Windows PowerShell first: System.Runtime.WindowsRuntime interop for the
    WinRT OCR types is a .NET Framework feature and is not available in pwsh
    (PowerShell 7 / .NET Core) on every machine."""
    candidates = [
        Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe",
        shutil.which("powershell.exe") or Path(""),
        shutil.which("pwsh.exe") or Path(""),
        shutil.which("pwsh") or Path(""),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    raise SystemExit("找不到 PowerShell，无法调用 Windows OCR 引擎。")


POWERSHELL = find_powershell()

# Windows PowerShell writes to a pipe using the OEM code page unless the parent
# decodes the bytes explicitly; subprocess.run(encoding="utf-8") below handles
# that, and PYTHONIOENCODING keeps any Python child on UTF-8 too.
OCR_ENV = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")


def run_ocr(image_path: Path) -> dict:
    """Return the parsed JSON emitted by ocr.ps1, or a {ok: false, error} dict."""
    command = [
        POWERSHELL,
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(OCR_SCRIPT),
        "-InputPath",
        str(image_path),
        "-Json",
    ]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            timeout=OCR_TIMEOUT,
            encoding="utf-8",
            errors="replace",
            env=OCR_ENV,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"识别超时（{OCR_TIMEOUT}s）", "code": 4}
    except OSError as exc:
        return {"ok": False, "error": f"无法启动识别进程：{exc}", "code": 3}

    stdout = (completed.stdout or "").strip()
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    detail = (completed.stderr or "").strip() or stdout or "no output"
    return {"ok": False, "error": detail[-800:], "code": completed.returncode}


def probe_engine() -> dict:
    """Ask ocr.ps1 which recognizers this machine has, for the status bar."""
    command = [
        POWERSHELL,
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(OCR_SCRIPT),
        "-ListLanguages",
        "-Json",
    ]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            timeout=60,
            encoding="utf-8",
            errors="replace",
            env=OCR_ENV,
        )
        payload = json.loads((completed.stdout or "").strip().splitlines()[-1])
    except Exception as exc:  # noqa: BLE001 - any failure means "not ready"
        return {"ok": False, "error": str(exc), "hint": "Windows OCR 引擎不可用，请确认已安装中文/英文语言包。"}

    names = [item.get("name", item.get("tag", "")) for item in payload.get("languages", [])]
    label = "、".join(name for name in names if name)
    return {"ok": True, "languages": label, "raw": payload.get("languages", [])}


class Handler(BaseHTTPRequestHandler):
    server_version = "fetch-picture-word"

    # -- plumbing ---------------------------------------------------------
    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        if self.server.verbose:  # type: ignore[attr-defined]
            sys.stderr.write("  %s %s\n" % (self.address_string(), fmt % args))

    def send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path: Path) -> None:
        if not path.is_file():
            self.send_json({"ok": False, "error": "not found"}, status=404)
            return
        body = path.read_bytes()
        guessed, _ = mimetypes.guess_type(path.name)
        content_type = guessed or "application/octet-stream"
        if path.suffix in {".html", ".js", ".css"}:
            content_type += "; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # -- routes -----------------------------------------------------------
    def do_GET(self):  # noqa: N802 - stdlib signature
        route = self.path.split("?", 1)[0]
        if route in {"/", "/index.html"}:
            self.send_file(ASSETS_DIR / "chat.html")
        elif route == "/api/health":
            self.send_json(probe_engine())
        elif route.startswith("/references/"):
            name = route[len("/references/"):]
            if name in SAMPLES:
                self.send_file(REFERENCES_DIR / name)
            else:
                self.send_json({"ok": False, "error": "unknown sample"}, status=404)
        elif route.startswith("/api/") or ".." in route:
            self.send_json({"ok": False, "error": "unknown endpoint"}, status=404)
        else:
            self.send_file(ASSETS_DIR / route.lstrip("/"))

    def do_POST(self):  # noqa: N802 - stdlib signature
        if self.path.split("?", 1)[0] != "/api/ocr":
            self.send_json({"ok": False, "error": "unknown endpoint"}, status=404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_UPLOAD:
            self.send_json({"ok": False, "error": "图片为空或超过 32 MB"}, status=413)
            return

        data = self.rfile.read(length)
        suffix = ".png"
        content_type = (self.headers.get("Content-Type") or "").lower()
        if "jpeg" in content_type or "jpg" in content_type:
            suffix = ".jpg"
        elif "webp" in content_type:
            suffix = ".webp"
        elif "bmp" in content_type:
            suffix = ".bmp"

        started = time.perf_counter()
        temp_dir = Path(tempfile.mkdtemp(prefix="fpw-upload-"))
        try:
            image_path = temp_dir / f"upload{suffix}"
            image_path.write_bytes(data)
            result = run_ocr(image_path)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

        result["elapsedMs"] = round((time.perf_counter() - started) * 1000)
        self.send_json(result)


def claim_port(host: str, preferred: int) -> tuple[ThreadingHTTPServer, int]:
    for port in range(preferred, preferred + 20):
        try:
            return ThreadingHTTPServer((host, port), Handler), port
        except OSError:
            continue
    raise SystemExit(f"{host}:{preferred}-{preferred + 19} 都被占用，请用 --port 换一个端口。")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the fetch-picture-word dialog in a browser.")
    parser.add_argument("--host", default="127.0.0.1", help="bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8765, help="first port to try (default: 8765)")
    parser.add_argument("--no-browser", action="store_true", help="do not open a browser window")
    parser.add_argument("--verbose", action="store_true", help="log every request")
    parser.add_argument(
        "--sample",
        choices=("all",) + tuple(name.removeprefix("sample-").removesuffix(".png") for name in SAMPLES),
        help="open the page with a bundled sample image already sent to the OCR engine",
    )
    args = parser.parse_args()

    if not OCR_SCRIPT.is_file():
        print(f"缺少 {OCR_SCRIPT}", file=sys.stderr)
        return 2

    server, port = claim_port(args.host, args.port)
    server.verbose = args.verbose  # type: ignore[attr-defined]
    url = f"http://{args.host}:{port}/"
    if args.sample:
        url += f"?sample={args.sample}"

    print(f"fetch-picture-word  |  {url}")
    print(f"  识别脚本 : {OCR_SCRIPT}")
    print("  按 Ctrl+C 停止。截图、粘贴或选择图片，文字会直接出现在对话框里。")

    if not args.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    if os.name != "nt":
        print("这个 Skill 依赖 Windows 自带的 OCR 引擎，只能在 Windows 上运行。", file=sys.stderr)
        sys.exit(3)
    sys.exit(main())
