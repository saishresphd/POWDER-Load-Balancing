#!/bin/bash
# revert_and_restart_gnb1_ue40_49.sh
# 1. Revert fail_on_disconnect=false -> true on enb_ue40-49.conf
# 2. Kill current ue40-49 srsenb slots
# 3. Restart them one by one, waiting for each ZMQ port to LISTEN before moving on
# Run on gNB1 (pc818): bash /proj/.../scripts/revert_and_restart_gnb1_ue40_49.sh

PROJ="/proj/ATLANTIC-eVISION/exp/loadbalance/tmp/ran_9ue_lb"
COLLECT="/tmp/ran_collect"
mkdir -p "$COLLECT"

echo "[$(date)] Step 1: Revert fail_on_disconnect back to true"
for N in 40 41 42 43 44 45 46 47 48 49; do
    sudo sed -i 's/fail_on_disconnect=false/fail_on_disconnect=true/g' /etc/srsenb/enb_ue${N}.conf
    VAL=$(grep fail_on_disconnect /etc/srsenb/enb_ue${N}.conf | grep -o 'fail_on_disconnect=[a-z]*')
    echo "  enb_ue${N}.conf: $VAL"
done

echo "[$(date)] Step 2: Kill all ue40-49 srsenb slots"
for N in 40 41 42 43 44 45 46 47 48 49; do
    PIDS=$(ps aux | grep "[s]rsenb.*enb_ue${N}.conf" | awk '{print $2}')
    for PID in $PIDS; do
        sudo kill -9 "$PID" 2>/dev/null || true
    done
done
sleep 3

REMAIN=$(ps aux | grep "[s]rsenb.*enb_ue4[0-9]" | grep -v grep | wc -l)
echo "[$(date)] Remaining ue40-49 srsenb procs after kill: $REMAIN"

echo "[$(date)] Step 3: Start each srsenb slot, wait for ZMQ port to bind"
for N in 40 41 42 43 44 45 46 47 48 49; do
    CONF=/etc/srsenb/enb_ue${N}.conf
    # Port formula: tx_port = tcp://*:4N000 where N is the UE number
    PORT=4${N}00
    STDOUT="$COLLECT/gnb1_ue${N}_stdout.log"
    > "$STDOUT"

    # Start srsenb exactly as the working experiment_ue50 script does
    sudo bash -c "srsenb $CONF >> $STDOUT 2>&1 &"
    echo "  [$(date)] ue${N}: started, waiting for port $PORT to LISTEN..."

    # Poll up to 20s for the ZMQ REP port to appear
    READY=0
    for TICK in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        sleep 1
        if ss -tnlp 2>/dev/null | grep -q ":${PORT} " || ss -tnlp 2>/dev/null | grep -q ":${PORT}$"; then
            echo "  [$(date)] ue${N}: port $PORT LISTEN (${TICK}s)"
            READY=1
            break
        fi
    done

    if [ "$READY" -eq 0 ]; then
        echo "  [$(date)] ue${N}: WARNING port $PORT not seen after 20s — check $STDOUT"
        tail -5 "$STDOUT"
    fi
done

echo "[$(date)] All 10 srsenb slots started."
echo "MME eNB count:"
# MME check from gNB1 is indirect — just confirm procs
ps aux | grep "[s]rsenb.*enb_ue4[0-9]" | wc -l
echo "processes running (should be 20: 10 sudo + 10 srsenb)"
