#!/usr/bin/env python3
"""Build Banana/Resources/Airports.tsv: every airport a trip can pass through.

Sources (both free to bundle):
  - OurAirports airports.csv (public domain): the list, kind, city, country, scheduled service.
    https://davidmegginson.github.io/ourairports-data/airports.csv
  - mwgg/Airports airports.json (MIT): the IANA time zone per airport.
    https://raw.githubusercontent.com/mwgg/Airports/master/airports.json

Kept: every open airport with an IATA code that is large or medium, or has scheduled service.
An airport the time zone source doesn't know takes the zone of the nearest one that it does,
in the same country and within 150 km; otherwise it is left out.

Columns (tab-separated, one airport per line, sorted by code):
  code  latitude  longitude  time zone  city  country  size(L/M/S)  scheduled(1/0)

usage: build.py [cache dir]   (downloads into the cache dir when the files aren't there)
"""
import csv, json, math, os, re, sys, urllib.request
from zoneinfo import available_timezones

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "Banana", "Resources", "Airports.tsv")
SOURCES = {
    "ourairports.csv": "https://davidmegginson.github.io/ourairports-data/airports.csv",
    "mwgg.json": "https://raw.githubusercontent.com/mwgg/Airports/master/airports.json",
}

def fetch(cache):
    os.makedirs(cache, exist_ok=True)
    for name, url in SOURCES.items():
        path = os.path.join(cache, name)
        if not os.path.exists(path):
            print("downloading", url)
            urllib.request.urlretrieve(url, path)

def km(a_lat, a_lon, b_lat, b_lon):
    d_lat, d_lon = math.radians(b_lat - a_lat), math.radians(b_lon - a_lon)
    h = math.sin(d_lat / 2) ** 2 + math.cos(math.radians(a_lat)) * math.cos(math.radians(b_lat)) * math.sin(d_lon / 2) ** 2
    return 2 * 6371 * math.asin(min(1, math.sqrt(h)))

# The city an airport is known by, where neither source says it: the airport sits in a
# neighbouring town, and that town is what the data names.
CITY = {
    "NRT": "Tokyo", "TPE": "Taipei", "EZE": "Buenos Aires", "BGY": "Bergamo", "IAD": "Washington",
    "KEF": "Reykjavik", "CIA": "Rome", "DFW": "Dallas", "HHN": "Frankfurt", "BVA": "Paris",
    "CRL": "Brussels", "NYO": "Stockholm", "TRF": "Oslo", "GIG": "Rio de Janeiro", "SDU": "Rio de Janeiro",
    "CGH": "São Paulo", "VCP": "São Paulo", "DWC": "Dubai", "SZX": "Shenzhen", "HKG": "Hong Kong",
    "MFM": "Macau", "CGK": "Jakarta", "MNL": "Manila", "SGN": "Ho Chi Minh City", "DEL": "Delhi",
    "BLR": "Bangalore", "YYZ": "Toronto", "YUL": "Montreal", "YVR": "Vancouver", "SJO": "San José",
    "PTY": "Panama City", "TLV": "Tel Aviv", "AMM": "Amman", "JNB": "Johannesburg", "CMN": "Casablanca",
}

def fold(text):
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFKD", text.lower()) if not unicodedata.combining(c))

def clean(text):
    return re.sub(r"\s+", " ", re.sub(r"\s*\(.*?\)", "", text)).strip()

def city(code, municipality, name, other):
    """The city an airport serves, in the words people use for it.

    OurAirports names the municipality the airfield stands in ('Velika Gorica' for Zagreb, 'Ferno
    (VA)' for Milan Malpensa, 'Pendik, Istanbul'); mwgg names the city served but is wrong for
    some. Whichever of them the airport's own name carries is the one people say.
    """
    if code in CITY:
        return CITY[code]
    named = fold(name)
    parts = [clean(part.split("/")[0]) for part in clean(municipality).split(",")]
    parts = [part for part in parts if part]
    other = clean(other.split("/")[0])
    for part in parts:
        if fold(part) in named:
            return part
    if other and fold(other) in named:
        return other
    return parts[0] if parts else (other or clean(name))

def main():
    cache = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "airports")
    fetch(cache)
    zones = available_timezones()
    known, served = {}, {}
    for entry in json.load(open(os.path.join(cache, "mwgg.json"), encoding="utf-8")).values():
        code, zone = (entry.get("iata") or "").strip().upper(), (entry.get("tz") or "").strip()
        if len(code) == 3 and zone in zones:
            known[code] = zone
        if len(code) == 3:
            served[code] = (entry.get("city") or "").strip()

    size = {"large_airport": "L", "medium_airport": "M"}
    rows = {}
    for r in csv.DictReader(open(os.path.join(cache, "ourairports.csv"), encoding="utf-8")):
        code = r["iata_code"].strip().upper()
        if not re.fullmatch(r"[A-Z]{3}", code) or r["type"] == "closed":
            continue
        scheduled = r["scheduled_service"] == "yes"
        kind = size.get(r["type"], "S")
        if kind == "S" and not scheduled:
            continue
        name = city(code, r["municipality"], r["name"], served.get(code, "")).replace("\t", " ")
        try:
            lat, lon = float(r["latitude_deg"]), float(r["longitude_deg"])
        except ValueError:
            continue
        if not name or not r["iso_country"] or not (-90 <= lat <= 90 and -180 <= lon <= 180):
            continue
        row = dict(code=code, lat=lat, lon=lon, city=name, country=r["iso_country"], size=kind, scheduled=scheduled)
        # A code listed twice: the bigger airport, then the one with scheduled service.
        rank = ("LMS".index(kind), 0 if scheduled else 1)
        if code not in rows or rank < rows[code][0]:
            rows[code] = (rank, row)

    placed = [row for _, row in rows.values() if row["code"] in known]
    for row in placed:
        row["zone"] = known[row["code"]]
    borrowed = dropped = 0
    out = list(placed)
    for _, row in rows.values():
        if "zone" in row:
            continue
        near = [(km(row["lat"], row["lon"], p["lat"], p["lon"]), p) for p in placed if p["country"] == row["country"]]
        near = [n for n in near if n[0] <= 150]
        if not near:
            dropped += 1
            continue
        row["zone"] = min(near, key=lambda n: n[0])[1]["zone"]
        borrowed += 1
        out.append(row)

    out.sort(key=lambda row: row["code"])
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        for row in out:
            f.write("\t".join([row["code"], f"{row['lat']:.4f}", f"{row['lon']:.4f}", row["zone"], row["city"],
                               row["country"], row["size"], "1" if row["scheduled"] else "0"]) + "\n")
    large = sum(1 for row in out if row["size"] == "L")
    print(f"{len(out)} airports ({large} large), {borrowed} took a neighbour's zone, {dropped} left out → {OUT}")

if __name__ == "__main__":
    main()
