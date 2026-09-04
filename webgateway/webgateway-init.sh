#!/bin/sh
# Web Gateway bootstrap for the AI Hub EAP iris-community image, which has no
# private web server (WebServer=0, no CSP binaries). Fixes the three known
# webgateway bugs: CSP.ini init race, missing [LOCAL] credentials, and the
# CSP On (not SetHandler) Apache directive.
/startWebGateway &

# Bug 1: CSP.ini is written asynchronously — wait before patching
for i in $(seq 1 60); do
    grep -q "Configuration_Initialized" /opt/webgateway/bin/CSP.ini 2>/dev/null && break
    sleep 1
done

# Bug 2: default [LOCAL] has no credentials (CSPSystem doesn't exist here).
# Guard the insert — a container restart re-runs this script against the
# already-patched CSP.ini and would otherwise duplicate the credentials.
grep -q '^Username=_SYSTEM' /opt/webgateway/bin/CSP.ini \
    || sed -i '/^\[LOCAL\]/a Username=_SYSTEM\nPassword=SYS' /opt/webgateway/bin/CSP.ini

# Point [LOCAL] at the IRIS service (Docker DNS name, not localhost)
sed -i 's/^Ip_Address=127\.0\.0\.1/Ip_Address=iris/' /opt/webgateway/bin/CSP.ini

# The index advisor waits on a local LLM: ~50s is normal, and the gateway's
# 60s default cuts the connection mid-answer, which reaches the browser as an
# empty body ("JSON.parse: unexpected end of data"). Give it room.
sed -i 's/^Server_Response_Timeout=.*/Server_Response_Timeout=300/' /opt/webgateway/bin/CSP.ini
sed -i 's/^Queued_Request_Timeout=.*/Queued_Request_Timeout=300/' /opt/webgateway/bin/CSP.ini

# Bug 3: only "CSP On" routes correctly (official ISC webgateway-examples pattern)
cat > /etc/apache2/conf-enabled/CSP.conf << "EOF"
CSPModulePath "${ISC_PACKAGE_INSTALLDIR}/bin/"
CSPConfigPath "${ISC_PACKAGE_INSTALLDIR}/bin/"

<Location />
    CSP On
</Location>

<Directory "${ISC_PACKAGE_INSTALLDIR}/bin/">
    AllowOverride None
    Options None
    Require all granted
    <FilesMatch "\.(log|ini|pid|exe)$">
         Require all denied
    </FilesMatch>
</Directory>
EOF

apachectl graceful 2>/dev/null || true
wait
