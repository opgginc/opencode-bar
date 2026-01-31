#!/usr/bin/env python3
"""
Browser Cookie Extractor for GitHub
Supports: Chrome, Brave, Arc, Edge, Firefox, Safari, ChatGPT Atlas
"""

import os
import sys
import json
import sqlite3
import tempfile
import shutil
import subprocess
from pathlib import Path
from typing import Optional, Dict, List, Tuple
from dataclasses import dataclass
from enum import Enum

# Crypto imports - try multiple options
try:
    from Crypto.Cipher import AES
    from Crypto.Protocol.KDF import PBKDF2
    CRYPTO_BACKEND = "pycryptodome"
except ImportError:
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.backends import default_backend
        CRYPTO_BACKEND = "cryptography"
    except ImportError:
        CRYPTO_BACKEND = None


class BrowserType(Enum):
    CHROME = "chrome"
    BRAVE = "brave"
    ARC = "arc"
    EDGE = "edge"
    FIREFOX = "firefox"
    SAFARI = "safari"
    VIVALDI = "vivaldi"
    OPERA = "opera"
    OPERA_GX = "opera_gx"
    CHROMIUM = "chromium"
    CHATGPT_ATLAS = "chatgpt_atlas"


@dataclass
class BrowserProfile:
    browser: BrowserType
    profile_path: str
    profile_name: str
    display_name: str  # Human readable


@dataclass
class Cookie:
    name: str
    value: str
    domain: str
    path: str
    expires: int
    secure: bool
    http_only: bool


class ChromiumCookieDecryptor:
    """Decrypt Chromium-based browser cookies on macOS"""
    
    def __init__(self, browser_name: str = "Chrome"):
        self.browser_name = browser_name
        self._key = None
    
    def _get_encryption_key(self) -> bytes:
        """Get encryption key from macOS Keychain"""
        if self._key:
            return self._key
            
        # Map browser to Keychain service name
        keychain_map = {
            "Chrome": ("Chrome Safe Storage", "Chrome"),
            "Brave": ("Brave Safe Storage", "Brave"),
            "Arc": ("Arc Safe Storage", "Arc"),
            "Edge": ("Microsoft Edge Safe Storage", "Microsoft Edge"),
            "Vivaldi": ("Vivaldi Safe Storage", "Vivaldi"),
            "Opera": ("Opera Safe Storage", "Opera"),
            "Chromium": ("Chromium Safe Storage", "Chromium"),
        }
        
        service, account = keychain_map.get(self.browser_name, ("Chrome Safe Storage", "Chrome"))
        
        try:
            password = subprocess.check_output([
                "security", "find-generic-password",
                "-w", "-s", service, "-a", account
            ], stderr=subprocess.DEVNULL).decode().strip()
            
            # Derive key using PBKDF2
            # Chrome uses 1003 iterations, 16 byte key length, salt='saltysalt'
            if CRYPTO_BACKEND == "pycryptodome":
                self._key = PBKDF2(password.encode(), b'saltysalt', dkLen=16, count=1003)
            elif CRYPTO_BACKEND == "cryptography":
                kdf = PBKDF2HMAC(
                    algorithm=hashes.SHA1(),
                    length=16,
                    salt=b'saltysalt',
                    iterations=1003,
                    backend=default_backend()
                )
                self._key = kdf.derive(password.encode())
            else:
                raise RuntimeError("No crypto backend available. Install pycryptodome or cryptography.")
                
            return self._key
        except subprocess.CalledProcessError:
            raise RuntimeError(f"Failed to get {self.browser_name} encryption key from Keychain")
    
    def decrypt_value(self, encrypted_value: bytes) -> str:
        """Decrypt a cookie value"""
        if not encrypted_value:
            return ""
            
        # Chrome cookies on macOS are prefixed with 'v10' or 'v11'
        if encrypted_value[:3] == b'v10' or encrypted_value[:3] == b'v11':
            encrypted_value = encrypted_value[3:]
        else:
            try:
                return encrypted_value.decode('utf-8')
            except (UnicodeDecodeError, ValueError):
                return ""
        
        key = self._get_encryption_key()
        iv = b' ' * 16  # Chrome uses 16 spaces as IV
        
        if CRYPTO_BACKEND == "pycryptodome":
            cipher = AES.new(key, AES.MODE_CBC, iv)
            decrypted = cipher.decrypt(encrypted_value)
        elif CRYPTO_BACKEND == "cryptography":
            cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
            decryptor = cipher.decryptor()
            decrypted = decryptor.update(encrypted_value) + decryptor.finalize()
        else:
            raise RuntimeError("No crypto backend available")
        
        # Remove PKCS7 padding
        padding_len = decrypted[-1]
        if 1 <= padding_len <= 16:
            decrypted = decrypted[:-padding_len]
        
        # Chrome on macOS has 32 bytes of garbage at the start (2 AES blocks)
        # The actual value is after this prefix
        if len(decrypted) > 32:
            decrypted = decrypted[32:]
        
        try:
            return decrypted.decode('utf-8')
        except UnicodeDecodeError:
            for i in range(len(decrypted)):
                try:
                    return decrypted[i:].decode('utf-8')
                except UnicodeDecodeError:
                    continue
            return ""


def get_chromium_profiles(browser: BrowserType) -> List[BrowserProfile]:
    """Get all profiles for a Chromium-based browser"""
    
    base_paths = {
        BrowserType.CHROME: "~/Library/Application Support/Google/Chrome",
        BrowserType.BRAVE: "~/Library/Application Support/BraveSoftware/Brave-Browser",
        BrowserType.ARC: "~/Library/Application Support/Arc/User Data",
        BrowserType.EDGE: "~/Library/Application Support/Microsoft Edge",
        BrowserType.VIVALDI: "~/Library/Application Support/Vivaldi",
        BrowserType.OPERA: "~/Library/Application Support/com.operasoftware.Opera",
        BrowserType.OPERA_GX: "~/Library/Application Support/com.operasoftware.OperaGX",
        BrowserType.CHROMIUM: "~/Library/Application Support/Chromium",
        BrowserType.CHATGPT_ATLAS: "~/Library/Application Support/com.openai.atlas/browser-data/host",
    }
    
    base_path = Path(os.path.expanduser(base_paths.get(browser, "")))
    if not base_path.exists():
        return []
    
    profiles = []
    
    # Look for Default and Profile * directories
    for item in base_path.iterdir():
        if not item.is_dir():
            continue
        if item.name == "Default" or item.name.startswith("Profile "):
            cookie_file = item / "Cookies"
            if cookie_file.exists():
                # Try to get profile name from Preferences
                pref_file = item / "Preferences"
                profile_name = item.name
                if pref_file.exists():
                    try:
                        with open(pref_file, 'r') as f:
                            prefs = json.load(f)
                            profile_name = prefs.get('profile', {}).get('name', item.name)
                    except (json.JSONDecodeError, IOError, KeyError):
                        pass
                
                profiles.append(BrowserProfile(
                    browser=browser,
                    profile_path=str(item),
                    profile_name=item.name,
                    display_name=f"{browser.value.title()} - {profile_name}"
                ))
    
    return profiles


def get_firefox_profiles() -> List[BrowserProfile]:
    """Get Firefox profiles"""
    base_path = Path(os.path.expanduser("~/Library/Application Support/Firefox/Profiles"))
    if not base_path.exists():
        return []
    
    profiles = []
    for item in base_path.iterdir():
        if item.is_dir():
            cookie_file = item / "cookies.sqlite"
            if cookie_file.exists():
                # Profile name is the folder name without the random prefix
                name_parts = item.name.split('.')
                profile_name = name_parts[-1] if len(name_parts) > 1 else item.name
                
                profiles.append(BrowserProfile(
                    browser=BrowserType.FIREFOX,
                    profile_path=str(item),
                    profile_name=item.name,
                    display_name=f"Firefox - {profile_name}"
                ))
    
    return profiles


def get_all_browser_profiles() -> List[BrowserProfile]:
    """Get all available browser profiles"""
    profiles = []
    
    # Chromium-based browsers
    for browser in [BrowserType.CHROME, BrowserType.BRAVE, BrowserType.ARC, 
                    BrowserType.EDGE, BrowserType.VIVALDI, BrowserType.OPERA,
                    BrowserType.OPERA_GX, BrowserType.CHROMIUM, BrowserType.CHATGPT_ATLAS]:
        profiles.extend(get_chromium_profiles(browser))
    
    # Firefox
    profiles.extend(get_firefox_profiles())
    
    # Safari - single profile
    safari_cookies = Path(os.path.expanduser("~/Library/Cookies/Cookies.binarycookies"))
    if safari_cookies.exists():
        profiles.append(BrowserProfile(
            browser=BrowserType.SAFARI,
            profile_path=str(safari_cookies.parent),
            profile_name="default",
            display_name="Safari"
        ))
    
    return profiles


def get_github_cookies_chromium(profile: BrowserProfile) -> Dict[str, str]:
    """Get GitHub cookies from a Chromium-based browser profile"""
    
    cookie_file = Path(profile.profile_path) / "Cookies"
    if not cookie_file.exists():
        return {}
    
    # Copy to temp file (Chrome locks the database)
    with tempfile.NamedTemporaryFile(delete=False, suffix=".db") as tmp:
        tmp_path = tmp.name
    shutil.copy2(cookie_file, tmp_path)
    
    browser_name_map = {
        BrowserType.CHROME: "Chrome",
        BrowserType.BRAVE: "Brave",
        BrowserType.ARC: "Arc",
        BrowserType.EDGE: "Edge",
        BrowserType.VIVALDI: "Vivaldi",
        BrowserType.OPERA: "Opera",
        BrowserType.OPERA_GX: "Opera",
        BrowserType.CHROMIUM: "Chromium",
        BrowserType.CHATGPT_ATLAS: "Chrome",  # Atlas uses Chrome storage
    }
    
    decryptor = ChromiumCookieDecryptor(browser_name_map.get(profile.browser, "Chrome"))
    
    cookies = {}
    try:
        conn = sqlite3.connect(tmp_path)
        cursor = conn.cursor()
        
        # Query GitHub cookies
        cursor.execute("""
            SELECT name, encrypted_value, value, host_key 
            FROM cookies 
            WHERE host_key LIKE '%github.com%'
        """)
        
        for name, encrypted_value, plain_value, host in cursor.fetchall():
            if plain_value:
                cookies[name] = plain_value
            elif encrypted_value:
                try:
                    decrypted = decryptor.decrypt_value(encrypted_value)
                    if decrypted:
                        cookies[name] = decrypted
                except Exception as e:
                    print(f"Warning: Failed to decrypt {name}: {e}", file=sys.stderr)
        
        conn.close()
    finally:
        os.unlink(tmp_path)
    
    return cookies


def get_github_cookies_firefox(profile: BrowserProfile) -> Dict[str, str]:
    """Get GitHub cookies from Firefox"""
    
    cookie_file = Path(profile.profile_path) / "cookies.sqlite"
    if not cookie_file.exists():
        return {}
    
    # Copy to temp file
    with tempfile.NamedTemporaryFile(delete=False, suffix=".db") as tmp:
        tmp_path = tmp.name
    shutil.copy2(cookie_file, tmp_path)
    
    cookies = {}
    try:
        conn = sqlite3.connect(tmp_path)
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT name, value FROM moz_cookies 
            WHERE host LIKE '%github.com%'
        """)
        
        for name, value in cursor.fetchall():
            cookies[name] = value
        
        conn.close()
    finally:
        os.unlink(tmp_path)
    
    return cookies


def get_github_cookies(profile: BrowserProfile) -> Dict[str, str]:
    """Get GitHub cookies from any supported browser profile"""
    
    if profile.browser == BrowserType.SAFARI:
        # Safari binary cookies require special parsing - not implemented yet
        print("Safari cookie extraction not yet implemented", file=sys.stderr)
        return {}
    elif profile.browser == BrowserType.FIREFOX:
        return get_github_cookies_firefox(profile)
    else:
        return get_github_cookies_chromium(profile)


def build_cookie_header(cookies: Dict[str, str]) -> str:
    """Build Cookie header string from cookies dict"""
    return "; ".join(f"{k}={v}" for k, v in cookies.items())


def test_github_session(cookies: Dict[str, str]) -> Tuple[bool, Optional[str]]:
    """Test if GitHub session is valid and get username"""
    import urllib.request
    
    cookie_header = build_cookie_header(cookies)
    
    req = urllib.request.Request(
        "https://github.com/settings/profile",
        headers={
            "Cookie": cookie_header,
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        }
    )
    
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            html = response.read().decode('utf-8')
            # Check if we're logged in by looking for username
            if 'dotcom_user' in cookies:
                return True, cookies.get('dotcom_user')
            # Try to find username in page
            import re
            match = re.search(r'login="([^"]+)"', html)
            if match:
                return True, match.group(1)
            return response.status == 200, None
    except Exception as e:
        return False, None


def main():
    """Main function - list profiles or get cookies"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Extract GitHub cookies from browsers")
    parser.add_argument("--list", action="store_true", help="List all available browser profiles")
    parser.add_argument("--profile", type=int, help="Profile index to use (from --list)")
    parser.add_argument("--test", action="store_true", help="Test if session is valid")
    parser.add_argument("--cookie-header", action="store_true", help="Output as Cookie header")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    
    args = parser.parse_args()
    
    profiles = get_all_browser_profiles()
    
    if args.list:
        print("Available browser profiles with GitHub cookies:\n")
        for i, profile in enumerate(profiles):
            cookies = get_github_cookies(profile)
            github_cookies = {k: v for k, v in cookies.items() if k in ['logged_in', 'dotcom_user', 'user_session', '_gh_sess']}
            status = "✓ logged in" if cookies.get('logged_in') == 'yes' else "✗ not logged in"
            user = cookies.get('dotcom_user', 'unknown')
            print(f"  [{i}] {profile.display_name}")
            print(f"      Status: {status}, User: {user}")
            print(f"      Cookies: {len(cookies)} total, {len(github_cookies)} GitHub-related")
            print()
        return
    
    if args.profile is not None:
        if args.profile < 0 or args.profile >= len(profiles):
            print(f"Error: Invalid profile index. Use --list to see available profiles.", file=sys.stderr)
            sys.exit(1)
        
        profile = profiles[args.profile]
        cookies = get_github_cookies(profile)
        
        if args.test:
            valid, username = test_github_session(cookies)
            if valid:
                print(f"Session valid! User: {username or 'unknown'}")
            else:
                print("Session invalid or expired")
            sys.exit(0 if valid else 1)
        
        if args.cookie_header:
            print(build_cookie_header(cookies))
        elif args.json:
            print(json.dumps(cookies, indent=2))
        else:
            for name, value in cookies.items():
                print(f"{name}={value}")
    else:
        parser.print_help()


if __name__ == "__main__":
    if CRYPTO_BACKEND is None:
        print("Error: No crypto backend available.", file=sys.stderr)
        print("Install one of: pip install pycryptodome  OR  pip install cryptography", file=sys.stderr)
        sys.exit(1)
    main()
