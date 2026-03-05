#!/usr/bin/env python3
"""Interactive Instagram login helper. Run from Mac (not VPS) to create a session.

Instagram blocks login attempts from datacenter IPs, so this must be run from
your Mac (residential IP) once to create a session file. The session is then
copied to the VPS where ig_fetch.py reuses it without re-authenticating.

Usage: python3 ig_login.py
Output: ~/Desktop/ig_session.json — copy this to VPS ~/.config/ig_session.json

Session lasts ~90 days. Renew by running this script again when ig_fetch.py
returns {"error": "..."}.
"""
import json, sys
from pathlib import Path

CREDS_FILE   = Path.home() / '.config' / 'ig_creds.json'
SESSION_FILE = Path.home() / 'Desktop' / 'ig_session.json'

if not CREDS_FILE.exists():
    print(f"Error: {CREDS_FILE} not found.")
    print('Create it with:')
    print('  echo \'{"username":"YOUR_USERNAME","password":"YOUR_PASSWORD"}\' > ~/.config/ig_creds.json')
    print('  chmod 600 ~/.config/ig_creds.json')
    sys.exit(1)

try:
    from instagrapi import Client
except ImportError:
    print("Error: instagrapi not installed.")
    print("Install it with: pip3 install --break-system-packages instagrapi")
    sys.exit(1)

creds = json.loads(CREDS_FILE.read_text())
cl = Client()
cl.delay_range = [1, 3]

print(f"Logging in as {creds['username']}...")
print("(Instagram may email you a 6-digit verification code)")
cl.login(creds['username'], creds['password'])
cl.dump_settings(SESSION_FILE)
print(f"\nSession saved to {SESSION_FILE}")
print(f"\nNow copy to VPS (replace <VPS_IP> and SSH port as needed):")
print(f"  scp -P 2222 {SESSION_FILE} openclaw@<VPS_IP>:~/.config/ig_session.json")
