#!/bin/bash
# ============================================================
# Roundcube RCE Lab — Complete Setup Script
# CVE-2016-9920 | Ubuntu 22.04 Jammy
# Run as: root
# Source: pulled from GitLab repo by CALDERA ability
# ============================================================

set -e

GITLAB_RAW="https://raw.githubusercontent.com/hacktifytechnologies/Range1-VM4/main"
LOG="/var/log/roundcube_lab_setup.log"
exec > >(tee -a "$LOG") 2>&1

echo "============================================"
echo " Roundcube RCE Lab Setup Starting"
echo " $(date)"
echo "============================================"

# ── STEP 1: System Preparation ─────────────────
echo "[1/7] System preparation..."
hostnamectl set-hostname mail.roundcube.lab
grep -q "mail.roundcube.lab" /etc/hosts || \
  echo "127.0.0.1  mail.roundcube.lab mail" >> /etc/hosts

export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q

apt-get install -y -q software-properties-common curl wget git \
  unzip net-tools mariadb-server dovecot-imapd dovecot-pop3d \
  apache2 sendmail sendmail-bin procmail m4 make

# Add Ondrej PPA for PHP 7.4
add-apt-repository ppa:ondrej/php -y
apt-get update -y -q

apt-get install -y -q php7.4 php7.4-cli php7.4-mysql php7.4-xml \
  php7.4-mbstring php7.4-intl php7.4-zip php7.4-json \
  php7.4-gd libapache2-mod-php7.4

# Switch Apache to PHP 7.4
a2dismod php8.1 2>/dev/null || true
a2enmod php7.4
a2enmod rewrite
echo "[1/7] Done."

# ── STEP 2: Configure MariaDB ──────────────────
echo "[2/7] Configuring MariaDB..."
systemctl start mariadb
systemctl enable mariadb

mysql -u root << 'SQLEOF'
DROP DATABASE IF EXISTS roundcubedb;
CREATE DATABASE roundcubedb CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER IF NOT EXISTS 'roundcube'@'localhost' IDENTIFIED BY 'roundcube123!';
GRANT ALL PRIVILEGES ON roundcubedb.* TO 'roundcube'@'localhost';
FLUSH PRIVILEGES;
SQLEOF
echo "[2/7] Done."

# ── STEP 3: Configure Dovecot ─────────────────
echo "[3/7] Configuring Dovecot..."
sed -i 's|#mail_location =.*|mail_location = maildir:~/Maildir|' \
  /etc/dovecot/conf.d/10-mail.conf

cat > /etc/dovecot/conf.d/10-auth.conf << 'EOF'
auth_mechanisms = plain login
!include auth-system.conf.ext
EOF

# Full master.conf required by Dovecot 2.x on Ubuntu 22.04
# NOTE: Postfix unix_listener removed — this lab uses Sendmail, postfix user does not exist
cat > /etc/dovecot/conf.d/10-master.conf << 'EOF'
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}

service lmtp {
  unix_listener lmtp {
    #mode = 0666
  }
}

service imap {
  #vsz_limit = $default_vsz_limit
  #process_limit = 1024
}

service pop3 {
  #process_limit = 1024
}

service submission-login {
  inet_listener submission {
    port = 587
  }
}

service auth {
  unix_listener auth-userdb {
    #mode = 0600
    #user =
    #group =
  }
  #user = $default_internal_user
}

service auth-worker {
  user = root
}

service dict {
  unix_listener dict {
    #mode = 0600
    #user =
    #group =
  }
}
EOF

systemctl restart dovecot
systemctl enable dovecot
echo "[3/7] Done."

# ── STEP 4: Create Lab User ───────────────────
echo "[4/7] Creating lab user..."
id labuser &>/dev/null || useradd -m -s /bin/bash labuser
echo "labuser:labuser" | chpasswd
mkdir -p /home/labuser/Maildir/{new,cur,tmp}
chown -R labuser:labuser /home/labuser/Maildir
chmod -R 700 /home/labuser/Maildir
echo "[4/7] Done."

# ── STEP 5: Install Roundcube 1.2.2 ──────────
echo "[5/7] Installing Roundcube 1.2.2..."
rm -rf /var/www/html/roundcube
rm -f /var/www/html/roundcubemail-*.tar.gz

cd /var/www/html

# Download raw tarball directly from GitHub raw content URL
echo "[5/7] Fetching tarball from GitHub..."
wget -q "${GITLAB_RAW}/resources/roundcubemail-1.2.2-complete.tar.gz" \
  -O roundcubemail-1.2.2-complete.tar.gz

tar xf roundcubemail-1.2.2-complete.tar.gz
mv roundcubemail-1.2.2 roundcube
rm -f roundcubemail-1.2.2-complete.tar.gz

# Import DB schema
mysql -u roundcube -proundcube123! roundcubedb < \
  /var/www/html/roundcube/SQL/mysql.initial.sql

# Download config from GitHub
wget -q "${GITLAB_RAW}/configs/roundcube_config.inc.php" \
  -O /var/www/html/roundcube/config/config.inc.php

echo "[5/7] Done."

# ── STEP 6: Configure Apache ──────────────────
echo "[6/7] Configuring Apache..."

# Download Apache vhost config from GitHub
wget -q "${GITLAB_RAW}/configs/roundcube_apache.conf" \
  -O /etc/apache2/sites-available/roundcube.conf

a2ensite roundcube.conf
a2dissite 000-default.conf 2>/dev/null || true

# CRITICAL: smmsp group allows sendmail -X to write to webroot
chown -R www-data:smmsp /var/www/html/roundcube
chmod -R 775 /var/www/html/roundcube
chmod g+s /var/www/html/roundcube

systemctl restart apache2
systemctl enable apache2
echo "[6/7] Done."

# ── STEP 7: Plant Flag & Sensitive Files ──────
echo "[7/7] Planting flags and artifacts..."

# CTF flag
echo "FLAG{r0undcub3_rce_s3ndm4il_1nj3ct10n}" > /var/www/flag.txt
chown www-data:www-data /var/www/flag.txt
chmod 640 /var/www/flag.txt

# Fake secrets for blue team discovery
mkdir -p /opt/corpmail
cat > /opt/corpmail/.env << 'EOF'
DB_HOST=localhost
DB_USER=roundcube
DB_PASS=roundcube123!
API_KEY=sk-prod-a8f3d2e1b9c4f7e2
SMTP_USER=noreply@corp.lab
SMTP_PASS=SmtpP@ss2024
EOF
chown www-data:www-data /opt/corpmail/.env
chmod 600 /opt/corpmail/.env
echo "[7/7] Done."

# ── Final Verification ────────────────────────
echo ""
echo "============================================"
echo " VERIFICATION"
echo "============================================"
echo -n " Apache:    "; systemctl is-active apache2
echo -n " Dovecot:   "; systemctl is-active dovecot
echo -n " MariaDB:   "; systemctl is-active mariadb
echo -n " Sendmail:  "; systemctl is-active sendmail
echo -n " HTTP:      "; curl -s -o /dev/null -w "%{http_code}" http://localhost/; echo
echo -n " Version:   "
grep 'RCMAIL_VERSION' /var/www/html/roundcube/program/include/iniset.php | \
  grep -o "'[^']*'" | head -1
echo -n " Flag:      "; ls /var/www/flag.txt
echo -n " smmsp:     "
sudo -u smmsp touch /var/www/html/roundcube/.test 2>/dev/null && \
  rm /var/www/html/roundcube/.test && echo "WRITE OK" || echo "WRITE FAIL"
echo ""
echo "============================================"
echo " SETUP COMPLETE — LAB READY"
echo "============================================"
