#!/bin/bash

# Obtenir les variables
SANDBOX_BRIDGE=$(terraform output -raw sandbox_bridge)
SANDBOX_NETWORK=$(terraform output -raw sandbox_network_cidr)
INETSIM_IP=$(terraform output -raw inetsim_ip)

# Supprimer et recréer la chaîne
iptables -F SANDBOX_FORWARD 2>/dev/null || true
iptables -X SANDBOX_FORWARD 2>/dev/null || true
iptables -N SANDBOX_FORWARD 2>/dev/null || true

# Autoriser les connexions déjà établies
iptables -A SANDBOX_FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Attacher la chaîne au bridge
iptables -A FORWARD -i $SANDBOX_BRIDGE -j SANDBOX_FORWARD
iptables -A FORWARD -o $SANDBOX_BRIDGE -j SANDBOX_FORWARD

# Autoriser Sandbox -> INetSim
iptables -A SANDBOX_FORWARD -s $SANDBOX_NETWORK -d $INETSIM_IP -j ACCEPT

# Autoriser INetSim -> Sandbox
iptables -A SANDBOX_FORWARD -s $INETSIM_IP -d $SANDBOX_NETWORK -j ACCEPT

# Interdire Sandbox -> Sandbox
iptables -A SANDBOX_FORWARD -s $SANDBOX_NETWORK -d $SANDBOX_NETWORK -j DROP

# Tout le reste du trafic sandbox -> DROP
iptables -A SANDBOX_FORWARD -j DROP
