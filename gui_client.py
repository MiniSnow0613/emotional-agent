import sys
import subprocess
import threading
import os
from PySide6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QTextEdit, QPushButton, QLineEdit, QLabel,
    QHBoxLayout, QFrame, QGraphicsDropShadowEffect, QGridLayout
)
from PySide6.QtGui import QFont, QIcon
from PySide6.QtCore import Qt, Signal


class PythonAppGUI(QWidget):
    add_log_signal = Signal(str, str)  # text, type: stdout/stderr/user

    def __init__(self, python_app_path):
        super().__init__()
        self.python_app_path = python_app_path
        self.proc = None
        self.add_log_signal.connect(self.add_log)

        # ── Window ────────────────────────────────────────────────────────────────
        self.setWindowTitle("🚀 tiny agent")
        self.setWindowIcon(QIcon.fromTheme("applications-python"))
        self.resize(900, 650)

        # 全域字體（含中文備援）
        base_font = QFont("Segoe UI", 10)
        self.setFont(base_font)

        # ── 主色 & StyleSheet（暗色） ─────────────────────────────────────────
        self.setStyleSheet("""
            QWidget {
                background-color: #0f1216;
                color: #e6e8ec;
            }
            QLabel#TitleLabel {
                font-family: "Segoe UI", "Noto Sans TC", "PingFang TC", sans-serif;
                font-size: 26px;
                font-weight: 700;
                letter-spacing: 0.3px;
            }
            QFrame#Card {
                background-color: #171b22;
                border: 1px solid #262c36;
                border-radius: 14px;
            }
            QTextEdit {
                background-color: #0f1115;
                border: 1px solid #262c36;
                border-radius: 10px;
                padding: 12px;
                font-family: "Cascadia Code", "JetBrains Mono", "Consolas", "Noto Sans Mono CJK TC", monospace;
                font-size: 16px;
            }
            QLineEdit {
                background-color: #0f1115;
                border: 1px solid #262c36;
                border-radius: 10px;
                padding: 10px 12px;
                selection-background-color: #2a3342;
                selection-color: #ffffff;
                font-family: "Segoe UI", "Noto Sans TC", "PingFang TC", sans-serif;
                font-size: 14px;
            }
            QPushButton {
                background-color: #1b212c;
                border: 1px solid #2b3340;
                border-radius: 10px;
                padding: 10px 16px;
                font-weight: 600;
            }
            QPushButton:hover { background-color: #222a38; }
            QPushButton:pressed { background-color: #1a2030; }

            /* Auto Detect（未勾選／暗色） */
            QPushButton#ToggleUnchecked {
                background-color: #1b212c;
                color: #e6e8ec;
                border: 1px solid #2b3340;
            }
            /* Auto Detect（勾選／亮綠松石） */
            QPushButton#ToggleChecked {
                background-color: #00c2a8;
                color: #0b0f14;
                border: none;
            }

            /* Quit：底色跟 Auto Detect 未勾選一樣（暗色系） */
            QPushButton#QuitLikeToggle {
                background-color: #1b212c;
                color: #e6e8ec;
                border: 1px solid #2b3340;
            }
            QPushButton#QuitLikeToggle:hover { background-color: #222a38; }
            QPushButton#QuitLikeToggle:pressed { background-color: #1a2030; }

            /* Send：紙飛機 + 更暗的主色 */
            QPushButton#Send {
                background-color: #0e6f5e;   /* 比主色更暗 */
                color: #e6e8ec;
                border: none;
            }
            QPushButton#Send:hover { background-color: #0c5f51; }
            QPushButton#Send:pressed { background-color: #0a4f44; }
        """)

        # ── 外層留白 ────────────────────────────────────────────────────────────
        root = QVBoxLayout(self)
        root.setContentsMargins(28, 28, 28, 28)
        root.setSpacing(22)

        # ── Header（三欄置中：左 Auto Detect、中 Title、右 Quit） ─────────────
        header_grid = QGridLayout()
        header_grid.setContentsMargins(0, 0, 0, 0)
        header_grid.setHorizontalSpacing(12)
        header_grid.setVerticalSpacing(0)
        header_grid.setColumnStretch(0, 1)
        header_grid.setColumnStretch(1, 1)
        header_grid.setColumnStretch(2, 1)

        # Auto Detect（左）
        self.auto_detect_enabled = False
        self.btn_auto_detect = QPushButton("✔ Auto Detect")
        self.btn_auto_detect.setCheckable(True)
        self.btn_auto_detect.setObjectName("ToggleUnchecked")
        self.btn_auto_detect.setFixedHeight(40)
        self.btn_auto_detect.clicked.connect(self.toggle_auto_detect)
        header_grid.addWidget(self.btn_auto_detect, 0, 0, Qt.AlignLeft)

        # Title（中）
        title = QLabel("🚀 tiny agent")
        title.setObjectName("TitleLabel")
        header_grid.addWidget(title, 0, 1, Qt.AlignCenter)

        # Quit（右）─ 底色改成跟 Auto Detect（未勾選）一致的暗色
        self.btn_stop_top = QPushButton("⏹ Quit")
        self.btn_stop_top.setObjectName("QuitLikeToggle")
        self.btn_stop_top.setFixedHeight(40)
        self.btn_stop_top.setMinimumWidth(110)
        self.btn_stop_top.setToolTip("Terminate Python app and exit GUI")
        self.btn_stop_top.clicked.connect(self.stop_python_app)
        header_grid.addWidget(self.btn_stop_top, 0, 2, Qt.AlignRight)

        root.addLayout(header_grid)

        # ── 卡片：Log 區域 ─────────────────────────────────────────────────────
        log_card = QFrame()
        log_card.setObjectName("Card")
        log_layout = QVBoxLayout(log_card)
        log_layout.setContentsMargins(16, 16, 16, 16)
        log_layout.setSpacing(12)

        # 陰影
        shadow = QGraphicsDropShadowEffect(self)
        shadow.setOffset(0, 8)
        shadow.setBlurRadius(24)
        shadow.setColor(Qt.black)
        log_card.setGraphicsEffect(shadow)

        # Log 輸出區
        self.log_output = QTextEdit()
        self.log_output.setReadOnly(True)
        self.log_output.setLineWrapMode(QTextEdit.WidgetWidth)
        # 提前插入一段 style（僅作為視覺初始化，不影響後續 append）
        self.log_output.append(
            '<div style="font-family:\'Cascadia Code\',\'JetBrains Mono\',Consolas,monospace; '
            'font-size:14.5px; line-height:1.5;"></div>'
        )
        log_layout.addWidget(self.log_output)
        root.addWidget(log_card, 2)

        # ── 卡片：輸入列（左輸入、右紙飛機 Send） ─────────────────────────────
        input_card = QFrame()
        input_card.setObjectName("Card")
        input_layout = QHBoxLayout(input_card)
        input_layout.setContentsMargins(12, 12, 12, 12)
        input_layout.setSpacing(12)

        self.input_box = QLineEdit()
        self.input_box.setPlaceholderText("Type your message and press Enter…")
        self.input_box.returnPressed.connect(self.send_input)
        input_layout.addWidget(self.input_box, 1)

        # 紙飛機 Send：用 Unicode，避免外部資源相依
        self.btn_send = QPushButton("🛩 Send")
        self.btn_send.setObjectName("Send")
        self.btn_send.setFixedHeight(40)
        self.btn_send.setMinimumWidth(110)
        self.btn_send.setToolTip("Send message to Python app (same as Enter)")
        self.btn_send.clicked.connect(self.send_input)
        input_layout.addWidget(self.btn_send, 0, Qt.AlignRight)

        # 陰影
        shadow2 = QGraphicsDropShadowEffect(self)
        shadow2.setOffset(0, 6)
        shadow2.setBlurRadius(18)
        shadow2.setColor(Qt.black)
        input_card.setGraphicsEffect(shadow2)

        root.addWidget(input_card)

        # ── 啟動子程式（保持原始邏輯） ────────────────────────────────────────
        threading.Thread(target=self.start_python_app, daemon=True).start()

    # ── 行為邏輯（未更動核心流程，只調整按鈕樣式切換） ────────────────────────
    def toggle_auto_detect(self):
        self.auto_detect_enabled = not self.auto_detect_enabled
        if self.auto_detect_enabled:
            self.btn_auto_detect.setText("✔ Auto Detect")
            self.btn_auto_detect.setObjectName("ToggleChecked")
        else:
            self.btn_auto_detect.setText("✖ Auto Detect")
            self.btn_auto_detect.setObjectName("ToggleUnchecked")
        # 重新套用樣式（切換 ObjectName 後）
        self.btn_auto_detect.style().unpolish(self.btn_auto_detect)
        self.btn_auto_detect.style().polish(self.btn_auto_detect)

    def start_python_app(self):
        if self.proc and self.proc.poll() is None:
            self.add_log_signal.emit("⚠️ Python App already running.", "stderr")
            return

        self.proc = subprocess.Popen(
            [sys.executable, self.python_app_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
            text=True,
            bufsize=1
        )

        threading.Thread(target=self.read_stream, args=(self.proc.stdout, "stdout"), daemon=True).start()
        threading.Thread(target=self.read_stream, args=(self.proc.stderr, "stderr"), daemon=True).start()

    def stop_python_app(self):
        print("exit")
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.add_log_signal.emit("⏹ Python App stopped.", "stderr")
            self.proc = None
        self.add_log_signal.emit("🛑 GUI stopped.", "stderr")
        QApplication.instance().quit()

    def send_input(self):
        if self.proc and self.proc.poll() is None:
            text = self.input_box.text()
            if text.strip():
                self.add_log_signal.emit(f"> {text}", "user")
                try:
                    self.proc.stdin.write(text + "\n")
                    self.proc.stdin.flush()
                except Exception as e:
                    self.add_log_signal.emit(f"❌ Failed to send input: {e}", "stderr")
            self.input_box.clear()

    def read_stream(self, stream, stream_type):
        for line in iter(stream.readline, ''):
            if line.strip():
                self.add_log_signal.emit(line.strip(), stream_type)
        stream.close()

    def add_log(self, text, log_type="stdout"):
        # 不顯示 stderr（維持你原本的行為）
        if log_type == "stderr":
            return
        elif log_type == "user":
            color = "#00c2a8"  # 主色
        else:
            color = "#8ab4ff"  # 輸出藍
        self.log_output.append(
            f'<span style="color:{color}; '
            f'font-family:\'Cascadia Code\',\'JetBrains Mono\',Consolas,monospace; '
            f'font-size:14.5px; line-height:1.5;">{text}</span>'
        )
        self.log_output.verticalScrollBar().setValue(self.log_output.verticalScrollBar().maximum())


# ------------------ 主程式 ------------------
if __name__ == "__main__":
    app = QApplication(sys.argv)

    # 全域字體（含中文備援）
    app.setFont(QFont("Segoe UI", 10))

    if len(sys.argv) < 2:
        print("Usage: python gui_client.py <PythonAppPath>")
        sys.exit(1)

    PYTHON_APP_PATH = sys.argv[1]
    if not os.path.exists(PYTHON_APP_PATH):
        print(f"Error: Python app not found: {PYTHON_APP_PATH}")
        sys.exit(1)

    gui = PythonAppGUI(PYTHON_APP_PATH)
    gui.show()
    sys.exit(app.exec())

