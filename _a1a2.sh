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
# 注意：不能用 [![:ascii:]] 字符类——它是 GNU 扩展，macOS 自带的老版 bash 3.2 不支持，会直接崩溃。
# 改为按字节判断：UTF-8 的非 ASCII 字节都在 0x80–0xFF，十六进制首位是 8/9/a/b/c/d/e/f。
# 用 od 在 C locale 下逐字节检查，兼容任何 bash 版本、locale 与平台。
has_nonascii() {
