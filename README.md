# VPS Monitoring Script using Bash

This project is a simple VPS monitoring system built using Bash scripting.

It helps you monitor system health and receive email alerts when something goes wrong.

---

## 🚀 Features

* Monitor CPU usage
* Monitor RAM usage
* Monitor disk usage
* Check load average
* Monitor system services (SSH, cron, etc.)
* Detect zombie processes
* Send email alerts
* Automatic log rotation

---

## ⚙️ Requirements

* Linux VPS (Ubuntu / AlmaLinux / etc.)
* Bash
* Postfix (for email alerts)

---

## 📦 Setup Guide

### 1. Clone the repository

```bash
git clone https://github.com/YOUR_USERNAME/vps-monitoring-bash.git
cd vps-monitoring-bash
```

---

### 2. Make the script executable

```bash
chmod +x vps_monitor.sh
```

---

### 3. Configure settings

Edit the config file:

```bash
nano monitor.conf
```

Update:

* ALERT_EMAIL
* Threshold values (CPU, RAM, Disk, etc.)
* Services to monitor

---

### 4. Setup Postfix (Email alerts)

Install postfix:

```bash
sudo apt install postfix
```

Choose:

```
Internet Site
```

Set system mail name:

```
your-hostname
```

---

### 5. (Recommended) Configure Gmail SMTP relay

Because direct VPS emails may fail or go to spam.

Add to `/etc/postfix/main.cf`:

```bash
relayhost = [smtp.gmail.com]:587
smtp_use_tls = yes
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
```

Create credentials:

```bash
echo "[smtp.gmail.com]:587 your-email@gmail.com:APP_PASSWORD" | sudo tee /etc/postfix/sasl_passwd
sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd
sudo systemctl restart postfix
```

---

### 6. Test the script

```bash
./vps_monitor.sh
```

Check logs:

```bash
cat /var/log/vps_monitor/monitor_$(date +%Y-%m-%d).log
```

---

### 7. Automate with cron

```bash
crontab -e
```

Example (run every 15 minutes):

```bash
*/15 * * * * /path/to/vps_monitor.sh
```

---

## 📊 How it works

* CPU: Reads `/proc/stat`
* RAM: Reads `/proc/meminfo`
* Disk: Uses `df`
* Services: Uses `systemctl`
* Logs: Stored daily and rotated automatically

---

## 📚 What you will learn

* Bash scripting fundamentals
* Linux system monitoring
* Working with `/proc`
* Cron jobs
* Postfix mail setup
* Log management

---

## 💡 Notes

* Gmail SMTP is recommended for reliable email delivery
* Adjust thresholds based on your server capacity

---

## 🙌 Contribution

Feel free to improve or extend this project.

---
