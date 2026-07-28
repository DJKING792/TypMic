  case "${TYPOMIC_ASR}" in
    local|whisper) ASRMODE=whisper ;;
    sensevoice)    ASRMODE=sensevoice ;;
  esac
elif [ -f "$KEYFILE" ]; then
  cur="$(grep -i "^TYPOMIC_ASR=" "$KEYFILE" | head -1 | cut -d= -f2-)"
  case "$cur" in
    local|whisper) ASRMODE=whisper ;;
    sensevoice)    ASRMODE=sensevoice ;;
  esac
fi

echo
echo "============================================================"
echo "  请选择语音识别模式："
echo "    1. 云端 MiMo（推荐）"
echo "       中文最强，需联网，免费申请 API key"
echo "    2. 本地 Whisper"
echo "       纯离线，英文好、中文一般，无标点"
echo "    3. 本地 SenseVoice（阿里开源模型，1G 文件大小，下载需等待）"
echo "       纯离线，中文准，自带标点，CPU 可跑"
echo "  当前默认：$ASRMODE"
echo "============================================================"
read -r -p "输入 1 / 2 / 3（直接回车沿用当前默认）：" CHOICE
case "$CHOICE" in
  1) ASRMODE=cloud;    setenv TYPOMIC_ASR cloud;    echo "已选择云端模式（MiMo，已写入 .env，下次自动沿用）。" ;;
  2) ASRMODE=whisper;  setenv TYPOMIC_ASR whisper;  echo "已选择离线模式（faster-whisper，已写入 .env，下次自动沿用）。" ;;
  3) ASRMODE=sensevoice; setenv TYPOMIC_ASR sensevoice
     # 追问设备与语种（有 N 卡可选 cuda 提速；默认 zh 准确率最高）
     read -r -p "SenseVoice 设备 [1]cpu(默认) [2]cuda:0(有N卡): " SVDEVCH
     SVDEV=cpu; [ "$SVDEVCH" = "2" ] && SVDEV=cuda:0
     setenv SENSEVOICE_DEVICE "$SVDEV"
     read -r -p "SenseVoice 语种 [1]zh(默认) [2]auto(中英混说) [3]en: " SVLANGCH
     SVLANG=zh; [ "$SVLANGCH" = "2" ] && SVLANG=auto; [ "$SVLANGCH" = "3" ] && SVLANG=en
     setenv SENSEVOICE_LANG "$SVLANG"
     echo "已选择离线模式（SenseVoice，设备=$SVDEV，语种=$SVLANG，已写入 .env）。" ;;
  *)
     if [ "$ASRMODE" != "cloud" ]; then
       setenv TYPOMIC_ASR "$ASRMODE"
       echo "沿用 .env 中的 $ASRMODE 模式。"
     else
       echo "使用云端模式。"
     fi
     ;;
esac

# —— 检查 Python 是否支持创建虚拟环境 ——
if ! "$PYTHON" -m venv --help >/dev/null 2>&1; then
  echo
  echo "错误：当前 Python（$PYTHON）不支持创建虚拟环境。"
  echo "常见原因及解决："
  echo "  1. macOS 自带的 /usr/bin/python3 缺少 ensurepip，请安装完整版 Python 3.10+："
  echo "     brew install python@3.12"
  echo "     装好后重新打开终端再运行 bash start.sh"
  echo "  2. Linux 的 python3-venv 未安装："
  echo "     sudo apt install python3-venv    # Debian / Ubuntu"
  echo "     sudo dnf install python3-virtualenv  # Fedora"
  exit 1
fi

# —— 创建虚拟环境（若不存在）——
if [ ! -x "$VENV/bin/python" ] && [ ! -x "$VENV/Scripts/python.exe" ]; then
  echo "[1/3] 正在创建虚拟环境..."
  if ! "$PYTHON" -m venv "$VENV" 2>&1; then
    echo
    echo "虚拟环境创建失败。请检查："
    echo "  - Python 路径：$PYTHON"
    echo "  - Python 版本：$("$PYTHON" --version 2>&1 || true)"
    echo "  - 目标路径：$VENV"
    echo "可尝试删除 $VENV 后重试，或改用 Homebrew / python.org 安装的 Python。"
    exit 1
  fi
fi

# 兼容 Linux/macOS 的 .venv/bin/python，以及 Windows Git Bash 的 .venv/Scripts/python.exe
if [ -x "$VENV/bin/python" ]; then
  VENV_PY="$VENV/bin/python"
elif [ -x "$VENV/Scripts/python.exe" ]; then
