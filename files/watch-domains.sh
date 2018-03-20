#!/bin/sh

staging_cmd=""
if [ "$LETSENCRYPT_STAGING" = true ]; then
    staging_cmd="--staging"
fi

current_hash=
while true; do
    # Calculate the new domains.conf file hash
    new_hash=`md5sum /etc/letsencrypt/domains.conf | awk '{ print $1 }'`
    if [ "$current_hash" != "$new_hash" ]; then
        # Clean all autorestart/autocmd containers instances
        rm -f /etc/supervisord.d/*_autorestart-containers
	rm -f /etc/supervisord.d/*_autocmd-containers

        echo "#### Registering Let's Encrypt account if needed ####"
        certbot register -n --agree-tos -m $LETSENCRYPT_USER_MAIL $staging_cmd --server https://acme-v02.api.letsencrypt.org/directory

        echo "#### Creating missing certificates if needed (~1min for each) ####"
        while read -r entry; do
	    autorestart_config=`echo $entry | grep -E -o 'autorestart-containers=.*' | sed 's/autocmd-containers=.*//' | sed 's/autorestart-containers=//' | xargs`
	    autocmd_config=`echo $entry | grep -E -o 'autocmd-containers=.*' | sed 's/autorestart-containers=.*//' | sed 's/autocmd-containers=//' | xargs`
	    clean_domains=`echo $entry | sed 's/autorestart-containers=.*//' | sed 's/autocmd-containers=.*//' | xargs`
            domains_cmd=""
            main_domain=""

	    for domain in $clean_domains; do
		if [ -z $main_domain ]; then
		    main_domain=$domain
		fi
		domains_cmd="$domains_cmd -d $domain"
	    done

            echo ">>> Creating a certificate for domain(s):$domains_cmd"
            certbot certonly \
                -n \
                --manual \
                --preferred-challenges=dns-01 \
                --manual-auth-hook /var/lib/letsencrypt/hooks/authenticator.sh \
                --manual-cleanup-hook /var/lib/letsencrypt/hooks/cleanup.sh \
                --manual-public-ip-logging-ok \
                --expand \
                --deploy-hook deploy-hook.sh \
                --server https://acme-v02.api.letsencrypt.org/directory \
		$staging_cmd \
                $domains_cmd

            if [ "$autorestart_config" != "" ]; then
                echo ">>> Watching certificate for main domain $main_domain: containers $autorestart_config autorestarted when certificate is changed."
                echo "[program:${main_domain}_autorestart-containers]" >> /etc/supervisord.d/${main_domain}_autorestart-containers
                echo "command = /scripts/autorestart-containers.sh $main_domain $autorestart_config" >> /etc/supervisord.d/${main_domain}_autorestart-containers
                echo "redirect_stderr = true" >> /etc/supervisord.d/${main_domain}_autorestart-containers
                echo "stdout_logfile = /dev/stdout" >> /etc/supervisord.d/${main_domain}_autorestart-containers
                echo "stdout_logfile_maxbytes = 0" >> /etc/supervisord.d/${main_domain}_autorestart-containers
            fi

	    if [ "$autocmd_config" != "" ]; then
		echo ">>> Watching certificate for main domain $main_domain: autocmd config $autocmd_config executed when certificate is changed."
		echo "[program:${main_domain}_autocmd-containers]" >> /etc/supervisord.d/${main_domain}_autocmd-containers
		echo "command = /scripts/autocmd-containers.sh $main_domain '$autocmd_config'" >> /etc/supervisord.d/${main_domain}_autocmd-containers
		echo "redirect_stderr = true" >> /etc/supervisord.d/${main_domain}_autocmd-containers
		echo "stdout_logfile = /dev/stdout" >> /etc/supervisord.d/${main_domain}_autocmd-containers
		echo "stdout_logfile_maxbytes = 0" >> /etc/supervisord.d/${main_domain}_autocmd-containers
	    fi
        done < /etc/letsencrypt/domains.conf

        echo "### Revoke and delete certificates if needed ####"
        for domain in `ls /etc/letsencrypt/live`; do
            remove_domain=true
            while read entry; do
                for comp_domain in $entry; do
                    if [ "$domain" = "$comp_domain" ]; then
                        remove_domain=false
                        break;
                    fi
                done
            done < /etc/letsencrypt/domains.conf

            if [ "$remove_domain" = true ]; then
                echo ">>> Removing the certificate $domain"
                certbot revoke -n $staging_cmd --cert-path /etc/letsencrypt/live/$domain/cert.pem --server https://acme-v02.api.letsencrypt.org/directory
            fi
        done

        echo "### Reloading supervisord configuration ###"
        supervisorctl update

        # Keep new hash version
        current_hash="$new_hash"
    fi

    # Wait 1s for next iteration
    sleep 1
done
