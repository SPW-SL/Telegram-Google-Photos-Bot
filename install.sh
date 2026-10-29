#!/bin/bash
set -e

INSTALL_DIR="/opt/gphotosbot"
CACHE_DIR="$INSTALL_DIR/cache"
CONFIG_FILE="$INSTALL_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/gphotosbot.service"
CLI_BIN="/usr/local/bin/gphotos-bot"

clear
cat << "BANNER_EOF"
======================================================================
  ____   ___ _____ ____    ____  __   __  ____  ______        __
 | __ ) / _ \_   _/ ___|  | __ ) \ \ / / / ___||  _ \ \      / /
 |  _ \| | | || | \___ \  |  _ \  \ V /  \___ \| |_) \ \ /\ / / 
 | |_) | |_| || |  ___) | | |_) |  | |    ___) |  __/ \ V  V /  
 |____/ \___/ |_| |____/  |____/   |_|   |____/|_|     \_/\_/   
                                                                
   📸 TELEGRAM GROUP TO GOOGLE PHOTOS EXIF TIME-MACHINE BOT 📸
======================================================================
BANNER_EOF

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this installer as root (sudo bash install.sh)."
    exit 1
fi

echo ""
echo "💡 KEY FEATURES & RECOMMENDATIONS:"
echo " • Strict Order     : Preserves exact message sequence (+1s per file)."
echo " • Smart Filtering  : Uploads ONLY Photos & Videos (skips text/voice/stickers)."
echo " • Dual Date Modes  : Stamp a Custom Date or keep Original Telegram Post Date."
echo " • Zero Disk Bloat  : Every file is erased from VPS immediately after upload."
echo "======================================================================"

mkdir -p "$INSTALL_DIR" "$CACHE_DIR"

USE_EXISTING="n"
if [ -f "$CONFIG_FILE" ]; then
    read -rp "⚙️  Existing config.json found. Keep current credentials? [Y/n]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
fi

if [[ ! "$USE_EXISTING" =~ ^[Yy]$ ]]; then
    echo ""
    echo "🔑 Enter your Telegram & Google OAuth Credentials:"
    echo "   (Tip: You can press Enter on Google Client ID/Secret and upload client_secret.json inside the bot!)"
    read -rp "👉 Enter Telegram APP API_ID (from my.telegram.org): " INPUT_API_ID
    read -rp "👉 Enter Telegram API_HASH: " INPUT_API_HASH
    read -rp "👉 Enter BOT_TOKEN (from @BotFather): " INPUT_BOT_TOKEN
    read -rp "👉 Enter ADMIN_IDS (space-separated, e.g. 111111111 222222222): " INPUT_ADMINS
    read -rp "👉 Enter Google OAuth CLIENT_ID (optional): " INPUT_G_ID
    read -rp "👉 Enter Google OAuth CLIENT_SECRET (optional): " INPUT_G_SEC

    ADMIN_JSON=$(echo "$INPUT_ADMINS" | tr ',' ' ' | awk '{
        printf "[";
        for(i=1;i<=NF;i++) {
            printf "%s%s", $i, (i<NF ? ", " : "");
        }
        printf "]";
    }')

    cat << CONFIG_EOF > "$CONFIG_FILE"
{
    "api_id": $INPUT_API_ID,
    "api_hash": "$INPUT_API_HASH",
    "bot_token": "$INPUT_BOT_TOKEN",
    "admin_ids": $ADMIN_JSON,
    "google_client_id": "$INPUT_G_ID",
    "google_client_secret": "$INPUT_G_SEC",
    "target_date": "2024-01-01 12:00:00",
    "date_mode": "custom",
    "album_name": "",
    "album_id": "",
    "parallel_workers": 1
}
CONFIG_EOF
    chmod 600 "$CONFIG_FILE"
    echo "✅ Configuration saved to $CONFIG_FILE"
fi

echo ""
echo "======================================================================"
echo " 📦 Installing System Dependencies (exiftool, ffmpeg, python3)..."
echo "======================================================================"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip ffmpeg libimage-exiftool-perl git curl

echo "======================================================================"
echo " 🐍 Setting Up Python Virtual Environment & Libraries..."
echo "======================================================================"
cd "$INSTALL_DIR"
if [ ! -f "$INSTALL_DIR/venv/bin/python3" ]; then
    python3 -m venv venv
fi
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --upgrade telethon cryptg aiohttp google-auth google-auth-oauthlib requests qrcode pillow

echo "======================================================================"
echo " 🤖 Deploying Bot Application ($INSTALL_DIR/gphotos_bot.py)..."
echo "======================================================================"
cat << 'PY_EOF' > "$INSTALL_DIR/gphotos_bot.py"
import os
import io
import re
import json
import time
import shutil
import asyncio
import logging
import subprocess
import urllib.parse
from datetime import datetime, timedelta
from pathlib import Path

import qrcode
import aiohttp
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from google_auth_oauthlib.flow import InstalledAppFlow
from telethon import TelegramClient, events, Button
from telethon.errors import FloodWaitError, SessionPasswordNeededError
from telethon.tl.types import (
    MessageService,
    MessageMediaPhoto,
    MessageMediaDocument,
    DocumentAttributeFilename,
    DocumentAttributeSticker,
    DocumentAttributeAudio,
    DocumentAttributeAnimated,
    DocumentAttributeVideo,
    DocumentAttributeImageSize,
)

BASE_DIR = Path("/opt/gphotosbot")
CACHE_DIR = BASE_DIR / "cache"
CONFIG_FILE = BASE_DIR / "config.json"
TOKEN_FILE = BASE_DIR / "google_token.json"
RESUME_SYNC_FILE = BASE_DIR / "resume_sync.json"
BOT_SESSION = str(BASE_DIR / "bot_session")
USER_SESSION = str(BASE_DIR / "user_session")

shutil.rmtree(CACHE_DIR, ignore_errors=True)
CACHE_DIR.mkdir(parents=True, exist_ok=True)

SCOPES = [
    "https://www.googleapis.com/auth/photoslibrary.appendonly",
    "https://www.googleapis.com/auth/photoslibrary.sharing"
]

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif"}
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".avi", ".3gp", ".m4v"}
MAX_WORKERS_LIMIT = 5

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

def load_config() -> dict:
    with open(CONFIG_FILE, "r") as f:
        data = json.load(f)
    data.setdefault("google_client_id", "")
    data.setdefault("google_client_secret", "")
    data.setdefault("target_date", "2024-01-01 12:00:00")
    data.setdefault("date_mode", "custom")  # "custom" or "msg"
    data.setdefault("album_name", "")
    data.setdefault("album_id", "")
    data.setdefault("parallel_workers", 1)
    return data

def save_config(data: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(data, f, indent=4)

def load_sync_resume():
    if RESUME_SYNC_FILE.exists():
        try:
            with open(RESUME_SYNC_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return None

def save_sync_resume(state: dict):
    with open(RESUME_SYNC_FILE, "w") as f:
        json.dump(state, f, indent=4)

CFG = load_config()
API_ID = int(CFG["api_id"])
API_HASH = CFG["api_hash"]
BOT_TOKEN = CFG["bot_token"]
ADMINS = set(CFG["admin_ids"])

loop = asyncio.new_event_loop()
asyncio.set_event_loop(loop)

def create_user_client():
    return TelegramClient(
        USER_SESSION,
        API_ID,
        API_HASH,
        loop=loop,
        device_model="Telegram Desktop",
        system_version="Windows 11 x64",
        app_version="5.6.3 x64",
        lang_code="en",
        system_lang_code="en-US"
    )

bot = TelegramClient(BOT_SESSION, API_ID, API_HASH, loop=loop)
user_client = create_user_client()

QUEUE = asyncio.Queue()
STATS = {"uploaded": 0, "failed": 0, "queued": 0, "skipped_non_media": 0}
SEQUENCE_COUNTER = 0
WAITING_INPUT = {}
LOGIN_STATE = {}
PENDING_SYNC = {}
SYNC_RANGE_WAIT = {}
ACTIVE_SYNC = {
    "running": False,
    "paused": False,
    "cancelled": False,
    "task": None
}
SYNC_WORKER_STATUS = {}
BATCH_CREATE_LOCK = asyncio.Lock()

def is_admin(uid: int) -> bool:
    return uid in ADMINS

def fmt_size(b: float) -> str:
    if b <= 0:
        return "0.00 B"
    for u in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024.0:
            return f"{b:.2f} {u}"
        b /= 1024.0
    return f"{b:.2f} PB"

def progress_bar(curr: float, tot: float, length: int = 10) -> str:
    if tot <= 0:
        return "░" * length
    filled = max(0, min(length, int(round((curr / tot) * length))))
    return "█" * filled + "░" * (length - filled)

def fmt_time(seconds: float) -> str:
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h > 0:
        return f"{h}h {m}m {s}s"
    if m > 0:
        return f"{m}m {s}s"
    return f"{s}s"

def get_dir_size(path_obj: Path) -> int:
    total = 0
    if not path_obj.exists():
        return 0
    for root, _, files in os.walk(path_obj):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total

def wipe_cache() -> tuple[int, int]:
    b = get_dir_size(CACHE_DIR)
    cnt = 0
    if CACHE_DIR.exists():
        for _, _, files in os.walk(CACHE_DIR):
            cnt += len(files)
        shutil.rmtree(CACHE_DIR, ignore_errors=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return b, cnt

def make_qr_png(url: str) -> io.BytesIO:
    qr = qrcode.QRCode(version=1, box_size=10, border=4)
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    bio = io.BytesIO()
    bio.name = "qr_login.png"
    img.save(bio, "PNG")
    bio.seek(0)
    return bio

async def is_user_logged_in() -> bool:
    try:
        if not user_client.is_connected():
            await user_client.connect()
        return await user_client.is_user_authorized()
    except Exception:
        return False

async def reset_user_session():
    global user_client
    try:
        if user_client.is_connected():
            await user_client.disconnect()
    except Exception:
        pass
    for ext in ("", ".session", ".session-journal"):
        p = Path(f"{USER_SESSION}{ext}")
        if p.exists():
            p.unlink(missing_ok=True)
    user_client = create_user_client()
    await user_client.connect()

# ================= STRICT PHOTO & VIDEO FILTER =================

def is_strict_photo_or_video(msg) -> tuple[bool, str]:
    """
    Strictly accepts ONLY genuine Photos and Videos.
    Automatically rejects text, voice notes, audio, stickers (.webp/.tgs/.webm), GIFs, and video notes.
    """
    if not msg or isinstance(msg, MessageService) or not msg.media:
        return False, ""

    if (
        getattr(msg, "sticker", None)
        or getattr(msg, "voice", None)
        or getattr(msg, "audio", None)
        or getattr(msg, "gif", None)
        or getattr(msg, "video_note", None)
        or getattr(msg, "poll", None)
        or getattr(msg, "contact", None)
    ):
        return False, ""

    if isinstance(msg.media, MessageMediaPhoto):
        return True, f"IMG_{msg.id}.jpg"

    if isinstance(msg.media, MessageMediaDocument) and msg.document:
        doc = msg.document
        mime = (doc.mime_type or "").lower()
        fname = ""
        has_video_attr = False
        has_image_attr = False

        for attr in doc.attributes:
            if isinstance(attr, (DocumentAttributeSticker, DocumentAttributeAudio, DocumentAttributeAnimated)):
                return False, ""
            if isinstance(attr, DocumentAttributeVideo):
                if getattr(attr, "round_message", False):
                    return False, ""
                has_video_attr = True
            if isinstance(attr, DocumentAttributeImageSize):
                has_image_attr = True
            if isinstance(attr, DocumentAttributeFilename):
                fname = attr.file_name

        ext = os.path.splitext(fname)[1].lower()

        if ext in (".tgs", ".webp") or mime in ("application/x-tgsticker", "image/webp"):
            return False, ""

        if ext in IMAGE_EXTS or (mime.startswith("image/") and has_image_attr):
            if not ext:
                ext = ".jpg"
            clean_name = re.sub(r'[\\/*?:"<>|]', "_", fname) if fname else f"IMG_{msg.id}{ext}"
            return True, clean_name

        if ext in VIDEO_EXTS or (mime.startswith("video/") and has_video_attr and mime != "video/webm"):
            if not ext:
                ext = ".mp4"
            clean_name = re.sub(r'[\\/*?:"<>|]', "_", fname) if fname else f"VID_{msg.id}{ext}"
            return True, clean_name

    return False, ""

# ================= DATE & EXIF HELPERS =================

def parse_flexible_date(raw: str) -> datetime:
    s = raw.strip().replace("/", "-")
    patterns = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
        "%d-%m-%Y %H:%M:%S",
        "%d-%m-%Y %H:%M",
        "%d-%m-%Y",
    ]
    for p in patterns:
        try:
            dt = datetime.strptime(s, p)
            if p in ("%Y-%m-%d", "%d-%m-%Y"):
                dt = dt.replace(hour=12, minute=0, second=0)
            return dt
        except ValueError:
            continue
    raise ValueError("Invalid date format! Use `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS` (e.g., `2022-08-15 14:30:00`).")

def get_next_target_datetime(msg_date: datetime = None) -> datetime:
    global SEQUENCE_COUNTER
    cfg = load_config()
    if cfg.get("date_mode") == "msg" and msg_date:
        base_dt = msg_date.replace(tzinfo=None)
    else:
        base_dt = datetime.strptime(cfg["target_date"], "%Y-%m-%d %H:%M:%S")

    SEQUENCE_COUNTER += 1
    return base_dt + timedelta(seconds=SEQUENCE_COUNTER)

def stamp_exif_and_quicktime_date(filepath: str, target_dt: datetime) -> bool:
    exif_str = target_dt.strftime("%Y:%m:%d %H:%M:%S")
    iso_str = target_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    ext = os.path.splitext(filepath)[1].lower()

    cmd = [
        "exiftool",
        "-overwrite_original",
        "-m",
        f"-AllDates={exif_str}",
        f"-DateTimeOriginal={exif_str}",
        f"-CreateDate={exif_str}",
        f"-ModifyDate={exif_str}",
        f"-XMP:CreateDate={exif_str}",
        f"-XMP:DateCreated={exif_str}",
    ]
    if ext in VIDEO_EXTS:
        cmd.extend([
            "-api", "QuickTimeUTC",
            f"-TrackCreateDate={exif_str}",
            f"-TrackModifyDate={exif_str}",
            f"-MediaCreateDate={exif_str}",
            f"-MediaModifyDate={exif_str}",
            f"-CreationTime={iso_str}",
            f"-Keys:CreationDate={iso_str}",
        ])
    cmd.append(filepath)

    res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    ts = target_dt.timestamp()
    try:
        os.utime(filepath, (ts, ts))
    except OSError:
        pass
    return res.returncode == 0

# ================= GOOGLE PHOTOS OAUTH & API =================

def get_google_creds() -> Credentials | None:
    if not TOKEN_FILE.exists():
        return None
    try:
        creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
            with open(TOKEN_FILE, "w") as f:
                f.write(creds.to_json())
        return creds if (creds and creds.valid) else None
    except Exception as e:
        logging.warning(f"Failed to load Google token: {e}")
        return None

def build_oauth_client_config() -> dict:
    cfg = load_config()
    cid = cfg.get("google_client_id", "").strip()
    csec = cfg.get("google_client_secret", "").strip()
    if not cid or not csec:
        raise ValueError("Google Client ID & Secret are not configured yet! Send `/setcreds <CLIENT_ID> <CLIENT_SECRET>` or upload `client_secret.json`.")
    return {
        "installed": {
            "client_id": cid,
            "client_secret": csec,
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "redirect_uris": ["http://localhost:8080/"]
        }
    }

async def ensure_google_album(album_title: str) -> str:
    creds = await asyncio.to_thread(get_google_creds)
    if not creds:
        raise RuntimeError("Google Photos is not connected! Run `/auth` first.")

    headers = {
        "Authorization": f"Bearer {creds.token}",
        "Content-Type": "application/json"
    }
    payload = {"album": {"title": album_title}}
    async with aiohttp.ClientSession() as session:
        async with session.post(
            "https://photoslibrary.googleapis.com/v1/albums",
            headers=headers,
            json=payload
        ) as resp:
            data = await resp.json()
            if resp.status >= 400:
                raise RuntimeError(f"Google Album creation failed: {data}")
            return data["id"]

async def upload_file_to_google_photos(filepath: str, filename: str, caption: str):
    creds = await asyncio.to_thread(get_google_creds)
    if not creds:
        raise RuntimeError("Google Photos is not authenticated! Send `/auth` first.")

    upload_headers = {
        "Authorization": f"Bearer {creds.token}",
        "Content-type": "application/octet-stream",
        "X-Goog-Upload-Content-Type": "application/octet-stream",
        "X-Goog-Upload-Protocol": "raw",
        "X-Goog-Upload-File-Name": urllib.parse.quote(filename),
    }

    timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=300)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        with open(filepath, "rb") as f:
            async with session.post(
                "https://photoslibrary.googleapis.com/v1/uploads",
                headers=upload_headers,
                data=f
            ) as up_resp:
                upload_token = (await up_resp.text()).strip()
                if up_resp.status >= 400 or not upload_token:
                    raise RuntimeError(f"Google byte upload failed ({up_resp.status}): {upload_token[:200]}")

        async with BATCH_CREATE_LOCK:
            cfg = load_config()
            album_id = cfg.get("album_id", "").strip()
            item_entry = {
                "simpleMediaItem": {
                    "fileName": filename,
                    "uploadToken": upload_token
                }
            }
            if caption and caption.strip():
                item_entry["description"] = caption.strip()[:990]

            body = {"newMediaItems": [item_entry]}
            if album_id:
                body["albumId"] = album_id

            json_headers = {
                "Authorization": f"Bearer {creds.token}",
                "Content-Type": "application/json"
            }
            async with session.post(
                "https://photoslibrary.googleapis.com/v1/mediaItems:batchCreate",
                headers=json_headers,
                json=body
            ) as bc_resp:
                bc_data = await bc_resp.json()
                if bc_resp.status >= 400:
                    raise RuntimeError(f"batchCreate error: {bc_data}")
                results = bc_data.get("newMediaItemResults", [{}])
                status_info = results[0].get("status", {})
                if status_info.get("code", 0) != 0 and "message" in status_info:
                    raise RuntimeError(f"Google Photos rejected item: {status_info['message']}")

# ================= PARSE TARGET & RANGE HELPERS =================

def parse_tg_target(raw: str):
    text = raw.strip()
    if re.match(r"^-?\d+$", text):
        return int(text), None

    m_priv = re.search(r"t\.me/c/(\d+)(?:/(\d+))?", text)
    if m_priv:
        chat_id = int(f"-100{m_priv.group(1)}")
        max_id = int(m_priv.group(2)) if m_priv.group(2) else None
        return chat_id, max_id

    m_pub = re.search(r"t\.me/([a-zA-Z0-9_]+)(?:/(\d+))?", text)
    if m_pub and m_pub.group(1).lower() not in ("c", "joinchat"):
        uname = m_pub.group(1)
        max_id = int(m_pub.group(2)) if m_pub.group(2) else None
        return uname, max_id

    return text, None

def parse_input_with_range(raw_text: str):
    tokens = raw_text.strip().split()
    links = [t for t in tokens if "t.me/" in t or re.match(r"^-100\d+$", t)]
    if not links:
        target, mid = parse_tg_target(tokens[0])
        return target, 1, (mid or 0)

    if len(links) >= 2:
        t1, id1 = parse_tg_target(links[0])
        _, id2 = parse_tg_target(links[1])
        if id1 and id2:
            return t1, min(id1, id2), max(id1, id2)

    target, link_msg_id = parse_tg_target(links[0])
    remainder = raw_text.replace(links[0], " ")
    nums = [int(x) for x in re.findall(r"\b\d+\b", remainder)]

    if len(nums) >= 2:
        s_id, e_id = min(nums[0], nums[1]), max(nums[0], nums[1])
        return target, max(1, s_id), e_id
    elif len(nums) == 1:
        if link_msg_id and nums[0] < link_msg_id:
            return target, max(1, nums[0]), link_msg_id
        return target, max(1, nums[0]), 0

    return target, 1, (link_msg_id or 0)

# ================= DIRECT GROUP SYNC ENGINE =================

def sync_control_buttons():
    pause_label = "▶️ Resume" if ACTIVE_SYNC["paused"] else "⏸️ Pause"
    return [
        [
            Button.inline(pause_label, b"syncctrl:pause"),
            Button.inline("❌ Stop & Wipe Cache", b"syncctrl:cancel")
        ]
    ]

async def run_group_sync_job(status_msg, job_cfg: dict):
    global SEQUENCE_COUNTER
    ACTIVE_SYNC["running"] = True
    ACTIVE_SYNC["paused"] = False
    ACTIVE_SYNC["cancelled"] = False
    SYNC_WORKER_STATUS.clear()

    src_target = job_cfg["source"]
    start_id = max(1, int(job_cfg.get("start_id", 1)))
    end_id = int(job_cfg.get("end_id") or 0)
    workers = max(1, min(MAX_WORKERS_LIMIT, int(job_cfg.get("workers", 1))))

    uploaded_cnt = int(job_cfg.get("uploaded_cnt", 0))
    skipped_cnt = int(job_cfg.get("skipped_cnt", 0))
    failed_cnt = int(job_cfg.get("failed_cnt", 0))

    t_start = time.time()
    current_scan_id = start_id
    in_flight_ids = set()
    ui_running = True

    async def sync_ui_updater(total_range: int):
        while ui_running and not ACTIVE_SYNC["cancelled"]:
            await asyncio.sleep(3.5)
            if not ui_running:
                break
            done_ids = max(0, current_scan_id - start_id)
            pct = min(100.0, (done_ids / max(1, total_range)) * 100)
            elapsed = time.time() - t_start
            rate = done_ids / max(0.1, elapsed)
            eta = max(0, end_id - current_scan_id) / max(0.01, rate)

            w_lines = []
            for mid, st in sorted(SYNC_WORKER_STATUS.items()):
                w_lines.append(f"• `ID {mid}`: {st}")
            active_block = "\n".join(w_lines) if w_lines else "• *Scanning & filtering next batch in order...*"

            cfg = load_config()
            d_label = cfg["target_date"] if cfg.get("date_mode") == "custom" else "Original Telegram Post Date"
            banner = "⏸️ **GROUP SYNC PAUSED**" if ACTIVE_SYNC["paused"] else f"☁️ **Syncing Group to Google Photos ({workers}x Mode)...**"

            text = (
                f"{banner}\n"
                f"`[{progress_bar(done_ids, total_range, 12)}] {pct:.1f}%`\n\n"
                f"✅ **Uploaded (Photos/Videos):** `{uploaded_cnt}`\n"
                f"⏭️ **Filtered Out (Text/Voice/Stickers):** `{skipped_cnt}`\n"
                f"❌ **Failed:** `{failed_cnt}`\n"
                f"🔢 **Ordered Range:** `{start_id}` → `{end_id}` (At `{current_scan_id}`)\n"
                f"📅 **EXIF Date Mode:** `{d_label}`\n"
                f"🧹 **VPS Temp Cache:** `{fmt_size(get_dir_size(CACHE_DIR))}`\n"
                f"⏱️ **Elapsed:** `{fmt_time(elapsed)}` • **ETA:** `{fmt_time(eta)}`\n\n"
                f"⚡ **Active Workers ({len(SYNC_WORKER_STATUS)}/{workers}):**\n"
                f"{active_block}"
            )
            try:
                await status_msg.edit(text, buttons=sync_control_buttons())
            except Exception:
                pass

    ui_task = None
    try:
        if not await is_user_logged_in():
            raise RuntimeError("Telegram User Session is not logged in! Send `/qr` or `/login` so the bot can read your private group.")
        if not get_google_creds():
            raise RuntimeError("Google Photos is not connected! Send `/auth` first.")

        src_entity = await user_client.get_entity(src_target)

        if end_id <= 0:
            latest = await user_client.get_messages(src_entity, limit=1)
            end_id = latest[0].id if latest else 5000

        if start_id > end_id:
            start_id, end_id = end_id, start_id

        total_range = max(1, end_id - start_id + 1)
        ui_task = asyncio.create_task(sync_ui_updater(total_range))

        sem = asyncio.Semaphore(workers)
        batch_size = max(30, workers * 12)

        async def sync_one_message(msg, filename: str, preassigned_dt: datetime):
            nonlocal uploaded_cnt, failed_cnt
            item_dir = CACHE_DIR / f"sync_{msg.id}_{int(time.time()*1000)}"
            item_dir.mkdir(parents=True, exist_ok=True)
            local_path = str(item_dir / filename)

            async with sem:
                if ACTIVE_SYNC["cancelled"]:
                    in_flight_ids.discard(msg.id)
                    shutil.rmtree(item_dir, ignore_errors=True)
                    return
                while ACTIVE_SYNC["paused"] and not ACTIVE_SYNC["cancelled"]:
                    await asyncio.sleep(1)
                if ACTIVE_SYNC["cancelled"]:
                    in_flight_ids.discard(msg.id)
                    shutil.rmtree(item_dir, ignore_errors=True)
                    return

                try:
                    t0 = time.time()

                    def dl_prog(curr, tot):
                        if ACTIVE_SYNC["cancelled"]:
                            raise asyncio.CancelledError()
                        spd = curr / max(0.1, time.time() - t0)
                        pct = (curr / tot * 100) if tot else 0
                        SYNC_WORKER_STATUS[msg.id] = f"📥 Caching `{pct:.0f}%` (`{fmt_size(spd)}/s`)"

                    SYNC_WORKER_STATUS[msg.id] = f"📥 Caching `{filename}`..."
                    while True:
                        try:
                            dl_path = await user_client.download_media(
                                msg,
                                file=local_path,
                                progress_callback=dl_prog
                            )
                            break
                        except FloodWaitError as fw:
                            SYNC_WORKER_STATUS[msg.id] = f"⏳ FloodWait ({fw.seconds}s)"
                            await asyncio.sleep(fw.seconds + 2)

                    if not dl_path or not os.path.exists(dl_path):
                        raise RuntimeError("Empty media download")

                    SYNC_WORKER_STATUS[msg.id] = f"🕒 Stamping EXIF `{preassigned_dt.strftime('%Y-%m-%d %H:%M:%S')}`..."
                    await asyncio.to_thread(stamp_exif_and_quicktime_date, dl_path, preassigned_dt)

                    fsize = os.path.getsize(dl_path)
                    SYNC_WORKER_STATUS[msg.id] = f"☁️ Uploading to Google Photos (`{fmt_size(fsize)}`)..."
                    await upload_file_to_google_photos(dl_path, os.path.basename(dl_path), msg.text or "")

                    uploaded_cnt += 1
                    STATS["uploaded"] += 1
                except asyncio.CancelledError:
                    pass
                except Exception as e:
                    logging.warning(f"Sync item {msg.id} failed: {e}")
                    failed_cnt += 1
                    STATS["failed"] += 1
                finally:
                    SYNC_WORKER_STATUS.pop(msg.id, None)
                    in_flight_ids.discard(msg.id)
                    shutil.rmtree(item_dir, ignore_errors=True)
                    safe_next_id = min(in_flight_ids) if in_flight_ids else (msg.id + 1)
                    job_cfg["start_id"] = safe_next_id
                    job_cfg["end_id"] = end_id
                    job_cfg["uploaded_cnt"] = uploaded_cnt
                    job_cfg["skipped_cnt"] = skipped_cnt
                    job_cfg["failed_cnt"] = failed_cnt
                    save_sync_resume(job_cfg)

        for batch_start in range(start_id, end_id + 1, batch_size):
            if ACTIVE_SYNC["cancelled"]:
                break
            while ACTIVE_SYNC["paused"] and not ACTIVE_SYNC["cancelled"]:
                await asyncio.sleep(1)

            batch_end = min(end_id, batch_start + batch_size - 1)
            id_list = list(range(batch_start, batch_end + 1))

            while True:
                try:
                    msgs = await user_client.get_messages(src_entity, ids=id_list)
                    break
                except FloodWaitError as fw:
                    await asyncio.sleep(fw.seconds + 2)

            # Pre-assign timestamps in strict ascending message ID order so Google Photos order is 100% preserved
            valid_items = []
            for m in sorted((x for x in (msgs or []) if x is not None), key=lambda x: x.id):
                ok, fname = is_strict_photo_or_video(m)
                if not ok:
                    skipped_cnt += 1
                    STATS["skipped_non_media"] += 1
                    continue
                assigned_dt = get_next_target_datetime(m.date)
                valid_items.append((m, fname, assigned_dt))
                in_flight_ids.add(m.id)

            if valid_items:
                tasks = [asyncio.create_task(sync_one_message(m, fn, dt)) for m, fn, dt in valid_items]
                await asyncio.gather(*tasks, return_exceptions=True)

            current_scan_id = batch_end + 1
            if not in_flight_ids:
                job_cfg["start_id"] = current_scan_id
                job_cfg["end_id"] = end_id
                job_cfg["uploaded_cnt"] = uploaded_cnt
                job_cfg["skipped_cnt"] = skipped_cnt
                job_cfg["failed_cnt"] = failed_cnt
                save_sync_resume(job_cfg)

        ui_running = False
        if ui_task:
            ui_task.cancel()
        wipe_cache()

        if ACTIVE_SYNC["cancelled"]:
            await status_msg.edit(
                f"🛑 **Group Sync Stopped at Message ID `{job_cfg['start_id']}` & Cache Wiped (`0.00 B`).**\n\n"
                f"✅ **Uploaded Photos/Videos:** `{uploaded_cnt}`\n"
                f"⏭️ **Filtered Out (Text/Voice/Stickers):** `{skipped_cnt}`\n"
                "💡 *Send `/resumesync` anytime to continue from this exact message!*",
                buttons=None
            )
        else:
            RESUME_SYNC_FILE.unlink(missing_ok=True)
            await status_msg.edit(
                f"🎉 **Private Group Sync to Google Photos 100% Complete!**\n\n"
                f"🔢 **Scanned Range (In Order):** `{start_id}` → `{end_id}`\n"
                f"✅ **Photos & Videos Uploaded:** `{uploaded_cnt}`\n"
                f"⏭️ **Ignored (Text, Voice, Stickers, GIFs):** `{skipped_cnt}`\n"
                f"❌ **Failed:** `{failed_cnt}`\n"
                f"🧹 **VPS Cache Folder:** `0.00 B (Erased)`\n"
                f"⏱️ **Total Time:** `{fmt_time(time.time() - t_start)}`",
                buttons=None
            )
    except Exception as e:
        ui_running = False
        if ui_task:
            ui_task.cancel()
        wipe_cache()
        await status_msg.edit(f"❌ **Group Sync Error:** `{e}`\n🧹 *VPS cache automatically wiped.*", buttons=None)
    finally:
        ui_running = False
        if ui_task:
            ui_task.cancel()
        SYNC_WORKER_STATUS.clear()
        wipe_cache()
        ACTIVE_SYNC["running"] = False
        ACTIVE_SYNC["paused"] = False
        ACTIVE_SYNC["cancelled"] = False
        ACTIVE_SYNC["task"] = None

# ================= FORWARDED MEDIA QUEUE WORKER =================

async def process_forwarded_item(item: dict):
    msg = item["msg"]
    status_msg = item["status_msg"]
    orig_fname = item["filename"]
    target_dt: datetime = item["target_dt"]

    item_dir = CACHE_DIR / f"item_{msg.id}_{int(time.time()*1000)}"
    item_dir.mkdir(parents=True, exist_ok=True)
    local_path = str(item_dir / orig_fname)

    try:
        await status_msg.edit(
            f"📥 **Downloading Photo/Video to Temp Cache...**\n"
            f"📄 **File:** `{orig_fname}`\n"
            f"📅 **Target Date:** `{target_dt.strftime('%Y-%m-%d %H:%M:%S')}`"
        )

        dl_path = await bot.download_media(msg, file=local_path)
        if not dl_path or not os.path.exists(dl_path):
            raise RuntimeError("Telegram media download returned empty file.")

        await status_msg.edit(
            f"🕒 **Injecting EXIF / QuickTime Date Header...**\n"
            f"📄 **File:** `{os.path.basename(dl_path)}`\n"
            f"📅 **New Embedded Date:** `{target_dt.strftime('%Y-%m-%d %H:%M:%S')}`"
        )
        await asyncio.to_thread(stamp_exif_and_quicktime_date, dl_path, target_dt)

        fsize = os.path.getsize(dl_path)
        await status_msg.edit(
            f"☁️ **Uploading to Google Photos Library...**\n"
            f"📄 **File:** `{os.path.basename(dl_path)}` (`{fmt_size(fsize)}`)\n"
            f"📅 **Library Date:** `{target_dt.strftime('%Y-%m-%d %H:%M:%S')}`"
        )
        await upload_file_to_google_photos(dl_path, os.path.basename(dl_path), msg.text or "")

        STATS["uploaded"] += 1
        cfg = load_config()
        album_note = f"\n🖼️ **Album:** `{cfg['album_name']}`" if cfg.get("album_name") else ""
        await status_msg.edit(
            f"✅ **Uploaded to Google Photos & Erased from VPS!**\n\n"
            f"📄 **File:** `{os.path.basename(dl_path)}` (`{fmt_size(fsize)}`)\n"
            f"📅 **Google Photos Date:** `{target_dt.strftime('%Y-%m-%d %H:%M:%S')}`{album_note}\n"
            f"🧹 **VPS Cache:** `0.00 B (Deleted)`"
        )
    except Exception as e:
        STATS["failed"] += 1
        await status_msg.edit(f"❌ **Upload Failed (`{orig_fname}`):** `{e}`\n🧹 *Temp file erased from VPS.*")
    finally:
        STATS["queued"] = max(0, STATS["queued"] - 1)
        shutil.rmtree(item_dir, ignore_errors=True)

async def queue_worker():
    while True:
        item = await QUEUE.get()
        try:
            await process_forwarded_item(item)
        except Exception as e:
            logging.error(f"Worker error: {e}")
        finally:
            QUEUE.task_done()

# ================= UI & SETUP MENUS =================

def build_sync_setup_text(setup: dict) -> str:
    cfg = load_config()
    s_id = setup.get("start_id", 1)
    end_id = setup.get("end_id", 0)
    range_txt = f"`{s_id}` → `{end_id}` (`{max(1, end_id - s_id + 1)}` msgs)" if end_id > 0 else f"`{s_id}` → `Latest (Auto-Detect)`"
    d_mode = f"🎯 Custom Date (`{cfg['target_date']}`)" if cfg.get("date_mode") == "custom" else "📨 Original Telegram Post Date"
    album_str = f"`{cfg['album_name']}`" if cfg.get("album_name") else "`Main Library`"
    w = setup.get("workers", 1)

    return (
        f"📸 **Direct Private Group Sync to Google Photos**\n\n"
        f"📤 **Source Group:** `{setup['source']}`\n"
        f"🔢 **Ordered ID Range:** {range_txt}\n"
        f"🛡️ **Strict Media Filter:** `Images & Videos ONLY ✅`\n"
        f"   *(Automatically skips text, voice notes, audio, stickers & GIFs)*\n"
        f"📅 **EXIF Date Stamp:** {d_mode}\n"
        f"🖼️ **Google Album:** {album_str}\n"
        f"⚡ **Upload Speed:** `{w}x` *(`1x` recommended for strict sequential order)*\n\n"
        "👇 **Adjust your Range, Date Mode, or Speed, then tap Start:**"
    )

def build_sync_setup_buttons(key: str, selected_workers: int):
    w_row = []
    for w in [1, 2, 3, 4, 5]:
        lbl = f"✅ {w}x" if w == selected_workers else f"⚡ {w}x"
        w_row.append(Button.inline(lbl, f"syncw:{key}:{w}".encode()))

    return [
        w_row,
        [
            Button.inline("🔢 Set Custom ID Range", f"syncr:{key}".encode()),
            Button.inline("📅 Toggle Custom/Post Date", f"syncd:{key}".encode())
        ],
        [Button.inline(f"🚀 Start Ordered Google Photos Sync ({selected_workers}x)", f"syncgo:{key}".encode())],
        [Button.inline("❌ Cancel", b"menu:close")]
    ]

async def build_dashboard_text() -> str:
    cfg = load_config()
    creds = get_google_creds()
    g_status = "Connected ✅" if creds else "Not Linked ❌ (Run /auth)"
    u_logged = await is_user_logged_in()
    if u_logged:
        me = await user_client.get_me()
        u_status = f"Connected ✅ ({me.first_name} | {me.id})"
    else:
        u_status = "Not Logged In ⚠️ (Use /qr for Group Sync)"

    mode_str = (
        f"🎯 Custom Date (`{cfg['target_date']}`)"
        if cfg.get("date_mode") == "custom"
        else "📨 Original Telegram Post Date (`/date msg`)"
    )
    album_str = f"`{cfg['album_name']}`" if cfg.get("album_name") else "`Main Library (No Album)`"
    cache_bytes = get_dir_size(CACHE_DIR)

    return (
        "📸 **BOTS BY SPW — Telegram to Google Photos Time-Machine**\n\n"
        f"☁️ **Google Photos:** `{g_status}`\n"
        f"👤 **Telegram User (Group Pull):** `{u_status}`\n"
        f"📅 **Active Date Stamp:** {mode_str}\n"
        f"🖼️ **Target Google Album:** {album_str}\n"
        f"🛡️ **Strict Filter:** `Photos & Videos ONLY (Skips Text/Voice/Stickers)`\n"
        f"📊 **Stats:** `{STATS['uploaded']} Uploaded` | `{STATS['skipped_non_media']} Skipped` | `{STATS['failed']} Failed`\n"
        f"🧹 **VPS Temp Cache:** `{fmt_size(cache_bytes)}` *(Auto-erased after each file)*\n\n"
        "**Two Ways to Upload in Order:**\n"
        "• **Option 1 (Forward):** Set `/date YYYY-MM-DD` and forward messages from your group.\n"
        "• **Option 2 (Direct Group Pull):** Paste your private group link (e.g. `https://t.me/c/xxxx/500`) or use `/sync <link> <start_id> <end_id>`!"
    )

def build_dashboard_buttons():
    btns = [
        [
            Button.inline("📅 Set Target Date", b"menu:setdate"),
            Button.inline("📨 Use Original Post Date", b"menu:datemsg")
        ],
        [
            Button.inline("🖼️ Set Google Album", b"menu:setalbum"),
            Button.inline("🚫 Clear Album", b"menu:clearalbum")
        ],
        [
            Button.inline("🔑 Connect Google (/auth)", b"menu:auth"),
            Button.inline("📱 Telegram QR Login (/qr)", b"menu:qr")
        ],
        [
            Button.inline("🧹 Clean VPS Cache", b"menu:clean"),
            Button.inline("📖 Full Instructions", b"menu:help")
        ]
    ]
    res = load_sync_resume()
    if res:
        btns.insert(0, [Button.inline(f"▶️ Resume Group Sync (ID {res.get('start_id')} → {res.get('end_id')})", b"menu:resumesync")])
    return btns

HELP_TEXT = (
    "📖 **BOTS BY SPW — Complete Setup & Usage Guide**\n\n"
    "**1. Connect Google Photos (One-Time):**\n"
    "• Upload `client_secret.json` here (or `/setcreds <ID> <SECRET>`), then run **`/auth`**.\n\n"
    "**2. Choose How Dates Are Stamped:**\n"
    "• **Custom Date (`/date 2021-08-15`):** Stamps every photo/video with your chosen date (+1s per file so exact order is preserved).\n"
    "• **Group Post Date (`/date msg`):** Stamps each photo/video with the original date it was uploaded to your Telegram group.\n\n"
    "**3. Upload Method A — Direct Private Group Sync:**\n"
    "• Connect your Telegram account via **`/qr`**.\n"
    "• Paste your private group post link (`https://t.me/c/123456/500`), paste two links for a range, or run:\n"
    "  `/sync https://t.me/c/123456/500 1 500`\n"
    "• Scans in strict ascending order, **skips all text, voice notes, audio, stickers & GIFs**, stamps EXIF dates, uploads to Google Photos, and deletes the VPS cache!\n\n"
    "**4. Upload Method B — Forward Messages:**\n"
    "• Simply forward messages from your group to this bot."
)

# ================= COMMAND HANDLERS =================

@bot.on(events.NewMessage(pattern=r"^/start"))
async def start_h(event):
    if not is_admin(event.sender_id):
        return
    WAITING_INPUT.pop(event.sender_id, None)
    SYNC_RANGE_WAIT.pop(event.sender_id, None)
    await event.reply(await build_dashboard_text(), buttons=build_dashboard_buttons())

@bot.on(events.NewMessage(pattern=r"^/help"))
async def help_h(event):
    if not is_admin(event.sender_id):
        return
    await event.reply(HELP_TEXT)

@bot.on(events.NewMessage(pattern=r"^/qr"))
async def qr_login_h(event):
    if not is_admin(event.sender_id):
        return
    uid = event.sender_id
    LOGIN_STATE.pop(uid, None)
    await reset_user_session()
    status = await event.reply("⏳ **Generating Telegram Login QR Code...**")
    try:
        qr_login = await user_client.qr_login()
        qr_img = make_qr_png(qr_login.url)
        await status.delete()
        qr_msg = await bot.send_file(
            event.chat_id,
            file=qr_img,
            caption="📱 **Scan this QR Code in Telegram → Settings → Devices → Link Desktop Device**"
        )
        try:
            await qr_login.wait(timeout=60)
            me = await user_client.get_me()
            await qr_msg.delete()
            await event.respond(f"✅ **Telegram User Connected: `{me.first_name}` (`{me.id}`)!**\nYou can now paste private group links or use `/sync`!")
        except SessionPasswordNeededError:
            await qr_msg.delete()
            LOGIN_STATE[uid] = {"step": "2fa"}
            await event.respond("🔒 **2FA enabled. Send your Telegram 2FA password:**")
        except asyncio.TimeoutError:
            await qr_msg.delete()
            await event.respond("⏱️ **QR expired. Send `/qr` to try again.**")
    except Exception as e:
        await event.respond(f"❌ **QR Error:** `{e}`")

@bot.on(events.NewMessage(pattern=r"^/login"))
async def login_h(event):
    if not is_admin(event.sender_id):
        return
    await reset_user_session()
    LOGIN_STATE[event.sender_id] = {"step": "phone"}
    await event.reply("🔑 Send your **Phone Number** in international format (e.g. `+1234567890`):")

@bot.on(events.NewMessage(pattern=r"^/logout"))
async def logout_h(event):
    if not is_admin(event.sender_id):
        return
    LOGIN_STATE.pop(event.sender_id, None)
    try:
        if await is_user_logged_in():
            await user_client.log_out()
    except Exception:
        pass
    await reset_user_session()
    await event.reply("🗑️ **Telegram User Session logged out.**")

@bot.on(events.NewMessage(func=lambda e: e.sender_id in LOGIN_STATE and e.raw_text and not e.raw_text.startswith("/")))
async def login_flow_h(event):
    uid = event.sender_id
    st = LOGIN_STATE.get(uid)
    if not st:
        return
    text = event.raw_text.strip()
    if not user_client.is_connected():
        await user_client.connect()
    try:
        if st["step"] == "phone":
            phone = text.replace(" ", "")
            sent = await user_client.send_code_request(phone)
            st["phone"] = phone
            st["hash"] = sent.phone_code_hash
            st["step"] = "code"
            await event.reply("📲 **OTP sent!** Send the code with spaces (e.g. `1 2 3 4 5`):")
        elif st["step"] == "code":
            code = text.replace(" ", "").replace("-", "")
            try:
                await user_client.sign_in(phone=st["phone"], code=code, phone_code_hash=st["hash"])
                LOGIN_STATE.pop(uid, None)
                me = await user_client.get_me()
                await event.reply(f"✅ **Logged in as `{me.first_name}`!**")
            except SessionPasswordNeededError:
                st["step"] = "2fa"
                await event.reply("🔒 **Send 2FA password:**")
        elif st["step"] == "2fa":
            await user_client.sign_in(password=text)
            LOGIN_STATE.pop(uid, None)
            me = await user_client.get_me()
            await event.respond(f"✅ **Logged in as `{me.first_name}`!**")
    except Exception as e:
        LOGIN_STATE.pop(uid, None)
        await event.reply(f"❌ **Login Error:** `{e}`")

@bot.on(events.NewMessage(pattern=r"^/sync\s+(.+)"))
async def sync_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    await open_sync_setup(event, event.pattern_match.group(1))

@bot.on(events.NewMessage(pattern=r"^/resumesync"))
async def resumesync_h(event):
    if not is_admin(event.sender_id):
        return
    if ACTIVE_SYNC["running"]:
        return await event.reply("⚠️ **A group sync job is already running!**")
    res = load_sync_resume()
    if not res:
        return await event.reply("ℹ️ **No saved sync job to resume.**")
    status_msg = await event.reply("⏳ **Resuming saved Group Sync to Google Photos...**")
    ACTIVE_SYNC["task"] = asyncio.create_task(run_group_sync_job(status_msg, res))

@bot.on(events.NewMessage(func=lambda e: is_admin(e.sender_id) and e.sender_id not in LOGIN_STATE and e.sender_id not in WAITING_INPUT and e.sender_id not in SYNC_RANGE_WAIT and e.raw_text and ("t.me/" in e.raw_text or re.match(r"^-100\d+", e.raw_text.strip())) and not e.raw_text.startswith("/")))
async def paste_group_link_h(event):
    await open_sync_setup(event, event.raw_text.strip())

async def open_sync_setup(event, raw_input: str):
    if ACTIVE_SYNC["running"]:
        return await event.reply("⚠️ **A Group Sync job is already running!**")
    src_target, start_id, end_id = parse_input_with_range(raw_input)
    cfg = load_config()
    default_w = int(cfg.get("parallel_workers", 1))

    key = str(int(time.time() * 1000))
    setup = {
        "source": src_target,
        "start_id": start_id,
        "end_id": end_id,
        "workers": default_w
    }
    PENDING_SYNC[key] = setup
    await event.reply(
        build_sync_setup_text(setup),
        buttons=build_sync_setup_buttons(key, default_w)
    )

@bot.on(events.NewMessage(func=lambda e: e.sender_id in SYNC_RANGE_WAIT and e.raw_text and not e.raw_text.startswith("/")))
async def sync_range_input_h(event):
    uid = event.sender_id
    st = SYNC_RANGE_WAIT.pop(uid, None)
    if not st:
        return
    key = st["key"]
    setup_msg = st["setup_msg"]
    setup = PENDING_SYNC.get(key)
    if not setup:
        return await event.reply("⚠️ **Session expired. Paste the group link again.**")

    text = event.raw_text.strip()
    link_ids = [int(x) for x in re.findall(r"t\.me/(?:c/\d+|[a-zA-Z0-9_]+)/(\d+)", text)]
    if len(link_ids) >= 2:
        s_id, e_id = min(link_ids[0], link_ids[1]), max(link_ids[0], link_ids[1])
    else:
        nums = [int(x) for x in re.findall(r"\b\d+\b", text)]
        if not nums:
            return await event.reply("⚠️ **Invalid range.** Send two numbers like `100 500` or `100-500`.")
        if len(nums) >= 2:
            s_id, e_id = min(nums[0], nums[1]), max(nums[0], nums[1])
        else:
            s_id = nums[0]
            e_id = setup.get("end_id", 0)

    setup["start_id"] = max(1, s_id)
    setup["end_id"] = max(0, e_id)
    try:
        await event.delete()
    except Exception:
        pass
    await setup_msg.edit(
        build_sync_setup_text(setup),
        buttons=build_sync_setup_buttons(key, setup["workers"])
    )

@bot.on(events.NewMessage(pattern=r"^/setcreds\s+(\S+)\s+(\S+)"))
async def setcreds_h(event):
    if not is_admin(event.sender_id):
        return
    cid = event.pattern_match.group(1).strip()
    csec = event.pattern_match.group(2).strip()
    cfg = load_config()
    cfg["google_client_id"] = cid
    cfg["google_client_secret"] = csec
    save_config(cfg)
    try:
        await event.delete()
    except Exception:
        pass
    await event.respond("✅ **Google OAuth Client ID & Secret saved!** Now send `/auth` to link your Google Photos account.")

@bot.on(events.NewMessage(pattern=r"^/auth"))
async def auth_h(event):
    if not is_admin(event.sender_id):
        return
    try:
        client_cfg = build_oauth_client_config()
        flow = InstalledAppFlow.from_client_config(
            client_cfg,
            scopes=SCOPES,
            redirect_uri="http://localhost:8080/"
        )
        auth_url, _ = flow.authorization_url(prompt="consent", access_type="offline")
        WAITING_INPUT[event.sender_id] = {"mode": "oauth", "flow": flow}
        await event.reply(
            "🔑 **Connect Google Photos (Headless VPS Login)**\n\n"
            f"1️⃣ **[Click Here to Authorize with Google]({auth_url})**\n"
            "2️⃣ Log in and click **Continue / Allow**.\n"
            "3️⃣ Copy the redirected `http://localhost:8080/?code=...` URL from your browser address bar and paste it here:",
            link_preview=False
        )
    except Exception as e:
        await event.reply(f"⚠️ **OAuth Setup Error:** `{e}`")

@bot.on(events.NewMessage(pattern=r"^/date(?:\s+(.+))?"))
async def date_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    global SEQUENCE_COUNTER
    arg = (event.pattern_match.group(1) or "").strip()
    if not arg:
        WAITING_INPUT[event.sender_id] = {"mode": "date"}
        return await event.reply(
            "📅 **Send the target date for your photos/videos:**\n\n"
            "• Example 1: `2021-12-25`\n"
            "• Example 2: `2021-12-25 18:30:00`\n"
            "• Or send `msg` to use each message's original Telegram timestamp."
        )

    if arg.lower() == "msg":
        cfg = load_config()
        cfg["date_mode"] = "msg"
        save_config(cfg)
        SEQUENCE_COUNTER = 0
        return await event.reply("✅ **Date Mode set to:** `Original Telegram Message Date`!")

    try:
        dt = parse_flexible_date(arg)
        cfg = load_config()
        cfg["target_date"] = dt.strftime("%Y-%m-%d %H:%M:%S")
        cfg["date_mode"] = "custom"
        save_config(cfg)
        SEQUENCE_COUNTER = 0
        await event.reply(
            f"✅ **Target Google Photos Date Set!**\n\n"
            f"📅 **New EXIF Date:** `{cfg['target_date']}`\n"
            "👉 *Forward your photos/videos OR paste your private group link to sync a range!*"
        )
    except Exception as e:
        await event.reply(f"⚠️ {e}")

@bot.on(events.NewMessage(pattern=r"^/album(?:\s+(.+))?"))
async def album_cmd_h(event):
    if not is_admin(event.sender_id):
        return
    arg = (event.pattern_match.group(1) or "").strip()
    if not arg:
        WAITING_INPUT[event.sender_id] = {"mode": "album"}
        return await event.reply("🖼️ **Send the name of the Google Photos Album to create/use (or send `off` to disable):**")

    cfg = load_config()
    if arg.lower() in ("off", "none", "clear"):
        cfg["album_name"] = ""
        cfg["album_id"] = ""
        save_config(cfg)
        return await event.reply("✅ **Album disabled.** Files will upload to your main Google Photos library.")

    msg = await event.reply(f"⏳ **Creating album `{arg}` in Google Photos...**")
    try:
        aid = await ensure_google_album(arg)
        cfg["album_name"] = arg
        cfg["album_id"] = aid
        save_config(cfg)
        await msg.edit(f"✅ **Google Photos Album Active:** `{arg}`")
    except Exception as e:
        await msg.edit(f"❌ **Album Error:** `{e}`")

@bot.on(events.NewMessage(pattern=r"^/(?:cleancache|clean)"))
async def cleancache_h(event):
    if not is_admin(event.sender_id):
        return
    if ACTIVE_SYNC["running"]:
        ACTIVE_SYNC["cancelled"] = True
        ACTIVE_SYNC["paused"] = False
        await asyncio.sleep(1.5)
    freed, cnt = wipe_cache()
    await event.reply(
        f"🧹 **VPS Cache Wiped Clean!**\n"
        f"🗑️ **Files Removed:** `{cnt}` (`{fmt_size(freed)}`)\n"
        f"📂 **Current `/opt/gphotosbot/cache`:** `0.00 B`"
    )

@bot.on(events.NewMessage(func=lambda e: is_admin(e.sender_id) and e.sender_id in WAITING_INPUT and e.raw_text and not e.raw_text.startswith("/")))
async def waiting_input_h(event):
    global SEQUENCE_COUNTER
    uid = event.sender_id
    state = WAITING_INPUT.pop(uid, None)
    if not state:
        return
    text = event.raw_text.strip()

    if state["mode"] == "date":
        if text.lower() == "msg":
            cfg = load_config()
            cfg["date_mode"] = "msg"
            save_config(cfg)
            SEQUENCE_COUNTER = 0
            return await event.reply("✅ **Date Mode set to:** `Original Telegram Message Date`!")
        try:
            dt = parse_flexible_date(text)
            cfg = load_config()
            cfg["target_date"] = dt.strftime("%Y-%m-%d %H:%M:%S")
            cfg["date_mode"] = "custom"
            save_config(cfg)
            SEQUENCE_COUNTER = 0
            await event.reply(
                f"✅ **Target Google Photos Date Updated!**\n"
                f"📅 **Date:** `{cfg['target_date']}`\n"
                "👉 *Now forward your photos/videos or paste a private group link!*"
            )
        except Exception as e:
            await event.reply(f"⚠️ {e}")

    elif state["mode"] == "album":
        cfg = load_config()
        if text.lower() in ("off", "none", "clear"):
            cfg["album_name"] = ""
            cfg["album_id"] = ""
            save_config(cfg)
            return await event.reply("✅ **Album cleared.**")
        msg = await event.reply(f"⏳ **Creating album `{text}` in Google Photos...**")
        try:
            aid = await ensure_google_album(text)
            cfg["album_name"] = text
            cfg["album_id"] = aid
            save_config(cfg)
            await msg.edit(f"✅ **Google Photos Album Set:** `{text}`")
        except Exception as e:
            await msg.edit(f"❌ **Album Error:** `{e}`")

    elif state["mode"] == "oauth":
        flow = state["flow"]
        code = text
        if "code=" in text:
            parsed = urllib.parse.urlparse(text)
            qs = urllib.parse.parse_qs(parsed.query)
            code = qs.get("code", [text])[0]
        try:
            await asyncio.to_thread(flow.fetch_token, code=code)
            creds = flow.credentials
            with open(TOKEN_FILE, "w") as f:
                f.write(creds.to_json())
            os.chmod(TOKEN_FILE, 0o600)
            await event.reply("🎉 **Google Photos Account Connected Successfully!**")
        except Exception as e:
            await event.reply(f"❌ **OAuth Token Error:** `{e}`\nSend `/auth` to try again.")

@bot.on(events.NewMessage(func=lambda e: is_admin(e.sender_id) and bool(e.media)))
async def media_handler(event):
    if event.document:
        for attr in event.document.attributes:
            if isinstance(attr, DocumentAttributeFilename) and attr.file_name.endswith(".json"):
                tmp_json = CACHE_DIR / "creds_upload.json"
                await bot.download_media(event.message, file=str(tmp_json))
                try:
                    with open(tmp_json, "r") as f:
                        jdata = json.load(f)
                    block = jdata.get("installed") or jdata.get("web") or {}
                    cid = block.get("client_id")
                    csec = block.get("client_secret")
                    if cid and csec:
                        cfg = load_config()
                        cfg["google_client_id"] = cid
                        cfg["google_client_secret"] = csec
                        save_config(cfg)
                        tmp_json.unlink(missing_ok=True)
                        try:
                            await event.delete()
                        except Exception:
                            pass
                        return await event.respond(
                            "✅ **`client_secret.json` imported & deleted from chat!**\n"
                            "Now send **`/auth`** to connect your Google Photos account."
                        )
                except Exception as e:
                    tmp_json.unlink(missing_ok=True)
                    return await event.reply(f"⚠️ Invalid Google JSON file: `{e}`")

    ok, filename = is_strict_photo_or_video(event.message)
    if not ok:
        STATS["skipped_non_media"] += 1
        return

    if not get_google_creds():
        return await event.reply("⚠️ **Google Photos is not connected yet!** Send `/auth` first.")

    orig_dt = event.message.fwd_from.date if event.message.fwd_from and event.message.fwd_from.date else event.message.date
    target_dt = get_next_target_datetime(orig_dt)

    STATS["queued"] += 1
    status_msg = await event.reply(
        f"⏳ **Queued for Google Photos (`#{STATS['queued']}`)**\n"
        f"📄 **File:** `{filename}`\n"
        f"📅 **Target EXIF Date:** `{target_dt.strftime('%Y-%m-%d %H:%M:%S')}`"
    )

    await QUEUE.put({
        "msg": event.message,
        "status_msg": status_msg,
        "filename": filename,
        "target_dt": target_dt
    })

@bot.on(events.CallbackQuery)
async def cb_h(event):
    if not is_admin(event.sender_id):
        return await event.answer("⛔ Admin only.", alert=True)
    uid = event.sender_id
    data = event.data.decode("utf-8")

    if data == "menu:close":
        SYNC_RANGE_WAIT.pop(uid, None)
        return await event.delete()

    if data == "menu:setdate":
        WAITING_INPUT[uid] = {"mode": "date"}
        await event.answer()
        return await event.respond(
            "📅 **Send the target date for your photos/videos:**\n"
            "• Format: `YYYY-MM-DD` (e.g. `2022-04-18`)\n"
            "• Or with time: `YYYY-MM-DD HH:MM:SS` (e.g. `2022-04-18 15:30:00`)"
        )

    if data == "menu:datemsg":
        cfg = load_config()
        cfg["date_mode"] = "msg"
        save_config(cfg)
        await event.answer("✅ Using Original Telegram Post Date!", alert=True)
        return await event.edit(await build_dashboard_text(), buttons=build_dashboard_buttons())

    if data == "menu:setalbum":
        WAITING_INPUT[uid] = {"mode": "album"}
        await event.answer()
        return await event.respond("🖼️ **Send the Google Photos Album name to create/use:**")

    if data == "menu:clearalbum":
        cfg = load_config()
        cfg["album_name"] = ""
        cfg["album_id"] = ""
        save_config(cfg)
        await event.answer("✅ Album cleared (Main Library active)", alert=True)
        return await event.edit(await build_dashboard_text(), buttons=build_dashboard_buttons())

    if data == "menu:auth":
        await event.answer()
        return await auth_h(event)

    if data == "menu:qr":
        await event.answer()
        return await qr_login_h(event)

    if data == "menu:clean":
        freed, cnt = wipe_cache()
        await event.answer(f"🧹 Cleaned {cnt} files ({fmt_size(freed)})!", alert=True)
        return await event.edit(await build_dashboard_text(), buttons=build_dashboard_buttons())

    if data == "menu:help":
        await event.answer()
        return await event.respond(HELP_TEXT)

    if data == "menu:resumesync":
        res = load_sync_resume()
        if not res:
            return await event.answer("No saved sync job.", alert=True)
        msg = await event.get_message()
        ACTIVE_SYNC["task"] = asyncio.create_task(run_group_sync_job(msg, res))
        return

    if data.startswith("syncw:"):
        _, key, w_str = data.split(":")
        w = int(w_str)
        setup = PENDING_SYNC.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired, paste link again.", alert=True)
        setup["workers"] = w
        cfg = load_config()
        cfg["parallel_workers"] = w
        save_config(cfg)
        await event.answer(f"⚡ Upload speed set to {w}x")
        return await event.edit(build_sync_setup_text(setup), buttons=build_sync_setup_buttons(key, w))

    if data.startswith("syncd:"):
        _, key = data.split(":")
        setup = PENDING_SYNC.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired.", alert=True)
        cfg = load_config()
        cfg["date_mode"] = "msg" if cfg.get("date_mode") == "custom" else "custom"
        save_config(cfg)
        await event.answer(f"📅 Mode switched to: {cfg['date_mode']}")
        return await event.edit(build_sync_setup_text(setup), buttons=build_sync_setup_buttons(key, setup["workers"]))

    if data.startswith("syncr:"):
        _, key = data.split(":")
        setup = PENDING_SYNC.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired.", alert=True)
        msg = await event.get_message()
        SYNC_RANGE_WAIT[uid] = {"key": key, "setup_msg": msg}
        await event.answer("🔢 Send Start and End ID")
        return await event.edit(
            f"🔢 **Set Custom Message ID Range for `{setup['source']}`**\n\n"
            f"Current Range: `{setup.get('start_id', 1)}` → `{setup.get('end_id') or 'End'}`\n\n"
            "👇 **Send your desired range now:**\n"
            "• `100 - 500` or `100 500` *(Syncs from ID 100 to 500)*\n"
            "• `250` *(Starts at ID 250 and syncs to the end)*\n"
            "• Or paste two post links (`https://t.me/c/xxx/100 https://t.me/c/xxx/500`)",
            buttons=[[Button.inline("🔙 Back", f"syncback:{key}".encode())]]
        )

    if data.startswith("syncback:"):
        _, key = data.split(":")
        SYNC_RANGE_WAIT.pop(uid, None)
        setup = PENDING_SYNC.get(key)
        if not setup:
            return await event.answer("⚠️ Session expired.", alert=True)
        return await event.edit(build_sync_setup_text(setup), buttons=build_sync_setup_buttons(key, setup["workers"]))

    if data.startswith("syncgo:"):
        SYNC_RANGE_WAIT.pop(uid, None)
        _, key = data.split(":")
        setup = PENDING_SYNC.pop(key, None)
        if not setup:
            return await event.answer("⚠️ Expired, paste link again.", alert=True)
        msg = await event.get_message()
        ACTIVE_SYNC["task"] = asyncio.create_task(run_group_sync_job(msg, setup))
        return

    if data == "syncctrl:pause":
        ACTIVE_SYNC["paused"] = not ACTIVE_SYNC["paused"]
        await event.answer("⏸️ Paused" if ACTIVE_SYNC["paused"] else "▶️ Resumed")
        msg = await event.get_message()
        try:
            await msg.edit(msg.text, buttons=sync_control_buttons())
        except Exception:
            pass
        return

    if data == "syncctrl:cancel":
        ACTIVE_SYNC["cancelled"] = True
        ACTIVE_SYNC["paused"] = False
        return await event.answer("🛑 Stopping sync & wiping cache...", alert=True)

async def main():
    await bot.start(bot_token=BOT_TOKEN)
    await user_client.connect()
    workers = max(1, min(MAX_WORKERS_LIMIT, int(load_config().get("parallel_workers", 1))))
    for _ in range(workers):
        asyncio.create_task(queue_worker())
    logging.info(f"Google Photos Bot started with {workers} queue workers.")
    await bot.run_until_disconnected()

if __name__ == "__main__":
    loop.run_until_complete(main())
PY_EOF

echo "======================================================================"
echo " 🛠️ Creating Terminal SSH Manager (gphotos-bot)..."
echo "======================================================================"
cat << 'CLI_EOF' > "$CLI_BIN"
#!/bin/bash
while true; do
    clear
    cat << "BANNER"
======================================================================
  ____   ___ _____ ____    ____  __   __  ____  ______        __
 | __ ) / _ \_   _/ ___|  | __ ) \ \ / / / ___||  _ \ \      / /
 |  _ \| | | || | \___ \  |  _ \  \ V /  \___ \| |_) \ \ /\ / / 
 | |_) | |_| || |  ___) | | |_) |  | |    ___) |  __/ \ V  V /  
 |____/ \___/ |_| |____/  |____/   |_|   |____/|_|     \_/\_/   
              GOOGLE PHOTOS BOT - SSH MANAGEMENT MENU
======================================================================
BANNER
    echo "1) Check Bot Status"
    echo "2) View Live Logs (Ctrl+C to exit)"
    echo "3) Restart Bot"
    echo "4) Stop Bot"
    echo "5) Force Clean Cache (/opt/gphotosbot/cache)"
    echo "6) Edit config.json"
    echo "7) Uninstall Google Photos Bot"
    echo "0) Exit"
    echo "======================================================================"
    read -rp "Select an option [0-7]: " choice
    case $choice in
        1) systemctl status gphotosbot --no-pager; read -rp "Press Enter..." ;;
        2) journalctl -u gphotosbot -f ;;
        3) systemctl restart gphotosbot && echo "✅ Restarted!" && sleep 1 ;;
        4) systemctl stop gphotosbot && echo "🛑 Stopped." && sleep 1 ;;
        5) rm -rf /opt/gphotosbot/cache/* && echo "🧹 Cache wiped!" && sleep 1 ;;
        6) nano /opt/gphotosbot/config.json && systemctl restart gphotosbot ;;
        7)
            read -rp "⚠️ Uninstall Google Photos Bot? [y/N]: " c
            if [[ "$c" =~ ^[Yy]$ ]]; then
                systemctl stop gphotosbot || true
                systemctl disable gphotosbot || true
                rm -f /etc/systemd/system/gphotosbot.service /usr/local/bin/gphotos-bot
                rm -rf /opt/gphotosbot
                systemctl daemon-reload
                echo "🗑️ Uninstalled."
                exit 0
            fi
            ;;
        0) exit 0 ;;
        *) echo "Invalid option." && sleep 1 ;;
    esac
done
CLI_EOF
chmod +x "$CLI_BIN"

/opt/gphotosbot/venv/bin/python -m py_compile "$INSTALL_DIR/gphotos_bot.py"

cat << 'SVC_EOF' > "$SERVICE_FILE"
[Unit]
Description=BOTS BY SPW Telegram to Google Photos Time-Machine Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/gphotosbot
ExecStart=/opt/gphotosbot/venv/bin/python /opt/gphotosbot/gphotos_bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable gphotosbot
systemctl restart gphotosbot

echo ""
echo "======================================================================"
echo " ✅ BOTS BY SPW — GOOGLE PHOTOS BOT INSTALLED!"
echo "======================================================================"
echo " • Status   : $(systemctl is-active gphotosbot)"
echo " • SSH Menu : Type 'gphotos-bot' anytime in terminal"
echo "======================================================================"
