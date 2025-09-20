import os
import platform
import subprocess
from fastmcp import FastMCP

# 建立 MCP 伺服器
mcp = FastMCP("media_browser")

# 預設媒體資料夾（可用環境變數覆蓋）
DEFAULT_MEDIA_DIR = os.environ.get("MEDIA_DIR", r"C:\Users\weare\emotion-music-agent\media")

def _resolve_dir(dir_path: str | None) -> str:
    """確認資料夾存在並回傳實際路徑。"""
    path = (dir_path or DEFAULT_MEDIA_DIR).strip('"').strip("'")
    if not os.path.isdir(path):
        raise ValueError(f"Directory not found: {path}")
    return path

def _open_with_default_app(path: str) -> None:
    """用系統預設應用程式開啟檔案。"""
    if platform.system() == "Windows":
        os.startfile(path)  # type: ignore[attr-defined]
    elif platform.system() == "Darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])

@mcp.tool
def list_media(dir: str | None = None) -> dict:
    """
    列出資料夾中的 mp3 / mp4 檔案。
    - dir: 目標資料夾（可省略，使用預設 MEDIA_DIR）
    """
    folder = _resolve_dir(dir)
    names = os.listdir(folder)
    mp3 = sorted([f for f in names if f.lower().endswith(".mp3")])
    mp4 = sorted([f for f in names if f.lower().endswith(".mp4")])
    return {"directory": folder, "mp3": mp3, "mp4": mp4}

@mcp.tool
def open_media(name: str, dir: str | None = None) -> str:
    """
    以系統預設播放器開啟指定檔案。
    - name: 檔名（需位於 dir 內）
    - dir : 目標資料夾（可省略，使用預設 MEDIA_DIR）
    """
    folder = _resolve_dir(dir)
    path = os.path.join(folder, name)
    if not os.path.isfile(path):
        raise ValueError(f"File not found in directory:\n  {path}")
    if not (path.lower().endswith(".mp3") or path.lower().endswith(".mp4")):
        raise ValueError("Only .mp3 or .mp4 files are allowed")
    _open_with_default_app(path)
    return f"Opening: {path}"

@mcp.tool
def open_index(kind: str, index: int, dir: str | None = None) -> str:
    """
    依索引開啟檔案（方便在聊天中用數字選擇）。
    - kind : 'mp3' 或 'mp4'
    - index: 從 1 開始的序號（依字母排序）
    - dir  : 目標資料夾（可省略）
    """
    kind = kind.lower()
    if kind not in ("mp3", "mp4"):
        raise ValueError("kind must be 'mp3' or 'mp4'")
    folder = _resolve_dir(dir)
    files = sorted([f for f in os.listdir(folder) if f.lower().endswith(f".{kind}")])
    if not files:
        raise ValueError(f"No .{kind} files found in {folder}")
    if not (1 <= index <= len(files)):
        raise ValueError(f"index out of range (1..{len(files)})")
    target = os.path.join(folder, files[index - 1])
    _open_with_default_app(target)
    return f"Opening: {target}"

if __name__ == "__main__":
    # 用 stdio 跑 MCP server，給 Claude Desktop 連線
    mcp.run(transport="streamable-http", host="127.0.0.1", port=8002)
