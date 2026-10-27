#!/usr/bin/env python3
"""Refresh exact model identifiers and artwork from Apple's identification articles."""

import argparse
import concurrent.futures
import hashlib
import html
import json
import pathlib
import re
import subprocess
import tempfile
import urllib.parse
import urllib.request
from datetime import date

SOURCES = {
    "macBookPro": "https://support.apple.com/en-us/108052",
    "macBookAir": "https://support.apple.com/en-us/102869",
    "macBook": "https://support.apple.com/en-us/103257",
    "iMac": "https://support.apple.com/en-us/108054",
    "macMini": "https://support.apple.com/en-us/102852",
    "macStudio": "https://support.apple.com/en-us/102231",
    "macPro": "https://support.apple.com/en-us/102887",
}
HOSTS = {"support.apple.com", "cdsassets.apple.com"}
IDENTIFIER = re.compile(r"\b(?:Mac(?:Book(?:Air|Pro)?|mini|Pro)?|iMac(?:Pro)?)\d+,\d+\b")


def clean(value):
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", value)).split())


class AppleRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def validate_url(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in HOSTS or parsed.username or parsed.password:
        raise ValueError(f"Unapproved Apple resource URL: {url}")


def fetch(url, limit=8_000_000):
    validate_url(url)
    with urllib.request.build_opener(AppleRedirects()).open(url, timeout=30) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"Resource exceeds size limit: {url}")
    return data


def parse_article(document, family, source):
    # Model identifiers live in paragraphs; headings alone do not identify variants.
    headings = list(re.finditer(r"<h[23]\b[^>]*>(.*?)</h[23]>", document, re.I | re.S))
    records = []
    for index, heading in enumerate(headings):
        end = headings[index + 1].start() if index + 1 < len(headings) else len(document)
        section = document[heading.end():end]
        paragraphs = list(re.finditer(r"<p\b[^>]*>(.*?)</p>", section, re.I | re.S))
        for paragraph_index, paragraph in enumerate(paragraphs):
            value = clean(paragraph.group(1))
            if "model identifier" not in value.lower():
                continue
            identifiers = IDENTIFIER.findall(value)
            if not identifiers:
                continue
            title = clean(heading.group(1))
            if not title.startswith(("Mac", "iMac")):
                names = [clean(p.group(1)) for p in paragraphs[:paragraph_index] if clean(p.group(1)).startswith("MacBook (")]
                title = names[-1] if names else "MacBook " + title
            images = list(re.finditer(r'<img\b[^>]*\bsrc="([^"]+)"', section[:paragraph.start()], re.I))
            if not images:
                raise ValueError(f"Missing model image: {source}: {title}")
            image_url = html.unescape(images[-1].group(1))
            validate_url(image_url)
            specs = None
            for link in re.finditer(r'<a\b[^>]*\bhref="([^"]+)"[^>]*>(.*?)</a>', section[paragraph.end():], re.I | re.S):
                if "tech spec" in clean(link.group(2)).lower():
                    candidate = urllib.parse.urljoin(source, html.unescape(link.group(1)))
                    validate_url(candidate)
                    specs = candidate
                    break
            token = hashlib.sha256(image_url.encode()).hexdigest()[:20]
            records.append({
                "id": family + "-" + hashlib.sha256((title + image_url).encode()).hexdigest()[:16],
                "identifiers": sorted(set(identifiers)), "name": title, "family": family,
                "imageURL": image_url, "imageName": "apple-" + token,
                "sourceURL": source, "specsURL": specs,
            })
    if not records:
        raise ValueError(f"No model identifiers found; Apple markup may have changed: {source}")
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata-only", action="store_true", help="Do not download artwork")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    resources = root / "src/PortsCore/Resources"
    artwork = resources / "ModelArtwork"
    artwork.mkdir(parents=True, exist_ok=True)

    def read_source(item):
        family, source = item
        return parse_article(fetch(source).decode("utf-8"), family, source)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        records = [record for group in pool.map(read_source, SOURCES.items()) for record in group]
    records = list({r["id"]: r for r in records}.values())

    def download(record):
        destination = artwork / (record["imageName"] + ".png")
        if destination.exists():
            return
        data = fetch(record["imageURL"])
        with tempfile.TemporaryDirectory(prefix="iports-artwork-") as temp:
            original = pathlib.Path(temp) / "original"
            original.write_bytes(data)
            converted = pathlib.Path(temp) / "image.png"
            subprocess.run(["/usr/bin/sips", "-s", "format", "png", "-Z", "640", str(original), "--out", str(converted)], check=True, capture_output=True)
            destination.write_bytes(converted.read_bytes())

    if not args.metadata_only:
        unique = {r["imageName"]: r for r in records}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(download, unique.values()))
    payload = {"version": 1, "updatedAt": date.today().isoformat(), "models": records}
    destination = resources / "MacCatalog.json"
    temporary = destination.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(destination)
    identifiers = {identifier for record in records for identifier in record["identifiers"]}
    print(f"Updated {len(records)} variants, {len(identifiers)} exact identifiers, {len(SOURCES)} Apple articles")


if __name__ == "__main__":
    main()
