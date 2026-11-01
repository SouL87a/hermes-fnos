#!/bin/bash
# <data>/.env 的读写助手 —— cmd/main 与 cmd/*_callback 共用，保证「写进去的」和
# 「读出来的」与 python-dotenv 逐字节一致。
#
# 为什么必须一致：
#   1) 上游 hermes_cli.main 启动即 load_hermes_dotenv(override=True)，.env 的值会
#      覆盖我们 `exec env` 传进去的值。我们按 A 启动、上游按 B 校验 = 登录死活不过。
#   2) python-dotenv 在双引号里会反转义 \" \\ \n；不加引号时又把 " #" 之后当注释、
#      吃掉首尾空白。裸写密码（如 pa#ss）会被静默改成 pa。
#
# 本文件只定义函数，不执行任何动作。调用方需先设置 DATA_DIR。

### 从 ${DATA_DIR}/.env 安全读取单个键（不 source 整个文件：.env 由用户/向导写入，
### 直接 source 会执行任意 shell）。只取 KEY=VALUE 形式，去掉引号与 export 前缀；
### 同名取【最后一条】。
env_get() {
    local key="$1" f="${DATA_DIR}/.env" line val
    [ -r "${f}" ] || return 1
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "${f}" 2>/dev/null | tail -n 1)"
    [ -n "${line}" ] || return 1
    val="${line#*=}"
    val="${val%$'\r'}"
    # 去掉值前导空白（dotenv 允许 KEY=  value）
    val="${val#"${val%%[![:space:]]*}"}"
    case "${val}" in
        \"*)
            # 逐字节扫描双引号值。不能用 `${val%%\"*}` 找结尾引号（值里本身可能有
            # 转义的 \"），也不能按顺序跑 sed（\\n 会被错误地拆成 \ + 换行）。
            local out="" i=1 n=${#val} c
            while [ "${i}" -lt "${n}" ]; do
                c="${val:${i}:1}"
                if [ "${c}" = '\' ]; then
                    i=$((i + 1))
                    c="${val:${i}:1}"
                    case "${c}" in
                        n) out="${out}"$'\n' ;;
                        *) out="${out}${c}" ;;   # \"→"  \\→\  等：与 dotenv 一致，吃掉反斜杠
                    esac
                elif [ "${c}" = '"' ]; then
                    break
                else
                    out="${out}${c}"
                fi
                i=$((i + 1))
            done
            val="${out}"
            ;;
        \'*)
            # 单引号：dotenv 内部不做转义，找下一个 ' 即可
            val="${val#\'}"; val="${val%%\'*}"
            ;;
        *)
            # 未加引号：去掉 " #" 起的注释，再去尾部空白
            val="${val%%[[:space:]]#*}"
            val="${val%"${val##*[![:space:]]}"}"
            ;;
    esac
    printf '%s' "${val}"
}

### 按 dotenv 语义写一行（env_kv KEY VALUE → KEY="..."）。
### 统一用双引号：不加引号时 dotenv 会把 " #" 之后当注释、并吃掉首尾空白，
### 含这两种字符的密码会被静默改掉（实测：pa#ss → pa）。
### ⚠ 只用 \\ 与 \" 两种转义 —— 这也正是 env_get 能反转义的全部子集。
###   $ / ${...} 不处理：上游用 interpolate=False 解析，不做变量展开。
env_kv() {
    local _k="$1" _v="$2"
    _v="${_v//\\/\\\\}"
    _v="${_v//\"/\\\"}"
    printf '%s="%s"' "${_k}" "${_v}"
}
