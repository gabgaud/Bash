#!/bin/bash

# Script d'installation et de configuration d'un serveur DNS avec BIND9
# Auteur : Gabriel Gaudreault
# Date : 8 mai 2025

# ============================================
# 1. Validation des fichiers /etc/hosts et /etc/hostname
# ============================================

hostname_fichier=$(cat /etc/hostname | tr -d " \t\n\r")
fqdn=$(hostname -f 2>/dev/null)

if ! grep -q "$fqdn" /etc/hosts; then
    echo "Le fichier /etc/hosts ne contient pas le FQDN : $fqdn"
    echo "Veuillez corriger /etc/hosts avant de poursuivre."
    exit 1
fi

echo "Nom d'hôte valide détecté : $fqdn"

# ============================================
# 2. Installation de BIND9
# ============================================

apt install -y bind9 bind9-utils bind9-doc

# ============================================
# 3. Désactivation du support IPv6 dans BIND9
# ============================================

sed -i 's/OPTIONS="/OPTIONS="-4 /' /etc/default/named

# ============================================
# 4. Configuration des redirecteurs DNS
# ============================================

while true; do
    read -p "Entrez l'adresse IP d'un ou plusieurs redirecteurs DNS (séparées par des points-virgules) : " redirecteurs
    if [[ "$redirecteurs" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(;[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$ ]]; then
        break
    else
        echo "Format invalide. Exemple : 8.8.8.8;1.1.1.1"
    fi
done

# ============================================
# 5. Configuration de la récursivité et des redirecteurs
# ============================================

interface=$(ip route | grep default | awk '{print $5}')
ip_cidr=$(ip -o -f inet addr show "$interface" | awk '{print $4}')
ip_address=${ip_cidr%%/*}
mask_bits=${ip_cidr##*/}

IFS=. read -r o1 o2 o3 o4 <<< "$ip_address"
mask=$(( 0xFFFFFFFF << (32 - mask_bits) & 0xFFFFFFFF ))
ip_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
network_int=$(( ip_int & mask ))

net1=$(( (network_int >> 24) & 0xFF ))
net2=$(( (network_int >> 16) & 0xFF ))
net3=$(( (network_int >> 8) & 0xFF ))
net4=$(( network_int & 0xFF ))

subnet="$net1.$net2.$net3.$net4/$mask_bits"

cat <<EOF > /etc/bind/named.conf.options
options {
    directory "/var/cache/bind";

    listen-on port 53 { any; };
    listen-on-v6 { none; };

    allow-query { localhost; $subnet; };
    allow-recursion { localhost; $subnet; };

    forwarders {
        ${redirecteurs//;/; };
    };

    dnssec-validation auto;
    auth-nxdomain no;
};
EOF

# ============================================
# 6-7. Création de zones de recherche directe
# ============================================

mkdir -p /etc/bind/zones

while true; do
    read -p "Souhaitez-vous créer une zone de recherche directe ? (oui/non) : " reponse_directe
    if [[ "$reponse_directe" == "non" ]]; then
        break
    elif [[ "$reponse_directe" == "oui" ]]; then
        read -p "Nom de domaine pour la zone (ex : gabriel.local) : " domaine
        read -p "Courriel du gestionnaire de la zone : " email
        email_bind=${email/@/.}
        read -p "Rafraîchissement (sec) : " refresh
        read -p "Retry (sec) : " retry
        read -p "Expire (sec) : " expire
        read -p "Negative Cache TTL (sec) : " ttl

        fqdn=$(hostname -f)
        ip_dns=$(hostname -I | awk '{print $1}')
        zone_file="/etc/bind/zones/db.${domaine}"

        cat <<EOF > "$zone_file"
;
; Fichier pour la zone $domaine
;
\$TTL    604800
@       IN      SOA     $fqdn. $email_bind. (
                        1         ; Serial
                        $refresh  ; Refresh
                        $retry    ; Retry
                        $expire   ; Expire
                        $ttl )    ; Negative Cache TTL

        IN      NS      $fqdn.
        IN      A       $ip_dns
${fqdn%%.*}   IN      A       $ip_dns
EOF

        while true; do
            read -p "Ajouter un enregistrement A ? (oui/non) : " ajout_a
            if [[ "$ajout_a" == "non" ]]; then
                break
            fi
            read -p "Nom d'hôte (ex : poste1) : " host
            read -p "Adresse IP : " ip
            echo "$host   IN   A   $ip" >> "$zone_file"
        done

        echo "zone \"$domaine\" {
    type master;
    file \"$zone_file\";
};" >> /etc/bind/named.conf.local

    fi
done

# ============================================
# 8-9. Création de zones de recherche inversée
# ============================================

while true; do
    read -p "Souhaitez-vous créer une zone de recherche inversée ? (oui/non) : " reponse_inverse
    if [[ "$reponse_inverse" == "non" ]]; then
        break
    elif [[ "$reponse_inverse" == "oui" ]]; then
        while true; do
            read -p "Sous-réseau pour la zone inverse (ex : 192.168.32.0/24) : " subnet
            if [[ "$subnet" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]]; then
                reverse_zone="${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}.in-addr.arpa"
                reverse_file="/etc/bind/zones/db.${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}"
                break
            else
                echo "Format invalide."
            fi
        done

        read -p "Courriel du gestionnaire de la zone : " email
        email_bind=${email/@/.}
        read -p "Rafraîchissement (sec) : " refresh
        read -p "Retry (sec) : " retry
        read -p "Expire (sec) : " expire
        read -p "Negative Cache TTL (sec) : " ttl

        fqdn=$(hostname -f)
        ip_dns=$(hostname -I | awk '{print $1}')

        cat <<EOF > "$reverse_file"
;
; Fichier pour la zone inverse $reverse_zone
;
\$TTL    604800
@       IN      SOA     $fqdn. $email_bind. (
                        1         ; Serial
                        $refresh  ; Refresh
                        $retry    ; Retry
                        $expire   ; Expire
                        $ttl )    ; Negative Cache TTL

        IN      NS      $fqdn.
EOF

        while true; do
            read -p "Ajouter un enregistrement PTR ? (oui/non) : " ajout_ptr
            if [[ "$ajout_ptr" == "non" ]]; then
                break
            fi
            read -p "Dernier octet de l'IP (ex : 101 pour 192.168.32.101) : " octet
            read -p "Nom complet (FQDN) : " fqdn_machine
            echo "$octet   IN   PTR   $fqdn_machine." >> "$reverse_file"
        done

        echo "zone \"$reverse_zone\" {
    type master;
    file \"$reverse_file\";
};" >> /etc/bind/named.conf.local

    fi
done

# ============================================
# 10. Configuration de systemd-resolved
# ============================================

read -p "Entrez le nom de domaine local pour ce serveur (ex: gabriel.local) : " nom_domaine

cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak

sed -i 's/^#*DNS=.*$/DNS=127.0.0.1/' /etc/systemd/resolved.conf
sed -i 's/^#*FallbackDNS=.*$/FallbackDNS=8.8.8.8/' /etc/systemd/resolved.conf
sed -i "s/^#*Domains=.*$/Domains=$nom_domaine/" /etc/systemd/resolved.conf

grep -q "^DNS=" /etc/systemd/resolved.conf || echo "DNS=127.0.0.1" >> /etc/systemd/resolved.conf
grep -q "^FallbackDNS=" /etc/systemd/resolved.conf || echo "FallbackDNS=8.8.8.8" >> /etc/systemd/resolved.conf
grep -q "^Domains=" /etc/systemd/resolved.conf || echo "Domains=$nom_domaine" >> /etc/systemd/resolved.conf

if grep -q "^#*DNSStubListener=" /etc/systemd/resolved.conf; then
    sed -i 's/^#*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
else
    echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
fi

systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# ============================================
# 11. Démarrage de BIND9
# ============================================

systemctl restart bind9
systemctl enable bind9

echo "Le serveur DNS est maintenant configuré et en service."
