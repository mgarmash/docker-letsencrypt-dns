#!/bin/sh

echo "Launch renew test"
certbot renew -n --deploy-hook deploy-hook.sh  --server https://acme-v02.api.letsencrypt.org/directory
