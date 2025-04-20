#!/bin/bash

# Script pour la création d'un contrôleur de domaine principal avec Samba
# Date: 19 avril 2025
# Auteur : Gabriel Gaudreault

# Définition d'une variable contenant le chemin vers un fichier de checkpoint
CHECKPOINT_FILE="/etc/scripts/pdc_checkpoint.txt"

# Fonction pour sauver l'état du script
save_checkpoint() {
        echo "$1" > "$CHECKPOINT_FILE"
}

# Fonction pour récupérer l'état du script
get_checkpoint() {
        if [[ -f "$CHECKPOINT_FILE" ]]; then
                cat "$CHECKPOINT_FILE"
        else
                echo "O"
        fi
}

STEP=$(get_checkpoint)

#Étape 1
if [[ "$STEP" -lt 1 ]]; then
        echo -n "Ce script nécessite une adresse IP statique (DHCP ou manuelle). Veuillez-vous en assurez avant de continuer. Continuer ? (o/n) :"
	read ready
        if [[ $ready == 'o' ]]; then

        #Obtenir l'adresse IP du serveur
        IPAddr=$(hostname -I)

        #Obtenir le nom de domaine utilisé
        echo -n "Quel sera le nom de domaine utilisé ? (exemple.local) :"
        read DomainName

        #Édition du fichier /etc/hosts
        sed -i '2d' /etc/hosts
        awk -v ip="$IPAddr" -v domain="$DomainName" '
                /localhost/ && !done {
                        print $0
                        print ip " dc1." domain " dc1"
                        done=1
                        next
                }
                { print $0 }

        ' /etc/hosts > /tmp/hosts && mv /tmp/hosts /etc/hosts

        #Édition du fichier /etc/hostname
        echo 'dc1' > /etc/hostname
        save_checkpoint 1

        #Redémarrage requis
        echo -n "La première étape du script est terminé. Relancez celui-ci après le redémarrage du serveur. Appuyez sur une touche..."
        read -n 1 -s
        sleep 3 && reboot now
        else
                exit
        fi
        exit 0;
fi

#Étape 2
if [[ "$STEP" -lt 2 ]]; then
        #Désactivation du résolveur DNS intégré à Ubuntu
        systemctl disable systemd-resolved
        unlink /etc/resolv.conf

        #Création d'un nouveau fichier /etc/resolv.conf qui sera utilisé pour le résolveur de Samba
	IPAddr=$(hostname -I)
	DomainName=$(grep -Po 'dc1\.\K\S+' /etc/hosts)
	KerberosRealm="${DomainName^^}"
        echo "nameserver $IPAddr" > /etc/resolv.conf
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        echo "search $DomainName" >> /etc/resolv.conf

        #Préparation du fichier /etc/krb5.conf
        KrbConf="/etc/krb5.conf"
        echo "[libdefaults]" > $KrbConf
        sed -i "1a\\\tdefault_realm = $KerberosRealm" $KrbConf
        sed -i "2a\\\tdns_lookup_kdc = true" $KrbConf
        sed -i "3a\\\tdns_lookup_realm = false" $KrbConf
        sed -i '/false/G' $KrbConf
        sed -i "5a\[realms]" $KrbConf
        sed -i "6a\\\t$KerberosRealm = {" $KrbConf
        sed -i "7a\\\t\\tkdc = dc1.$DomainName" $KrbConf
        sed -i "8a\\\t\\tadmin_server = dc1.$DomainName" $KrbConf
        sed -i "9a\\\t}" $KrbConf
        sed -i '/}/G' $KrbConf
        sed -i "11a\[domain_realm]" $KrbConf
        sed -i "12a\\\t.$DomainName = $KerberosRealm" $KrbConf
        sed -i "13a\\\t$DomainName = $KerberosRealm" $KrbConf

        # Préparation des réponses pour krb5-user
        debconf-set-selections <<< "krb5-config krb5-config/default_realm string $KerberosRealm"
        debconf-set-selections <<< "krb5-config krb5-config/admin_server string dc1.$DomainName"
        debconf-set-selections <<< "krb5-config krb5-config/kdc_server string dc1.$DomainName"


        #Installation des paquets
        apt install samba winbind libnss-winbind krb5-user smbclient ldb-tools python3-cryptography -y

        #Désactivation de la configuration de samba par défaut
        mv /etc/samba/smb.conf /etc/samba/smb.conf.original

        #Arrêt des services en lien avec le serveur de fichiers Samba
        systemctl stop samba winbind nmbd smbd

        #Promotion du serveur en contrôleur de domaine
        DomainNetbios="${DomainName%%.*}"
        DomainNetbios=$(echo "$DomainNetbios" | tr 'a-z' 'A-Z')
        samba-tool domain provision --realm=$KerberosRealm --domain=$DomainNetbios --server-role=dc

        #Définition du mot de passe Administrateur
        samba-tool user setpassword administrator --newpassword=Passw0rd

	#Définition du redirecteur dans smb.conf
	sed -i -e "s/$IPAddr/8.8.8.8/g" /etc/samba/smb.conf
fi
