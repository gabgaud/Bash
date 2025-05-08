#!/bin/bash

# Script pour la mise en place d'un service DHCP avec KEA
# Date : 08 mai 2025
# Auteur : Gabriel Gaudreault

# ========================
# 1. Installation du service
# ========================
echo "Installation du service DHCP Kea..."
apt update && apt install kea-dhcp4-server -y

# Sauvegarde de l'ancien fichier de configuration
echo "Sauvegarde du fichier de configuration existant..."
mv /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.bak

# ========================
# 2. Choix de l'interface réseau
# ========================
# On récupère les interfaces réseau disponibles sauf 'lo' (boucle locale)
ifaces=($(ls /sys/class/net | grep -v '^lo$'))

echo "Veuillez sélectionner une interface réseau pour le service DHCP :"
select ifaceSelection in "${ifaces[@]}"; do
    if [[ -n "$ifaceSelection" ]]; then
        echo "Vous avez choisi : $ifaceSelection"
        break
    else
        echo "Sélection invalide. Réessayez."
    fi
done

# ========================
# 3. Saisie de la durée du bail (en heures)
# ========================
while true; do
    read -p "Entrez la durée du bail (en heures) : " lease_hours
    if [[ "$lease_hours" =~ ^[0-9]+$ && "$lease_hours" -gt 0 ]]; then
        lease_seconds=$((lease_hours * 3600))
        renew_timer=$((lease_seconds / 2))
        rebind_timer=$((lease_seconds * 8 / 10))
        break
    else
        echo "Valeur invalide. Veuillez entrer un nombre entier positif."
    fi
done

# ========================
# 4. Définir l'étendue d'adresses IP
# ========================
while true; do
    read -p "Entrez l'étendue IP (ex. 192.168.21.100 - 192.168.21.200) : " ip_range
    if [[ "$ip_range" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*-[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        ip_start="${BASH_REMATCH[1]}"
        ip_end="${BASH_REMATCH[2]}"
        IFS='.' read -r a1 a2 a3 a4 <<< "$ip_start"
        IFS='.' read -r b1 b2 b3 b4 <<< "$ip_end"
        if [[ "$a1.$a2.$a3" == "$b1.$b2.$b3" && "$a4" -lt "$b4" ]]; then
            subnet_prefix="$a1.$a2.$a3"
            subnet="$subnet_prefix.0/24"
            break
        else
            echo "L'étendue IP semble invalide ou incohérente."
        fi
    else
        echo "Format invalide. Utilisez : IP_DÉBUT - IP_FIN"
    fi
done

# ========================
# 5. Adresse IP de la passerelle
# ========================
while true; do
    read -p "Entrez l'adresse IP de la passerelle (ex. ${subnet_prefix}.1) : " gateway_ip
    if [[ "$gateway_ip" =~ ^${subnet_prefix}\.[0-9]+$ ]]; then
        break
    else
        echo "L'adresse doit appartenir au sous-réseau $subnet_prefix.0/24"
    fi
done

# ========================
# 6. Adresse IP du/des serveurs DNS
# ========================
while true; do
    read -p "Entrez les adresses IP des serveurs DNS (séparées par des virgules si plusieurs) : " dns_ips
    if [[ "$dns_ips" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(,[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$ ]]; then
        break
    else
        echo "Format invalide. Exemple : 8.8.8.8 ou 192.168.21.1,8.8.8.8"
    fi
done

# ========================
# 7. Génération du fichier de configuration
# ========================
echo "Création du fichier de configuration /etc/kea/kea-dhcp4.conf ..."

cat <<EOF > /etc/kea/kea-dhcp4.conf
{
 "Dhcp4": {

    "interfaces-config": {
        "interfaces": [ "$ifaceSelection" ]
    },

    "valid-lifetime": $lease_seconds,
    "renew-timer": $renew_timer,
    "rebind-timer": $rebind_timer,
    "authoritative": true,

    "lease-database": {
        "type": "memfile",
        "persist": true,
        "name": "/var/lib/kea/kea-leases4.csv",
        "lfc-interval": 3600
    },

    "subnet4": [
        {
            "subnet": "$subnet",
            "pools": [ { "pool": "$ip_start - $ip_end" } ],
            "option-data": [
                {
                    "name": "routers",
                    "data": "$gateway_ip"
                },
                {
                    "name": "domain-name-servers",
                    "data": "$dns_ips"
                },
                {
                    "name": "domain-search",
                    "data": "gabriel.local"
                }
            ]
        }
    ]
 }
}
EOF

# ========================
# 8. Démarrage du service
# ========================
echo "Redémarrage du service Kea DHCP..."
systemctl restart kea-dhcp4-server

echo "Configuration terminée. Le service Kea DHCP est actif sur l'interface $ifaceSelection."
