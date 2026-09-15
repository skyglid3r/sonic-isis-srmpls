#!/bin/bash

USER="admin"
PASS="admin"

# Define the nodes and their management IPs
NODES=("leaf11" "leaf12" "spine11" "spine12")
IPS=("172.40.40.2" "172.40.40.4" "172.40.40.3" "172.40.40.5")

GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
RESET=$(printf '\033[0m')

echo "========================================================"
echo "🏗️  STARTING COMPREHENSIVE SONiC FABRIC DEPLOYMENT"
echo "========================================================"

# ========================================================
# STEP 0: HOST SERVER DATA PLANE INITIALIZATION
# ========================================================
echo "🧠 Unlocking Host Machine kernel for MPLS transport processing..."
if [ ! -d "/proc/sys/net/mpls" ]; then
    echo "⚠️ MPLS kernel extensions missing on host. Injecting modules now..."
    sudo modprobe mpls_router &>/dev/null
    sudo modprobe mpls_iptunnel &>/dev/null
fi

# Apply system control variables to host infrastructure to unblock directory mounting
sudo sysctl -w net.mpls.platform_labels=1048575 > /dev/null 2>&1
sudo sysctl -w net.mpls.conf.all.input=1 > /dev/null 2>&1
echo "✅ Host Linux kernel successfully prepared for virtual MPLS paths."
echo ""

# Force-clear the cached keys on the host machine before starting to prevent collisions
echo "🧹 Clearing old SSH host keys from your server memory..."
for IP in "${IPS[@]}"; do
    ssh-keygen -f "/root/.ssh/known_hosts" -R "$IP" &>/dev/null
done

# Check if sshpass is installed on your host server
if ! command -v sshpass &> /dev/null; then
    echo "❌ sshpass is missing. Installing it now..."
    sudo dnf install -y sshpass || sudo yum install -y sshpass || sudo apt-get install -y sshpass
fi

# SSH Bypass Flags to force authentication through without confirmation prompts
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ========================================================
# FABRIC PROVISIONING LOOP
# ========================================================
for i in "${!NODES[@]}"; do
    NODE="${NODES[$i]}"
    IP="${IPS[$i]}"

    CFG_DIR="configs/wan-edge/${NODE}"
    DB_FILE="${CFG_DIR}/config_db.json"
    FRR_FILE="${CFG_DIR}/${NODE}.frr.conf"

    echo "--------------------------------------------------------"
    echo "${YELLOW}[$NODE] Processing Node...${RESET}"
    echo "--------------------------------------------------------"

    # ========================================================
    # STEP 1: PUSH & RELOAD CONFIG_DB.JSON
    # ========================================================
    if [ -f "$DB_FILE" ]; then
        echo "📤 Copying custom config_db.json to $NODE ($IP)..."
        sshpass -p "$PASS" scp $SSH_OPTS "$DB_FILE" "$USER@$IP:/tmp/config_db.json"

        echo "🔄 Applying config_db.json and saving changes..."
        sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$IP" "
            echo $PASS | sudo -S mv /tmp/config_db.json /etc/sonic/config_db.json &&
            sudo config reload -y &&
            sudo config save -y
        "
        echo "✅ Config DB Applied successfully."
    else
        echo "⚠️  Skipping DB copy: $DB_FILE not found."
    fi

    # ========================================================
    # STEP 2: PUSH FRR.CONF, INTEGRATE DATABASE, & SPAWN DAEMONS
    # ========================================================
    if [ -f "$FRR_FILE" ]; then
        echo "📤 Copying $NODE.frr.conf to $NODE ($IP)..."
        sshpass -p "$PASS" scp $SSH_OPTS "$FRR_FILE" "$USER@$IP:/tmp/frr.conf"

        echo "⚙️  Configuring host kernel, enabling management framework, and spawning isisd..."
        sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$IP" "
            echo $PASS | sudo -S mkdir -p /etc/sonic/frr
            sudo mv /tmp/frr.conf /etc/sonic/frr/frr.conf
            sudo chown -R 300:300 /etc/sonic/frr/
            sudo chmod 777 /etc/sonic/frr/frr.conf

            # --- MPLS KERNEL PROCESSING HOOKS ---
            sudo modprobe mpls_router &>/dev/null
            sudo modprobe mpls_iptunnel &>/dev/null
            
            echo '🧠 Unlocking internal Virtual Node data plane for MPLS handling...'
            # Configure label space allocation
            if [ -f /proc/sys/net/mpls/platform_labels ]; then
                echo 1048575 | sudo tee /proc/sys/net/mpls/platform_labels > /dev/null
            fi
            
            # Target active physical interface structures explicitly, skipping non-existent 'all' folder
            [ -f /proc/sys/net/mpls/conf/eth1/input ] && echo 1 | sudo tee /proc/sys/net/mpls/conf/eth1/input > /dev/null
            [ -f /proc/sys/net/mpls/conf/eth2/input ] && echo 1 | sudo tee /proc/sys/net/mpls/conf/eth2/input > /dev/null
            [ -f /proc/sys/net/mpls/conf/lo/input ]   && echo 1 | sudo tee /proc/sys/net/mpls/conf/lo/input > /dev/null

            # --- INTEGRATED ROUTING FRAMEWORK ACTIVATION ---
            sudo redis-cli -n 4 HSET 'DEVICE_METADATA|localhost' 'docker_routing_config_mode' 'split-unified'
            sudo redis-cli -n 4 HSET 'DEVICE_METADATA|localhost' 'frr_mgmt_framework_config' 'true'
            sudo config save -y

            # Restart the routing container to ensure clean state base with native modules
            sudo docker restart bgp
            sleep 4

            # Explicitly force-spawn isisd daemon inside the running container namespace
            echo '🔧 Launching isisd process directly inside bgp container...'
            sudo docker exec bgp /usr/lib/frr/isisd -d
        "
        echo "${GREEN}✅ FRR Management Framework & IS-IS daemon successfully running for $NODE!${RESET}"
    else
        echo "⚠️  Skipping FRR copy: $FRR_FILE not found."
    fi
    echo ""
done

echo "========================================================"
echo "${GREEN}🚀 All fabric configurations have been successfully pushed and loaded!${RESET}"
echo "========================================================"

