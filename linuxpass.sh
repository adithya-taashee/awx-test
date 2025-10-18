#!/bin/bash

# --- Parameters ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -smtpUser)
      SMTP_USER="$2"
      shift 2
      ;;
    -smtpPassword)
      SMTP_PASS="$2"
      shift 2
      ;;
    *)
      echo "Unknown parameter: $1"
      echo "Usage: $0 [-smtpUser <user>] [-smtpPassword <password>]"
      exit 1
      ;;
  esac
done

# --- Fallback to environment variables ---
SMTP_USER="${SMTP_USER:-$SMTP_USER_ENV}"
SMTP_PASS="${SMTP_PASS:-$SMTP_PASSWORD_ENV}"

# --- Check for missing credentials ---
if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" ]]; then
  echo "SMTP credentials are missing. Provide -smtpUser and -smtpPassword or set SMTP_USER_ENV/SMTP_PASSWORD_ENV."
  exit 1
fi

# --- SMTP and mail settings ---
SMTP_SERVER="smtp.office365.com"
SMTP_PORT=587
FROM="$SMTP_USER"
TO="ashok.t@taashee.com"

# --- Warning threshold in days ---
MAX_WARN_DAYS=50

HOSTNAME=$(hostname)
IP=$(hostname -I | awk '{print $1}')
TMP_HTML="/tmp/password_expiry_report.html"

# --- Build HTML report ---
cat <<EOF > "$TMP_HTML"
<html><body>
<h3>Password Expiry Report</h3>
<p>The following user accounts on <strong>$HOSTNAME</strong> have their password expiry status:</p>
<table border='1' cellpadding='5' cellspacing='0'>
<tr style='background-color:#e0e0e0;'>
<th>Host</th><th>IP Address</th><th>Username</th><th>Status</th>
</tr>
EOF

# --- Loop through non-system users (UID >= 1000) ---
for user in $(getent passwd | awk -F: '$3>=1000 {print $1}'); do
  expiry_info=$(chage -l "$user" 2>/dev/null | grep "Password expires")
  expiry_date=$(echo "$expiry_info" | awk -F": " '{print $2}')

  if [[ "$expiry_date" == "never" || -z "$expiry_date" ]]; then
    status="Never Expires"
    color="#ccffcc"
  else
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
    current_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

    if (( days_left < 0 )); then
      status="Expired ($((-days_left)) days ago)"
      color="#ffcccc"
    elif (( days_left < MAX_WARN_DAYS )); then
      status="Expires in $days_left days (Warning)"
      color="#ffffcc"
    else
      status="Expires in $days_left days"
      color="#ccffcc"
    fi
  fi

  echo "<tr style='background-color:$color;'><td>$HOSTNAME</td><td>$IP</td><td>$user</td><td>$status</td></tr>" >> "$TMP_HTML"
done

# --- Finish HTML ---
cat <<EOF >> "$TMP_HTML"
</table>
<p>Thanks and Regards,<br/>
<b>Apollo ProProtect Admin</b></p>
</body></html>
EOF

# --- Send email (using mail or swaks if available) ---
SUBJECT="[$HOSTNAME] Linux User Password Expiry Report"

if command -v mail >/dev/null 2>&1; then
  cat "$TMP_HTML" | mail -a "Content-Type: text/html" -s "$SUBJECT" "$TO"
  echo "Report sent via mail to $TO"
elif command -v swaks >/dev/null 2>&1; then
  swaks --to "$TO" \
        --from "$FROM" \
        --server "$SMTP_SERVER" \
        --port "$SMTP_PORT" \
        --auth LOGIN \
        --auth-user "$SMTP_USER" \
        --auth-password "$SMTP_PASS" \
        --header "Subject: $SUBJECT" \
        --body "$(cat "$TMP_HTML")" \
        --content-type "text/html" \
        --tls
  echo "Report sent via swaks to $TO"
else
  echo "Neither 'mail' nor 'swaks' command is available. Please install one to send emails."
fi
