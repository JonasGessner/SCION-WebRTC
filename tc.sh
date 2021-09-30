#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

function config {
    dev="$1"

    tc filter del dev "$dev"
    tc qdisc del dev "$dev" root > /dev/null 2>&1

    # https://stackoverflow.com/questions/40196730/simulate-network-latency-on-specific-port-using-tc
    tc qdisc add dev "$dev" root handle 1: prio bands 6 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    # This is so that two different ports used by scion map to the same filter. 0b1100000000000000 (49152) and 0b100000000000000 (16384) map to the same filter, etx
    tc filter add dev "$dev" parent 1: protocol ip u32 match ip sport 16384 0x7fff flowid 1:2
    tc filter add dev "$dev" parent 1: protocol ip u32 match ip sport 16385 0x7fff flowid 1:3
    tc filter add dev "$dev" parent 1: protocol ip u32 match ip sport 16386 0x7fff flowid 1:4
    tc filter add dev "$dev" parent 1: protocol ip u32 match ip sport 16387 0x7fff flowid 1:5
    tc filter add dev "$dev" parent 1: protocol ip u32 match ip sport 16388 0x7fff flowid 1:6
}

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <class (0-4)> <netem-rules> <tbf-rules>"
    echo ""
    echo "Pass an empty string to each rule type to not apply that rule"
    echo ""
    echo "To configure tc and to reset all rules: This needs to be run before any rules are set"
    echo "      Example: $0 config 0 0"
    echo ""
    echo "To set rules on a specific class:"
    echo "    Example: $0 1 'delay 50ms limit 1000' 'rate 2000kbit burst 2Kb latency 5ms'"
    echo ""
    echo "To clear rules for a class:"
    echo "      Example: $0 <class> clear 0"
    exit 1
fi

function status {
    dev="$1"

    echo "    Filters:"
    tc -s -d filter show dev "$dev"

    echo ""
    echo "    qdiscs:"
    tc -s -d qdisc show dev "$dev"
}

function configCommon {
    dev="$1"
    class=$(("$2" + 2))
    netem="$3"
    tbf="$4"
    
    netemHandle=$((class))
    tbfHandle=$((class + 5))

    echo "Configuring device $dev, class $class: ($netemHandle, $tbfHandle)"
    echo ""

    echo "Cleaning..."
    # clean up existing qdiscs
    tc qdisc del dev "$dev" parent $netemHandle: handle $tbfHandle
    tc qdisc del dev "$dev" parent 1:$class handle $netemHandle:

    if [[ "$netem" == "clear" ]]; then
        echo "Cleared filters on device $dev"
    else
        echo "Configuring..."
        echo ""
        # set up new qdiscs
        if [ ! -z "$netem" ]; then
            tc qdisc add dev "$dev" parent 1:$class handle $netemHandle: netem $netem
                if [ ! -z "$tbf" ]; then
                    tc qdisc add dev "$dev" parent $netemHandle: handle $tbfHandle: tbf $tbf
                fi
        elif [ ! -z "$tbf" ]; then
            tc qdisc add dev "$dev" parent 1:$class handle $netemHandle: tbf $tbf
        fi
        echo "Configured netem rules: $netem, tbf rules $tbf for port $port on device $dev."
    fi

    status "$dev"
}

if [[ "$1" == "config" ]]; then
    echo "Configuring devices"

    config enp0s1
    
    status enp0s1
    
    exit 0
elif [[ "$1" == "status" ]]; then
    echo "Configuring devices"

    status enp0s1

    exit 0
fi

configCommon enp0s1 "$1" "$2" "$3"

echo ""

echo "Done"
