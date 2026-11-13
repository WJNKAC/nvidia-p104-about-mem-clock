#!/bin/bash
# rsh.sh —— 在**测试机**上远程执行命令
#
# 用法:
#   export P104_SSH_HOST=...      # 测试机地址（IP 或主机名）
#   export P104_SSH_USER=...      # 登录账号
#   export P104_SSH_PW=...        # 密码（仅本会话，勿写进任何文件）
#   ./rsh.sh 'nvidia-smi'
#   ./rsh.sh -f local_script.sh
#
# ── 安全约定（必读）──────────────────────────────────────────────
#   本脚本**不含任何**主机、账号或密码。三者一律从环境变量取，
#   缺失即报错退出 —— 绝不回落到内置默认值。
#   密码只写进 mktemp 建的 700 文件，退出时 trap 删除；
#   不 echo、不写日志。请用 export 而非把密码写在命令行参数里
#   （后者会进 shell history 和 ps 输出）。
#
# ── 为什么用 askpass 而不是 sshpass ──────────────────────────────
#   环境里没有 sshpass/expect。SSH_ASKPASS + SSH_ASKPASS_REQUIRE=force
#   是 openssh 自带机制，只需一个读环境变量并打印密码的可执行脚本。
#   必须同时配 PreferredAuthentications=password + PubkeyAuthentication=no，
#   否则会先试公钥、报 Permission denied，而不会去读 askpass。

set -u

: "${P104_SSH_HOST:?必须先 export P104_SSH_HOST（测试机地址）}"
: "${P104_SSH_USER:?必须先 export P104_SSH_USER（登录账号）}"
: "${P104_SSH_PW:?必须先 export P104_SSH_PW（密码，勿写入文件）}"

AP=$(mktemp /tmp/.p104-askpass.XXXXXX)
chmod 700 "$AP"
printf '#!/bin/sh\nprintf "%%s\\n" "$P104_SSH_PW"\n' > "$AP"
trap 'rm -f "$AP"' EXIT INT TERM

export SSH_ASKPASS="$AP"
export SSH_ASKPASS_REQUIRE=force
export DISPLAY="${DISPLAY:-:0}"

SSHOPTS="-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
 -o PreferredAuthentications=password -o PubkeyAuthentication=no
 -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 -o LogLevel=ERROR"

TARGET="${P104_SSH_USER}@${P104_SSH_HOST}"

if [ "${1:-}" = "-f" ]; then
    [ -f "${2:-}" ] || { echo "找不到脚本: ${2:-}" >&2; exit 1; }
    exec timeout "${RSH_TIMEOUT:-120}" ssh $SSHOPTS "$TARGET" 'bash -s' < "$2"
else
    exec timeout "${RSH_TIMEOUT:-120}" ssh $SSHOPTS "$TARGET" "$@"
fi
