#!/usr/bin/env python3
"""
GitHub Copilot Usage History Query Tool
Fetches daily usage history using browser cookies
"""

import sys
import os
import json
import re
import argparse
import urllib.request
import urllib.error
from datetime import datetime
from typing import Optional, Dict, Any, List

# Add scripts directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from browser_cookies import (
    get_all_browser_profiles,
    get_github_cookies,
    build_cookie_header,
    CRYPTO_BACKEND
)


class GitHubCopilotAPI:
    """GitHub Copilot internal API client"""
    
    def __init__(self, cookies: Dict[str, str]):
        self.cookies = cookies
        self.cookie_header = build_cookie_header(cookies)
        self._customer_id: Optional[str] = None
    
    def _request(self, url: str, accept: str = "application/json") -> Any:
        """Make authenticated request to GitHub"""
        req = urllib.request.Request(
            url,
            headers={
                "Cookie": self.cookie_header,
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "Accept": accept,
                "X-Requested-With": "XMLHttpRequest"
            }
        )
        
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                content_type = response.headers.get('Content-Type', '')
                data = response.read().decode('utf-8')
                
                if 'application/json' in content_type or accept == 'application/json':
                    try:
                        return json.loads(data)
                    except json.JSONDecodeError:
                        return data
                return data
        except urllib.error.HTTPError as e:
            if e.code == 401 or e.code == 403:
                raise RuntimeError("Session expired or invalid. Please refresh browser login.")
            raise RuntimeError(f"HTTP {e.code}: {e.reason}")
        except urllib.error.URLError as e:
            raise RuntimeError(f"Network error: {e.reason}")
    
    def get_customer_id(self) -> str:
        """Get GitHub customer ID from billing page"""
        if self._customer_id:
            return self._customer_id
        
        html = self._request(
            "https://github.com/settings/billing",
            accept="text/html"
        )
        
        match = re.search(r'"customerId":\s*(\d+)', html)
        if not match:
            raise RuntimeError("Could not find customer ID. Are you logged in?")
        
        self._customer_id = match.group(1)
        return self._customer_id
    
    def get_usage_card(self) -> Dict[str, Any]:
        """Get current usage summary"""
        customer_id = self.get_customer_id()
        url = f"https://github.com/settings/billing/copilot_usage_card?customer_id={customer_id}&period=3"
        return self._request(url)
    
    def get_usage_history(self, page: int = 1) -> Dict[str, Any]:
        """Get daily usage history with model breakdown"""
        customer_id = self.get_customer_id()
        url = f"https://github.com/settings/billing/copilot_usage_table?customer_id={customer_id}&group=0&period=3&query=&page={page}"
        return self._request(url)
    
    def get_username(self) -> str:
        """Get logged in username"""
        return self.cookies.get('dotcom_user', 'unknown')


def parse_daily_usage(table_data: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Parse usage table into clean daily data"""
    days = []
    
    for row in table_data.get('table', {}).get('rows', []):
        cells = row.get('cells', [])
        if len(cells) < 5:
            continue
        
        date_str = cells[0].get('value', '')
        included_req = cells[1].get('value', '0')
        billed_req = cells[2].get('value', '0')
        gross_amount = cells[3].get('value', '$0')
        billed_amount = cells[4].get('value', '$0')
        
        # Parse model breakdown from subtable
        models = []
        subtable = row.get('subtable')
        if subtable:
            for model_row in subtable.get('rows', []):
                model_cells = model_row.get('cells', [])
                if len(model_cells) >= 5:
                    models.append({
                        'model': model_cells[0].get('value', ''),
                        'included': model_cells[1].get('value', '0'),
                        'billed': model_cells[2].get('value', '0'),
                        'gross': model_cells[3].get('value', '$0'),
                        'cost': model_cells[4].get('value', '$0'),
                    })
        
        days.append({
            'date': date_str,
            'included_requests': float(included_req.replace(',', '')) if included_req else 0,
            'billed_requests': float(billed_req.replace(',', '')) if billed_req else 0,
            'gross_amount': gross_amount,
            'billed_amount': billed_amount,
            'models': models
        })
    
    return days


def print_summary(api: GitHubCopilotAPI) -> None:
    """Print usage summary"""
    usage = api.get_usage_card()
    history = api.get_usage_history()
    days = parse_daily_usage(history)
    
    print(f"=== GitHub Copilot Usage ({api.get_username()}) ===")
    print()
    
    # Current usage
    net_qty = usage.get('netQuantity', 0)
    discount_qty = usage.get('discountQuantity', 0)
    entitlement = usage.get('userPremiumRequestEntitlement', 0)
    net_billed = usage.get('netBilledAmount', 0)
    
    total_used = net_qty + discount_qty
    pct = (total_used / entitlement * 100) if entitlement > 0 else 0
    
    print(f"Used: {total_used:.0f} / {entitlement} ({pct:.1f}%)")
    if net_billed > 0:
        print(f"Add-on Cost: ${net_billed:.2f}")
    print()
    
    # Recent days
    print("Recent Usage:")
    for day in days[:10]:
        total_req = day['included_requests'] + day['billed_requests']
        cost_str = f" ({day['billed_amount']})" if day['billed_requests'] > 0 else ""
        print(f"  {day['date']}: {total_req:.0f} req{cost_str}")
    
    print()
    
    # Top models
    model_totals: Dict[str, float] = {}
    for day in days:
        for model in day['models']:
            name = model['model']
            req = float(model['included'].replace(',', '') or 0) + float(model['billed'].replace(',', '') or 0)
            model_totals[name] = model_totals.get(name, 0) + req
    
    print("Model Usage (this period):")
    for model, req in sorted(model_totals.items(), key=lambda x: -x[1])[:5]:
        print(f"  {model}: {req:.0f} req")


def print_json(api: GitHubCopilotAPI) -> None:
    """Print full data as JSON"""
    usage = api.get_usage_card()
    history = api.get_usage_history()
    
    output = {
        'user': api.get_username(),
        'fetched_at': datetime.now().isoformat(),
        'usage_card': usage,
        'daily_history': parse_daily_usage(history),
        'raw_history': history
    }
    
    print(json.dumps(output, indent=2, ensure_ascii=False))


def list_profiles() -> None:
    """List available browser profiles"""
    profiles = get_all_browser_profiles()
    
    print("Available browser profiles:\n")
    
    for i, profile in enumerate(profiles):
        cookies = get_github_cookies(profile)
        logged_in = cookies.get('logged_in') == 'yes'
        user = cookies.get('dotcom_user', 'unknown')
        
        status = "✓ logged in" if logged_in else "✗ not logged in"
        
        print(f"  [{i}] {profile.display_name}")
        print(f"      Status: {status}, User: {user}")
        print()


def main():
    if CRYPTO_BACKEND is None:
        print("Error: No crypto backend available.", file=sys.stderr)
        print("Install: pip install cryptography", file=sys.stderr)
        sys.exit(1)
    
    parser = argparse.ArgumentParser(
        description="Query GitHub Copilot usage history via browser cookies"
    )
    parser.add_argument(
        "--list", action="store_true",
        help="List available browser profiles"
    )
    parser.add_argument(
        "--profile", type=int,
        help="Browser profile index to use (from --list)"
    )
    parser.add_argument(
        "--summary", action="store_true",
        help="Print usage summary (default)"
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Output full data as JSON"
    )
    
    args = parser.parse_args()
    
    if args.list:
        list_profiles()
        return
    
    if args.profile is None:
        # Try to find a logged-in profile automatically
        profiles = get_all_browser_profiles()
        logged_in_profiles = []
        
        for i, profile in enumerate(profiles):
            cookies = get_github_cookies(profile)
            if cookies.get('logged_in') == 'yes':
                logged_in_profiles.append((i, profile, cookies.get('dotcom_user', 'unknown')))
        
        if not logged_in_profiles:
            print("No logged-in GitHub profiles found.", file=sys.stderr)
            print("Use --list to see available profiles.", file=sys.stderr)
            sys.exit(1)
        
        if len(logged_in_profiles) == 1:
            args.profile = logged_in_profiles[0][0]
            print(f"Using profile: {logged_in_profiles[0][1].display_name} ({logged_in_profiles[0][2]})\n", file=sys.stderr)
        else:
            print("Multiple logged-in profiles found:", file=sys.stderr)
            for i, profile, user in logged_in_profiles:
                print(f"  [{i}] {profile.display_name} ({user})", file=sys.stderr)
            print("\nUse --profile <index> to select one.", file=sys.stderr)
            sys.exit(1)
    
    profiles = get_all_browser_profiles()
    if args.profile < 0 or args.profile >= len(profiles):
        print(f"Error: Invalid profile index {args.profile}", file=sys.stderr)
        sys.exit(1)
    
    profile = profiles[args.profile]
    cookies = get_github_cookies(profile)
    
    if cookies.get('logged_in') != 'yes':
        print(f"Warning: Profile {profile.display_name} may not be logged in", file=sys.stderr)
    
    api = GitHubCopilotAPI(cookies)
    
    try:
        if args.json:
            print_json(api)
        else:
            print_summary(api)
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
