  LANG=C LC_ALL=C printf '%s' "$1" | od -An -tx1 2>/dev/null | grep -E -q "[89a-f][0-9a-f]"
}
safe_path_msg() {
  local prefix="$1" path="$2" suffix="$3" rel="${4:-}"
  local shown
  if has_nonascii "$path"; then
    if [ -n "$rel" ]; then shown="$rel"; else shown="本项目的 $(basename "$path")"; fi
  else
    shown="$path"
  fi
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
