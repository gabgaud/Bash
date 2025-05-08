#!/bin/bash

# Script pour l'installation et la configuration de BIND9
# Date : 8 mai 2025
# Auteur : Gabriel Gaudreault

# ===============================
# 1. Validation /etc/hosts et /etc/hostname
# ===============================

echo "Vérification de la configuration du nom d'hôte..."

# Lire le nom d'hôte actuel
hostname_fichier=$(cat /etc/hostname | tr -d " \t\n\r")
fqdn=$(hostname -f 2>/dev/null)

if ! grep -q "$fqdn" /etc/hosts; then
    echo "Le fichier /etc/hosts ne contient pas le FQDN : $fqdn"
    echo "Veuillez corriger /etc/hosts avant de poursuivre."
    exit 1
fi

echo "Nom d'hôte valide détecté : $fqdn"

# ===============================
# 2. Installation de Bind9
# ===============================

echo "Installation de BIND9..."
apt install -y bind9 bind9-utils bind9-doc

# ===============================
# 3. Désactivation de l'IPv6 dans Bind9
# ===============================

echo "Suppression du support IPv6 dans BIND9..."

# Modifier les options de lancement de named
sed -i 's/OPTIONS=\"/OPTIONS=\"-4 /' /etc/default/named

# ===============================
# 4. Demande des redirecteurs DNS
# ===============================

while true; do
    read -p "Entrez l'adresse IP d'un ou plusieurs redirecteurs DNS (séparés par des points-virgules) : " redirecteurs
    if [[ "$redirecteurs" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(;[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$ ]]; then
        break
    else
        echo "Format invalide. Exemple : 8.8.8.8;1.1.1.1"
    fi
done

# ===============================
# 5. Configuration de la récursivité et des redirecteurs
# ===============================

echo "Détection automatique du sous-réseau..."

# Trouver l'interface active (celle qui a la route par défaut)
interface=$(ip route | grep default | awk '{print $5}')

# Obtenir l'adresse IP et le masque CIDR de cette interface
subnet=$(ip -o -f inet addr show "$interface" | awk '{print $4}')

echo "Interface active : $interface"
echo "Sous-réseau détecté : $subnet"

echo "Configuration du fichier /etc/bind/named.conf.options..."

cat <<EOF > /etc/bind/named.conf.options
options {
    directory "/var/cache/bind";

    // Activer uniquement IPv4
    listen-on port 53 { any; };
    listen-on-v6 { none; };

    allow-query { localhost; $subnet; };
    allow-recursion { localhost; $subnet; };

    forwarders {
        ${redirecteurs//;/; };
    };

    dnssec-validation auto;
    auth-nxdomain no;
    listen-on port 53 { any; };
};
EOF

echo "Configuration de base avec sous-réseau local terminée."

# ===============================
# 6-7. Création de zones de recherche directe
# ===============================

while true; do
    read -p "Souhaitez-vous créer une zone de recherche directe ? (oui/non) : " reponse_directe
    if [[ "$reponse_directe" == "non" ]]; then
        break
    elif [[ "$reponse_directe" == "oui" ]]; then

        # 7a - Nom de domaine
        read -p "Entrez le nom de domaine pour la zone (ex : gabriel.local) : " domaine

        # 7b - Informations pour l'entrée SOA
        read -p "Courriel du gestionnaire de la zone (format admin@example.com) : " email
        email_bind=${email/@/.}  # format BIND : admin.example.com.
        read -p "Valeur de rafraîchissement (en secondes) : " refresh
        read -p "Valeur de retry (en secondes) : " retry
        read -p "Valeur d'expiration (en secondes) : " expire
        read -p "Valeur de negative cache TTL (en secondes) : " ttl

        # 7c - FQDN du serveur DNS (autorité)
        fqdn=$(hostname -f)
        ip_dns=$(hostname -I | awk '{print $1}')

        zone_file="/etc/bind/db.${domaine//./_}"

        echo "Création de la zone : $domaine"

        # 7d et 7e - Génération du fichier de zone
        cat <<EOF > "$zone_file"
\$TTL    86400
@   IN  SOA $fqdn. $email_bind. (
        1         ; Serial
        $refresh  ; Refresh
        $retry    ; Retry
        $expire   ; Expire
        $ttl      ; Negative Cache TTL
)
    IN  NS  $fqdn.
@   IN  A   $ip_dns
EOF

        # 7f - Boucle pour les enregistrements A
        while true; do
            read -p "Ajouter un enregistrement A ? (oui/non) : " ajout_a
            if [[ "$ajout_a" == "non" ]]; then
                break
            elif [[ "$ajout_a" == "oui" ]]; then
                read -p "Nom de l'hôte (ex : poste1) : " host
                read -p "Adresse IP correspondante : " ip
                echo "$host   IN   A   $ip" >> "$zone_file"
            fi
        done

        # Ajout de la zone dans named.conf.local
        echo "zone \"$domaine\" {
    type master;
    file \"$zone_file\";
};" >> /etc/bind/named.conf.local

        echo "Zone $domaine ajoutée avec succès."

    else
        echo "Veuillez répondre par oui ou non."
    fi
done

# ===============================
# 8-9. Création de zones de recherche inversée
# ===============================

while true; do
    read -p "Souhaitez-vous créer une zone de recherche inversée ? (oui/non) : " reponse_inverse
    if [[ "$reponse_inverse" == "non" ]]; then
        break
    elif [[ "$reponse_inverse" == "oui" ]]; then

        # 9a - Nom du sous-réseau pour la zone (ex : 192.168.21.0/24)
        while true; do
            read -p "Entrez le sous-réseau pour la zone inverse (ex : 192.168.21.0/24) : " subnet
            if [[ "$subnet" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0\/24$ ]]; then
                subnet_prefix="${BASH_REMATCH[1]}"
                reverse_zone="$(echo $subnet_prefix | awk -F. '{print $3"."$2"."$1}').in-addr.arpa"
                break
            else
                echo "Format invalide. Veuillez entrer un sous-réseau de type 192.168.21.0/24"
            fi
        done

        # 9b - Informations pour l'entrée SOA
        read -p "Courriel du gestionnaire de la zone (format admin@example.com) : " email
        email_bind=${email/@/.}
        read -p "Valeur de rafraîchissement (en secondes) : " refresh
        read -p "Valeur de retry (en secondes) : " retry
        read -p "Valeur d'expiration (en secondes) : " expire
        read -p "Valeur de negative cache TTL (en secondes) : " ttl

        # 9c - FQDN du serveur DNS (autorité)
        fqdn=$(hostname -f)
        ip_dns=$(hostname -I | awk '{print $1}')

        reverse_file="/etc/bind/db.${reverse_zone//./_}"

        echo "Création de la zone inverse : $reverse_zone"

        # 9d, 9e - Génération du fichier de zone inverse
        cat <<EOF > "$reverse_file"
\$TTL    86400
@   IN  SOA $fqdn. $email_bind. (
        1         ; Serial
        $refresh  ; Refresh
        $retry    ; Retry
        $expire   ; Expire
        $ttl      ; Negative Cache TTL
)
    IN  NS  $fqdn.
EOF

        # 9f - Boucle pour les enregistrements PTR
        while true; do
            read -p "Ajouter un enregistrement PTR ? (oui/non) : " ajout_ptr
            if [[ "$ajout_ptr" == "non" ]]; then
                break
            elif [[ "$ajout_ptr" == "oui" ]]; then
                read -p "Dernet octet de l'IP (ex : 101 pour 192.168.21.101) : " octet
                read -p "Nom complet de la machine (FQDN) : " fqdn_machine
                echo "$octet   IN   PTR   $fqdn_machine." >> "$reverse_file"
            fi
        done

        # Ajout de la zone inverse dans named.conf.local
        echo "zone \"$reverse_zone\" {
    type master;
    file \"$reverse_file\";
};" >> /etc/bind/named.conf.local

        echo "Zone inverse $reverse_zone ajoutée avec succès."

    else
        echo "Veuillez répondre par oui ou non."
    fi
done

# ===============================
# 10. Configuration de systemd-resolved (sans Netplan)
# ===============================

echo "Configuration de systemd-resolved..."

# Sauvegarde du fichier
cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak

# Demander le nom de domaine pour le champ 'domains'
read -p "Entrez le nom de domaine local pour ce serveur (ex: gabriel.local) : " nom_domaine

# Modifier ou ajouter les entrées nécessaires dans resolved.conf
sed -i 's/^#*DNS=.*$/DNS=127.0.0.1/' /etc/systemd/resolved.conf
sed -i 's/^#*FallbackDNS=.*$/FallbackDNS=8.8.8.8/' /etc/systemd/resolved.conf
sed -i "s/^#*Domains=.*$/Domains=$nom_domaine/" /etc/systemd/resolved.conf

# Si DNS= ou FallbackDNS= ou Domains= n'existent pas, on les ajoute
grep -q "^DNS=" /etc/systemd/resolved.conf || echo "DNS=127.0.0.1" >> /etc/systemd/resolved.conf
grep -q "^FallbackDNS=" /etc/systemd/resolved.conf || echo "FallbackDNS=8.8.8.8" >> /etc/systemd/resolved.conf
grep -q "^Domains=" /etc/systemd/resolved.conf || echo "Domains=$nom_domaine" >> /etc/systemd/resolved.conf

# Désactiver le DNSStubListener pour libérer le port 53
if grep -q "^#*DNSStubListener=" /etc/systemd/resolved.conf; then
    sed -i 's/^#*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
else
    echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
fi

# Redémarrage du service
systemctl restart systemd-resolved

# S'assurer que /etc/resolv.conf pointe vers la bonne version
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

echo "systemd-resolved a été configuré avec succès :
  - DNS principal : 127.0.0.1
  - DNS secondaire : 8.8.8.8
  - Domaine : $nom_domaine
  - DNSStubListener désactivé"

# ===============================
# 11. Démarrage de BIND9 et test
# ===============================

echo "Démarrage de BIND9..."
systemctl restart bind9
systemctl enable bind9

echo "Test de résolution locale (si une zone a été créée)..."
dig gabriel.local @127.0.0.1 | grep -A1 "ANSWER SECTION"

echo "Le serveur DNS BIND9 est maintenant actif et configuré pour le système local."
