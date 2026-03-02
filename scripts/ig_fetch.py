#!/usr/bin/env python3
"""Fetch Instagram post caption using instagrapi.

Usage: python3 ig_fetch.py <post_url_or_shortcode>
Output: JSON with caption, username, timestamp
"""
import sys, json, re, os
from pathlib import Path

SESSION_FILE = Path.home() / '.config' / 'ig_session.json'
CREDS_FILE   = Path.home() / '.config' / 'ig_creds.json'

def shortcode_from_url(url):
    m = re.search(r'instagram\.com/(?:p|reel)/([A-Za-z0-9_-]+)', url)
    return m.group(1) if m else url.strip('/')

def get_client():
    from instagrapi import Client
    cl = Client()
    cl.delay_range = [1, 3]
    if SESSION_FILE.exists():
        try:
            cl.load_settings(SESSION_FILE)
            creds = json.loads(CREDS_FILE.read_text())
            cl.login(creds['username'], creds['password'])
            cl.dump_settings(SESSION_FILE)
            return cl
        except Exception:
            pass
    creds = json.loads(CREDS_FILE.read_text())
    cl.login(creds['username'], creds['password'])
    cl.dump_settings(SESSION_FILE)
    return cl

def main():
    if len(sys.argv) < 2:
        print(json.dumps({'error': 'no URL provided'}))
        sys.exit(1)

    arg = sys.argv[1]
    shortcode = shortcode_from_url(arg)

    try:
        cl = get_client()
        media_id = cl.media_id(cl.media_pk_from_code(shortcode))
        info = cl.media_info(media_id)
        result = {
            'shortcode': shortcode,
            'caption': info.caption_text or '',
            'username': info.user.username,
            'timestamp': str(info.taken_at),
            'url': f'https://www.instagram.com/p/{shortcode}/',
            'error': None
        }
    except Exception as e:
        result = {'shortcode': shortcode, 'caption': '', 'error': str(e)}

    print(json.dumps(result))

if __name__ == '__main__':
    main()
