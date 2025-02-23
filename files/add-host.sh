#! /bin/bash
# version: 1.5.0

# nginx 1.19.4+ required
# openssl 1.1.1+ required

# make sure that DNS record is pointing to the server

# for manual installation without ansible you need to install the following packages:
# openssl python3-certbot-nginx python3-certbot python3-acme python3-zope.interface

# examples (interractive):
# ./add-host.sh

# examples (with predefined values):
# ./add-host.sh -h test.com
# ./add-host.sh -h test.com -t localhost:8080
# ./add-host.sh -h test.com -e www.test.com
# ./add-host.sh -h test.com -e www.test.com -t localhost:8080

set -o pipefail

while getopts "h:e:t:" option; do
  case "${option}" in
  h) DEFAULT_HOSTNAME=${OPTARG} ;;
  e) EXTRA_HOSTNAME=${OPTARG} ;;
  t) TARGET=${OPTARG} ;;
  esac
done

CONF_DIR_PATH="/etc/nginx/conf.d"

SNIPPETS_DIR_PATH="/etc/nginx/snippets"
GENERAL_CONFIG_PATH="$SNIPPETS_DIR_PATH/general.conf"
HTTPS_CONFIG_PATH="$SNIPPETS_DIR_PATH/https.conf"
LETSENCRYPT_CONFIG_PATH="$SNIPPETS_DIR_PATH/letsencrypt.conf"
SECURITY_CONFIG_PATH="$SNIPPETS_DIR_PATH/security.conf"
PROXY_CONFIG_PATH="$SNIPPETS_DIR_PATH/proxy.conf"

function print_success() {
  printf '%s# %s%s\n' "$(printf '\033[32m')" "$*" "$(printf '\033[m')" >&2
}

function print_warning() {
  printf '%sWARNING: %s%s\n' "$(printf '\033[31m')" "$*" "$(printf '\033[m')" >&2
}

function print_error() {
  printf '%sERROR: %s%s\n' "$(printf '\033[31m')" "$*" "$(printf '\033[m')" >&2
  exit 1
}

function get_input() {
  [[ $ZSH_VERSION ]] && read "$2"\?"$1"
  [[ $BASH_VERSION ]] && read -p "$1" "$2"
}

function get_keypress() {
  local REPLY IFS=
  printf >/dev/tty '%s' "$*"
  [[ $ZSH_VERSION ]] && read -rk1
  [[ $BASH_VERSION ]] && read </dev/tty -rn1
  printf '%s' "$REPLY"
}

function confirm() {
  local prompt="${1:-Are you sure?} [y/n] "
  local enter_return=$2
  local REPLY
  while REPLY=$(get_keypress "$prompt"); do
    [[ $REPLY ]] && printf '\n'
    case "$REPLY" in
    Y | y) return 0 ;;
    N | n) return 1 ;;
    '') [[ $enter_return ]] && return "$enter_return" ;;
    esac
  done
}

function check_dns() {
  local DNS_RECORD_HOST="$1"
  local EXTERNAL_IP=$(curl -4 -s ident.me)
  local DNS_RECORD_IP=$(dig +short "$DNS_RECORD_HOST")

  if [[ "$DNS_RECORD_IP" =~ ^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$ ]]; then
    if [ "$EXTERNAL_IP" = "$DNS_RECORD_IP" ]; then
      print_success "DNS record $DNS_RECORD_HOST is pointing to $DNS_RECORD_IP."
    else
      print_error "DNS record $DNS_RECORD_HOST is not pointing to $EXTERNAL_IP. It currently resolves to $DNS_RECORD_IP."
    fi
  else
    print_error "Cannot resolve DNS record $DNS_RECORD_HOST"
  fi
}

function generate_general_config() {
  mkdir -p $SNIPPETS_DIR_PATH

  echo '# favicon.ico
    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    # robots.txt
    location = /robots.txt {
        log_not_found off;
        access_log off;
    }

    # gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
    ' | sed 's/^[ \t]*//' >$GENERAL_CONFIG_PATH
}

function generate_https_config() {
  local CERTS_DIR_PATH="/etc/ssl/certs"
  local DH_PARAM_PATH="$CERTS_DIR_PATH/dhparam.pem"
  local DH_PARAM_SIZE="2048"

  mkdir -p $CERTS_DIR_PATH
  mkdir -p $SNIPPETS_DIR_PATH

  [ ! -r "$DH_PARAM_PATH" ] && openssl dhparam -out $DH_PARAM_PATH $DH_PARAM_SIZE

  echo "ssl_protocols TLSv1.3 TLSv1.2;
    ssl_dhparam $DH_PARAM_PATH;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_ecdh_curve secp384r1;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_session_timeout 1d;
    ssl_stapling on;
    ssl_stapling_verify on;

    resolver 1.1.1.1 8.8.8.8 valid=60s;
    resolver_timeout 2s;
    " | sed 's/^[ \t]*//' >$HTTPS_CONFIG_PATH
}

function generate_letsencrypt_config() {
  mkdir -p $SNIPPETS_DIR_PATH

  echo '# ACME-challenge
    location ^~ /.well-known/acme-challenge/ {
    root /var/www/_letsencrypt;
    }
    ' | sed 's/^[ \t]*//' >$LETSENCRYPT_CONFIG_PATH
}

function generate_security_config() {
  mkdir -p $SNIPPETS_DIR_PATH

  echo 'proxy_hide_header X-Powered-By;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header Permissions-Policy "interest-cohort=()" always;

    location ~ /\.(?!well-known) {
        deny all;
    }
    ' | sed 's/^[ \t]*//' >$SECURITY_CONFIG_PATH
}

function generate_proxy_config() {
  mkdir -p $SNIPPETS_DIR_PATH

  echo 'proxy_http_version 1.1;

    # Cache
    proxy_cache_bypass $http_upgrade;
    proxy_cache_valid any 10m;
    proxy_cache default;
    proxy_set_header X-Proxy-Cache $upstream_cache_status;

    # Proxy headers
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Forwarded $proxy_add_forwarded;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;

    # Proxy timeouts
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    ' | sed 's/^[ \t]*//' >$PROXY_CONFIG_PATH
}

if [ ! -d "$CONF_DIR_PATH" ]; then
  print_error "Directory for configs does not exist: $CONF_DIR_PATH"
fi

if [[ "$DEFAULT_HOSTNAME" == "" ]]; then
  get_input "Hostname: " DEFAULT_HOSTNAME
  [ "${DEFAULT_HOSTNAME//[A-Za-z0-9._-]/}" ] && print_error "Valid characters for 'Hostname' value are 'A-Z', 'a-z', '0-9' and '._-'"
  get_input "Extra hostname ['Enter' to skip]: " EXTRA_HOSTNAME
  [ "${EXTRA_HOSTNAME//[A-Za-z0-9._-]/}" ] && print_error "Valid characters for 'Extra hostname' value are 'A-Z', 'a-z', '0-9', and '._-'"
  get_input "Target ['Enter' to skip]: " TARGET
  [ "${TARGET//[A-Za-z0-9:._-]/}" ] && print_error "Valid characters for 'Target' value are 'A-Z', 'a-z', '0-9' and '._-:'"
fi

if [[ $DEFAULT_HOSTNAME == *"http://"* ]] || [[ $DEFAULT_HOSTNAME == *"https://"* ]]; then
  print_error "Do not use 'http://' or 'https://' for 'Hostname' variable"
fi

if [[ $EXTRA_HOSTNAME == *"http://"* ]] || [[ $EXTRA_HOSTNAME == *"https://"* ]]; then
  print_error "Do not use 'http://' or 'https://' for 'Extra hostname' variable"
fi

if [[ $TARGET == *"http://"* ]] || [[ $TARGET == *"https://"* ]]; then
  print_error "Do not use 'http://' or 'https://' for 'Target' variable"
fi

CONF_FILE_PATH="$CONF_DIR_PATH/$DEFAULT_HOSTNAME.conf"

if [ -r "$CONF_FILE_PATH" ]; then
  print_warning "File already exist: $CONF_FILE_PATH"
  confirm "Whether to replace config file?" && rm -rf $CONF_FILE_PATH || print_error "exit"
fi

if [ ! -r "$GENERAL_CONFIG_PATH" ]; then
  print_warning "File does not exist: $GENERAL_CONFIG_PATH"
  confirm "Whether to generate required general config file?" && generate_general_config || print_error "exit"
fi

if [ ! -r "$HTTPS_CONFIG_PATH" ]; then
  print_warning "File does not exist: $HTTPS_CONFIG_PATH"
  confirm "Whether to generate required HTTPS config file?" && generate_https_config || print_error "exit"
fi

if [ ! -r "$LETSENCRYPT_CONFIG_PATH" ]; then
  print_warning "File does not exist: $LETSENCRYPT_CONFIG_PATH"
  confirm "Whether to generate required letsencrypt config file?" && generate_letsencrypt_config || print_error "exit"
fi

if [ ! -r "$SECURITY_CONFIG_PATH" ]; then
  print_warning "File does not exist: $SECURITY_CONFIG_PATH"
  confirm "Whether to generate required security config file?" && generate_security_config || print_error "exit"
fi

if [ ! -r "$PROXY_CONFIG_PATH" ]; then
  print_warning "File does not exist: $PROXY_CONFIG_PATH"
  confirm "Whether to generate required proxy config file?" && generate_proxy_config || print_error "exit"
fi

if [[ "$EXTRA_HOSTNAME" == "" ]]; then
  check_dns "$DEFAULT_HOSTNAME"
  NGINX_HOSTNAME="$DEFAULT_HOSTNAME"
else
  check_dns "$DEFAULT_HOSTNAME"
  check_dns "$EXTRA_HOSTNAME"
  NGINX_HOSTNAME="$DEFAULT_HOSTNAME $EXTRA_HOSTNAME"
fi

echo 'server {
    listen 80;
    listen [::]:80;

    server_name NGINX_HOSTNAME;

    location / {
        try_files $uri $uri/ =403;
    }
}
' >$CONF_FILE_PATH

sed -i "s,NGINX_HOSTNAME,$NGINX_HOSTNAME,g" $CONF_FILE_PATH

if nginx -t 2>/dev/null; then
  nginx -s reload 2>/dev/null
else
  rm -rf $CONF_FILE_PATH
  nginx -s reload 2>/dev/null
  print_error "Something wrong with config"
fi

if [ -z "$EXTRA_HOSTNAME" ]; then
  certbot --agree-tos --no-eff-email --authenticator nginx --installer null --keep-until-expiring \
    --register-unsafely-without-email -d $DEFAULT_HOSTNAME
else
  certbot --agree-tos --no-eff-email --authenticator nginx --installer null --keep-until-expiring \
    --register-unsafely-without-email -d $DEFAULT_HOSTNAME -d $EXTRA_HOSTNAME
fi

echo 'server {
    listen 80;
    listen [::]:80;

    server_name NGINX_HOSTNAME;

    include LETSENCRYPT_CONFIG_PATH;

    return 301 https://$host$request_uri;

}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name NGINX_HOSTNAME;

    include GENERAL_CONFIG_PATH;
    include HTTPS_CONFIG_PATH;
    include SECURITY_CONFIG_PATH;

    ssl_certificate /etc/letsencrypt/live/DEFAULT_HOSTNAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DEFAULT_HOSTNAME/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/DEFAULT_HOSTNAME/chain.pem;

    location / {
        include PROXY_CONFIG_PATH;
        proxy_pass http://TARGET;
    }
}
' >$CONF_FILE_PATH

sed -i "s,NGINX_HOSTNAME,$NGINX_HOSTNAME,g" $CONF_FILE_PATH
sed -i "s,DEFAULT_HOSTNAME,$DEFAULT_HOSTNAME,g" $CONF_FILE_PATH
sed -i "s,GENERAL_CONFIG_PATH,$GENERAL_CONFIG_PATH,g" $CONF_FILE_PATH
sed -i "s,LETSENCRYPT_CONFIG_PATH,$LETSENCRYPT_CONFIG_PATH,g" $CONF_FILE_PATH
sed -i "s,HTTPS_CONFIG_PATH,$HTTPS_CONFIG_PATH,g" $CONF_FILE_PATH
sed -i "s,SECURITY_CONFIG_PATH,$SECURITY_CONFIG_PATH,g" $CONF_FILE_PATH
sed -i "s,PROXY_CONFIG_PATH,$PROXY_CONFIG_PATH,g" $CONF_FILE_PATH

if [ -z "$TARGET" ]; then
  sed -i "s,proxy_pass http://TARGET,return 403,g" $CONF_FILE_PATH
else
  sed -i "s,TARGET,$TARGET,g" $CONF_FILE_PATH
fi

if nginx -t 2>/dev/null; then
  nginx -s reload 2>/dev/null
else
  rm -rf $CONF_FILE_PATH
  nginx -s reload 2>/dev/null
  print_error "Something wrong with config"
fi

print_success "Config file path: $CONF_FILE_PATH"
print_success "Hostname: https://$DEFAULT_HOSTNAME"

if [ ! -z "$EXTRA_HOSTNAME" ]; then
  print_success "Hostname: https://$EXTRA_HOSTNAME"
fi
