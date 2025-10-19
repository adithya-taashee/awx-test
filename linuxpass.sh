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
TO="ashok.t@taashee.com"
SUBJECT="[$(hostname)] Linux User Password Expiry Report"
LOG_FILE="/tmp/mail_send.log"

# --- Other settings ---
MAX_WARN_DAYS=50
HOSTNAME=$(hostname)
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")

# --- Temporary report files ---
TMP_HTML=$(mktemp /tmp/password_expiry_report.XXXX.html)
TMP_MAIL=$(mktemp /tmp/password_expiry_report.XXXX.eml)

# --- Build HTML report ---
cat > "$TMP_HTML" <<EOF
<html><body>
<h3>Password Expiry Report</h3>
<p>The following user accounts on <strong>$HOSTNAME</strong> have their password expiry status:</p>
<table border='1' cellpadding='5' cellspacing='0'>
<tr style='background-color:#e0e0e0;'>
<th>Host</th><th>IP Address</th><th>Username</th><th>Status</th>
</tr>
EOF

# --- Loop through users with UID >= 1000 ---
while IFS=: read -r user _ uid _ _ _ _; do
  if [[ "$uid" -lt 1000 ]]; then
    continue
  fi

  expiry_info=$(chage -l "$user" 2>/dev/null | grep "Password expires" || true)
  expiry_date=$(echo "$expiry_info" | awk -F": " '{print $2}')

  if [[ -z "$expiry_date" || "$expiry_date" == "never" ]]; then
    status="Never Expires"
    color="#ccffcc"
  else
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "")
    if [[ -z "$expiry_epoch" ]]; then
      status="Unknown"
      color="#ffffff"
    else
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
  fi

  printf "<tr style='background-color:%s;'><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n" \
    "$color" "$HOSTNAME" "$IP" "$user" "$status" >> "$TMP_HTML"
done < <(getent passwd)

# --- Finish HTML ---
cat >> "$TMP_HTML" <<EOF
</table>
<p>Thanks and Regards,<br/>
<b>Apollo ProProtect Admin</b></p>
</body></html>
EOF

# --- Build complete MIME mail message ---
{
  echo "From: $FROM"
  echo "To: $TO"
  echo "Subject: $SUBJECT"
  echo "MIME-Version: 1.0"
  echo "Content-Type: text/html; charset=UTF-8"
  echo
  cat "$TMP_HTML"
} > "$TMP_MAIL"

# --- Send mail using curl SMTP (STARTTLS) ---
echo "Sending report via curl SMTP (Office365)..."
{
  curl --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
       --ssl-reqd \
       --mail-from "$FROM" \
       --mail-rcpt "$TO" \
       --upload-file "$TMP_MAIL" \
       --user "$SMTP_USER:$SMTP_PASS" \
       --verbose
} &> "$LOG_FILE" || {
  echo "Mail send failed. Check $LOG_FILE for details."
  exit 1
}

echo "Mail sent successfully."
echo "Detailed log available at $LOG_FILE"

# --- Cleanup temporary files ---
rm -f "$TMP_HTML" "$TMP_MAIL"
