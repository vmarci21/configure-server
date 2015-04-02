#!/bin/bash

# #######################################################################
# Configure-server.sh
# Script to configure a Ubuntu (or Debian) server.
# (c) Daniel Kraus (bovender) 2012-2015
# MIT license.
#
# !!! USE AT YOUR OWN RISK !!!
# The author assumes no responsibility nor liability for loss of data,
# disclose of private information including passwords, or any other 
# harm that may be the result of running this script.
# #######################################################################


# Internal ('work') variables
VERSION=0.0.1 # Semantic version
HOMEPAGE="https://github.com/bovender/configure-server"
MSGSTR="*** "
BOLD=`tput bold`
NORMAL=`tput sgr0`
IP=$(ip address show dev eth0 2> /dev/null | awk '/inet / { print $2 }' \
	| grep -o -E '([0-9]{1,3}\.){3}[0-9]{1,3}')

shopt -s nocasematch


# #######################################################################
# Helper functions
# #######################################################################

# Prompts the user for a y/n choice
# $1 - prompt
# $2 - default answer
# Returns 0 if non-default answer, 1 if default answer.
yesno() {
	if [[ -n $3 && ! $2 =~ [yn] ]]; then
		echo "### Fatal: yesno() received default answer '$2', which is neither yes nor no."
		exit 99
	fi
	local choice="yn"
	[[ $2 =~ y ]] && local choice="Yn"
	[[ $2 =~ n ]] && local choice="yN"
	echo -n $1" [$choice] "
	local answer=x
	until [[ -z $answer || $answer =~ [yn] ]]; do
		read -s -n 1 answer
	done
	[[ -z "$answer" ]] && answer=$2
	echo "$answer"
	[[ $answer =~	$2 ]] && return 1
	return 0
}

# Creates a backup file containing the original distribution's
# configuration
backup() {
	for F in "$@"; do
		if [[ ! -a "$F.dist" ]]; then
			sudo cp "$F" "$F.dist"
		fi
	done
}

# Prints out a heading
heading() {
	echo -e $BOLD"\n$MSGSTR$*"$NORMAL
}

# Prints out a message
# (Currently this uses the heading() function, but may be adjusted
# according to personal preference.)
message() {
	heading "$*"
}

# Checks if a package is installed and installs it if necessary.
# This could also be accomplished by simply attempting to install it 
# using 'apt-get install', but this may take some time as apt-get
# builds the database first.
install() {
	local NEED_TO_INSTALL=0
	# Use "$@" in the FOR loop to get expansion like "$1" "$2" etc.
	for P in "$@"; do
		if [[ $(dpkg -s $P 2>&1 | grep -i "not installed") ]]; then
			local NEED_TO_INSTALL=1
			break
		fi
	done
	# Use "$*" in the messages to get expansion like "$1 $2 $3" etc.
	if (( $NEED_TO_INSTALL )); then
		heading "Installing '$*'..."
		sudo apt-get install -qqy $@
	else
		heading "'$*': installed already."
	fi
	for P in "$@"; do
		if [[ $(dpkg -s $P 2>&1 | grep -i "not installed") ]]
		then
			message "Required package $P still not installed -- aborting."
			exit 1
		fi
	done
}

# Synchronizes the script on the desktop with the one on the server
sync_script() {
	rsync -vuza $0 $CONFIG_FILE $ADMIN_USER@$SERVER_FQDN:.
	CODE=$?
	if (( $CODE==0 )); then
		# Sync the script (but not the config) back to the local computer
		# in case the script was amended while working on the server
		rsync -vuza $ADMIN_USER@$SERVER_FQDN:$(basename $0) .
		CODE=$?
	fi
	return $CODE
}

# Prepares the certificate authority
prepare_certificate_authority() {
	# Check if the CA directory structure has been initialized
	if [[ ! -a $CA_DIR/index.txt ]]; then
		message "Generating CA directory structure..."
		pushd $CA_DIR
		touch index.txt
		mkdir -p newcerts crl certs private
		popd
	fi
	if [[ ! -a $CA_DIR/serial ]]; then
		echo "01" > $CA_DIR/serial
	fi

	# Generate a root certificate if none is found
	ROOT_CERT_PATH="$CA_DIR/certs/${CA_FILE_NAME}.pem"
	if [[ ! -e "$ROOT_CERT_PATH" ]]
	then
		message "No root certificate found in $ROOT_CERT_PATH."
		yesno "Generate one now?" y
		if (( $? )) # default answer?
		then 
			ROOT_KEY_PATH="$CA_DIR/private/${CA_FILE_NAME}.key"
			if [[ ! -e "$ROOT_KEY_PATH" ]]
			then	
				openssl genrsa -des3 -out "$ROOT_KEY_PATH"  2048
				message "Adjusting ownership and permissions for private key file..."
				sudo chmod 400 "$ROOT_KEY_PATH"
				sudo chown root:root "$ROOT_KEY_PATH"
			fi
			echo
			openssl req -new -x509 -days 3650 -key "$ROOT_KEY_PATH" -out "$ROOT_CERT_PATH"
			if (( $? ))
			then
				set -e; exit 96
			else
				echo "Generated root certificate."
			fi
		else
			set -e; exit 97
		fi
	else
		echo "Using root certificate from $ROOT_CERT_PATH."
	fi
}

# Creates a config file for OpenSSL.
# This file has to be created for every certificate that we generate
# because we need to supply the commonName specifically for the
# certificate.
# Params:
# $1 - common name
create_openssl_config() {
	OPENSSL_CONFIG="$CA_DIR/${0%.sh}.openssl"
	tee "$OPENSSL_CONFIG" >/dev/null <<-EOF
		HOME   = .
		RANDFILE  = \$ENV::HOME/.rnd

		[ ca ]
		default_ca             = CA_default  # The default ca section

		[ CA_default ]
		dir                    = $CA_DIR
		certs                  = \$dir/certs
		crl_dir                = \$dir/crl
		database               = \$dir/index.txt
		new_certs_dir          = \$dir/newcerts
		certificate            = \$certs/$CA_FILE_NAME.pem
		private_key            = \$dir/private/$CA_FILE_NAME.key
		serial                 = \$dir/serial
		crlnumber              = \$dir/crlnumber 
		crl                    = \$dir/crl.pem  
		RANDFILE               = \$dir/private/.rand # private random number file
		x509_extensions        = usr_cert  # The extentions to add to the cert
		name_opt               = ca_default  # Subject Name options
		cert_opt               = ca_default  # Certificate field options
		default_days           = $CERT_DAYS
		default_crl_days       = 30
		default_md             = default
		preserve               = no	
		policy                 = my_policy
		unique_subject         = no

		[ my_policy ]
		countryName            = optional
		stateOrProvinceName    = optional
		localityName           = optional
		organizationName       = optional
		organizationalUnitName = optional
		commonName             = supplied
		emailAddress           = optional

		[ req ]
		prompt                 = no
		default_bits           = 2048
		default_keyfile        = privkey.pem
		distinguished_name     = req_distinguished_name
		x509_extensions        = v3_ca
		string_mask            = utf8only

		[ req_distinguished_name ]
		commonName             = $1
		countryName            = $CERT_COUNTRY
		stateOrProvinceName    = $CERT_STATE
		localityName           = $CERT_CITY
		0.organizationName     = $CERT_ORG
		#organizationalUnitName =
		emailAddress           = ca@$SERVER_FQDN

		[ usr_cert ]
		basicConstraints       = CA:FALSE
		nsCertType             = server, email
		nsComment              = "Generated with OpenSSL by $(basename $0) ($HOMEPAGE)"
		subjectKeyIdentifier   = hash
		authorityKeyIdentifier = keyid,issuer
		# Need extended key usage 'serverAuth' to make it work with OpenLDAP!
		extendedKeyUsage       = serverAuth

		[ v3_req ]
		basicConstraints       = CA:FALSE
		keyUsage               = nonRepudiation, digitalSignature, keyEncipherment

		[ v3_ca ]
		subjectKeyIdentifier   = hash
		authorityKeyIdentifier = keyid:always,issuer
		basicConstraints       = CA:true

		[ crl_ext ]
		authorityKeyIdentifier = keyid:always
		EOF

}

# Generates an SSL certificate
# Parameters:
# $1 - pass phrase for the CA key
# $2 - common name (e.g., virtual.domain.tld)
generate_and_copy_cert() {
	heading "Generating and signing SSL certificate for $2 ..."

	create_openssl_config "$2"
	local FILENAME=`echo $2 | sed "s/^\*\./wildcard./"`
	openssl req -config "$OPENSSL_CONFIG" -new -nodes \
		-keyout "$FILENAME.key" -out "$FILENAME.csr" 
	if [[ -e "$FILENAME.csr" ]]; then
		openssl ca  -config "$OPENSSL_CONFIG" -key $1 \
		 	-batch -in "$FILENAME.csr" -out "$FILENAME.pem" 
		if (( $? )); then exit 10; fi
		rm "$FILENAME.csr"
		chmod 444 "$FILENAME.pem"
		chmod 400 "$FILENAME.key"
		rsync -v "$FILENAME.pem" "$FILENAME.key" $ADMIN_USER@$SERVER_FQDN:
		rm -f "$FILENAME.key" "$FILENAME.pem" 2>&1 >/dev/null
	else
		message "Failed to generate certificate signing request for $2."
		set -e; exit 90
	fi
}

# Returns the fingerprint of an SSL certificate.
# @param $1 Base name of the certificate (in /etc/ssl/certs/).
# @return Fingerprint
get_fingerprint() {
	echo `openssl x509 -fingerprint -noout -in /etc/ssl/certs/${1%.pem}.pem \
	 	| awk -F '=' '{ print $2 }'`
}


# Trim() function by GuruM and mkelement, http://stackoverflow.com/a/7486606/270712
trim() {
    # Determine if 'extglob' is currently on.
    local extglobWasOff=1
    shopt extglob >/dev/null && extglobWasOff=0 
    (( extglobWasOff )) && shopt -s extglob # Turn 'extglob' on, if currently turned off.
    # Trim leading and trailing whitespace
    local VAR=$1
    VAR=${VAR##+([[:space:]])}
    VAR=${VAR%%+([[:space:]])}
    (( extglobWasOff )) && shopt -u extglob # If 'extglob' was off before, turn it back off.
    echo -n "$VAR"  # Output trimmed string.
}

remove_quotes() {
	sed -r -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\1/" <<< "$1"
}

# #######################################################################
# Begin main part of script
# #######################################################################

if [[ $(whoami) == "root" ]]; then
	echo "Please do not run this script as root. The script will sudo commands as necessary."
	exit 1
fi

heading "   $(basename $0), version $VERSION    ***"
heading "This will configure the Ubuntu server. ***"

# ########################################################################
# Read configuration
# ########################################################################

CONFIG_FILE="${0%.sh}.config"
read -d '' CONFIG_TEMPLATE <<-EOF
	# Configuration file for $(basename $0) version $VERSION
	# ============================================================================
	# Do not remove any variables that are listed here, or the script will refuse
	# to run. You should fill in values for all variables; use "" or '' if you
	# really do want an empty value. However, leaving any of the domain variables
	# or the admin user information empty will cause the server configuration to
	# FAIL.

	# Domains
	# -------
	# Please split a domain like "example.com" into the domain part "example" and
	# the top-level domain (TLD) "com". This is required to build LDAP DN's.
	DOMAIN=
	TLD=
	HORDE_SUBDOMAIN=horde
	OWNCLOUD_SUBDOMAIN=cloud
	SMTP_SUBDOMAIN=mail

	# Details of the 'admin user'.
	# ----------------------------
	# Note that this is not the server user, but a user account that is stored in
	# the LDAP database and is used to administer Horde and the other services.
	ADMIN_USER=
	# The admin_mail field must be just the part before the @ sign! Do not use
	# the server's domain name here.
	ADMIN_MAIL=
	ADMIN_REAL_NAME=
	ADMIN_PASS=

	# Certificates
	# ------------
	# File name of the certificate authority's root certificate PEM file (on your
	# USB drive, enter without path and extension).
	CA_FILE_NAME=my-own-root-certificate
	CERT_ORG=""
	CERT_COMPANY=""
	CERT_COUNTRY=
	CERT_STATE=
	CERT_CITY=
	# certificates are valid for 10 years by default
	CERT_DAYS=3650
	EOF

if [[ ! -e "$CONFIG_FILE" ]]
then
	heading "No configuration file was found."
	message "Will no generate a template file in $CONFIG_FILE which you will need to"
	message "edit before running this script again. All fields need to be filled."
	echo "$CONFIG_TEMPLATE" > "$CONFIG_FILE"
	exit 1
else
	# Config file was found, let's parse it
	# We find out about the _expected_ variables by reading the _default template_
	# line by line, then try to get the value for the variable from the actual
	# config file.
	heading "Reading configuration..."
	while IFS= read -r LINE
	do
		CONFIG_VAR_NAME="${LINE%%=*}" # remove everything after the '='
		CONFIG_VAR_NAME="${CONFIG_VAR_NAME%%#*}" # remove everything after a '#'
		if [[ ! -z "$CONFIG_VAR_NAME" ]]
		then
			CONFIG_VAR_VALUE=`grep "^$CONFIG_VAR_NAME=.*$" "$CONFIG_FILE"`
			CONFIG_VAR_VALUE=$(trim "${CONFIG_VAR_VALUE#*=}")
			if [[ ! -z "$CONFIG_VAR_VALUE" ]]
			then
				read -d '' "$CONFIG_VAR_NAME" <<< $(remove_quotes "$CONFIG_VAR_VALUE")
				# Use indirect variable reference: See http://tldp.org/LDP/abs/html/ivr.html
				# (at bottom of the page).
				echo "$CONFIG_VAR_NAME = \"${!CONFIG_VAR_NAME}\""
			else
				message "Configuration error: variable $CONFIG_VAR_NAME not set."
				message "All configuration variables must be assigned in $CONFIG_FILE."
				exit 
			fi
		fi
	done <<< "$CONFIG_TEMPLATE"
fi

# #######################################################################
# Site-specific configuration is achieved via a configuration file (see
# below).
# #######################################################################

# Certificate generation
CA_DIR=/media/$USER/CA/ca

# Domain names
SERVER_FQDN=$DOMAIN.$TLD
HORDE_FQDN=$HORDE_SUBDOMAIN.$SERVER_FQDN
OWNCLOUD_FQDN=$OWNCLOUD_SUBDOMAIN.$SERVER_FQDN
POSTFIX_FQDN=$SMTP_SUBDOMAIN.$SERVER_FQDN

# Postfix configuration directories
POSTFIX_BASE=/etc/postfix
POSTFIX_MAIN=$POSTFIX_BASE/main.cf
POSTFIX_MASTER=$POSTFIX_BASE/master.cf

# Dovecot
VMAIL_USER=vmail
VMAIL_DIR=/var/mail
DOVECOT_BASE=/etc/dovecot
DOVECOT_CONFD=$DOVECOT_BASE/conf.d

# LDAP DNs
LDAPBASEDN="dc=$DOMAIN,dc=$TLD"
LDAPUSERSDN="ou=users,$LDAPBASEDN"
LDAPAUTHDN="ou=auth,$LDAPBASEDN"
LDAPSHAREDDN="ou=shared,$LDAPBASEDN"
LDAPADDRESSBOOKDN="ou=contacts,$LDAPSHAREDDN"
ADMINDN="cn=admin,$LDAPBASEDN"
PWHASH="{SSHA}"

# MySQL 
MYSQL_ADMIN=root
HORDE_DATABASE=horde
OWNCLOUD_DATABASE=owncloud

# Control users for MySQL and OpenLDAP
# These control users get new, random passwords whenever the script
# is run; the generated passwords are mailed to root at the end.
HORDE_MYSQL_USER=horde
OWNCLOUD_MYSQL_USER=owncloud
# Do not change the following LDAP defintions, because 'dovecot' and
# 'postfix' are hard-coded in the 'cn: ...' directives of LDIF files
DOVECOT_LDAP_USER="cn=dovecot,$LDAPAUTHDN"
POSTFIX_LDAP_USER="cn=postfix,$LDAPAUTHDN"
HORDE_LDAP_USER="cn=horde,$LDAPAUTHDN"
OWNCLOUD_LDAP_USER="cn=owncloud,$LDAPAUTHDN"

# Horde parameters
HORDE_DIR=/var/horde

# OwnCloud parameters
# The OwnCloud dir should always end in 'owncloud' as this is the name of the
# directory in the distributed tarball.
OWNCLOUD_DIR=/var/owncloud

# Command to generate a random password (used for control users)
PASSWORD_CMD="pwgen -cns 16 1"


# ########################################################################
# Find out about the current environment
# ########################################################################

# if this is the server, the script should be executed in an SSH.
if [ -z "$SSH_CLIENT" ]; then
	heading "Local computer mode"
	message "You appear to be on your local desktop computer, because there is no SSH client."
	message "If this is not correct and you are running this script on a local terminal on"
	message "the server (rather than a secure shell), please exit the script now (CTRL+C)."
	message "Configured remote: $BOLD$ADMIN_USER@$SERVER_FQDN$NORMAL"

	if [[ -d "$CA_DIR" ]]; then
		heading "External media with 'CA' directory found!"
		echo "    $CA_DIR"
		yesno "Generate SSL certificates and copy them to server?" y
		if (( $? )); then 
			prepare_certificate_authority
			read -sp "Please enter the passphrase for the CA's private key:" CA_PASS
			generate_and_copy_cert $CA_PASS *.$DOMAIN.$TLD
			generate_and_copy_cert $CA_PASS $SERVER_FQDN
			generate_and_copy_cert $CA_PASS $HORDE_FQDN
			generate_and_copy_cert $CA_PASS $OWNCLOUD_FQDN
			generate_and_copy_cert $CA_PASS $POSTFIX_FQDN
			# Copy the CA itself to the server
			rsync $CA_DIR/certs/$CA_FILE_NAME.pem $ADMIN_USER@$SERVER_FQDN:.
			if (( $? )); then exit 98; fi
		fi
	fi

	heading "Update script..."
	yesno "Synchronize the script with the one on the server?" y
	if (( $? )); then
		message "Updating..."
		sync_script
		CODE=$?
		if (( code )); then
			message "An error occurred (rsync exit code: $CODE). Bye."
			exit 3
		fi

		# Offer to log into server via SSH only if script was updated
		yesno "Log into secure shell?" y
		if (( $? )); then
			heading "Logging into server's secure shell..."
			ssh $ADMIN_USER@$SERVER_FQDN
			message "Returned from SSH session."
			sync_script
			exit 
		fi
	fi
	echo "Bye."
	exit
else
	message "Apparently running in a secure shell on the server."
fi


# #####################################################################
# Now let's configure the server. 
# Everything below this comment should only be executed on a running
# server. (The above parts of the script should make sure this is the
# case.)
# #####################################################################

# Look for SSL certificates in the current directory; if there are
# any, assume that the 'desktop' part of the script copied them here,
# and move them to the appropriate directory.
if [[ $(find . -name '*.pem') ]]; then
	heading "Detected SSL certificates -- moving them to /etc/ssl/certs..."
	sudo mv *.pem /etc/ssl/certs
	sudo chown root:root *.key
	sudo chmod 0400 *.key
	sudo mv *.key /etc/ssl/private
	# Special treatment for OpenLDAP certificates
	pushd /etc/ssl
	sudo cp certs/$SERVER_FQDN.pem certs/openldap.pem
	sudo cp private/$SERVER_FQDN.key private/openldap.key
	sudo adduser openldap ssl-cert
	sudo chgrp ssl-cert certs/openldap.pem private/openldap.key
	sudo chmod 440 certs/openldap.pem private/openldap.key
	popd
fi

# Make sure we have the certificates
if [ `ls -1 /etc/ssl/certs/*${SERVER_FQDN}.pem 2>/dev/null | wc -l ` -eq 0 ]
then
	heading "No certificates for this server were found!"
	message "Please generate certificates by running this script on your local computer"
	message "with a USB drive named 'CA' plugged in. (See the README file.)"
fi

# Install required packages
install apache2 mysql-server dovecot-imapd dovecot-ldap \
	postfix postfix-ldap postfix-pcre \
  pwgen slapd ldap-utils bsd-mailx \
  spamassassin clamav clamav-daemon amavisd-new phpmyadmin php-pear \
  php5-ldap php5-memcache memcached php-apc \
  libimage-exiftool-perl aspell aspell-de aspell-de-alt php5-imagick php5-memcache

# Passwords for control users and services
POSTFIX_PASS=$($PASSWORD_CMD)
DOVECOT_PASS=$($PASSWORD_CMD)
HORDE_PASS=$($PASSWORD_CMD)
OWNCLOUD_PASS=$($PASSWORD_CMD)

# Configure SSH
if [[ -n $(grep -i "^AllowUsers $USER" /etc/ssh/sshd_config) ]]; then
	heading "Configuring SSH to allow only $USER to log in."
	sudo sed -i -r '/^AllowUsers/ d; s/^(PermitRootLogin\s*).*$/\1no/' /etc/ssh/sshd_config
	sudo tee -a /etc/ssh/sshd_config >/dev/null <<-EOF
		AllowUsers $USER
		EOF
fi

# Prevent Grub from waiting indefinitely for user input on a headless server.

if [[ -n $(grep "set timeout=-1" /etc/grub.d/00_header) ]]; then
	yesno "Patch Grub to not wait for user input when booting the system?" y
	if (( $? )); then
		heading "Patching Grub..."
		patch /etc/grub.d/00_header <<-'EOF'
			--- 00_header	2012-04-17 20:20:48.000000000 +0200
			+++ 00_header-no-timeout	2012-07-10 22:53:26.440676690 +0200
			@@ -233,7 +233,7 @@
			 {
				 cat << EOF
			 if [ "\${recordfail}" = 1 ]; then
			-  set timeout=-1
			+  set timeout=${2}
			 else
			   set timeout=${2}
			 fi
		EOF
		sudo update-grub
	fi
else
	heading "Grub is already patched."
fi


# Restrict sudo usage to the current user

if [[ ! $(sudo grep "^$(whoami)" /etc/sudoers) ]]; then
	yesno "Make $(whoami) the only sudoer?" y
	if (( $? )); then
		heading "Patching /etc/sudoers"
		# To be on the safe side, we patch a copy of /etc/sudoers and only
		# make the system use it if it passes the visudo test.
		sudo sed 's/^\(%admin\|root\|%sudo\)/#&/'  /etc/sudoers > configure-sudoers.tmp
		echo 'daniel	ALL=(ALL:ALL) ALL ' | sudo tee -a configure-sudoers.tmp > /dev/null

		# Visudo returns 0 if everything is correct; 1 if errors are found
		sudo visudo -c -f configure-sudoers.tmp
		[[ $? ]] && sudo cp configure-sudoers.tmp /etc/sudoers && rm configure-sudoers.tmp
	fi
else
	heading "Sudoers already configured."
fi

# ##################
# MySQL
# ##################

heading "Creating MySQL users and databases for applications."
echo "When prompted, please enter the MySQL database's administrative user's password."
# Run mysql with the -f option to continue after errors.
mysql -f -u $MYSQL_ADMIN -p <<EOF
	DROP USER '$HORDE_MYSQL_USER';
	CREATE USER '$HORDE_MYSQL_USER' IDENTIFIED BY '$HORDE_PASS';
	DROP USER '$OWNCLOUD_MYSQL_USER';
	CREATE USER '$OWNCLOUD_MYSQL_USER' IDENTIFIED BY '$OWNCLOUD_PASS';
	CREATE DATABASE IF NOT EXISTS $HORDE_DATABASE CHARACTER SET utf8 COLLATE utf8_Unicode_ci;
	CREATE DATABASE IF NOT EXISTS $OWNCLOUD_DATABASE CHARACTER SET utf8 COLLATE utf8_Unicode_ci;
	GRANT ALL PRIVILEGES ON $HORDE_DATABASE.* TO '$HORDE_MYSQL_USER';
	GRANT ALL PRIVILEGES ON $OWNCLOUD_DATABASE.* TO '$OWNCLOUD_MYSQL_USER';
EOF


# ##################
# LDAP configuration
# ##################

# Add misc schema to LDAP directory
if [[ -z $(sudo ldapsearch -LLL -Y external -H ldapi:/// \
	-b "cn=schema,cn=config" "cn=*misc*" dn 2>/dev/null ) ]]
then
	heading "Adding misc schema to LDAP directory..."
	sudo ldapadd -Y EXTERNAL -H ldapi:/// -c -f /etc/ldap/schema/misc.ldif
else
	message "Misc schema already imported into LDAP."
fi

# Check if the LDAP backend database (hdb) already contains an ACL directive
# for Postfix. If none is found, assume that we need to configure the backend
# database.
if [[ -z $(sudo ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -s one \
	-b "olcDatabase={1}hdb,cn=config" "olcAccess=*postfix*" dn 2>/dev/null ) ]]
# if (( 1 ))
then
	# Add the schema, ACLs and first user account to LDAP.
	# Be aware that LDAP is picky about leading space!

	message "Adding access control lists (ACLs) to LDAP backend database..."
	# Ubuntu pre-configures the OpenLDAP online configuration such
	# that it is accessible as the system root, therefore we sudo
	# the following command.
	sudo ldapmodify -Y EXTERNAL -H ldapi:/// -c <<EOF
# Configure ACLs for the hdb backend database.
# Note: Continued lines MUST have a trailing space; continuation lines
# MUST have a leading space.
# First, remove the existing ACLs
dn: olcDatabase={1}hdb,cn=config
changetype: modify
delete: olcAccess

# Then, add our own ACLs
# (Note that we cannot use "-" lines here, because the entire operation would
# fail if an olcAccess attribute had not been present already.
dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcAccess
# Passwords may only be accessed for authentication, or modified by the 
# correponsing users and admin.
olcAccess: to attrs=userPassword 
 by dn=$ADMINDN manage 
 by dn=$HORDE_LDAP_USER manage 
 by dn=$DOVECOT_LDAP_USER read 
 by anonymous auth 
 by self write 
 by * none
# Only admin may write to the uid, mailRoutingAddress, and mailLocalAddress
# fields; Postfix can look up these attributes
olcAccess: to attrs=uid,mailRoutingAddress,mailLocalAddress 
 by dn=$ADMINDN manage 
 by dn=$HORDE_LDAP_USER manage 
 by self read 
 by users read 
 by dn=$POSTFIX_LDAP_USER read 
 by * read
# Personal address book
olcAccess: to dn.regex="ou=contacts,uid=([^,]+),$LDAPUSERSDN$" 
 by dn.exact,expand="uid=\$1,$LDAPUSERSDN" write 
 by dn=$ADMINDN manage 
 by users none
# Shared address book
olcAccess: to dn.subtree="$LDAPADDRESSBOOKDN" 
 by dn=$ADMINDN manage 
 by dn=$HORDE_LDAP_USER write 
 by users write
# An owner of an entry may modify it (and so may the admin);
# deny read access to non-authenticated entities
olcAccess: to * 
 by dn=$HORDE_LDAP_USER manage 
 by self write 
 by users read 
 by * none

dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: uid pres
EOF
else
	message "LDAP ACLs already configured..."
fi

#if [[ -z $(sudo ldapsearch -LLL -Y external -H ldapi:/// \
#	-b "cn=config" "cn=*olcLog*" dn 2>/dev/null ) ]]
if (( 1 ))
then
	heading "Enabling slapd logging..."
	sudo ldapmodify -Y EXTERNAL -H ldapi:/// -c <<EOF
# Note: Logs go to /var/log/syslog; olcLogFile is only used on Windows systems 
# Log level 'none' does not mean no logging, but comprizes non-categorized
# messages (see docs!. Use 'acl' for ACL logging.)
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: none
EOF
else
	message "slapd logging already configured."
fi

if [[ -z $(sudo ldapsearch -LLL -Y external -H ldapi:/// \
	-b "cn=config" "cn=*olcTLSCertificate*" dn 2>/dev/null ) ]]
#if (( 1 ))
then
	heading "Enabling OpenLDAP TLS/SSL..."
	sudo ldapmodify -Y EXTERNAL -H ldapi:/// -c <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ssl/certs/openldap.pem
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ssl/private/openldap.key

dn: cn=config
changetype: modify
replace: olcTLSVerifyClient
olcTLSVerifyClient: never
EOF
else
	message "OpenLDAP TLS/SSL already set up."
fi

heading "Binding to LDAP directory..."
echo "For binding to the LDAP directory, please enter the password that you used"
echo "during installation of this server."
CODE=-1
until (( $CODE==0 )); do
	read -sp "LDAP password for $ADMINDN: " LDAP_ADMIN_PW
	if [[ $LDAP_ADMIN_PW ]]; then
		ldapsearch -LLL -w $LDAP_ADMIN_PW -D "$ADMINDN" -H ldapi:/// \
			-b "$LDAPBASEDN" "$LDAPBASEDN" dc /dev/null
		CODE=$?
		if (( $CODE==49 )); then
			echo "Incorrect password. Please enter password again. Empty password will abort."
		fi
	else
		message "Empty password -- aborting. Bye."
		exit 1
	fi
done
if (( $CODE!=0 )); then
	message "LDAP server returned error code $CODE -- aborting. Bye."
	exit 2
fi

if [[ -z $(ldapsearch -LLL -w $LDAP_ADMIN_PW -D "$ADMINDN" -b "$LDAPUSERSDN" "uid=$ADMIN_USER" uid) ]]
then
	message "Adding an entry for user $ADMIN_USER to the LDAP tree..."
	ldapadd -c -x -w $LDAP_ADMIN_PW -D "$ADMINDN" -H ldapi:/// <<-EOF
		dn: $LDAPUSERSDN
		ou: users
		objectClass: organizationalUnit

		dn: uid=$ADMIN_USER,$LDAPUSERSDN
		objectClass: inetOrgPerson
		objectClass: inetLocalMailRecipient
		uid: $ADMIN_USER
		sn: $(echo $ADMIN_REAL_NAME | sed 's/^.* //')
		cn: $ADMIN_REAL_NAME
		mailRoutingAddress: $ADMIN_MAIL
		mailLocalAddress: root
		mailLocalAddress: postmaster
		mailLocalAddress: webmaster
		mailLocalAddress: abuse
		mailLocalAddress: ca
		mailLocalAddress: www-data

		dn: ou=contacts,uid=$ADMIN_USER,$LDAPUSERSDN
		ou: contacts
		objectClass: organizationalUnit
		EOF
	ldappasswd -x -w $LDAP_ADMIN_PW -D "$ADMINDN" -H ldapi:/// \
		-s "$ADMIN_PASS" "uid=$ADMIN_USER,$LDAPUSERSDN"
else
	message "User $ADMIN_USER already has an LDAP entry under $LDAPUSERSDN."
fi

message "Adding/replacing LDAP entries for the Dovecot and Postfix control users..."
ldapadd -c -x -w $LDAP_ADMIN_PW -D "$ADMINDN" <<-EOF
	dn: $POSTFIX_LDAP_USER
	changetype: delete

	dn: $DOVECOT_LDAP_USER
	changetype: delete

	dn: $HORDE_LDAP_USER
	changetype: delete

	dn: $OWNCLOUD_LDAP_USER
	changetype: delete

	# ldapadd will complain if $LDAPAUTH exists already, but we don't care
	# as we do not need to update it, we just need to make sure it's there
	dn: $LDAPAUTHDN
	changetype: add
	ou: auth
	objectClass: organizationalUnit

	dn: $POSTFIX_LDAP_USER
	changetype: add
	objectClass: organizationalRole
	objectClass: simpleSecurityObject
	cn: postfix
	userPassword:
	description: Postfix control user
	
	dn: $DOVECOT_LDAP_USER
	changetype: add
	objectClass: organizationalRole
	objectClass: simpleSecurityObject
	cn: dovecot
	userPassword:
	description: Dovecot control user
	
	dn: $HORDE_LDAP_USER
	changetype: add
	objectClass: organizationalRole
	objectClass: simpleSecurityObject
	cn: horde
	userPassword:
	description: Horde control user
	
	dn: $OWNCLOUD_LDAP_USER
	changetype: add
	objectClass: organizationalRole
	objectClass: simpleSecurityObject
	cn: owncloud
	userPassword:
	description: OwnCloud control user

	dn: $LDAPSHAREDDN
	changetype: add
	ou: shared
	objectClass: organizationalUnit

	dn: $LDAPADDRESSBOOKDN
	changetype: add
	ou: contacts
	objectClass: organizationalUnit
	EOF
ldappasswd -x -w $LDAP_ADMIN_PW -D "$ADMINDN" -H ldapi:/// -s "$POSTFIX_PASS" "$POSTFIX_LDAP_USER"
ldappasswd -x -w $LDAP_ADMIN_PW -D "$ADMINDN" -H ldapi:/// -s "$DOVECOT_PASS" "$DOVECOT_LDAP_USER"
ldappasswd -x -w $LDAP_ADMIN_PW -D "$ADMINDN" -H ldapi:/// -s "$HORDE_PASS"   "$HORDE_LDAP_USER"
ldappasswd -x -w $LDAP_ADMIN_PW -D "$ADMINDN" -H ldapi:/// -s "$OWNCLOUD_PASS"   "$OWNCLOUD_LDAP_USER"


# ######################################################################
# Postfix configuration
# ----------------------------------------------------------------------
# NB: This assumes that postfix was included in the system installation.
# ######################################################################


# Set up spamassassin, clamav, and amavisd-new
if [[ -z $(grep -i 'ENABLED=1' /etc/default/spamassassin) ]]; then
	heading "Enabling spamassassin (including cron job for nightly updates)..."
	backup /etc/default/spamassassin
	sudo sed -i 's/^ENABLED=.$/ENABLED=1/' /etc/default/spamassassin
	sudo sed -i 's/^CRON=.$/CRON=1/' /etc/default/spamassassin
	echo "Starting spamassassin..."
	sudo service spamassassin start
fi

if [[ -z $(grep amavis $POSTFIX_BASE/master.cf) ]]; then
	heading "Creating Postfix service for amavisd-new..."
	sudo tee -a $POSTFIX_BASE/master.cf >/dev/null <<EOF
amavisfeed unix    -       -       n        -      2     lmtp
    -o lmtp_data_done_timeout=1200
    -o lmtp_send_xforward_command=yes
    -o disable_dns_lookups=yes
    -o max_use=20
127.0.0.1:10025 inet n    -       n       -       -     smtpd
    -o content_filter=
    -o smtpd_delay_reject=no
    -o smtpd_client_restrictions=permit_mynetworks,reject
    -o smtpd_helo_restrictions=
    -o smtpd_sender_restrictions=
    -o smtpd_recipient_restrictions=permit_mynetworks,reject
    -o smtpd_data_restrictions=reject_unauth_pipelining
    -o smtpd_end_of_data_restrictions=
    -o smtpd_restriction_classes=
    -o mynetworks=127.0.0.0/8
    -o smtpd_error_sleep_time=0
    -o smtpd_soft_error_limit=1001
    -o smtpd_hard_error_limit=1000
    -o smtpd_client_connection_count_limit=0
    -o smtpd_client_connection_rate_limit=0
    -o receive_override_options=no_header_body_checks,no_unknown_recipient_checks,no_milters
    -o local_header_rewrite_clients=
EOF
else
	message "Postfix service for amavisd-new already exists."
fi

if [[ -z $(grep amavis $POSTFIX_MAIN) ]]; then
	heading "Setting global content filter for amavisd-new in Postfix..."
	sudo postconf -e "content_filter=amavisfeed:[127.0.0.1]:10024"
else
	message "Global content filter in Postfix already set."
fi

if [[ -z $(groups clamav | grep amavis) ]]; then
	heading "Adding clamav user to amavis group..."
	sudo adduser clamav amavis
else
	message "clamav is a member of the amavis group already."
fi

if [[ ! -a /etc/amavis/conf.d/99-custom ]]; then
	heading "Adding custom configuration for amavisd-new..."
	sudo tee /etc/amavis/conf.d/99-custom >/dev/null <<'EOF'
use strict;

@bypass_virus_checks_maps = (
   \%bypass_virus_checks, \@bypass_virus_checks_acl, \$bypass_virus_checks_re);

@bypass_spam_checks_maps = (
   \%bypass_spam_checks, \@bypass_spam_checks_acl, \$bypass_spam_checks_re);

# Always add spam info header
$sa_tag_level_deflt  = undef;
$sa_tag2_level_deflt = 5;
$sa_kill_level_deflt = 20;

1;  # ensure a defined return
EOF
else
	message "Custom configuration for amavisd-new already exists."
fi

# Configure Postfix to use LDAP maps
if [[ ! -a $POSTFIX_BASE/postfix-ldap-aliases.cf ]]; then
	heading "Configuring Postfix to use LDAP maps for alias lookup..."
	sudo tee $POSTFIX_BASE/postfix-ldap-aliases.cf > /dev/null <<-EOF
		# Postfix LDAP map generated by $(basename $0)
		# See $HOMEPAGE
		# $(date --rfc-3339=seconds)

		server_host = ldapi:///

		bind = yes
		bind_dn = $POSTFIX_LDAP_USER
		bind_pw = $POSTFIX_PASS

		search_base = $LDAPUSERSDN

		# Use the %u parameter to search for the local part of an
		# email address only. %s would search for the entire string.
		query_filter = (&(objectClass=inetLocalMailRecipient)(mailLocalAddress=%u))

		# The result_format uses %u to return the local part of an
		# address. To use virtual domains, replace %u with %s
		result_format = %u
		result_attribute = uid
		EOF
	sudo chgrp postfix $POSTFIX_BASE/postfix-ldap-aliases.cf 
	sudo chmod 640     $POSTFIX_BASE/postfix-ldap-aliases.cf 

	# Configure postfix to look up 'virtual' aliases. Keep in mind
	# that virtual_alias_maps is for address rewriting on receiving
	# mails, while alias_maps is for address rewriting on delivering
	# mails. Since we do not use Postfix' "local" service for 
	# delivery (but Dovecot instead), virtual_maps will never be
	# consulted in our setup.
	sudo postconf -e "virtual_alias_maps=proxy:ldap:$POSTFIX_BASE/postfix-ldap-aliases.cf"
fi

# The Postfix password must be updated, because it was updated in the LDAP
# entry as well.
sudo sed -i -r "s/^(bind_pw =).*$/\1 $POSTFIX_PASS/" $POSTFIX_BASE/postfix-ldap-aliases.cf

if [[ ! -a $POSTFIX_BASE/postfix-ldap-local-recipients.cf ]]; then
	heading "Configuring Postfix to use LDAP maps for local recipient lookup..."
	sudo tee $POSTFIX_BASE/postfix-ldap-local-recipients.cf > /dev/null <<-EOF
		# Postfix LDAP map generated by $(basename $0)
		# See $HOMEPAGE

		server_host = ldapi:///
		bind = yes
		bind_dn = $POSTFIX_LDAP_USER
		bind_pw = $POSTFIX_PASS

		search_base = $LDAPUSERSDN
		query_filter = (&(objectClass=inetLocalMailRecipient)(|(uid=%u)(mailRoutingAddress=%u)(mailLocalAddress=%u)))
		result_attribute = uid
		EOF
	sudo chgrp postfix $POSTFIX_BASE/postfix-ldap-local-recipients.cf 
	sudo chmod 640     $POSTFIX_BASE/postfix-ldap-local-recipients.cf 

	sudo postconf -e "local_recipient_maps=proxy:ldap:$POSTFIX_BASE/postfix-ldap-local-recipients.cf"
fi
# The Postfix password must be updated, because it was updated in the LDAP
# entry as well.
sudo sed -i -r "s/^(bind_pw =).*$/\1 $POSTFIX_PASS/" \
	$POSTFIX_BASE/postfix-ldap-local-recipients.cf


if [[ ! -a $POSTFIX_BASE/postfix-ldap-canonical-map.cf ]]; then
	heading "Configuring Postfix to use LDAP maps for local recipient lookup..."
	sudo tee $POSTFIX_BASE/postfix-ldap-canonical-map.cf > /dev/null <<-EOF
		# Postfix LDAP map for canonical names generated by $(basename $0)
		# See $HOMEPAGE

		server_host = ldapi:///
		bind = yes
		bind_dn = $POSTFIX_LDAP_USER
		bind_pw = $POSTFIX_PASS

		search_base = $LDAPUSERSDN
		query_filter = (&(objectClass=inetLocalMailRecipient)(uid=%u))
		result_attribute = mailRoutingAddress
		EOF
	sudo chgrp postfix $POSTFIX_BASE/postfix-ldap-canonical-map.cf 
	sudo chmod 640     $POSTFIX_BASE/postfix-ldap-canonical-map.cf 

	sudo postconf -e "canonical_maps = proxy:ldap:$POSTFIX_BASE/postfix-ldap-canonical-map.cf"
	sudo postconf -e "canonical_classes = header_recipient, header_sender, envelope_recipient, envelope_sender"
	sudo postconf -e "local_header_rewrite_clients = static:all"
	sudo postconf -e "myhostname = $POSTFIX_FQDN"
fi
# The Postfix password must be updated, because it was updated in the LDAP
# entry as well.
sudo sed -i -r "s/^(bind_pw =).*$/\1 $POSTFIX_PASS/" \
	$POSTFIX_BASE/postfix-ldap-canonical-map.cf


if [[ -z $(grep dovecot $POSTFIX_BASE/master.cf) ]]; then
	heading "Declaring Dovecot transport Postfix master..."
	backup $POSTFIX_BASE/master.cf
	sudo tee -a $POSTFIX_BASE/master.cf > /dev/null <<EOF
dovecot   unix  -       n       n       -       -       pipe
  flags=DRhu user=$VMAIL_USER:$VMAIL_USER argv=/usr/lib/dovecot/deliver -f \${sender} -d \${recipient}
EOF
fi

if [[ -z $(grep "local_transport = dovecot" $POSTFIX_MAIN) ]]; then
	heading "Configuring Postfix' local transport to use dovecot pipe..."
	sudo postconf -e "dovecot_destination_recipient_limit = 1"
	sudo postconf -e "local_transport = dovecot"
	# Comment out the mailbox_command directive:
	sudo sed -i 's/^mailbox_command/#&/' $POSTFIX_MAIN
fi

# Require fully qualified HELO -- this requirement (though RFC2821 conformant)
# may not be met by Outlook and Outlook Express.
# sudo postconf -e "smtpd_helo_required = yes"

# The following restrictions may be made more tight by adding:
#	reject_unknown_sender_domain \
# after 'reject_non_fqdn_sender'. Note however that this will cause all e-mails
# from your local, non-DNS-registered test domain to be rejected.
sudo sed -i '/^smtpd_recipient_restrictions/,/^\spermit$/d' $POSTFIX_MAIN
sudo tee -a $POSTFIX_MAIN >/dev/null <<EOF
smtpd_recipient_restrictions = 
	reject_non_fqdn_recipient,
	reject_non_fqdn_sender,
	reject_unknown_recipient_domain,
	permit_mynetworks,
	reject_unauth_destination,
	check_recipient_access hash:$POSTFIX_BASE/roleaccount_exceptions,
	reject_multi_recipient_bounce,
	reject_non_fqdn_hostname,
	reject_invalid_hostname,
	check_helo_access pcre:$POSTFIX_BASE/helo_checks,
	check_sender_mx_access cidr:$POSTFIX_BASE/bogus_mx,
	permit
EOF

sudo tee $POSTFIX_BASE/roleaccount_exceptions >/dev/null <<-EOF
	postmaster@  OK
	abuse@       OK
	hostmaster@  OK
	webmaster@   OK
	EOF
sudo postmap hash:/$POSTFIX_BASE/roleaccount_exceptions

sudo tee $POSTFIX_BASE/helo_checks >/dev/null <<-EOF
	/^$(echo $SERVER_FQDN | sed 's/\./\\./g')\$/    550 Don't use my hostname
	/^$(echo $IP | sed 's/\./\\./g')\$/             550 Don't use my IP address
	/^\[$(echo $IP | sed 's/\./\\./g')\]\$/         550 Don't use my IP address
	EOF

sudo tee $POSTFIX_BASE/bogus_mx >/dev/null <<-EOF
	# bogus networks
	0.0.0.0/8       550 Mail server in broadcast network
	10.0.0.0/8      550 No route to your RFC 1918 network
	# The following line prevents proper operation if Postfix has a subdomain
	# 127.0.0.0/8     550 Mail server in loopback network
	224.0.0.0/4     550 Mail server in class D multicast network
	172.16.0.0/12   550 No route to your RFC 1918 network
	192.168.0.0/16  550 No route to your RFC 1918 network
	# spam havens
	69.6.0.0/18     550 REJECT Listed on Register of Known Spam Operations
	# Wild-card MTA
	64.94.110.11/32 550 REJECT VeriSign domain wildcard
	EOF

# Configure SSL/LS
pushd /etc/postfix
sudo sed -i -r \
	's#(smtpd_tls_cert_file=/etc/ssl/certs/).+$#\1'$POSTFIX_FQDN'.pem#' main.cf
sudo sed -i -r \
	's#(smtpd_tls_key_file=/etc/ssl/private/).+$#\1'$POSTFIX_FQDN'.key#' main.cf

heading "Enabling port 587 in Postfix configuration..."
sudo sed -i -r 's/^#(submission\sinet.+)$/\1/' master.cf
popd

# #######################################################################
# Dovecot configuration
# #######################################################################

# Relax permissions of Dovecot's auth-userdb socket (required when dovecot-lda
# is used for local mail delivery).
# The following sed command will adjust the mode, user, and group directives
# for auth-userdb.
if [[ $(grep -Pzo "auth-userdb.*\N\s*?#mode" $DOVECOT_CONFD/10-master.conf) ]]; then
	heading "Adjusting permissions of Dovecot's auth-userdb socket..."
	sudo sed -i -r "/auth-userdb \{/,/}/ { \
		s/^(\s*)#mode = 0600.*$/\1mode = 0660/; \
		s/^(\s*)#user =.*$/\1user = $VMAIL_USER/; \
		s/^(\s*)#group =.*$/\1group = $VMAIL_USER/ ;}" $DOVECOT_CONFD/10-master.conf
else
	message "Dovecot's auth-userdb socket permissions already adjusted."
fi

if [[ -n $(grep '#!include auth-ldap' $DOVECOT_CONFD/10-auth.conf) ]]; then
	pushd $DOVECOT_CONFD
	backup 10-auth.conf auth-ldap.conf.ext
	heading "Configuring Dovecot to look up users and passwords in LDAP directory..."
	sudo tee auth-ldap.conf.ext >/dev/null <<EOF
# Authentication for LDAP users. Included from auth.conf.
# Automagically generated by $(basename $0)
# See $HOMEPAGE
# $(date --rfc-3339=seconds)

passdb {
  driver = ldap
  args = $DOVECOT_BASE/dovecot-ldap.conf.ext
}

userdb {
 driver = static
 args = uid=$VMAIL_USER gid=$VMAIL_USER home=$VMAIL_DIR/%Ln
}
EOF
	sudo sed -i -r 's/^#?(!include auth)/#\1/'           10-auth.conf
	sudo sed -i -r 's/^#(!include auth-ldap)/\1/'        10-auth.conf
	sudo sed -i -r "s/^#?(mail_.id =).*$/\1 $VMAIL_USER/" 10-mail.conf
	cd $DOVECOT_BASE
	backup dovecot-ldap.conf.ext
	sudo tee dovecot-ldap.conf.ext >/dev/null <<-EOF
		# Dovecot LDAP configuration generated by $(basename $0)
		# See $HOMEPAGE
		# $(date --rfc-3339=seconds)
		uris = ldapi:///
		dn = $DOVECOT_LDAP_USER
		dnpass = $DOVECOT_PASS

		#sasl_bind = yes
		#sasl_mech =
		#sasl_realm =

		#tls = yes
		#tls_ca_cert_file =
		#tls_ca_cert_dir =
		#tls_cipher_suite =

		#debug_level = -1

		# We don't do authentication binds for lookups, therefore 'no'
		auth_bind = no
		base = $LDAPUSERSDN
		#deref = never
		pass_attrs = uid=user,userPassword=password

		# Change %Ln to %u if you want user IDs with domain
		# Since Postfix rewrites the envelope recipient to the canonical
		# mail address (mailRoutingAddress attribute in LDAP entry), we need to
		# search for %Ln in 'mailRoutingAddress' also.
		pass_filter = (&(objectClass=inetOrgPerson)(|(uid=%Ln)(mailRoutingAddress=%Ln)))

		#default_pass_scheme = SSHA

		# Attributes and filter to get a list of all users
		#iterate_attrs = uid=user
		#iterate_filter = (objectClass=inetOrgPerson)
		EOF
	sudo chmod 600 dovecot-ldap.conf.ext
	popd
else
	heading "Dovecot custom configuration already present."
fi

# The Dovecot password must be updated, because it was updated in the LDAP
# entry as well.
sudo sed -i -r "s/^(dnpass =).*$/\1 $DOVECOT_PASS/" $DOVECOT_BASE/dovecot-ldap.conf.ext

# Add the vmail user.
# No need to make individual user's directories as Dovecot will
# take care of this.
if [[ -z $(id $VMAIL_USER) ]]; then
	heading "Adding vmail user..."
	sudo adduser --system --home $VMAIL_DIR --uid 5000 --group $VMAIL_USER
else
	heading "User $VMAIL_USER already exists."
fi
sudo chgrp -R $VMAIL_USER $VMAIL_DIR
sudo chmod -R 770 $VMAIL_DIR

# Configure SSL/TLS for Dovecot
pushd /etc/dovecot/conf.d
backup 10-ssl.conf
sudo sed -i -r \
	's#^(ssl_cert = <).*$#\1/etc/ssl/certs/'$SERVER_FQDN'.pem#'  10-ssl.conf
sudo sed -i -r \
	's#^(ssl_key = <).*$#\1/etc/ssl/private/'$SERVER_FQDN'.key#' 10-ssl.conf
popd

# ######################
# PHPmyadmin
# ######################

if [[ ! $(grep ForceSSL /etc/phpmyadmin/config.inc.php) ]]; then
	heading "Make phpMyAdmin enforce SSL connections..."
	echo "\$cfg['ForceSSL']=true;" | \
		sudo tee -a /etc/phpmyadmin/config.inc.php > /dev/null
fi


# ######################
# Horde configuration
# ######################

if [[ ! -d $HORDE_DIR ]]; then
	heading "Installing Horde..."
	sudo pear upgrade PEAR
	sudo pear channel-discover pear.horde.org
	sudo pear install horde/horde_role
	sudo pear run-scripts horde/horde_role
	sudo pear install horde/webmail
	sudo pear install horde/Horde_Ldap
	sudo pear install horde/Horde_Memcache

	message "When prompted, enter the following information:"
	message "- Database name:     $HORDE_DATABASE"
	message "- Database user:     $HORDE_MYSQL_USER"
	message "- Database password: $HORDE_PASS"
	message "Note that a configuration will be written later on that also contains"
	message "this information. The horde installer needs the credentials to create"
	message "the database tables."
	sudo webmail-install
	sudo chown www-data:www-data $HORDE_DIR
else
	heading "Horde already installed."
fi

# Adjust horde configuration
heading "Adjusting horde configuration..."
# sudo sed -i -r "s/^(.conf..ldap....bindpw.*=.).*$/\1'$HORDE_PASS';/" $HORDE_DIR/config/conf.php

# Extract the local horde's secret key
HORDE_SECRET_KEY=`grep -o -E '.{8}-.{4}-.{4}-.{4}-.{12}' $HORDE_DIR/config/conf.php`
[[ -z $HORDE_SECRET_KEY ]] && HORDE_SECRET_KEY=`uuidgen`

sudo tee $HORDE_DIR/config/conf.php >/dev/null <<-EOF
	<?php
	/* CONFIG START. DO NOT CHANGE ANYTHING IN OR AFTER THIS LINE. */
	// \$Id: 41a4cec5f53fb2d327c8ed9e1c6cfd330a6b7217 \$
	\$conf['vhosts'] = false;
	\$conf['debug_level'] = E_ALL & ~E_NOTICE;
	\$conf['max_exec_time'] = 0;
	\$conf['compress_pages'] = true;
	\$conf['secret_key'] = '$HORDE_SECRET_KEY';
	\$conf['umask'] = 077;
	\$conf['testdisable'] = true;
	\$conf['use_ssl'] = 2;
	\$conf['server']['name'] = \$_SERVER['SERVER_NAME'];
	\$conf['urls']['token_lifetime'] = 30;
	\$conf['urls']['hmac_lifetime'] = 30;
	\$conf['urls']['pretty'] = false;
	\$conf['safe_ips'] = array();
	\$conf['session']['name'] = 'Horde';
	\$conf['session']['use_only_cookies'] = true;
	\$conf['session']['timeout'] = 0;
	\$conf['session']['cache_limiter'] = 'nocache';
	\$conf['session']['max_time'] = 604800;
	\$conf['cookie']['domain'] = \$_SERVER['SERVER_NAME'];
	\$conf['cookie']['path'] = '/';
	\$conf['sql']['username'] = '$HORDE_MYSQL_USER';
	\$conf['sql']['password'] = '$HORDE_PASS';
	\$conf['sql']['protocol'] = 'unix';
	\$conf['sql']['database'] = '$HORDE_DATABASE';
	\$conf['sql']['charset'] = 'utf-8';
	\$conf['sql']['ssl'] = true;
	\$conf['sql']['splitread'] = false;
	\$conf['sql']['phptype'] = 'mysqli';
	\$conf['nosql']['phptype'] = false;
	\$conf['ldap']['hostspec'] = array('localhost');
	\$conf['ldap']['tls'] = false;
	\$conf['ldap']['timeout'] = 5;
	\$conf['ldap']['version'] = 3;
	\$conf['ldap']['binddn'] = '$HORDE_LDAP_USER';
	\$conf['ldap']['bindpw'] = '$HORDE_PASS';
	\$conf['ldap']['bindas'] = 'admin';
	\$conf['ldap']['useldap'] = true;
	\$conf['auth']['admins'] = array('$ADMIN_USER');
	\$conf['auth']['checkip'] = true;
	\$conf['auth']['checkbrowser'] = true;
	\$conf['auth']['resetpassword'] = true;
	\$conf['auth']['alternate_login'] = false;
	\$conf['auth']['redirect_on_logout'] = false;
	\$conf['auth']['list_users'] = 'list';
	\$conf['auth']['params']['basedn'] = '$LDAPUSERSDN';
	\$conf['auth']['params']['scope'] = 'sub';
	\$conf['auth']['params']['ad'] = false;
	\$conf['auth']['params']['uid'] = 'uid';
	\$conf['auth']['params']['encryption'] = 'ssha';
	\$conf['auth']['params']['newuser_objectclass'] =
		array('inetOrgPerson', 'inetLocalMailRecipient');
	\$conf['auth']['params']['filter'] = '(objectclass=inetOrgPerson)';
	\$conf['auth']['params']['password_expiration'] = 'no';
	\$conf['auth']['params']['driverconfig'] = 'horde';
	\$conf['auth']['driver'] = 'ldap';
	\$conf['auth']['params']['count_bad_logins'] = false;
	\$conf['auth']['params']['login_block'] = false;
	\$conf['auth']['params']['login_block_count'] = 5;
	\$conf['auth']['params']['login_block_time'] = 5;
	\$conf['signup']['allow'] = false;
	\$conf['log']['priority'] = 'WARNING';
	\$conf['log']['ident'] = 'HORDE';
	\$conf['log']['name'] = LOG_USER;
	\$conf['log']['type'] = 'syslog';
	\$conf['log']['enabled'] = true;
	\$conf['log_accesskeys'] = false;
	\$conf['prefs']['maxsize'] = 65535;
	\$conf['prefs']['params']['driverconfig'] = 'horde';
	\$conf['prefs']['driver'] = 'Sql';
	\$conf['alarms']['params']['driverconfig'] = 'horde';
	\$conf['alarms']['params']['ttl'] = 300;
	\$conf['alarms']['driver'] = 'Sql';
	\$conf['group']['driverconfig'] = 'horde';
	\$conf['group']['driver'] = 'Sql';
	\$conf['perms']['driverconfig'] = 'horde';
	\$conf['perms']['driver'] = 'Sql';
	\$conf['share']['no_sharing'] = false;
	\$conf['share']['auto_create'] = true;
	\$conf['share']['world'] = true;
	\$conf['share']['any_group'] = false;
	\$conf['share']['hidden'] = false;
	\$conf['share']['cache'] = false;
	\$conf['share']['driver'] = 'Sqlng';
	\$conf['cache']['default_lifetime'] = 86400;
	\$conf['cache']['params']['sub'] = 0;
	\$conf['cache']['driver'] = 'File';
	\$conf['cache']['use_memorycache'] = '';
	\$conf['cachecssparams']['driver'] = 'filesystem';
	\$conf['cachecssparams']['filemtime'] = false;
	\$conf['cachecssparams']['lifetime'] = 86400;
	\$conf['cachecss'] = true;
	\$conf['cachejsparams']['driver'] = 'filesystem';
	\$conf['cachejsparams']['compress'] = 'php';
	\$conf['cachejsparams']['lifetime'] = 86400;
	\$conf['cachejs'] = true;
	\$conf['cachethemesparams']['check'] = 'appversion';
	\$conf['cachethemesparams']['lifetime'] = 604800;
	\$conf['cachethemes'] = true;
	\$conf['lock']['params']['driverconfig'] = 'horde';
	\$conf['lock']['driver'] = 'Sql';
	\$conf['token']['params']['driverconfig'] = 'horde';
	\$conf['token']['driver'] = 'Sql';
	\$conf['history']['params']['driverconfig'] = 'horde';
	\$conf['history']['driver'] = 'Sql';
	\$conf['davstorage']['params']['driverconfig'] = 'horde';
	\$conf['davstorage']['driver'] = 'Sql';
	\$conf['mailer']['params']['port'] = 587;
	\$conf['mailer']['params']['secure'] = 'tls';
	\$conf['mailer']['params']['auth'] = false;
	\$conf['mailer']['params']['lmtp'] = false;
	\$conf['mailer']['type'] = 'smtp';
	\$conf['vfs']['params']['driverconfig'] = 'horde';
	\$conf['vfs']['type'] = 'Sql';
	\$conf['sessionhandler']['type'] = 'Builtin';
	\$conf['sessionhandler']['hashtable'] = false;
	\$conf['spell']['params']['path'] = '/usr/bin/aspell';
	\$conf['spell']['driver'] = 'aspell';
	\$conf['gnupg']['keyserver'] = array('pool.sks-keyservers.net');
	\$conf['gnupg']['timeout'] = 10;
	\$conf['openssl']['cafile'] = '/etc/ssl/certs';
	\$conf['openssl']['path'] = '/usr/bin/openssl';
	\$conf['nobase64_img'] = false;
	\$conf['image']['driver'] = 'Imagick';
	\$conf['exif']['params']['exiftool'] = '/usr/bin/exiftool';
	\$conf['exif']['driver'] = 'Exiftool';
	\$conf['timezone']['location'] = 'ftp://ftp.iana.org/tz/tzdata-latest.tar.gz';
	\$conf['problems']['email'] = 'webmaster@$SERVER_FQDN';
	\$conf['problems']['maildomain'] = '$SERVER_FQDN';
	\$conf['problems']['tickets'] = false;
	\$conf['problems']['attachments'] = true;
	\$conf['menu']['links']['help'] = 'all';
	\$conf['menu']['links']['prefs'] = 'authenticated';
	\$conf['menu']['links']['problem'] = 'all';
	\$conf['menu']['links']['login'] = 'all';
	\$conf['menu']['links']['logout'] = 'authenticated';
	\$conf['portal']['fixed_blocks'] = array();
	\$conf['accounts']['params']['basedn'] = '$LDAPUSERSDN';
	\$conf['accounts']['params']['scope'] = 'sub';
	\$conf['accounts']['params']['attr'] = 'uid';
	\$conf['accounts']['params']['strip'] = true;
	\$conf['accounts']['params']['driverconfig'] = 'horde';
	\$conf['accounts']['driver'] = 'ldap';
	\$conf['user']['verify_from_addr'] = true;
	\$conf['user']['select_view'] = true;
	\$conf['facebook']['enabled'] = false;
	\$conf['twitter']['enabled'] = false;
	\$conf['urlshortener'] = 'TinyUrl';
	\$conf['weather']['provider'] = false;
	\$conf['imap']['enabled'] = false;
	\$conf['imsp']['enabled'] = false;
	\$conf['kolab']['enabled'] = false;
	\$conf['hashtable']['driver'] = 'none';
	\$conf['activesync']['enabled'] = false;
	/* CONFIG END. DO NOT CHANGE ANYTHING IN OR BEFORE THIS LINE. */
	EOF

# Enable Horde's mail module IMP to authenticate with the IMAP server
# using the credentials provided to horde
sudo tee $HORDE_DIR/imp/config/backends.local.php >/dev/null <<-EOF
	<?php
	\$servers['imap']['hordeauth'] = true;
	EOF

# Horde-alarms does not work properly.
# One issue is that the directory stored in the PEAR configuration
# is not correct. While this can be solved by cd'ing to /var/horde/lib
# in the crontab before executing horde-alarms, the other, bigger
# issue is that Horde attempts to log into the MySQL server without
# password if horde-alarms is run from the command line.
# if [[ -z $(grep horde-alarms /etc/crontab) ]]; then
# 	heading "Adding horde-alarms to system-wide crontab..."
# 	sudo tee -a /etc/crontab <<-EOF
# 		# Horde-alarms added by $0
# 		*/5 * * * *	www-data	/usr/bin/horde-alarms
# 	EOF
# else
# 	heading "Crontab already contains horde-alarms."
# fi

heading "Configuring Horde address books..."
TURBA_BACKENDS_LOCAL="$HORDE_DIR/turba/config/backends.local.php"
if [[ -z $(grep configure-server "$TURBA_BACKENDS_LOCAL" 2>/dev/null) ]]; then
	if [[ ! -e $TURBA_BACKENDS_LOCAL ]]; then
		sudo tee  "$TURBA_BACKENDS_LOCAL" >/dev/null <<-EOF
		<?php
		EOF
	fi
	sudo tee -a "$TURBA_BACKENDS_LOCAL" >/dev/null <<-EOF
	# Address books added by configure-server

	# Turn off MySQL-based address books
	\$cfgSources['localsql']['disabled'] = true;

	\$_ldap_uid = \$GLOBALS['registry']->getAuth('bare');

	# Configure shared LDAP address book
	\$cfgSources['localldap']['disabled'] = false;
	\$cfgSources['localldap']['title'] = _("Shared Address Book (LDAP)");
	\$cfgSources['localldap']['params']['server'] = 'localhost';
	\$cfgSources['localldap']['params']['root'] = '$LDAP_ADDRESSBOOK_DN';
	\$cfgSources['localldap']['params']['bind_dn'] = 'uid=' . \$_LDAP_UID . ',$LDAPUSERSDN';
	\$cfgSources['localldap']['params']['bind_password'] = \$GLOBALS['registry']->getAuthCredential('password');

	# Use the same mapping for both personal and shared LDAP address books
	\$cfgSources['localhost']['map'] = \$cfgSources['personal_ldap']['map'];

	# Configure personal LDAP address book
	\$cfgSources['personal_ldap']['disabled'] = false;
	\$cfgSources['personal_ldap']['title'] = _('Personal Address Book (LDAP)');
	\$cfgSources['personal_ldap']['params']['server'] = 'localhost';
	\$cfgSources['personal_ldap']['params']['root'] = 'ou=contacts,uid=' . \$_LDAP_UID . ',$LDAPUSERSDN';
	\$cfgSources['personal_ldap']['params']['bind_dn'] = 'uid=' . \$_LDAP_UID . ',$LDAPUSERSDN';
	\$cfgSources['personal_ldap']['params']['bind_password'] = \$GLOBALS['registry']->getAuthCredential('password');
	EOF
fi

if [[ ! -e $HORDE_DIR/config/hooks.php ]]
then
	heading "Adding Horde hooks..."
	sudo tee $HORDE_DIR/config/hooks.php >/dev/null <<EOF
<?php
class Horde_Hooks
{
	private function ldapSearchBase()
	{
		return '$LDAPUSERSDN';
	}

	private function getMailDomain()
	{
		preg_match('/dc=([^,]+),dc=(.+)\$/', \$this->ldapSearchBase(), \$matches);
		return \$matches[1] . "." . \$matches[2];
	}

	private function bindLdap(\$username)
	{
		\$conn = @ldap_connect('ldapi:///', '389');
		@ldap_set_option(\$conn, LDAP_OPT_PROTOCOL_VERSION, 3);
		\$pass = \$GLOBALS['registry']->getAuthCredential('password');
		@ldap_bind(\$conn, "uid=\$username," . \$this->ldapSearchBase(), \$pass);
		return \$conn;
	}

	private function getUserRecord(\$conn, \$username)
	{
			\$searchResult = @ldap_search(\$conn, \$this->ldapSearchBase(),
				'uid=' . \$username);
			return @ldap_get_entries(\$conn, \$searchResult);
	}

	public function prefs_init(\$pref, \$value, \$username, \$scope_ob)
	{
		switch (\$pref) {
		case 'from_addr':
			if (is_null(\$username)) {
				return \$value;
			}

			\$conn = \$this->bindLdap(\$username);
			\$information = \$this->getUserRecord(\$conn, \$username);
			if ((\$information === false) || (\$information['count'] == 0)) {
				 \$user = '';
			} else {
				# Must use lowercase attribute names!
				\$user = (\$information[0]['mailroutingaddress'][0] != '')
					? \$information[0]['mailroutingaddress'][0] . "@" . \$this->getMailDomain()
					: \$information[0]['uid'][0];
			}
			ldap_close(\$conn);

			return empty(\$user)
				? \$username
				: \$user;

		case 'fullname':
			if (is_null(\$username)) {
				return \$value;
			}

			\$conn = \$this->bindLdap(\$username);
			\$information = \$this->getUserRecord(\$conn, \$username);
			if ((\$information === false) || (\$information['count'] == 0)) {
				\$name = '';
			} else {
				\$name = \$information[0]['cn'][0];
			}
			ldap_close(\$conn);

			return empty(\$name)
				? \$username
				: \$name;
		}
	}
}
EOF
fi

if [[ ! -e $HORDE_DIR/config/prefs.local.php ]]
then
	heading "Configuring Horde prefs..."
	sudo tee $HORDE_DIR/config/prefs.local.php >/dev/null <<-EOF
	<?php
	\$_prefs['from_addr']['hook'] = true;
	\$_prefs['from_addr']['locked'] = true;
	\$_prefs['fullname']['hook'] = true;
	\$_prefs['fullname']['locked'] = true;
	\$_prefs['username']['locked'] = true;
	EOF
fi

if [[ ! -e /etc/apache2/sites-enabled/horde.conf ]]; then
	heading "Configuring Horde subdomain ($HORDE_FQDN) for Apache..."
	sudo tee /etc/apache2/sites-available/horde.conf > /dev/null <<EOF
<IfModule mod_ssl.c>
<VirtualHost *:80>
	ServerName $HORDE_FQDN
	Redirect permanent / https://$HORDE_FQDN/
</Virtualhost>
<VirtualHost *:443>
	ServerAdmin webmaster@$SERVER_FQDN
	ServerName $HORDE_FQDN
	DocumentRoot $HORDE_DIR
	<Directory $HORDE_DIR>
		AllowOverride None
		Order allow,deny
		allow from all
		Require all granted
	</Directory>

	LogLevel warn
	ErrorLog \${APACHE_LOG_DIR}/horde-error.log
	CustomLog \${APACHE_LOG_DIR}/horde-access.log combined

	SSLEngine on
	SSLCertificateFile    /etc/ssl/certs/${HORDE_FQDN}.pem
	SSLCertificateKeyFile /etc/ssl/private/${HORDE_FQDN}.key

	#SSLOptions +FakeBasicAuth +ExportCertData +StrictRequire
	<FilesMatch "\.(cgi|shtml|phtml|php)$">
		SSLOptions +StdEnvVars
	</FilesMatch>
	<Directory /usr/lib/cgi-bin>
		SSLOptions +StdEnvVars
	</Directory>

	BrowserMatch "MSIE [2-6]" nokeepalive ssl-unclean-shutdown downgrade-1.0 force-response-1.0
	# MSIE 7 and newer should be able to use keepalive
	BrowserMatch "MSIE [17-9]" ssl-unclean-shutdown
</VirtualHost>
</IfModule>
EOF
	sudo a2ensite horde
else
	heading "Horde subdomain for apache already configured."
fi

if [[ ! -a /etc/apache2/sites-enabled/owncloud.conf ]]; then
	heading "Configuring OwnCloud subdomain ($OWNCLOUD_FQDN) for Apache..."
	sudo tee /etc/apache2/sites-available/owncloud.conf > /dev/null <<EOF
<IfModule mod_ssl.c>
<VirtualHost *:80>
	ServerName $OWNCLOUD_FQDN
	Redirect permanent / https://$OWNCLOUD_FQDN/
</Virtualhost>
<VirtualHost *:443>
	ServerAdmin webmaster@$SERVER_FQDN
	ServerName $OWNCLOUD_FQDN
	DocumentRoot $OWNCLOUD_DIR
	<Directory $OWNCLOUD_DIR>
		AllowOverride None
		Order allow,deny
		allow from all
		Require all granted
	</Directory>

	LogLevel warn
	ErrorLog \${APACHE_LOG_DIR}/owncloud-error.log
	CustomLog \${APACHE_LOG_DIR}/owncloud-access.log combined

	SSLEngine on
	SSLCertificateFile    /etc/ssl/certs/${OWNCLOUD_FQDN}.pem
	SSLCertificateKeyFile /etc/ssl/private/${OWNCLOUD_FQDN}.key

	#SSLOptions +FakeBasicAuth +ExportCertData +StrictRequire
	<FilesMatch "\.(cgi|shtml|phtml|php)$">
		SSLOptions +StdEnvVars
	</FilesMatch>
	<Directory /usr/lib/cgi-bin>
		SSLOptions +StdEnvVars
	</Directory>

	BrowserMatch "MSIE [2-6]" nokeepalive ssl-unclean-shutdown downgrade-1.0 force-response-1.0
	# MSIE 7 and newer should be able to use keepalive
	BrowserMatch "MSIE [17-9]" ssl-unclean-shutdown
</VirtualHost>
</IfModule>
EOF
	# sudo a2ensite owncloud
	message "Note: If you want to enable the owncloud Apache site," \
		"enter 'sudo a2ensite owncloud.config'"
else
	heading "OwnCloud subdomain ($OWNCLOUD_FQDN) for Apache already configured."
	message "(Enable with 'sudo a2ensite owncloud.config if desired.)"
fi
sudo a2enmod ssl rewrite

# If the default SSL host configuration contains the original 'snakeoil'
# certificate, replace it with our own.
DEFAULT_SSL_CONF=/etc/apache2/sites-available/default-ssl.conf
if [[ $(grep -i "snakeoil" $DEFAULT_SSL_CONF) ]]; then
	message "Configuring default SSL host to use our own certificate."
	sudo sed -i -r 's_^(\s*SSLCertificateFile\s+).*$_\1/etc/ssl/certs/'$SERVER_FQDN'.pem_' \
		$DEFAULT_SSL_CONF
	sudo sed -i -r 's_^(\s*SSLCertificateKeyFile\s+).*$_\1/etc/ssl/private/'$SERVER_FQDN'.key_' \
		$DEFAULT_SSL_CONF
	sudo a2ensite default-ssl.conf
else
	message "Default SSL host already configured to use our own certificate."
fi


heading "Update OwnCloud config (if exists) with current database password..."
sudo sed -i -r 's/(\s*.dbuser\s+=>\s+).*$/\1'"'$OWNCLOUD_MYSQL_USER',/" \
	/var/owncloud/config/config.php
sudo sed -i -r 's/(\s*.dbpassword.\s+=>\s+).*$/\1'"'$OWNCLOUD_PASS',/" \
	/var/owncloud/config/config.php

# Remove the default Apache2 page and turn Indexes off
sudo sed -i -r 's/^(\s*Options.+)(Indexes ?)(.*)$/\1\3/' /etc/apache2/apache2.conf

INDEX_HTML=/var/www/html/index.html
if [[ -e $INDEX_HTML ]]; then
	DEFAULT_SITE_ORIG=$(sha1sum /usr/share/apache2/default-site/index.html | awk '{print $1}')
	DEFAULT_SITE_CURR=$(sha1sum $INDEX_HTML | awk '{print $1}')
	if [[ $DEFAULT_SITE_CURR == $DEFAULT_SITE_ORIG ]]; then
		heading "Removing default Apache page..."
		sudo rm $INDEX_HTML
	fi
fi


# #######################################################################
# Finish up
# #######################################################################

heading "Restarting services..."
sudo postfix reload
sudo service dovecot restart
sudo service apache2 restart

# Multi-line variable: see http://stackoverflow.com/a/1655389/270712
read -r -d '' PWMSG <<EOF
Control users have been set up in MySQL and OpenLDAP for Horde, OwnCloud, 
Postfix, and Dovecot.  They share the same passwords.  Please make a note of 
these passwords somewhere safe, then delete this information.

$(printf "%-11s %-10s %-42s %s" "Application" "MySQL user" "LDAP user" "Password")
$(printf "%-11s %-10s %-42s %s" "-----------" "----------" "---------" "--------")
$(printf "%-11s %-10s %-42s %s" "Horde" "$HORDE_MYSQL_USER" "$HORDE_LDAP_USER" "$HORDE_PASS")
$(printf "%-11s %-10s %-42s %s" "OwnCloud" "$OWNCLOUD_MYSQL_USER" "$OWNCLOUD_LDAP_USER" "$OWNCLOUD_PASS")
$(printf "%-11s %-10s %-42s %s" "Dovecot" "n/a" "$DOVECOT_LDAP_USER" "$DOVECOT_PASS")
$(printf "%-11s %-10s %-42s %s" "Postfix" "n/a" "$POSTFIX_LDAP_USER" "$POSTFIX_PASS")


These are the SHA1 fingerprints of the SSL certificates:

$(printf "%-20s %s" "$SERVER_FQDN" $(get_fingerprint $SERVER_FQDN))
$(printf "%-20s %s" "$HORDE_FQDN" $(get_fingerprint $HORDE_FQDN))
$(printf "%-20s %s" "$OWNCLOUD_FQDN" $(get_fingerprint $OWNCLOUD_FQDN))
$(printf "%-20s %s" "Dovecot IMAP server" $(get_fingerprint $SERVER_FQDN))
EOF

INFOFILE=readme-configure-server
echo "$PWMSG" > ~/$INFOFILE
echo -e "\nThis file was generated by $0, version $VERSION." >> ~/$INFOFILE

# Send a mail to root informing about user names and passwords etc.
# We add a content-type header to enable mail readers to reflow the
# text; continued lines should end with two spaces (one of which will
# be removed by mail readers). 
mail \
	-a "Content-Type: text/plain; charset=utf-8; format=flowed; DelSp=Yes" \
 	-s "Message from $0" root <<EOF
Hello root,

the configure-server script has finished setting up the server at $SERVER_FQDN.

Script command line: $0

$PWMSG


Horde
-----

Horde has been set up at address http://$HORDE_FQDN


OwnCloud
--------

An Apache virtual host for OwnCloud has been set up at http://$OWNCLOUD_FQDN  
However, OwnCloud has not been automatically installed. To install, download  
the server package from http://owncloud.org, extract it into ${OWNCLOUD_DIR%/owncloud}  
(sudo tar xjf owncloud-x.y.z.tar.bz2 -C ${OWNCLOUD_DIR%/owncloud}),  
and change the ownership for Apache (sudo chown -R www-data $OWNCLOUD_DIR).

To configure OwnCloud to user the LDAP directory for user management, enter the  
OwnCloud LDAP user credentials (see above) in the OwnCloud LDAP form, and make  
it look under \`$LDAPUSERSDN\` for \`inetOrgPerson\` entries. See the  
OwnCloud administrator's manual for details.

*Please note:* If you are going to configure OwnCloud to look up users in the  
LDAP directory, the 'admin user' that is created by the configure-server script  
needs to be given administrator rights via OwnCloud's user management page.  
You may want to give the initial OwnCloud user a special name since you won't  
need this initial user to log in to OwnCloud very often.  If you log in to  
OwnCloud with the admin user from the LDAP directory, you can delete the  
initial OwnCloud user (provided the admin user from the LDAP directory was  
given admin rights by the initial OwnCloud user first).

-- 
$HOMEPAGE
EOF

heading "Finished."
echo "$PWMSG"
cat <<-EOF


	This information has also been stored in ~/$INFOFILE, and it was mailed to
	you.  Please delete both this file and the e-mail once you have memorized the
	information.

	$HOMEPAGE
EOF

# vim: fo+=ro ts=2 sw=2 noet nowrap
