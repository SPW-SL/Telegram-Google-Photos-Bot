<div align="center">

```text
  ____   ___ _____ ____    ____  __   __  ____  ______        __
 | __ ) / _ \_   _/ ___|  | __ ) \ \ / / / ___||  _ \ \      / /
 |  _ \| | | || | \___ \  |  _ \  \ V /  \___ \| |_) \ \ /\ / / 
 | |_) | |_| || |  ___) | | |_) |  | |    ___) |  __/ \ V  V /  
 |____/ \___/ |_| |____/  |____/   |_|   |____/|_|     \_/\_/   
```

# 📸 Telegram-to-Google Photos EXIF Time-Machine & Group Sync Bot

[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)](https://github.com/SPW-SL)
[![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://github.com/SPW-SL)
[![Google Photos API](https://img.shields.io/badge/Google%20Photos-API%20v1-4285F4?style=for-the-badge&logo=googlephotos&logoColor=white)](https://github.com/SPW-SL)
[![ExifTool](https://img.shields.io/badge/Metadata-ExifTool-FF6F00?style=for-the-badge)](https://github.com/SPW-SL)
[![Maintained](https://img.shields.io/badge/Bots%20By-SPW--SL-00C853?style=for-the-badge)](https://github.com/SPW-SL)

**Migrate your photos and videos from private Telegram groups directly into your Google Photos Library with exact historical dates and strict chronological ordering.**  
Automatically strips out text, voice notes, audio, and stickers, injects real `EXIF` & `QuickTime` creation headers via `exiftool`, uploads to Google Photos, and erases temporary files from your VPS (`0.00 B` left behind).

[🚀 One-Line Install](#-one-line-vps-installation) • [✨ Key Features](#-key-features) • [🔑 Google OAuth Setup](#-google-cloud-oauth-setup-2-minutes) • [📖 Usage Guide](#-interactive-usage-guide) • [⌨️ Bot Commands](#️-bot-commands)

</div>

---

## ✨ Key Features

| Feature | Description |
| :--- | :--- |
| 🕒 **True EXIF & QuickTime Time-Machine** | Telegram strips camera dates when forwarding. This bot uses `exiftool` to inject `DateTimeOriginal`, `CreateDate`, `XMP:CreateDate`, and QuickTime `CreationTime` headers so Google Photos places your media on the exact historical date you choose. |
| 🔢 **Strict Chronological Order (`+1s` Sequence)** | Pre-assigns timestamps in ascending message ID order (`12:00:01`, `12:00:02`, `12:00:03`...) so albums and batches appear in Google Photos in the exact order they were posted in Telegram. |
| 📅 **Dual Date Modes (Custom or Post Date)** | Stamp a custom date (`/date 2021-08-15`) onto a batch of photos, OR switch to **`/date msg`** to automatically stamp each photo/video with the original date it was uploaded to your Telegram group. |
| 🛡️ **Strict Photo & Video Filter** | Automatically filters out text messages, voice notes, music/audio files, static/animated/video stickers (`.webp`, `.tgs`, `.webm`), and GIFs during group syncs. |
| 🔄 **Direct Private Group Sync (`/sync`)** | No need to forward thousands of messages manually. Link your account via `/qr` and paste your private group link (`https://t.me/c/xxxx/500`) to sync any custom message range. |
| 🧹 **Zero-Storage VPS Pipeline** | Every photo and video is processed in an isolated `/opt/gphotosbot/cache/` subfolder and deleted inside a `finally:` block the instant its Google Photos upload finishes. |

---

## 🚀 One-Line VPS Installation

Run on any **Ubuntu 20.04 / 22.04 / 24.04** server as `root`:

```bash
curl -sSL [https://raw.githubusercontent.com/SPW-SL/Telegram-Google-Photos-Bot/main/install.sh](https://raw.githubusercontent.com/SPW-SL/Telegram-Google-Photos-Bot/main/install.sh) -o install.sh && sudo bash install.sh
```

<details>
<summary><b>🔽 Click to view Manual Git Clone Installation</b></summary>

```bash
git clone [https://github.com/SPW-SL/Telegram-Google-Photos-Bot.git](https://github.com/SPW-SL/Telegram-Google-Photos-Bot.git)
cd Telegram-Google-Photos-Bot
chmod +x install.sh
sudo ./install.sh
```

</details>

---

## 🧠 How the Pipeline Works

```text
[Private Telegram Group OR Forwarded Media]
         │
         ├──► 1. Strict Filter: Rejects Text, Voice Notes, Audio, Stickers (.webp/.tgs/.webm) & GIFs
         │
         ├──► 2. Sequence Lock: Assigns Target Date +1s per item in ascending Message ID order
         │
         ├──► 3. Temp Cache: Downloads to /opt/gphotosbot/cache/item_<id>/
         │
         ├──► 4. ExifTool Engine: Rewrites binary EXIF (Photos) & QuickTime UTC atoms (Videos)
         │
         └──► 5. Google Photos API: Streams bytes ──► Adds to Library/Album ──► Wipes VPS Cache (0.00 B)
```

---

## 🔑 Google Cloud OAuth Setup (2 Minutes)

<details open>
<summary><b>Step-by-step guide to getting your free Google Photos API credentials</b></summary>

1. Open the [Google Cloud Console](https://console.cloud.google.com/) and create a new project.
2. Go to **APIs & Services → Library**, search for **Photos Library API**, and click **Enable**.
3. Go to **APIs & Services → OAuth consent screen**:
   * Select **External**, enter an App Name (e.g., `SPW Photos Uploader`), and save.
   * Under **Test users**, click **+ Add Users** and add your personal Gmail address.
4. Go to **APIs & Services → Credentials**:
   * Click **+ Create Credentials → OAuth client ID**.
   * Choose **Desktop app** as the Application type.
   * Download the JSON file (`client_secret.json`).
5. **Upload `client_secret.json` directly to your Telegram Bot** in chat! The bot will automatically import your credentials, delete the file from chat for security, and prompt you to run `/auth`.

</details>

---

## 📖 Interactive Usage Guide

<details open>
<summary><b>Method A: Direct Private Group Range Sync (Recommended for Large Backups)</b></summary>

1. Send **`/qr`** to the bot and scan the QR code from your Telegram app (**Settings → Devices → Link Desktop Device**).
2. Choose your date mode:
   * Send **`/date 2022-05-14`** to stamp a specific date on all synced files, OR
   * Send **`/date msg`** to use each photo/video's original Telegram group upload date.
3. Paste the link to a post in your private group (e.g., `https://t.me/c/123456789/1500`) or run:
   ```text
   /sync [https://t.me/c/123456789/1500](https://t.me/c/123456789/1500) 1 1500
   ```
4. Tap **`🚀 Start Ordered Google Photos Sync`**.

</details>

<details>
<summary><b>Method B: Manual Forwarding</b></summary>

1. Send **`/date YYYY-MM-DD`** (e.g., `/date 2023-12-25 18:00:00`) to set the target date.
2. *(Optional)* Send **`/album Vacation 2023`** to create and target a specific Google Photos album.
3. Forward your photos and videos from any chat to the bot!

</details>

---

## ⌨️ Bot Commands

| Command | Description |
| :--- | :--- |
| `/start` | Open the interactive dashboard and view Google Photos & Telegram session status. |
| `/auth` | Generate a headless Google OAuth login link to connect your Google Photos account. |
| `/setcreds <id> <secret>` | Set Google OAuth Client ID and Secret manually (or upload `client_secret.json`). |
| `/date <YYYY-MM-DD>` | Set a custom date (and optional `HH:MM:SS` time) for all upcoming uploads. |
| `/date msg` | Stamp each photo/video with the original date it was posted to your Telegram group. |
| `/album <name>` | Create/select a Google Photos album for uploads (use `/album off` to disable). |
| `/qr` | Connect your Telegram User Session via QR code (no SMS OTP required) for group syncing. |
| `/sync <link> [start] [end]` | Pull, filter, re-date, and upload photos/videos from a private group range in order. |
| `/resumesync` | Resume an interrupted group sync from the exact last saved message ID. |
| `/cleancache` or `/clean` | Force-wipe `/opt/gphotosbot/cache` and verify `0.00 B` disk usage. |

---

## 🖥️ Terminal SSH Manager (`gphotos-bot`)

Run **`gphotos-bot`** anywhere in your VPS terminal to manage the background service, inspect live logs, or clean the cache:

```text
======================================================================
              GOOGLE PHOTOS BOT - SSH MANAGEMENT MENU
======================================================================
1) Check Bot Status
2) View Live Logs (Ctrl+C to exit)
3) Restart Bot
4) Stop Bot
5) Force Clean Cache (/opt/gphotosbot/cache)
6) Edit config.json
7) Uninstall Google Photos Bot
0) Exit
======================================================================
```

---

<div align="center">
  <b>Developed & Maintained by <a href="https://github.com/SPW-SL">BOTS BY SPW (SPW-SL)</a></b>
</div>
