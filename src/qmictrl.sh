#!/bin/bash
# shellcheck disable=SC2086
#
# @file      qmictrl.sh
# 
# @version   0.1.0
#
# @date      17-11-2026
#  
# @author    Fábio D. Pacheco, 
# @email     fabio.d.pacheco@inesctec.pt or pacheco.castro.fabio@gmail.com
#
# @note
# Copyright (C) 2026 Fábio D. Pacheco\n\n
# 
# Permission is hereby granted, free of charge, to any person obtaining a 
# copy of this software and associated documentation files (the “Software”), 
# to deal in the Software without restriction, including without limitation 
# the rights to use, copy, modify, merge, publish, distribute, sublicense, 
# and/or sell copies of the Software, and to permit persons to whom the 
# Software is furnished to do so, subject to the following conditions:\n\n
# 
# The above copyright notice and this permission notice shall be included 
# in all copies or substantial portions of the Software.\n\n
# 
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS 
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
# THE SOFTWARE.\n\n

VERSION="0.1.0"
function _help() {
        printf "qmictrl - linux 4G/5G control script, it initializes, registers in the network, gets an ipaddress and keeps the connection alive using qmicli\n\n"
        printf "usage:\n\tqmictrl [OPTIONS]\n\n"
        printf "description:\n\tqmictrl registers on the network, requests an ipv4 address, sets the nic interface and sets up the route.\n"
        printf "\tAdditionally it can be configured as a router, in all cases it mantains the connection alive by probing a desired ipaddress,\n"
        printf "\tit assumes the simcard is unlocked and its operation is valid.\n"
        printf "options:\n"
        printf "\t-h, --help              Display this help message and exit\n"
        printf "\t-v, --version           Display version information and exit\n"
        printf "\t-d, --devname PATH      Indicate the modem device path (default: /dev/cdc-wdm0)\n"
        printf "\t-a, --apn NAME          Set the provider APN (default: internet)\n"
        printf "\t-i, --interval SECONDS  Set probe interval (default: 10)\n"
        printf "\t-p, --probe_addr IP     Set the probe ipv4 address, a service with low prob of being down (default: 1.1.1.1)\n"
        printf "\t-r, --router Y|N        Set the device to router (default: 'n')\n"
        printf "\t-l, --lan \"DEV DEV\"     LAN interfaces to forward from when router is 'y' (default: \"eth0 wlan0\")\n"
        printf "\t-t, --tout SECONDS      Timeout for any command execution (default: 10)\n"
        printf "\nversion:\n\t%s\n" $VERSION
        printf "
Copyright (C) 2026 Fábio D. Pacheco

Permission is hereby granted, free of charge, to any person obtaining a 
copy of this software and associated documentation files (the 'Software'), 
to deal in the Software without restriction, including without limitation 
the rights to use, copy, modify, merge, publish, distribute, sublicense, 
and/or sell copies of the Software, and to permit persons to whom the 
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included 
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS 
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
THE SOFTWARE.\n"
        exit 0
}
function _version() {
        printf "qmictrl - linux 4G/5G control script, it initializes, registers in the network, gets an ipaddress and keeps the connection alive using qmicli\n\n"
        printf "version:\n\t%s\n" $VERSION
        exit 0
}

# Optional reset
function _reset() {
        local i
        if [[ -z "$gpio" || -z $(which gpioset) ]]; then
                return 1
        fi
        printf "[qmictrl][WARN ] reseting device through gpio %s ...\n" $gpio
        # HIGH 3-5s then LOW to power off
        gpioset -c gpiochip0 -t 0 $gpio=1; sleep 4
        gpioset -c gpiochip0 -t 0 $gpio=0
        # Wait for the module to shut down completely
        for (( i = 0; i < 30; i++ )); do
                if [ ! -e "$devname" ]; then
                        break
                fi
                sleep 1
        done
        if [ -e "$devname" ]; then
                printf "[qmictrl][WARN ] device did not shut down\n"
        fi
        # HIGH 1s then LOW to power on
        gpioset -c gpiochip0 -t 0 $gpio=1; sleep 1
        gpioset -c gpiochip0 -t 0 $gpio=0
        # Wait for the module to boot
        for (( i = 0; i < 60; i++ )); do
                if [ -e "$devname" ]; then
                        break
                fi
                sleep 1
        done
        return 0
}
function _checkdepend() {
        for cmd in qmicli ip udhcpc iptables ping timeout sysctl; do
                if [[ -z $(which $cmd) ]]; then
                        printf "[qmictrl][ERROR] %s is missing\n" $cmd
                        return 1
                fi
        done
        return 0
}
function _getcid() {
        local service=$1 ret cid
        sleep 0.2
        ret=$(timeout $tout qmicli -p -d $devname --${service}-noop --client-no-release-cid)
        if [[ -z $(printf "%s" $ret) ]]; then
                # To stderr, stdout is captured as the cid
                printf "[qmictrl][ERROR] failed to get cid %s\n" $service >&2
                return 1
        fi
        cid=$(printf "%s" $ret | grep -i CID | awk -F"'" '/CID/ {print $4}')
        if [[ -z $(printf "%s" $cid) ]]; then
                printf "[qmictrl][ERROR] failed to get cid %s\n" $service >&2
                return 1
        fi
        printf "%s\n" $cid
        return 0
}
function _freecid() {
        local service=$1 cid=$2 ret
        if ! timeout $tout qmicli -p -d $devname --${service}-noop --client-cid=$cid; then
                return 1
        fi
        return 0 
}
function _setmode() {
        local mode=$1 ret
        ret=$(timeout $tout qmicli -p -d $devname --dms-set-operating-mode=$mode --client-no-release-cid --client-cid=$dms)
        if ! grep -qi "success" <<< "$ret"; then
                printf "[qmictrl][INFO ] failed to set mode %s\n" $mode
                return 1
        fi
        printf "[qmictrl][INFO ] success to set mode %s\n" $mode
        return 0
} 
function _setrawmode() {
        local ret
        ret=$(ip link set $iface down) || return 1
        ret=$(echo 'Y' | tee /sys/class/net/$iface/qmi/raw_ip) || return 1
        ret=$(ip link set $iface up) || return 1
        return 0
}
function _getnetwork() {
        local ret
        ret=$(timeout $tout qmicli -p -d $devname --nas-get-home-network --client-no-release-cid --client-cid=$nas)
        if ! grep -qi "Successfully" <<< "$ret"; then
                return 1
        fi
        iface=$(timeout $tout qmicli -p -d $devname -w) || return 1
        printf "%s\n" $iface
        _setrawmode
        return 0
}
# Serving cell signal, RSSI/RSRP in dBm, RSRQ/SNR in dB, min is the usable limit
function _getsignal() {
        local ret rssi rsrp rsrq snr
        ret=$(timeout $tout qmicli -p -d $devname --nas-get-signal-info --client-no-release-cid --client-cid=$nas 2>&1)
        rssi=$(awk -F"'" '/RSSI:/ {split($2, v, " "); print v[1]; exit}' <<< "$ret")
        rsrp=$(awk -F"'" '/RSRP:/ {split($2, v, " "); print v[1]; exit}' <<< "$ret")
        rsrq=$(awk -F"'" '/RSRQ:/ {split($2, v, " "); print v[1]; exit}' <<< "$ret")
        snr=$(awk -F"'" '/SNR:/ {split($2, v, " "); print v[1]; exit}' <<< "$ret")
        printf "[qmictrl][DEBUG] RSSI: %s dBm (min -85), RSRP: %s dBm (min -100), RSRQ: %s dB (min -20), SNR: %s dB (min 0)\n" "${rssi:--}" "${rsrp:--}" "${rsrq:--}" "${snr:--}"
}
function _getaddr() {
        local ret
        if [[ -n $(printf "%s" $pdhandle) ]]; then
                _stopnetwork
        fi
        if ! ret=$(timeout $tout qmicli -p -d $devname           \
                --device-open-net='net-raw-ip|net-no-qos-header' \
                --wds-start-network="apn=$apn,ip-type=4"         \
                --client-no-release-cid --client-cid=$wds 2>&1); 
        then
                printf "[qmictrl][ERROR] failed to start network:\n%s\n" "$ret"
                return 1
        fi
        pdhandle=$(awk -F"'" '/Packet data handle/ {print $2}' <<< "$ret")
        if [[ -z "$pdhandle" ]]; then
                printf "[qmictrl][ERROR] failed to obtain packet data handle\n"
                return 1
        fi
        # -T Pause between packets, -t Send up to N discover packets
        if ! ret=$(timeout $tout udhcpc -i $iface -n -q -t 3 -T 2 2>&1); then
                printf "[qmictrl][INFO ] dhcp acquisition failed:\n%s\n" "$ret"
                _setrawmode
                return 1
        fi
        if ! grep -qi "lease" <<< "$ret" ; then
                printf "[qmictrl][INFO ] dhcp acquisition failed:\n%s\n" "$ret"
                _setrawmode
                return 1
        fi
        if ! ip -4 addr show dev $iface | grep -q 'inet '; then
                printf "[qmictrl][INFO ] dhcp did not configure an IPv4 address\n"
                return 1
        fi
        sleep 3
        ret=$(ip link set $iface up)
        ip route del default dev $iface 2>/dev/null
        ret=$(ip route add default dev $iface metric 200 2>&1) || printf "[qmictrl][WARN ] route add failed: %s\n" "$ret"
        printf "[qmictrl][INFO ] online %s\n" "$iface"
        return 0
}
function _stopnetwork() {
        local ret
        if [[ -z $(printf "%s" $pdhandle) ]]; then
                return 0
        fi
        if ! ret=$(timeout $tout qmicli -p -d $devname --wds-stop-network=$pdhandle --client-no-release-cid --client-cid=$wds); then
                printf "[qmictrl][WARN ] failed to stop WDS session:\n%s\n" "$ret"
                pdhandle=""
                return 1
        fi
        pdhandle=""
        return 0
}
function _setrouter() {
        local devs=("$@") dev dev_i dev_j ret
        
        ret=$(sysctl -w net.ipv4.ip_forward=1)
        # Enable NAT / Masquerade on WAN
        ret=$(iptables -t nat -C POSTROUTING -o $iface -j MASQUERADE 2>&1)
        if [[ -n $(printf "%s" $ret) ]]; then
                ret=$(iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE 2>&1)
                if [[ -n $(printf "%s" $ret) ]]; then
                        return 1
                fi 
        fi 
        ret=$(iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>&1)
        if [[ -n $(printf "%s" $ret) ]]; then
                # Allow return traffic for established connections across ALL interfaces
                ret=$(iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>&1)
                if [[ -n $(printf "%s" $ret) ]]; then
                        return 1
                fi 
        fi 
        # Allow forwarding from LAN interfaces (eth0, wlan0) out to WAN (wwan0)
        for dev in "${devs[@]}"; do
                ret=$(iptables -C FORWARD -i $dev -o  $iface -j ACCEPT 2>&1)
                if [[ -n $(printf "%s" $ret) ]]; then
                        ret=$(iptables -A FORWARD -i $dev -o  $iface -j ACCEPT 2>&1)
                        if [[ -n $(printf "%s" $ret) ]]; then
                                return 1
                        fi 
                fi 
        done
        # Allow LAN-to-LAN forwarding (eth0 <-> wlan0)
        for dev_i in "${devs[@]}"; do
                for dev_j in "${devs[@]}"; do
                        if [ "$dev_i" != "$dev_j" ]; then
                                ret=$(iptables -C FORWARD -i $dev_i -o $dev_j -j ACCEPT 2>&1)
                                if [[ -n $(printf "%s" $ret) ]]; then
                                        ret=$(iptables -A FORWARD -i $dev_i -o $dev_j -j ACCEPT 2>&1)
                                        if [[ -n $(printf "%s" $ret) ]]; then
                                                return 1
                                        fi 
                                fi 
                        fi
                done
        done
        return 0
}
function _cleanup() {
        local status=${1:-0}
        printf "[qmictrl][INFO ] releasing cids ...\n"
        _stopnetwork
        if [[ -n $(printf "%s" $wds) ]]; then 
                _freecid wds $wds || status=1
                wds=""
        fi
        if [[ -n $(printf "%s" $dms) ]]; then 
                _freecid dms $dms || status=1
                dms=""
        fi
        if [[ -n $(printf "%s" $nas) ]]; then 
                _freecid nas $nas || status=1
                nas=""
        fi
        exit $status
}

####

args=()
devname="/dev/cdc-wdm0"
iface="wwan0"
interval="10"
probe="1.1.1.1"
lan="eth0 wlan0"
router="n"
tout="10"
retryinterval="1"
apn="internet"
gpio="" # Reset gpio for _reset, empty disables it
pdhandle=""
while [[ $# -gt 0 ]]; do
        case $1 in
                -h|--help)       _help;;
                -v|--version)    _version;;
                -d|--devname)    devname="$2";  shift; shift;;
                -a|--apn)        apn="$2";      shift; shift;;
                -i|--interval)   interval="$2"; shift; shift;;
                -p|--probe_addr) probe="$2";    shift; shift;;
                -r|--router)     router="$2";   shift; shift;;
                -l|--lan)        lan="$2";      shift; shift;;
                -t|--tout)       tout="$2";     shift; shift;;
                -*|--*)
                        printf "[qmictrl][WARN ] %s unkown option ...\n" $1
                        shift; shift
                ;;
                *) args+=("$1"); shift;;
        esac
done

if [ "$(id -u)" -ne 0 ]; then
        printf "[qmictrl][ERROR] must be run as root ...\n"
        exit 1
fi

_checkdepend || exit 1
router=$(printf "%s" "$router" | tr 'A-Z' 'a-z')
read -r -a devs <<< "$lan"

trap _cleanup INT TERM # signal handler

telpath=/tmp/qmi/${devname##*/}/stats
printf "[qmictrl] create directory for telemetry: %s\n" $telpath
mkdir -p "$telpath"

state=STATUS
next_state=$state
maxtries=5
tries=0
while true; do
        if [ "$state" != "$next_state" ]; then
                tries=0
        fi

        tries=$((tries+1))
        state=$next_state
        case $state in
                STATUS)
                        # Modem not answering after maxtries, power cycle it
                        if [ "$tries" -gt "$maxtries" ]; then
                                _reset
                                tries=1
                        fi
                        printf "[qmictrl] device path:   \t%s\n" "$devname"
                        printf "[qmictrl] interface name:\t%s\n" "$iface"
                        printf "[qmictrl] probe address: \t%s\n" "$probe"
                        printf "[qmictrl] probe interval:\t%s\n" "$interval"
                        printf "[qmictrl] be router:     \t%s\n" "$router"
                        printf "[qmictrl] lan:           \t%s\n" "$lan"
                        printf "[qmictrl] reset gpio:    \t%s\n" "$gpio"

                        _stopnetwork
                        if [[ -n $(printf "%s" $wds) ]]; then 
                                _freecid wds $wds 
                                wds=""
                        fi
                        if [[ -n $(printf "%s" $dms) ]]; then 
                                _freecid dms $dms 
                                dms=""
                        fi
                        if [[ -n $(printf "%s" $nas) ]]; then 
                                _freecid nas $nas 
                                nas=""
                        fi
                        wds=$(_getcid wds); dms=$(_getcid dms); nas=$(_getcid nas)
                        if [[ -z $wds || -z $dms || -z $nas ]]; then
                                next_state=STATUS
                                sleep $retryinterval
                        else
                                printf "[qmictrl] wds cid:       \t%s\n" $wds
                                printf "[qmictrl] dms cid:       \t%s\n" $dms
                                printf "[qmictrl] nas cid:       \t%s\n" $nas
                                if ! _setmode online; then
                                        next_state=STATUS
                                        sleep $retryinterval
                                else
                                        next_state=AVAILABLE
                                fi
                        fi
                ;;
                AVAILABLE)
                        _getsignal
                        ret=$(_getnetwork)
                        if [[ -z $(printf "%s" $ret) ]]; then
                                if [ "$tries" -lt "$maxtries" ]; then
                                        next_state=AVAILABLE
                                        sleep $retryinterval
                                else
                                        next_state=STATUS
                                fi
                        else
                                iface=$ret
                                next_state=REQUEST
                        fi
                ;;
                REQUEST)
                        if ! _getaddr; then
                                if [ "$tries" -lt "$maxtries" ]; then
                                        next_state=REQUEST
                                        _stopnetwork
                                        sleep $retryinterval
                                else
                                        # Restart from STATUS, AVAILABLE succeeds while registered and loops back here
                                        next_state=STATUS
                                fi
                        else
                                if [[ "$router" == "n" ]]; then
                                        next_state=PROBE
                                else
                                        next_state=ROUTER
                                fi
                        fi
                ;;
                ROUTER)
                        if ! _setrouter "${devs[@]}"; then
                                printf "[qmictrl][WARN ] some router rules failed ...\n"
                                _cleanup 1
                        fi
                        next_state=PROBE
                ;;
                PROBE)
                        ret=$(ping -I $iface -3 -i 1 -w $interval $probe 2>&1)
                        # Search the "packet loss" field, ping adds "+N errors" before it on failures
                        loss=$(awk -F',' '/packet loss/ {
                                for (i = 1; i <= NF; i++)
                                        if ($i ~ /packet loss/) {
                                                gsub(/[^0-9.]/, "", $i)
                                                print int($i)
                                        }
                        }' <<< "$ret")
                        rtt=$(awk -F'/' '/^(rtt|round-trip)/ {
                                print $5
                        }' <<< "$ret")
                        if [[ -z $(printf "%s" $loss) ]]; then
                                loss=100
                        fi
                        # No reply means no rtt line from ping
                        if [[ -z $(printf "%s" $rtt) ]]; then
                                rtt="--"
                        fi
                        printf "[qmictrl][DEBUG] packet loss: %s%%, RTT: %s ms\n" "$loss" "$rtt"
                        _getsignal
                        ret=$(timeout $tout qmicli -p -d $devname --wds-get-packet-statistics --client-no-release-cid --client-cid=$wds)
                        if grep -qi "packets" <<< "$ret"; then
                                tx_packets=$(awk -F: '/TX packets OK:/ {gsub(/[^0-9]/,"",$2); print $2}' <<< "$ret")
                                rx_packets=$(awk -F: '/RX packets OK:/ {gsub(/[^0-9]/,"",$2); print $2}' <<< "$ret")
                                tx_dropped=$(awk -F: '/TX packets dropped:/ {gsub(/[^0-9]/,"",$2); print $2}' <<< "$ret")
                                rx_dropped=$(awk -F: '/RX packets dropped:/ {gsub(/[^0-9]/,"",$2); print $2}' <<< "$ret")
                                tx_bytes=$(awk -F: '/TX bytes OK:/ {gsub(/[^0-9]/,"",$2); print $2}' <<< "$ret")
                                rx_bytes=$(awk -F: '/RX bytes OK:/ {gsub(/[^0-9]/,"",$2); print $2}' <<< "$ret")
                                printf "%s\n" "$tx_packets" > "$telpath/tx_packets"
                                printf "%s\n" "$rx_packets" > "$telpath/rx_packets"
                                printf "%s\n" "$tx_dropped" > "$telpath/tx_dropped"
                                printf "%s\n" "$rx_dropped" > "$telpath/rx_dropped"
                                printf "%s\n" "$tx_bytes"   > "$telpath/tx_bytes"
                                printf "%s\n" "$rx_bytes"   > "$telpath/rx_bytes"
                        fi
                        if [ $loss -gt 80 ] && [ $loss -le 95 ]; then
                                printf "[qmictrl][INFO] Connection instable %s%% packet loss, %s ms ...\n" $loss $rtt
                                tries=0
                                next_state=PROBE
                        elif [ $loss -gt 95 ]; then
                                if [ "$tries" -lt "$maxtries" ]; then
                                        printf "[qmictrl][INFO] Connection instable %s%% packet loss, %s ms ...\n" $loss $rtt
                                        next_state=PROBE
                                        sleep $retryinterval
                                else
                                        printf "[qmictrl][INFO] Connection lost ...\n"
                                        next_state=AVAILABLE
                                        _stopnetwork
                                        sleep $retryinterval

                                fi
                        else
                                tries=0
                                next_state=PROBE
                        fi
                ;;
        esac
done
