from pathlib import Path
import tempfile, webbrowser, shutil
from fastmcp import FastMCP

mcp = FastMCP("puzzle-mcp")

ROOT = Path(__file__).parent
HTML_PATH = "C:/Users/weare/emotion-music-agent/static/puzzle.html"

# --- (A) 暴露你的拼圖頁作為「資源」 ---
# 設定 mime_type="text/html" 讓用戶端知道這是 HTML
@mcp.resource("puzzle://index", description="Standalone Puzzle Game HTML", mime_type="text/html")
def puzzle_index() -> str:
    """
    回傳 puzzle.html 原始內容（文字）。
    多數 MCP 用戶端會把這個資源顯示成可下載/開啟的檔案。
    """
    return HTML_PATH.read_text(encoding="utf-8")

# --- (B) 工具：輸出到指定資料夾 ---
@mcp.tool
def export_puzzle(dest_dir: str, filename: str = "puzzle.html") -> dict:
    """
    將 puzzle.html 複製到 dest_dir/filename，回傳絕對路徑。
    例：export_puzzle("C:\\Users\\你\\Desktop")
    """
    dest = Path(dest_dir).expanduser().resolve()
    dest.mkdir(parents=True, exist_ok=True)
    out_path = (dest / filename).resolve()
    shutil.copy2(HTML_PATH, out_path)
    return {"saved_to": str(out_path)}

# --- (C) 工具：暫存並在瀏覽器開啟 ---
@mcp.tool
def open_in_browser() -> dict:
    """
    將 puzzle.html 複製到臨時資料夾並嘗試用預設瀏覽器開啟。
    某些 MCP 用戶端可能會出於沙盒限制而忽略開窗；即使如此仍會回傳路徑。
    """
    tmpdir = Path(tempfile.gettempdir()) / "puzzle_mcp"
    tmpdir.mkdir(parents=True, exist_ok=True)
    out_path = tmpdir / "puzzle.html"
    shutil.copy2(HTML_PATH, out_path)
    try:
        webbrowser.open(out_path.as_uri())
    except Exception:
        pass
    return {"temp_path": str(out_path)}

if __name__ == "__main__":
    # 以 stdio 傳輸啟動（本機最常用；Claude Desktop 會用這種方式）
    mcp.run()
    # mcp.run(transport="streamable-http", host="http://127.0.0.1", port=8003)

