# -*- coding: utf-8 -*-
"""
整合版（MCP 專用；含強制正念本地音檔播放）
- 同意前靜默（只顯示壞情緒提醒）
- 情緒來源使用 MCP：背景偵測每輪「新建最小 Agent + nonce」，強制用工具、避免沿用舊答案
- /ok 啟用後提供選單：
    /music  -> 嚴格播放驗證（play_song）
    /game   -> 紓壓小遊戲（文字引導）
    /mind   -> 透過 MCP 本地媒體工具播放 mp3（list_media/open_index/open_media），不傳 dir
    /chat   -> 情緒諮商師聊天（自然語句也能觸發 音樂/遊戲/正念）
- 完全隱藏工具相關輸出，只顯示助理文字
- LOG_TOOL_DEBUG=1 可暫時檢視工具事件（預設不印）

相依：
    pip install huggingface_hub
Python：3.9+

環境變數（可選）：
    EMOTION_POLL_SEC=600          # 輪詢秒數（預設 600）
    BAD_EMOTIONS="angry,disgust,fear,sad, happy, neutral, surprise"
    LOG_EMOTION_DEBUG=1           # 顯示 MCP 情緒偵測除錯
    LOG_TOOL_DEBUG=1              # 顯示工具事件除錯（預設關）
"""

import os
import re
import json
import asyncio
import contextlib
from typing import Optional, Tuple


from huggingface_hub.inference._mcp.agent import Agent

# ---------------------- 路徑與設定 ----------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
AGENT_JSON_PATH = os.path.join(PROJECT_ROOT, "agent.json")

# ---------------------- 參數（可用環境變數覆寫） ----------------------
POLL_INTERVAL_SEC = int(os.environ.get("EMOTION_POLL_SEC", "600"))  # 預設 600 秒
BAD_EMOTIONS = {e.strip().lower() for e in os.environ.get(
    "BAD_EMOTIONS",
    "angry, disgust, fear, sad"
).split(",") if e.strip()}
LOG_EMOTION_DEBUG = os.environ.get("LOG_EMOTION_DEBUG", "0") == "1"
LOG_TOOL_DEBUG = os.environ.get("LOG_TOOL_DEBUG", "0") == "1"

# 同意前完全靜默（除了情緒通知）
SILENT_BEFORE_CONSENT = True

# 單一關鍵詞
CONSENT_KEYWORDS = {"/ok"}
CANCEL_KEYWORDS  = {"/no"}

MENU_TEXT = (
    "\n[已啟用協助] 想做什麼？\n"
    "  • /music 〈歌名或心情〉  例：/music 周杰倫 或 /music 想聽放鬆的鋼琴\n"
    "  • /game                 開啟 3 分鐘紓壓拼圖小遊戲（嘗試在瀏覽器開啟）\n"
    "  • /mind [索引或關鍵字]  播放本地正念音檔（例：/mind 2 或 /mind 放鬆）\n"
    "  • /chat                 與情緒諮商師聊天（聊天也能自然說：想聽音樂/玩遊戲/做正念）\n"
    "  • /reset                重設聊天對話（不影響工具執行的無記憶模式）\n"
    "  （隨時輸入 /menu 返回本選單）\n"
)

CHAT_HINT = (
    "\n[聊天模式] 你現在可以直接和我聊任何感受或近況。\n"
    "  • 自然語句也能觸發：說「想聽音樂」「來個遊戲」「帶我做正念」即可\n"
    "  • 輸入 /end 或 /menu 可結束聊天，返回功能選單。\n"
)

# 進入聊天模式時送給 LLM 的一次性指示（含自然語句可直接執行）
CHAT_SYSTEM_INSTRUCTION = (
    "你現在是一位溫暖、尊重、非指令式的『情緒諮商師』。"
    "聊天時請傾聽與反映感受，適度使用開放式問題，避免過度勸告或說教。"
    "請根據使用者話語推斷其情緒狀態（正向、中性、負向），"
    "在對話過程中若你判斷使用者情緒已顯著好轉且對話目標已達成，"
    "可以輕聲詢問是否要結束對話；若對方仍想聊，繼續陪伴即可。"
    "此外，若使用者在聊天中表達『想聽/播放音樂』『想玩遊戲』『想做正念/冥想』等意圖，"
    "你可以直接啟動相應流程；若需要補充資訊（如歌手/風格），以最少問題補齊即可。"
    "除非使用者主動詢問，否則不需要每輪給出選擇清單或教學步驟。"
)

EXPECTING_MUSIC_QUERY = object()  # 內部狀態旗標

# 嚴格播放指令模板（限制只能呼叫 play_song，且輸出工具原始 JSON）
MUSIC_PLAY_INSTRUCTION = (
    "任務：根據使用者線索『實際播放』音樂。\n"
    "硬性規則：\n"
    "A) 你【只能】呼叫名為 play_song 的 MCP 工具來播放（不要呼叫其他工具）。\n"
    "B) 呼叫完成後，請將 play_song 工具『原始回傳的 JSON』作為回覆的『最後一行，且只有一行 JSON』輸出；不要添加或改寫欄位。\n"
    "C) 僅當該 JSON 顯示播放成功（例如 status 為 ok/success，或 playing==true），才視為成功。\n"
    "D) JSON 之外可有極簡說明，但最後一行必須是工具『原始』JSON；不得捏造。\n"
    "E) 若使用者僅說『隨便』或只給歌手/風格，請直接用 play_song 按照線索播放，不要再追問。\n"
    "F) 嚴禁口頭宣稱成功而未真的呼叫工具。\n"
    "play_song 參數：可接受 track（歌名）、artist（歌手）、query（自由文字其一即可）。\n"
)

# 正念音檔播放（只允許 list_media/open_media/open_index；最後一行輸出原始 JSON；不傳 dir）
MINDFUL_PLAY_INSTRUCTION = (
    "任務：播放本地正念/放鬆的 mp3 音檔。\n"
    "硬性規則：\n"
    "A) 你【只能】使用以下 MCP 工具：list_media、open_media、open_index。（不要使用其它工具）\n"
    "B) 一律使用工具的預設資料夾，呼叫時不要傳入任何 dir 參數。\n"
    "C) 若使用者有給『索引數字』，請呼叫 open_index(kind='mp3', index=該數字)。\n"
    "D) 若使用者未給索引或給的是關鍵字，請先呼叫 list_media()，在回傳的 mp3 清單中挑選一個最符合關鍵字的檔案，"
    "   若沒有明顯匹配就選列表的第一個；然後呼叫 open_media(name='<檔名>')。\n"
    "E) 呼叫完成後，請將『工具的原始結果』轉為最後一行 JSON（單行），不得捏造；格式例如：\n"
    '   {"status":"ok","opened":"<檔名>","path":"<工具輸出或完整路徑>"}\n'
    "  若失敗：\n"
    '   {"status":"fail","reason":"<原因>"}\n'
    "F) JSON 之外可有極簡說明，但最後一行必須是那行 JSON。\n"
)

# 小遊戲（只允許 open_in_browser；最後一行輸出工具原始 JSON；不傳路徑）
PUZZLE_OPEN_INSTRUCTION = (
    "任務：開啟紓壓小遊戲（瀏覽器版拼圖）。\n"
    "硬性規則：\n"
    "A) 你【只能】呼叫名為 open_in_browser 的 MCP 工具（不要呼叫其他工具，也不要自行產生 HTML）。\n"
    "B) 呼叫完成後，請將 open_in_browser 工具『原始回傳的 JSON』作為回覆的『最後一行，且只有一行 JSON』輸出；不得改寫或新增欄位。\n"
    "C) 嚴禁口頭宣稱成功而未真的呼叫工具。\n"
    "說明：puzzle-mcp 伺服器已內建 puzzle.html 的位置，無需傳入任何目錄參數；工具通常回傳形如 {\"temp_path\": \"...\"}。\n"
)

# ---------------------- 小工具函式 ----------------------

def _basename(s: str) -> str:
    """擷取檔名basename，順便去除多餘引號與空白。"""
    if not isinstance(s, str):
        s = str(s or "")
    s = s.strip().strip('"').strip("'")
    return os.path.basename(s)

def _same_name(a: str, b: str) -> bool:
    """寬鬆比較：只比對basename（不含路徑）；不分大小寫。"""
    return _basename(a).casefold() == _basename(b).casefold()


def _get_attr(obj, name, default=None):
    """同時相容 pydantic 物件與 dict 結構。"""
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)

async def ainput(prompt: str) -> str:
    """非同步版 input，避免阻塞事件圈。"""
    return await asyncio.to_thread(input, prompt)

def _extract_last_json_line(text: str) -> Optional[dict]:
    """從助理輸出的最後一行或全文中抓取 JSON 物件。"""
    if not text:
        return None
    last_line = text.strip().splitlines()[-1].strip()
    if last_line.startswith("```") and last_line.endswith("```"):
        last_line = last_line.strip("`").strip()
    if last_line.lower().startswith("json"):
        last_line = last_line[4:].strip()
    try:
        return json.loads(last_line)
    except Exception:
        m = list(re.finditer(r"\{.*?\}", text, re.DOTALL))
        if m:
            try:
                return json.loads(m[-1].group(0))
            except Exception:
                return None
        return None

# ==== 自然語句 → 意圖判斷（規則式） ====
import re as _re

INTENT_PATTERNS = {
    "music": [
        r"(想|要|可以)?(聽|播|播放).*?(歌|音樂)",
        r"(來|放)一?首",
        r"音樂.*(放|播)",
    ],
    "game": [
        r"(想|要|可以)?(玩|來).*?(遊戲|小遊戲)",
        r"紓壓.*(遊戲)",
    ],
    "mind": [
        r"(想|要|可以)?.*?(正念|冥想|呼吸練習|身體掃描|放鬆練習)",
    ],
}

def detect_intent(text: str):
    t = text.strip().lower()
    if t.startswith(("/music", "/game", "/mind", "/menu", "/end", "/reset")):
        return None
    for intent, pats in INTENT_PATTERNS.items():
        for pat in pats:
            if _re.search(pat, text, _re.I):
                if intent == "music":
                    q = parse_music_query(text)
                    return ("music", q)
                return (intent, None)
    return None

def parse_music_query(text: str) -> str:
    m = _re.search(
        r"(聽|播|播放|來|放).*?(?P<q>周杰倫|五月天|lo-?fi|lofi|鋼琴|放鬆|輕音樂|抒情|搖滾|爵士|古典|電音|hip[- ]?hop|rap|白噪音|日文|韓文|英文|中文|中文歌|日語|韓語)",
        text, _re.I
    )
    if m:
        return m.group("q").strip()
    m = _re.search(r"想.*?聽(?P<q>.+?)(的歌)?$", text, _re.I)
    if m:
        return m.group("q").strip()
    m = _re.search(r"(來|放).*?一?首(?P<q>.+)$", text, _re.I)
    if m:
        return m.group("q").strip()
    return ""

# ---------------------- 無記憶工具呼叫：關鍵修正 ----------------------
BASE_CFG: Optional[dict] = None  # 由 main() 設定

async def tool_call_stateless(user_text: str) -> str:
    """
    每次動作都用「一次性、無記憶」的 micro-agent 執行，避免沿用舊上下文。
    只用於需要嚴格確認工具回傳(JSON)的流程。
    """
    if BASE_CFG is None:
        with open(AGENT_JSON_PATH, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    else:
        cfg = BASE_CFG

    async with Agent(
        model=cfg["model"],
        base_url="http://localhost:8000/api/",
        servers=cfg["servers"],
        prompt=(
            "You are a stateless tool runner. "
            "Never rely on prior conversation or assumed state. "
            "For every request you MUST call the specified MCP tool and base your final single-line JSON strictly on the tool's raw response."
        ),
    ) as a:
        await a.load_tools()
        return await run_agent_and_capture(a, user_text)

# ---------------------- 小遊戲（open_in_browser；讀原始 JSON 判定） ----------------------
async def open_puzzle_game(agent: Agent) -> bool:
    """
    強制只呼叫 open_in_browser()，最後一行鏡射工具原始 JSON。
    成功判定：JSON 內含可用欄位（例如 'temp_path' 為非空字串）。
    """
    prompt = PUZZLE_OPEN_INSTRUCTION + "\n---\n請立刻開啟紓壓小遊戲。"
    text = await tool_call_stateless(prompt)

    if text:
        print(text)

    obj = _extract_last_json_line(text or "")
    if not isinstance(obj, dict):
        return False

    temp_path = obj.get("temp_path")
    return isinstance(temp_path, str) and len(temp_path.strip()) > 0

# ---------------------- 背景：情緒輪詢（MCP 專用） ----------------------
EMOTION_MCP_PROMPT = (
    "請務必呼叫『情緒偵測』的 MCP 工具取得最新結果，"
    "不要沿用先前對話的任何答案，也不要猜測；"
    "最後只回一行 JSON，例如：{\"emotion\":\"sad\",\"score\":0.87}\n"
)

async def emotion_watcher(notify_queue: asyncio.Queue):
    """MCP 專用情緒輪詢：每輪新建最小 Agent，避免脈絡殘留。"""
    with open(AGENT_JSON_PATH, "r", encoding="utf-8") as f:
        base_cfg = json.load(f)
    mini_cfg = {"model": base_cfg["model"], "servers": base_cfg["servers"]}

    last_json = None  # 去重用（可取消）

    while True:
        try:
            async with Agent(
                model=mini_cfg["model"],
                base_url="http://localhost:8000/api/",
                servers=mini_cfg["servers"],
                prompt=EMOTION_MCP_PROMPT
            ) as probe:
                await probe.load_tools()

                import time, random
                nonce = f"{int(time.time())}-{random.randint(1000,9999)}"
                q = f"請立即偵測情緒並依規定格式回覆。nonce={nonce}"
                text = await run_agent_and_capture(probe, q)

            if LOG_EMOTION_DEBUG:
                print(f"[DEBUG] nonce={nonce} text={text!r}")

            data = {}
            try:
                data = json.loads(text.strip())
            except Exception:
                m = re.search(r"\{.*\}", text or "", re.DOTALL)
                if m:
                    data = json.loads(m.group(0))

            if LOG_EMOTION_DEBUG:
                print(f"[DEBUG] parsed={data}")

            if data and data != last_json:
                last_json = data
                label = (data.get("emotion") or "").lower()
                score = data.get("score")
                if label and label in BAD_EMOTIONS:
                    msg = (
                        f"\n[情緒偵測] 目前情緒：{label}"
                        + (f"（信心 {float(score):.2f}）" if isinstance(score, (int, float)) else "")
                        + f"\n→ 你看起來狀態不太好，需要幫忙嗎？\n   同意請輸入 {' / '.join(CONSENT_KEYWORDS)}（拒絕：{' / '.join(CANCEL_KEYWORDS)}）\n"
                    )
                    await notify_queue.put(msg)

        except Exception as e:
            await notify_queue.put(f"\n[情緒偵測/MCP] 呼叫失敗：{e}\n")

        await asyncio.sleep(POLL_INTERVAL_SEC)

# ---------------------- 與 Agent 的互動（隱藏工具輸出，支援工具除錯） ----------------------
async def run_agent_chat(agent: Agent, user_text: str):
    """
    只輸出助理文字內容（串流/整段），完全隱藏工具呼叫與工具回覆。
    """
    async for item in agent.run(user_text):
        # 可選：工具除錯輸出
        if LOG_TOOL_DEBUG and _get_attr(item, "role") == "tool":
            tname = _get_attr(item, "name")
            tcontent = _get_attr(item, "content")
            print(f"\n[TOOL-DEBUG] tool={tname} content={tcontent}\n")

        # 串流片段
        choices = _get_attr(item, "choices")
        if choices is not None:
            for choice in choices or []:
                delta = _get_attr(choice, "delta")
                text = _get_attr(delta, "content")
                if text:
                    print(text, end="", flush=True)
            continue

        # 完整助理訊息
        if _get_attr(item, "role") == "assistant":
            content = _get_attr(item, "content")
            if isinstance(content, str) and content:
                print(content, end="", flush=True)
    print()

async def run_agent_and_capture(agent: Agent, user_text: str) -> str:
    """
    不顯示任何工具訊息；不做串流印出，收集助理文字後回傳。
    用於需要檢查狀態碼或解析 JSON 的情境。
    """
    collected = []
    async for item in agent.run(user_text):
        # 可選：工具除錯輸出
        if LOG_TOOL_DEBUG and _get_attr(item, "role") == "tool":
            tname = _get_attr(item, "name")
            tcontent = _get_attr(item, "content")
            print(f"\n[TOOL-DEBUG] tool={tname} content={tcontent}\n")

        choices = _get_attr(item, "choices")
        if choices is not None:
            for choice in choices or []:
                delta = _get_attr(choice, "delta")
                text = _get_attr(delta, "content")
                if text:
                    collected.append(text)
            continue

        if _get_attr(item, "role") == "assistant":
            content = _get_attr(item, "content")
            if isinstance(content, str) and content:
                collected.append(content)

    return "".join(collected).strip()

# ---------------------- 音樂（play_song；讀原始 JSON 判定） ----------------------
async def play_music(agent: Agent, query: str) -> bool:
    prompt = (
        MUSIC_PLAY_INSTRUCTION
        + "\n---\n"
        + "請立刻播放音樂：\n"
        + f"- query: {query}\n"
        + "（若能更精準，請自行推斷並填入 track/artist；否則用 query）\n"
        + "（請勿沿用任何先前狀態，每次都要實際呼叫 play_song）\n"
    )
    text = await tool_call_stateless(prompt)

    if text:
        print(text)

    obj = _extract_last_json_line(text or "")
    if obj is None:
        return False

    status = str(obj.get("status", "")).lower()
    playing = obj.get("playing")
    if status in {"ok", "success"} or (isinstance(playing, bool) and playing):
        return True
    return False

# ---------------------- 正念（list_media/open_index/open_media；不傳 dir） ----------------------
def _parse_mind_arg(arg: str) -> Tuple[Optional[int], Optional[str]]:
    """
    判斷 /mind 後面的參數：
    - 整數 -> index
    - 其他 -> keyword
    """
    s = (arg or "").strip()
    if not s:
        return None, None
    if s.isdigit():
        return int(s), None
    return None, s

def _choose_by_keyword(candidates: list, keyword: str | None) -> Optional[str]:
    if not candidates:
        return None
    if not keyword:
        return candidates[0]
    kw = keyword.lower()
    best = [c for c in candidates if kw in c.lower()]
    if best:
        return best[0]
    base = [c for c in candidates if kw in c.rsplit(".", 1)[0].lower()]
    return (base[0] if base else candidates[0])

async def _mind_open_by_index(agent: Agent, index: int) -> bool:
    """
    強制 LLM 只呼叫 open_index(kind='mp3', index=<index>)，最後一行回單行 JSON。
    """
    prompt = (
        """請只做一件事：呼叫 MCP 工具 open_index(kind='mp3', index="
        + json.dumps(index)
        + ").\n"
        "不要呼叫任何其他工具，也不要多說話。\n"
        "不得依賴先前對話的任何狀態；以工具回傳為準。\n"
        "結束時，最後一行只輸出單行 JSON，鏡射工具結果，例如：\n"
        '{"status":"ok","opened":"<檔名>","path":"<開啟的完整路徑或工具輸出>"}\n'
        "若失敗：\n"
        '{"status":"fail","reason":"<原因>"}\n"""
    )
    text = await tool_call_stateless(prompt)
    if text:
        print(text)

    obj = _extract_last_json_line(text or "")
    if not obj:
        return False
    status = str(obj.get("status", "")).lower()
    opened = obj.get("opened") or obj.get("path")
    return (status in {"ok", "success"}) or bool(opened)

async def _mind_list_media(agent: Agent) -> list:
    """
    強制呼叫 list_media()，並回傳 mp3 清單（list[str]）。
    """
    prompt = (
        """請只做一件事：呼叫 MCP 工具 list_media() 取得預設資料夾清單。\n"
        "不得依賴先前對話的任何狀態；以工具回傳為準。\n"
        "最後一行只輸出單行 JSON，格式：\n"
        '{"status":"ok","mp3": ["a.mp3","b.mp3", ...]}\n'
        "若失敗：\n"
        '{"status":"fail","reason":"<原因>"}\n"""
    )
    text = await tool_call_stateless(prompt)
    if text:
        print(text)

    obj = _extract_last_json_line(text or "")
    if not obj or str(obj.get("status", "")).lower() not in {"ok", "success"}:
        return []
    mp3 = obj.get("mp3") or []
    # 僅保留字串，且去掉空白；不做任何補字或改名
    out = []
    for s in mp3:
        if isinstance(s, str):
            ss = s.strip()
            if ss:
                out.append(ss)
    return out

async def play_mind_audio(agent: Agent, index: Optional[int], keyword: Optional[str]) -> bool:
    """
    嚴格流程：
      - 有 index：直接 _mind_open_by_index(index)
      - 否則：_mind_list_media() → Python 選檔 → 強制呼叫 open_media(name=<exact filename from list>)
    皆不傳 dir，使用 MCP 預設資料夾。
    """
    if index is not None:
        return await _mind_open_by_index(agent, index)

    # 先拿清單
    files = await _mind_list_media(agent)
    if not files:
        return False

    # 根據關鍵字從「清單」挑選，不生成新名稱
    target = _choose_by_keyword(files, keyword)
    if not target:
        return False

    # 把「合法清單」與「目標檔名」一起告訴 LLM，要求逐字相同
    valid_list_json = json.dumps(files, ensure_ascii=False)
    target_json = json.dumps(target, ensure_ascii=False)

    prompt = (
        "你現在只能做一件事：呼叫 MCP 工具 open_media(name=<檔名>) 來開啟正念 mp3。\n"
        "【嚴格規則】\n"
        "1) name 參數必須從下方 valid_names（JSON 陣列）中擇一，且必須與該字串『逐字逐符號完全相同』；不得改名、不得加副檔名或路徑。\n"
        "2) 這次請使用下方 target_name 指定的那一個檔名，不得替換為其他清單項目。\n"
        "3) 呼叫完成後，最後一行只輸出單行 JSON，鏡射工具原始結果。\n"
        "4) 如果工具回傳的 'opened' 或 'path' 對應的檔名與 target_name 不相同，請回傳：\n"
        '   {\"status\":\"fail\",\"reason\":\"opened_mismatch\"}\n'
        "-----\n"
        f"valid_names = {valid_list_json}\n"
        f"target_name = {target_json}\n"
        "-----\n"
        "請現在直接呼叫 open_media(name=target_name)。"
    )

    text = await tool_call_stateless(prompt)
    if text:
        print(text)

    obj = _extract_last_json_line(text or "")
    if not obj:
        return False

    status = str(obj.get("status", "")).lower()
    opened = obj.get("opened") or obj.get("path") or ""

    # 驗證：回傳的實際檔名必須與我們指定的 target 相同（比對 basename，不分大小寫）
    if status in {"ok", "success"} and _same_name(opened, target):
        return True

    # 若 status 是 ok 但名稱不一致，視為失敗（避免 LLM/工具自行改名）
    return False


# ---------------------- 主互動迴圈（仲裁者） ----------------------
async def chat_loop(config: dict):
    """
    事件競態等候：
    - notify_queue：情緒偵測通知（壞情緒/錯誤）
    - ainput：使用者輸入
    同意前完全靜默（除了情緒通知）；同意後建立 Agent。
    模式：
      - MENU：顯示功能選單（/music /game /mind /chat）
      - CHAT：情緒諮商師聊天模式（不重覆顯示選單；/end 或 /menu 返回；自然語句可觸發功能）
    """
    notify_queue: asyncio.Queue[str] = asyncio.Queue()
    watcher_task = asyncio.create_task(emotion_watcher(notify_queue))

    agent: Optional[Agent] = None
    pending_state = None  # None / EXPECTING_MUSIC_QUERY
    mode = "MENU"         # "MENU" 或 "CHAT"

    async def ensure_agent():
        nonlocal agent, mode
        if agent is not None:
            return
        agent = Agent(
            model=config["model"],
            base_url="http://localhost:8000/api/",
            servers=config["servers"],
            prompt="You are an agent - please keep going until the user’s query is completely resolved."
        )
        await agent.__aenter__()
        await agent.load_tools()
        mode = "MENU"
        print(MENU_TEXT)

    # 啟動時不印任何提示（保持靜默）
    input_task = asyncio.create_task(ainput(""))
    notify_task = asyncio.create_task(notify_queue.get())

    try:
        while True:
            done, _ = await asyncio.wait(
                {input_task, notify_task},
                return_when=asyncio.FIRST_COMPLETED
            )

            # --- 情緒通知先到 ---
            if notify_task in done:
                msg = notify_task.result()
                print(msg, end="" if msg.endswith("\n") else "\n")
                notify_task = asyncio.create_task(notify_queue.get())

            # --- 使用者輸入先到（或同時到） ---
            if input_task in done:
                raw = (input_task.result() or "").strip()
                input_task = asyncio.create_task(ainput(""))
                if not raw:
                    continue

                lower = raw.lower()

                # 尚未啟用：只處理同意/拒絕；其他輸入全部靜默
                if agent is None:
                    if lower in CONSENT_KEYWORDS:
                        await ensure_agent()
                    elif lower in CANCEL_KEYWORDS:
                        if not SILENT_BEFORE_CONSENT:
                            print("[系統] 已記錄你的選擇：暫不啟用協助。\n")
                    continue

                # ===== 已啟用後：依模式分流 =====
                if mode == "MENU":
                    # 0) 手動重設聊天 agent（不影響無記憶工具呼叫）
                    if lower == "/reset":
                        if agent is not None:
                            with contextlib.suppress(Exception):
                                await agent.__aexit__(None, None, None)
                            agent = None
                        await ensure_agent()
                        print("[系統] 已重設對話狀態。\n")
                        continue

                    # 1) 音樂
                    if lower.startswith("/music"):
                        parts = raw.split(maxsplit=1)
                        if len(parts) == 2 and parts[1].strip():
                            query = parts[1].strip()
                            try:
                                ok = await play_music(agent, query)
                                if ok:
                                    print("\n[系統] ✅ 已確認播放器成功啟動。\n")
                                else:
                                    print("\n[系統] ⚠️ 未能確認播放成功。請檢查：\n"
                                          "  1) 音樂 MCP/播放器是否正在執行並連線成功？\n"
                                          "  2) 權限/地區限制（某些歌曲可能受限）\n"
                                          "  3) 換個關鍵字或指定另一首歌試試\n")
                            except Exception as e:
                                print(f"\n[系統] ⚠️ 播放時發生錯誤：{e}\n")
                            print(MENU_TEXT)
                            pending_state = None
                        else:
                            print("你想聽什麼歌或什麼風格？（例如：周杰倫／放鬆鋼琴／Lo-fi）")
                            pending_state = EXPECTING_MUSIC_QUERY
                        continue

                    # 2) 紓壓小遊戲（瀏覽器拼圖；只允許 open_in_browser）
                    if lower == "/game" or "玩紓壓" in raw:
                        try:
                            ok = await open_puzzle_game(agent)
                            if ok:
                                print("\n[系統] ✅ 已嘗試在預設瀏覽器開啟小遊戲（若被沙盒阻擋，仍可用回傳路徑手動開啟）。\n")
                            else:
                                print("\n[系統] ⚠️ 未能確認已成功開啟小遊戲。\n"
                                    "  • 請確認 puzzle-mcp 伺服器已啟動\n"
                                    "  • 某些 MCP 用戶端可能會阻擋自動開窗，可改用 export_puzzle 手動複製（如需我再幫你改流程）\n")
                        except Exception as e:
                            print(f"\n[系統] ⚠️ 小遊戲開啟時發生錯誤：{e}\n")
                        print(MENU_TEXT)
                        pending_state = None
                        continue

                    # 3) 正念：播放本地音檔（支援 /mind 2 或 /mind 關鍵字）
                    if lower.startswith("/mind") or "正念" in raw or "冥想" in raw:
                        # 解析 /mind 後參數（可空、可數字、可關鍵字）
                        idx, kw = None, None
                        if lower.startswith("/mind"):
                            parts = raw.split(maxsplit=1)
                            if len(parts) == 2 and parts[1].strip():
                                idx, kw = _parse_mind_arg(parts[1].strip())
                        try:
                            ok = await play_mind_audio(agent, idx, kw)
                            if ok:
                                print("\n[系統] ✅ 已開啟正念音檔，祝你放鬆愉快。\n")
                            else:
                                print("\n[系統] ⚠️ 未能確認已開啟音檔。請檢查：\n"
                                      "  1) 預設媒體資料夾是否有 .mp3 檔\n"
                                      "  2) 試著改用索引（/mind 1）或不同關鍵字\n")
                        except Exception as e:
                            print(f"\n[系統] ⚠️ 正念音檔播放時發生錯誤：{e}\n")
                        print(MENU_TEXT)
                        pending_state = None
                        continue

                    # 4) 聊天模式（情緒諮商師）
                    if lower == "/chat" or "聊天" in raw:
                        try:
                            await run_agent_chat(agent, CHAT_SYSTEM_INSTRUCTION)
                        except Exception as e:
                            print(f"\n[Agent 錯誤] {e}\n")
                        mode = "CHAT"
                        print(CHAT_HINT)
                        continue

                    # 5) 正在等音樂關鍵字（在選單模式下）
                    if pending_state is EXPECTING_MUSIC_QUERY:
                        query = raw
                        try:
                            ok = await play_music(agent, query or "隨便")
                            if ok:
                                print("\n[系統] ✅ 已確認播放器成功啟動。\n")
                            else:
                                print("\n[系統] ⚠️ 未能確認播放成功。請檢查：\n"
                                      "  1) 音樂 MCP/播放器是否正在執行並連線成功？\n"
                                      "  2) 權限/地區限制（某些歌曲可能受限）\n"
                                      "  3) 換個關鍵字或指定另一首歌試試\n")
                        except Exception as e:
                            print(f"\n[系統] ⚠️ 播放時發生錯誤：{e}\n")
                        print(MENU_TEXT)
                        pending_state = None
                        continue

                    # 6) 其它：一般對話，但完成後回到選單
                    try:
                        await run_agent_chat(agent, raw)
                    except Exception as e:
                        print(f"\n[Agent 錯誤] {e}\n")
                    print(MENU_TEXT)

                elif mode == "CHAT":
                    # 聊天模式：不重覆顯示選單
                    if lower in {"/end", "/menu"}:
                        mode = "MENU"
                        print(MENU_TEXT)
                        continue

                    # 音樂等待關鍵字
                    if pending_state is EXPECTING_MUSIC_QUERY:
                        query = raw
                        try:
                            ok = await play_music(agent, query or "隨便")
                            if ok:
                                print("\n[系統] ✅ 已確認播放器成功啟動。\n")
                            else:
                                print("\n[系統] ⚠️ 未能確認播放成功。可試著指定歌手/風格或換一首。\n")
                        except Exception as e:
                            print(f"\n[系統] ⚠️ 播放時發生錯誤：{e}\n")
                        pending_state = None
                        continue

                    # 自然語句 → 意圖攔截
                    intent = detect_intent(raw)
                    if intent:
                        kind, q = intent
                        if kind == "music":
                            if q:
                                try:
                                    ok = await play_music(agent, q)
                                    if ok:
                                        print("\n[系統] ✅ 已確認播放器成功啟動。\n")
                                    else:
                                        print("\n[系統] ⚠️ 未能確認播放成功。可試著指定歌手/風格或換一首。\n")
                                except Exception as e:
                                    print(f"\n[系統] ⚠️ 播放時發生錯誤：{e}\n")
                            else:
                                print("想聽哪一位或什麼風格呢？（例如：周杰倫／放鬆鋼琴／Lo-fi）")
                                pending_state = EXPECTING_MUSIC_QUERY
                            continue

                        if kind == "game":
                            try:
                                ok = await open_puzzle_game(agent)
                                if ok:
                                    print("\n[系統] ✅ 已嘗試在預設瀏覽器開啟小遊戲（若被沙盒阻擋，仍可用回傳路徑手動開啟）。\n")
                                else:
                                    print("\n[系統] ⚠️ 未能確認已成功開啟小遊戲。可改輸入 /game 重試或通知我改用 export_puzzle。\n")
                            except Exception as e:
                                print(f"\n[系統] ⚠️ 小遊戲開啟時發生錯誤：{e}\n")
                            continue

                        if kind == "mind":
                            # 聊天自然語句觸發正念：不問索引，嘗試用關鍵字（此處不傳關鍵字就讓 LLM 先 list 再挑第一個）
                            try:
                                ok = await play_mind_audio(agent, None, None)
                                if ok:
                                    print("\n[系統] ✅ 已開啟正念音檔，祝你放鬆愉快。\n")
                                else:
                                    print("\n[系統] ⚠️ 未能確認已開啟音檔。可嘗試輸入 /mind 2 或 /mind 關鍵字。\n")
                            except Exception as e:
                                print(f"\n[系統] ⚠️ 正念音檔播放時發生錯誤：{e}\n")
                            continue

                    # 無特定意圖 → 正常聊天（沉浸式）
                    try:
                        await run_agent_chat(agent, raw)
                    except Exception as e:
                        print(f"\n[Agent 錯誤] {e}\n")

    except KeyboardInterrupt:
        print("\n手動中斷")
    finally:
        for t in (input_task, notify_task):
            t.cancel()
        with contextlib.suppress(Exception):
            await asyncio.gather(input_task, notify_task)
        watcher_task.cancel()
        with contextlib.suppress(Exception):
            await watcher_task
        if agent is not None:
            with contextlib.suppress(Exception):
                await agent.__aexit__(None, None, None)

# ---------------------- 進入點 ----------------------
async def main():
    global BASE_CFG
    with open(AGENT_JSON_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)
    BASE_CFG = config  # 讓 tool_call_stateless 可讀取一致設定
    await chat_loop(config)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("結束對話")

