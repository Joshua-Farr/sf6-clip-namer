"""Minimal Buckler's Boot Camp (CFN web) client using stdlib only."""

from __future__ import annotations

import json
import logging
import re
import time
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import quote

from cfn_core import newest_match, normalize_cookie

BUCKLER_BASE = "https://www.streetfighter.com/6/buckler"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
BUILD_ID_RE = re.compile(r'"buildId":"([^"]+)"')

VALID_MODES = ("rank", "casual", "hub", "custom", "extreme")


class BucklerError(RuntimeError):
    """Raised when Buckler is unreachable or the session is invalid."""


class BucklerClient:
    def __init__(self, cookie: str, *, timeout: float = 15.0) -> None:
        self.cookie = normalize_cookie(cookie)
        if not self.cookie:
            raise BucklerError("Missing Buckler session cookie")
        self.timeout = timeout
        self._build_id: str | None = None

    def _headers(self, *, accept: str) -> dict[str, str]:
        return {
            "User-Agent": USER_AGENT,
            "Accept": accept,
            "Accept-Language": "en-US,en;q=0.9",
            "Cookie": self.cookie,
        }

    def _get(self, url: str, *, accept: str) -> bytes:
        req = urllib.request.Request(url, headers=self._headers(accept=accept), method="GET")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            body = exc.read() if hasattr(exc, "read") else b""
            raise BucklerError(f"HTTP {exc.code} for {url}: {body[:200]!r}") from exc
        except urllib.error.URLError as exc:
            raise BucklerError(f"Network error: {exc}") from exc

    def scrape_build_id(self) -> str:
        html = self._get(BUCKLER_BASE, accept="text/html,application/xhtml+xml").decode(
            "utf-8", errors="replace"
        )
        match = BUILD_ID_RE.search(html)
        if not match:
            raise BucklerError(
                "Could not find Buckler buildId (session may be expired — re-copy buckler_id cookie)"
            )
        self._build_id = match.group(1)
        return self._build_id

    def ensure_build_id(self) -> str:
        if not self._build_id:
            return self.scrape_build_id()
        return self._build_id

    def fetch_page_props(self, path: str, *, retry_build: bool = True) -> dict[str, Any]:
        """
        Fetch Next.js pageProps for a Buckler route path.
        Example path: profile/123/battlelog/rank?page=1
        """
        build_id = self.ensure_build_id()
        if "?" in path:
            pathname, query = path.split("?", 1)
            url = f"{BUCKLER_BASE}/_next/data/{build_id}/en/{pathname}.json?{query}"
        else:
            url = f"{BUCKLER_BASE}/_next/data/{build_id}/en/{path}.json"

        try:
            raw = self._get(url, accept="application/json,*/*")
        except BucklerError as exc:
            # Stale buildId after Capcom redeploy → refresh once.
            if retry_build and "HTTP 404" in str(exc):
                logging.info("Buckler buildId stale; refreshing")
                self.scrape_build_id()
                return self.fetch_page_props(path, retry_build=False)
            raise

        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise BucklerError("Malformed Buckler JSON (session may be expired)") from exc

        if not isinstance(payload, dict) or "pageProps" not in payload:
            raise BucklerError("No pageProps in response (session likely expired)")
        props = payload["pageProps"]
        if not isinstance(props, dict):
            raise BucklerError("Unexpected pageProps type")
        return props

    def battlelog(
        self,
        short_id: int,
        mode: str = "rank",
        page: int = 1,
    ) -> list[dict[str, Any]]:
        if mode not in VALID_MODES:
            raise BucklerError(f"Unsupported mode: {mode}")
        if not str(short_id).isdigit():
            raise BucklerError("short_id must be numeric")
        sid = quote(str(int(short_id)), safe="")
        props = self.fetch_page_props(f"profile/{sid}/battlelog/{mode}?page={page}")
        replay_list = props.get("replay_list") or []
        if not isinstance(replay_list, list):
            return []
        return [b for b in replay_list if isinstance(b, dict)]

    def latest_match(
        self,
        short_id: int,
        modes: list[str] | None = None,
    ) -> dict[str, Any] | None:
        modes = modes or ["rank", "casual"]
        by_mode: dict[str, list[dict[str, Any]]] = {}
        for i, mode in enumerate(modes):
            if i > 0:
                # Be polite to Capcom's frontend — small gap between mode pages.
                time.sleep(0.6)
            try:
                by_mode[mode] = self.battlelog(short_id, mode=mode, page=1)
            except BucklerError as exc:
                logging.warning("Battlelog %s failed: %s", mode, exc)
                by_mode[mode] = []
        match = newest_match(by_mode, my_short_id=int(short_id))
        if match:
            match["fetched_at"] = int(time.time())
        return match
