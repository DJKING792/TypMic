#!/usr/bin/env bash
# TypMic 启动脚本（macOS / Linux）
# 镜像 start.bat 的逻辑：自动建虚拟环境、选识别引擎、装依赖、引导 MiMo key、术语表、可选信任证书、启动服务。
# 用法：  bash start.sh      （Windows 请用 start.bat）

set -o pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
VENV="$BASE/.venv"
KEYFILE="$BASE/.env"

# —— 覆盖式写 .env 的某个键值（先删除旧行，再追加新行）——
setenv() {
  local k="$1" v="$2"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$KEYFILE" ]; then
    grep -v "^${k}=" "$KEYFILE" > "$tmp" 2>/dev/null || true
  fi
  echo "${k}=${v}" >> "$tmp"
  cat "$tmp" > "$KEYFILE"
  rm -f "$tmp"
}

# 路径可能含中文等非 ASCII 字符，部分终端会显示成 ?；此时改用相对描述（纯 ASCII，永不乱码）
safe_path_msg() {
  local prefix="$1" path="$2" suffix="$3" rel="${4:-}"
  local shown
  case "$path" in
    *[![:ascii:]]*)
      if [ -n "$rel" ]; then shown="$rel"; else shown="本项目的 $(basename "$path")"; fi ;;
    *) shown="$path" ;;
  esac
  echo "${prefix}${shown}${suffix}"
}

# —— 查找可用的 Python 3.10+（优先 python3）——
PYTHON=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
if [ -z "$PYTHON" ]; then
  echo "错误：未找到 Python 3.10+。请安装 Python 3.10+ 并将其加入 PATH。"
  exit 1
fi
echo "正在使用 Python：$PYTHON"

# 版本粗检（低于 3.10 给警告，但不强制退出）
PYVER="$("$PYTHON" -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>/dev/null)"
IFS='.' read -r MAJ MIN <<< "${PYVER:-0.0}"
if [ "${MAJ:-0}" -lt 3 ] || { [ "${MAJ:-0}" -eq 3 ] && [ "${MIN:-0}" -lt 10 ]; }; then
  echo "警告：Python 版本 ${PYVER:-未知} 低于 3.10，可能无法正常运行，建议升级到 3.10+。"
fi

# 终端统一 UTF-8，避免中文乱码
export PYTHONIOENCODING=utf-8
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# —— 识别模式选择（云端 / 离线）——
ASRMODE=cloud
if [ -n "${TYPOMIC_ASR:-}" ]; then
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
  3) ASRMODE=sensevoice; setenv TYPOMIC_ASR sensevoice; echo "已选择离线模式（SenseVoice，已写入 .env，下次自动沿用）。" ;;
  *)
     if [ "$ASRMODE" != "cloud" ]; then
       setenv TYPOMIC_ASR "$ASRMODE"
       echo "沿用 .env 中的 $ASRMODE 模式。"
     else
       echo "使用云端模式。"
     fi
     ;;
esac

# —— 创建虚拟环境（若不存在）——
if [ ! -x "$VENV/bin/python" ]; then
  echo "[1/3] 正在创建虚拟环境..."
  "$PYTHON" -m venv "$VENV" || { echo "虚拟环境创建失败。"; exit 1; }
fi
VENV_PY="$VENV/bin/python"

# —— 安装依赖（轻量，已安装的会跳过）——
echo "[2/3] 正在安装依赖（无需下载模型，很快）..."
"$VENV_PY" -m pip install --upgrade pip
"$VENV_PY" -m pip install -r "$BASE/requirements.txt" || { echo "依赖安装失败。请检查网络连接后重试。"; exit 1; }

if [ "$ASRMODE" = "whisper" ]; then
  echo "安装本地 Whisper 依赖（faster-whisper，首次下载模型）..."
  "$VENV_PY" -m pip install -r "$BASE/requirements-whisper.txt" || { echo "离线依赖安装失败。请检查网络后重试，或改用云端模式。"; exit 1; }
fi

if [ "$ASRMODE" = "sensevoice" ]; then
  echo "安装 SenseVoice 依赖（torch/funasr，首次下载模型）..."
  "$VENV_PY" -m pip install -r "$BASE/requirements-sensevoice.txt" || { echo "离线依赖安装失败（torch/funasr/modelscope）。请检查网络后重试，或改用云端模式。"; exit 1; }
  # 预下载模型到 TypMic/models/SenseVoiceSmall
  MS_CACHE="$BASE/models/SenseVoiceSmall"
  mkdir -p "$MS_CACHE" 2>/dev/null
  export MODELSCOPE_CACHE="$MS_CACHE"
  safe_path_msg "模型将保存到：" "$MS_CACHE" "（首次下载约 1GB，请耐心等待进度条）" "本项目的 models/SenseVoiceSmall 目录"
  echo "正在预下载 SenseVoice 模型..."
  "$VENV_PY" -c "from funasr import AutoModel; AutoModel(model='iic/SenseVoiceSmall', trust_remote_code=True); print('SenseVoice model ready')"
fi

# —— MiMo API key（离线模式无需）——
if [ "$ASRMODE" = "cloud" ]; then
  HAVE_KEY=""
  if [ -n "${MIMO_API_KEY:-}" ]; then
    HAVE_KEY=1
  elif [ -f "$KEYFILE" ] && grep -qi "^MIMO_API_KEY=." "$KEYFILE"; then
    HAVE_KEY=1
  fi
  if [ -z "$HAVE_KEY" ]; then
    echo
    echo "============================================================"
    echo "  语音识别需要 MiMo API key。"
    echo "  免费申请：https://platform.xiaomimimo.com（注册后创建 key）"
    echo "============================================================"
    read -r -p "请输入你的 MiMo API key（留空则跳过）：" USERKEY
    if [ -n "$USERKEY" ]; then
      setenv MIMO_API_KEY "$USERKEY"
      export MIMO_API_KEY="$USERKEY"
      echo
      echo "API key 已保存到 .env"
    else
      echo
      echo "未输入 key。服务仍会启动，但语音识别会失败。"
      echo "请编辑 .env 或设置 MIMO_API_KEY 后重启。"
    fi
  else
    echo "MiMo API key：已配置"
  fi
fi

# —— AI 润色（仅云端模式可用，自动复用 MiMo key）——
if [ "$ASRMODE" = "cloud" ]; then
  CURPOLISH=off
  CURMODE=""
  if [ -f "$KEYFILE" ]; then
    CURPOLISH="$(grep -i "^TYPOMIC_POLISH=" "$KEYFILE" | head -1 | cut -d= -f2-)"
    CURMODE="$(grep -i "^TYPOMIC_POLISH_MODE=" "$KEYFILE" | head -1 | cut -d= -f2-)"
  fi
  [ -z "$CURPOLISH" ] && CURPOLISH=off
  if [ "$CURPOLISH" = "on" ] && [ -z "$CURMODE" ]; then CURMODE=full; fi
  echo
  echo "============================================================"
  echo "  AI 润色（复用 MiMo key；模型已原生标点，无需额外补标点）"
  echo "    1. 关闭         （纯识别，最快，自动标点符号）"
  echo "    2. 通用润色      （去口语+顺句+分段，默认风格）"
  echo "    3. 理顺逻辑      （适合说话散乱：补连接、理清层次）"
  echo "    4. 小说创作      （保留文学性/口语感，不强行规范化）"
  echo "    5. 公司文案      （商务正式、专业、结构清晰）"
  echo "    6. 行政公文      （公文规范、条理、庄重）"
  echo "  当前：$CURPOLISH  $CURMODE"
  echo "  默认推荐：1（关闭）。回车即采用默认。"
  echo "============================================================"
  read -r -p "输入 1/2/3/4/5/6（回车=默认推荐）：" PCHOICE
  case "$PCHOICE" in
    1) setenv TYPOMIC_POLISH off; echo "已选择：关闭 AI 润色。" ;;
    2) setenv TYPOMIC_POLISH on; setenv TYPOMIC_POLISH_MODE full;    echo "已选择：通用润色。" ;;
    3) setenv TYPOMIC_POLISH on; setenv TYPOMIC_POLISH_MODE logic;   echo "已选择：理顺逻辑。" ;;
    4) setenv TYPOMIC_POLISH on; setenv TYPOMIC_POLISH_MODE novel;   echo "已选择：小说创作。" ;;
    5) setenv TYPOMIC_POLISH on; setenv TYPOMIC_POLISH_MODE business; echo "已选择：公司文案。" ;;
    6) setenv TYPOMIC_POLISH on; setenv TYPOMIC_POLISH_MODE admin;    echo "已选择：行政公文。" ;;
    *) setenv TYPOMIC_POLISH off; echo "已选择：关闭 AI 润色（默认推荐）。" ;;
  esac
else
  echo
  echo "离线模式无需 key，AI 润色不可用，已保持关闭。"
  setenv TYPOMIC_POLISH off
fi

# —— 术语表（纯本地，无需 key）——
GLOSSARY_STATE=无
[ -f "$BASE/glossary.txt" ] && GLOSSARY_STATE=已开启
echo
echo "============================================================"
echo "  术语表（错词纠正，纯本地无需 key）"
echo "    1. 关闭"
echo "    2. 开启（推荐：自动创建 glossary.txt，纠正常见谐音错词）"
echo "  当前：$GLOSSARY_STATE"
echo "  默认推荐：2（开启）。回车即采用默认。"
echo "============================================================"
read -r -p "输入 1/2（回车=默认推荐）：" GCHOICE
if [ "$GCHOICE" = "1" ]; then
  setenv TYPOMIC_GLOSSARY off
  echo "已选择：关闭术语表。"
else
  setenv TYPOMIC_GLOSSARY on
  if [ ! -f "$BASE/glossary.txt" ]; then
    if [ -f "$BASE/glossary.txt.example" ]; then
      cp "$BASE/glossary.txt.example" "$BASE/glossary.txt"
      echo "已从示例创建 glossary.txt（可随时编辑）。"
    else
      echo "未找到 glossary.txt.example，跳过。"
    fi
  else
    echo "glossary.txt 已存在，保持不变。"
  fi
fi

# —— 是否将根证书加入系统信任（消除浏览器“不安全”警告）——
echo
echo "============================================================"
echo "  是否将根证书加入系统信任（消除浏览器“不安全”警告）"
echo "    1. 不安装（默认，功能完全正常，仅浏览器提示“不安全”）"
echo "    2. 安装（macOS 会弹密码框；Linux 需手动导入）"
echo "  说明：装不装都不影响任何功能，仅决定浏览器是否报警告。"
echo "============================================================"
read -r -p "输入 1/2（回车=不安装）：" CCHOICE
if [ "$CCHOICE" = "2" ]; then
  if [ ! -f "$BASE/rootCA.pem" ]; then
    echo "正在生成证书（首次运行）..."
    "$VENV_PY" -c "import voice_input_server; voice_input_server.ensure_certs()" >/dev/null 2>&1
  fi
  os="$(uname)"
  if [ "$os" = "Darwin" ]; then
    echo "正在请求管理员权限安装根证书（会弹密码框）..."
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$BASE/rootCA.pem"
  else
    safe_path_msg "Linux：请手动将 " "$BASE/rootCA.pem" " 导入系统/浏览器信任（或忽略浏览器警告，功能不受影响）。" "本项目的 rootCA.pem"
  fi
fi

# —— 启动服务 ——
echo "[3/3] 正在启动服务..."
echo "下方出现横幅即表示服务已启动，请保持此窗口打开。"
echo "启动后请在电脑浏览器打开： https://localhost:8443/desktop"
echo
"$VENV_PY" "$BASE/voice_input_server.py"
echo
echo "服务已停止。"
