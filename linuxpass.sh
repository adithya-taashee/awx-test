#!/bin/bash
set -euo pipefail

# --- Parse arguments ---
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
      echo "Usage: $0 -smtpUser <user> -smtpPassword <password>"
      exit 1
      ;;
  esac
done

# --- Check credentials ---
if [[ -z "${SMTP_USER:-}" || -z "${SMTP_PASS:-}" ]]; then
  echo "SMTP credentials are required."
  exit 1
fi

# --- SMTP settings ---
SMTP_SERVER="smtp.office365.com"
SMTP_PORT=587
FROM="$SMTP_USER"
TO="internalapollo@taashee.com"
SUBJECT="[$(hostname)] Local User Password Status Report"
LOG_FILE="/tmp/mail_send.log"

# --- Host details ---
HOSTNAME=$(hostname)
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")

# --- Temporary files ---
TMP_HTML=$(mktemp /tmp/password_report.XXXX.html)
TMP_MAIL=$(mktemp /tmp/password_report.XXXX.eml)

# --- Build HTML (MATCHES WINDOWS FORMAT) ---
cat > "$TMP_HTML" <<EOF
<html>
<head>
    <style>
        table {
            border-collapse: collapse;
            width: 100%;
            font-family: Arial, sans-serif;
        }
        th, td {
            border: 1px solid #dddddd;
            text-align: left;
            padding: 8px;
        }
        th {
            background-color: #f2f2f2;
        }
    </style>
</head>
<body>
    <p><strong>Password Expiry Alert</strong></p>
    <p>The following user accounts on <strong>$hostname</strong> have passwords expiring in less than 50 days or already expired:</p>
    <table>
        <tr>
            <th>Host</th>
            <th>IP Address</th>
            <th>Username</th>
            <th>Days Until Expiry</th>
        </tr>
EOF

# --- Loop through users (UID >= 1000) ---
while IFS=: read -r user _ uid _ _ _ _; do
  [[ "$uid" -lt 1000 ]] && continue

  expiry_line=$(chage -l "$user" 2>/dev/null | grep "Password expires" || true)
  expiry_date=$(echo "$expiry_line" | awk -F": " '{print $2}')

  if [[ -z "$expiry_date" || "$expiry_date" == "never" ]]; then
    status="Never Expires"
  else
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "")
    if [[ -z "$expiry_epoch" ]]; then
      status="Unknown"
    else
      now_epoch=$(date +%s)
      days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      if (( days_left < 0 )); then
        status="Expired"
      else
        status="$days_left days"
      fi
    fi
  fi

  printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n" \
    "$HOSTNAME" "$IP" "$user" "$status" >> "$TMP_HTML"

done < <(getent passwd)

# --- Finish HTML ---
cat >> "$TMP_HTML" <<EOF
    </table>
    <p>Thanks and Regards,<br/>Apollo ProProtect Admin</p>
</body>
</html>
EOF

# --- Build MIME mail ---
{
  echo "From: $FROM"
  echo "To: $TO"
  echo "Subject: $SUBJECT"
  echo "MIME-Version: 1.0"
  echo "Content-Type: text/html; charset=UTF-8"
  echo
  cat "$TMP_HTML"
} > "$TMP_MAIL"

# --- Send mail via Office365 ---
echo "Sending report via Office365 SMTP..."
curl --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
     --ssl-reqd \
     --mail-from "$FROM" \
     --mail-rcpt "$TO" \
     --upload-file "$TMP_MAIL" \
     --user "$SMTP_USER:$SMTP_PASS" \
     --verbose &> "$LOG_FILE" || {
        echo "Mail send failed. Check $LOG_FILE"
        exit 1
     }

echo "Mail sent successfully."
rm -f "$TMP_HTML" "$TMP_MAIL"

