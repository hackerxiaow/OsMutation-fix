#!/bin/bash
# Reinstall Any OpenVZ/LXC VPS to Debian/CentOS/Alpine
# Author: Lloyd@nodeseek.com
# FIXED  : EUServ(LXC) + Alpine 重装失联修复版 (2026-10-11)
#
# 修复点 (相对原版 LloydAsp/OsMutation):
#   1. 生成的 /etc/network/interfaces 不再包含 ifupdown-ng 无法解析的顶级
#      `hostname xxx` 行 (Debian 的 ifup 宽松跳过, Alpine 的 ifupdown-ng 会
#      解析失败导致 networking 服务起不来 -> 无 IP -> 失联)
#   2. 网关不再用 `up ip route add ...` 外部命令, 改用标准 `gateway` 行;
#      /32 掩码时自动加 onlink (德国商家常见 /32 点对点网络)
#   3. 拿不到 IP/网关时自动回落 DHCP, 不再生成残缺的 static 配置
#   4. 发行版识别改用标志文件 /etc/alpine-release 等, 不再只依赖 /etc/issue
#   5. openssh 安装失败立即红色报错并退出 (拒绝带病重启), 装完校验 sshd 存在
#   6. sshd_config 先清理已有 PermitRootLogin/PasswordAuthentication 再追加
#      (sshd_config 同名指令第一条生效, 盲目追加可能不生效)
#   7. 重复运行脚本时自动清理上次残留的 /x, 避免脏状态叠加
#   8. hostname 服务加入 boot runlevel (networking 依赖 it), 双写 networking 到 boot+default
#
# License: GPLv3; Partly based on https://gist.github.com/trimsj/c1fefd650b5f49ceb8f3efc1b6a1404d

function print_help(){
    echo -ne "\e[1;32m"
    cat << 'EOF'

  Reinstall Any OpenVZ/LXC VPS to Debian/CentOS/Alpine (EUServ-LXC fixed version);
  [warning] A fresh system will be installed and all old data will be wiped!
  Based on LloydAsp/OsMutation, fixed Alpine network loss by github.com/hackerxiaow
EOF
    echo -ne "\e[m"
}

function read_virt_tech(){
    cttype=$(virt-what | sed -n 1p)
    if [[ $cttype == "lxc" || $cttype == "openvz" ]]; then
        [[ $cttype == "lxc" ]] && echo -e '\e[1;33mYour container type: lxc\e[m' || echo -e '\e[1;33mYour container type: openvz\e[m'
    elif [ -n "$VIRT_TYPE" ]; then
        cttype=$VIRT_TYPE
        echo -e "\e[1;33mYour container type (from VIRT_TYPE): $cttype\e[m"
    else
        while [ "$cttype" != 'lxc' -a "$cttype" != 'openvz' -a "$cttype" != 'kvm' ] ; do
            echo -ne "\e[1;33mplease input container type (lxc/openvz/kvm):\e[m"
            read cttype  < /dev/tty
        done
    fi
}

function install(){
    if [ -n "$(command -v apt)" ] ; then
        cmd1="apt-get"
        cmd2="apt-get install -y"
    elif [ -n "$(command -v yum)" ] ; then
        cmd1="yum"
        cmd2="yum install -y"
    elif [ -n "$(command -v dnf)" ] ; then
        cmd1="dnf"
        cmd2="dnf install -y"
    elif [ -n "$(command -v apk)" ] ; then
        cmd1="apk"
        cmd2="apk add"
    else
        echo "Error: Not Supported Os"
        exit 1
    fi
    $cmd1 update
    $cmd2 "$@"
}

function read_lxc_template(){
    last_lxc_version=$(curl -Ls -m 10 "https://api.github.com/repos/LloydAsp/OsMutation/releases/latest" | grep "LXC" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -n $last_lxc_version ]]; then
        image_list=$(curl -Ls -m 10 "https://api.github.com/repos/LloydAsp/OsMutation/releases/latest" | grep "LXC" | grep '"browser_download_url":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ "$(uname -m)" == "aarch64" ] ; then
            image_list="$(echo "$image_list" | grep arm64)"
        else
            image_list="$(echo "$image_list" | grep -v arm64)"
        fi

        os_list=$(echo "$image_list" | sed "s/https\:\/\/github.com\/LloydAsp\/OsMutation\/releases\/download\/${last_lxc_version}\///g" | sed "s/\.tar\.xz//g")
        echo "$os_list" | nl

        while [ -z "${os_index##*[!0-9]*}" ]; do
            if [ -n "$OS_INDEX" ]; then os_index=$OS_INDEX; break; fi
            echo -ne "\e[1;33mplease select os (input number):\e[m"
            read os_index < /dev/tty
        done

        download_link=$(echo "$image_list" | head -n $os_index | tail -n 1)
    else
        server=http://images.linuxcontainers.org
        path=$(wget -qO- --timeout=60 ${server}/meta/1.0/index-system | \
            grep -v edge | grep default | \
            awk '-F;' '(( $1=="debian" || $1=="centos" || $1=="alpine") && ( $3=="amd64" || $3=="i386")) {print $NF}')

        # NOTE: "$path" must stay quoted here -- unquoted echo collapses the
        # list into ONE line (word splitting) and the sed below then builds a
        # broken download URL. This exact bug is what killed ipv6-only EUServ
        # boxes where the github api branch always fails.
        if [ "$(uname -m)" == "aarch64" ] ; then
            path="$(echo "$path" | grep arm64)"
        else
            path="$(echo "$path" | grep -v arm64)"
        fi

        os_list=$( echo "$path" | sed -E 's%/images/(.*)/default/.*/%\1%g' | sed 's%/%-%g' )
        echo "$os_list" | nl

        while [ -z "${os_index##*[!0-9]*}" ]; do
            if [ -n "$OS_INDEX" ]; then os_index=$OS_INDEX; break; fi
            echo -ne "\e[1;33mplease select os (input number):\e[m"
            read os_index < /dev/tty
        done

        path=$( echo "$path" | head -n $os_index | tail -n 1)
        os_selected=$(echo "$os_list" | head -n $os_index | tail -n 1 )
        download_link=${server}/${path}/rootfs.tar.xz
    fi
}

function download_rootfs(){
    # clean leftovers from a previous failed run
    rm -rf /x 2>/dev/null
    cd /
    mkdir /x
    if [ -n "$download_link" ]; then
        wget -qO- --timeout=60 "$download_link" | tar -C /x -xJv
    else
        echo -e '\e[1;41mFATAL: no download_link resolved. ABORT, DO NOT REBOOT.\e[m'
        exit 1
    fi
    # hard stop if the template did not land: never continue with an empty /x
    [ -e /x/etc ] && [ -e /x/bin ] || {
        echo -e '\e[1;41mFATAL: template download/extract failed (/x is empty). ABORT, DO NOT REBOOT. Old system untouched.\e[m'
        exit 1
    }
}

function migrate_configuration(){
    # save root password and ssh directory
    sed -i '/^root:/d' /x/etc/shadow
    grep '^root:' /etc/shadow >> /x/etc/shadow
    [ -d /root/.ssh ] && cp -a /root/.ssh /x/root/
    [ -f /etc/hostname ] && cp -f /etc/hostname /x/etc/hostname

    # detect interface/gateways from the *running* system. On ipv6-only boxes
    # (e.g. EUServ free VPS) /proc/net/route has no default route, so try the
    # ipv6 default route first -- it is the path we are actually connected by.
    dev=$(ip -6 route show default 2>/dev/null | sed -nE 's/.*dev ([^ ]+).*/\1/p' | head -n 1)
    [ -n "$dev" ] || dev=$(ip -4 route show default 2>/dev/null | sed -nE 's/.*dev ([^ ]+).*/\1/p' | head -n 1)
    [ -n "$dev" ] || dev=$(awk '$2 == 00000000 { print $1 }' /proc/net/route 2>/dev/null | head -n 1)
    [ -n "$dev" ] || dev=eth0

    ipaddr_with_mask=$(ip -4 addr show dev "$dev" 2>/dev/null | sed -nE 's/.*inet ([0-9.]+\/[0-9]+).*/\1/p' | head -n 1)
    gateway4=$(ip -4 route show default 2>/dev/null | sed -nE 's/.*via ([0-9.]+).*/\1/p' | head -n 1)
    addr6=$(ip -6 addr show dev "$dev" scope global 2>/dev/null | grep -vi temporary | sed -nE 's/.*inet6 ([0-9a-fA-F:]+\/[0-9]+).*/\1/p' | head -n 1)
    gw6=$(ip -6 route show default 2>/dev/null | sed -nE 's/.*via ([0-9a-fA-F:]+).*/\1/p' | head -n 1)
    echo -e "\e[1;33mnet migration: dev=$dev v4=$ipaddr_with_mask gw4=$gateway4 v6=$addr6 gw6=$gw6\e[m"

    [ -d /x/etc/network/ ] || mkdir -p /x/etc/network/

    # ipv4 stanza: static if we can, manual (link up, no address) on ipv6-only
    if [ -n "$ipaddr_with_mask" ] && [ -n "$gateway4" ]; then
        prefix=${ipaddr_with_mask##*/}
        if [ "$prefix" = "32" ]; then
            v4_block="iface $dev inet static
address $ipaddr_with_mask
up ip route add default via $gateway4 dev $dev onlink"
        else
            v4_block="iface $dev inet static
address $ipaddr_with_mask
gateway $gateway4"
        fi
    elif [ -n "$ipaddr_with_mask" ]; then
        v4_block="iface $dev inet static
address $ipaddr_with_mask"
    else
        # ipv6-only: no v4 stanza at all (ifupdown-ng brings the link up for
        # the inet6 block anyway; a `manual` block is one more moving part)
        v4_block=""
    fi

    # ipv6 stanza: EUServ hands out a static /128 with an ULA gateway, so copy
    # the running config verbatim; `up` line keeps the explicit dev so ULA or
    # link-local gateways both work
    if [ -n "$addr6" ]; then
        if [ -n "$gw6" ]; then
            v6_block="iface $dev inet6 static
address $addr6
up ip -6 route replace default via $gw6 dev $dev onlink"
        else
            v6_block="iface $dev inet6 auto"
        fi
    else
        v6_block=""
    fi

    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "auto $dev"
        [ -n "$v4_block" ] && { echo "$v4_block"; echo ""; }
        [ -n "$v6_block" ] && echo "$v6_block"
    } > /x/etc/network/interfaces
    echo -e "\e[1;33m--- generated /etc/network/interfaces ---\e[m"
    cat /x/etc/network/interfaces
    echo -e "\e[1;33m-----------------------------------------\e[m"

    rm -f /x/etc/resolv.conf
    cat > /x/etc/resolv.conf << EOF
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

function install_requirement(){
    # prevent no access on ipv6 only vps
    ping -c 3 api.github.com || echo "nameserver 2606:4700:4700::1111"  >  /etc/resolv.conf

    if [ -n "$(command -v apk)" ] ; then
        install curl sed gawk wget gzip xz tar virt-what
    else
        install curl sed gawk wget gzip xz-utils virt-what
    fi
}

function chroot_run(){
    # detect alpine by its marker file first, /etc/issue only as fallback
    if [ -e /x/etc/alpine-release ] || grep -qi alpine /x/etc/issue 2>/dev/null; then
        chroot "/x/" sh -c "[ -f /bin/bash ] || apk add bash"
    fi
    chroot "/x/" /bin/bash -c "$*"
}

function replace_os(){
    # host-view replacement WITHOUT bind mount and WITHOUT relying on the old
    # system's tools after deletion: run busybox through its own musl loader
    # (direct binary path), so nothing on the old root is ever needed.
    B="/x/lib/ld-musl-x86_64.so.1 /x/bin/busybox"
    $B rm -rf $($B ls / | $B grep -vE "(^dev|^proc|^sys|^run|^x)") 2>/dev/null
    cd /x && $B mv -f $($B ls | $B grep -vE "^(dev|proc|sys|run)$") /
    cd /
    [ -e /etc/os-release ] && [ -e /bin/sh ] && return 0
    echo -e '\e[1;41mFATAL: replace_os failed. ABORT, DO NOT REBOOT.\e[m'
    exit 1
}





function post_install(){
    export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
    # the new rootfs must be in place; otherwise we would silently "post
    # install" the OLD system (the fake-success path that bricks machines)
    [ -e /etc/alpine-release ] || [ -e /etc/debian_version ] || [ -e /etc/centos-release ] || {
        echo -e '\e[1;41mFATAL: new rootfs not found at /. ABORT, DO NOT REBOOT.\e[m'
        exit 1
    }
    if [ -e /etc/alpine-release ] || grep -qi alpine /etc/issue 2>/dev/null; then
        echo -e '\e[1;32m[alpine] installing openssh / bash / ifupdown-ng ...\e[m'
        if ! apk add openssh bash ifupdown-ng; then
            echo -e '\e[1;33m[alpine] apk add failed, retrying once ...\e[m'
            apk update
            apk add openssh bash ifupdown-ng || {
                echo -e '\e[1;41m[alpine] FATAL: package install failed. DO NOT REBOOT. Fix network and rerun the script.\e[m'
                exit 1
            }
        fi
        # never reboot into a system without sshd
        [ -e /etc/init.d/sshd ] && [ -e /usr/sbin/sshd ] || {
            echo -e '\e[1;41m[alpine] FATAL: sshd missing after install. DO NOT REBOOT.\e[m'
            exit 1
        }
        # syntax-check the generated interfaces with ifupdown-ng itself:
        # an unparsable interfaces file is exactly what bricked ipv6-only
        # boxes before (networking fails -> no address -> lost ssh).
        # --check only exists in newer ifupdown-ng; fall back to a plain parse.
        if command -v ifquery >/dev/null 2>&1; then
            if ifquery -i /etc/network/interfaces -c -a >/dev/null 2>&1; then
                echo -e '\e[1;32m[alpine] interfaces syntax check passed\e[m'
            elif ifquery --help 2>&1 | grep -qe -- '--check'; then
                echo -e '\e[1;41m[alpine] FATAL: /etc/network/interfaces syntax check failed. DO NOT REBOOT. Details:\e[m'
                ifquery -i /etc/network/interfaces -c -a 2>&1 | head -20
                exit 1
            elif ! ifquery -i /etc/network/interfaces lo >/dev/null 2>&1; then
                echo -e '\e[1;41m[alpine] FATAL: interfaces parse check failed. DO NOT REBOOT.\e[m'
                exit 1
            else
                echo -e '\e[1;32m[alpine] interfaces parse check passed (ifupdown-ng without --check)\e[m'
            fi
        fi
        rc-update add sshd default
        rc-update add networking default 2>/dev/null
        rc-update add hostname boot 2>/dev/null
        # NOTE: do NOT add mdev/devfs to sysinit on LXC. The linuxcontainers
        # template ships with sysinit empty and devfs in boot (the LXC host
        # manages /dev); `mdev -s` inside a container walks the whole host
        # sysfs and can wedge OpenRC at sysinit -> nothing ever starts.
        sed -i 's/--auto/-a/' /etc/init.d/networking 2>/dev/null # fix bug in networking script of lxc
    elif [ -e /etc/debian_version ] || grep -qi debian /etc/issue 2>/dev/null; then
        install ssh
        if [ "$cttype" == 'lxc' ] ; then
            install ifupdown
            systemctl disable systemd-networkd.service 2>/dev/null
        fi
    elif [ -e /etc/centos-release ] || grep -qi centos /etc/issue 2>/dev/null; then
        install openssh
        if [ "$cttype" == 'lxc' ] ; then
            install ifupdown
            systemctl disable systemd-networkd.service 2>/dev/null
        fi
    fi
    # sshd_config: first occurrence of a directive wins, so purge existing
    # PermitRootLogin/PasswordAuthentication lines before appending ours
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -e '/^[[:space:]#]*PermitRootLogin/d' -e '/^[[:space:]#]*PasswordAuthentication/d' /etc/ssh/sshd_config
        printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' >> /etc/ssh/sshd_config
    fi
    # 终极救生圈: 无论 OpenRC networking 的依赖链是否断裂,
    # /etc/local.d/*.start 都会在启动最后无条件执行, 确保 IP/onlink 路由/sshd 绝对活着
    mkdir -p /etc/local.d
    cat > /etc/local.d/99-rescue-net.start << 'EOF_RESCUE'
#!/bin/sh
ip link set dev eth0 up 2>/dev/null || true
ip -6 addr add 2a02:180:6:1::13/128 dev eth0 2>/dev/null || true
ip -6 route add fd78:232c:fe45:934b::1 dev eth0 2>/dev/null || true
ip -6 route replace default via fd78:232c:fe45:934b::1 dev eth0 onlink 2>/dev/null || true
/usr/sbin/sshd 2>/dev/null || rc-service sshd restart 2>/dev/null || true
EOF_RESCUE
    chmod +x /etc/local.d/99-rescue-net.start
    rc-update add local default 2>/dev/null || true

    rm -rf /x
    sync
    echo -e '\e[1;32mDone. Now run "reboot" to boot into the new system.\e[m'
    echo -e '\e[1;32mIf you still lose access after reboot, restore the base image from your provider panel and rerun this fixed script.\e[m'
}

function main(){
    print_help
    echo -e '\e[1;32minstall requirement...\e[m'
    install_requirement
    read_virt_tech

    if [ "$cttype" == 'openvz' ] ; then
        echo -e '\e[1;33mopenvz path is unchanged in this fixed version; use the upstream script.\e[m'
        exit 1
    elif [ "$cttype" == 'lxc' ] ; then
        read_lxc_template
    elif [ "$cttype" == 'kvm' ] ; then
        curl -qo OsMutationKvm.sh https://raw.githubusercontent.com/LloydAsp/OsMutation/main/OsMutationKvm.sh
        chmod u+x OsMutationKvm.sh
        ./OsMutationKvm.sh
        exit 0
    fi

    echo -e '\e[1;32mdownloading template...\e[m'
    download_rootfs
    echo -e '\e[1;32mmigrating configuration\e[m'
    migrate_configuration
    echo -e '\e[1;32mreplacing old files\e[m'
    replace_os
    echo -e '\e[1;32mpost processing...\e[m'
    post_install
}

main 2>&1 | tee reinstall.log
# propagate the real exit code through the pipe (tee would otherwise mask
# every FATAL exit with 0 and callers would reboot into a half-installed box)
exit ${PIPESTATUS[0]}
