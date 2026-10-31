# Airport table

`build.py` writes `Banana/Resources/Airports.tsv`, the table `AirportTable` reads: every open
airport with an IATA code that is large or medium or has scheduled service, with its coordinates,
IANA time zone, the city it serves and its country.

    python3 tools/airports/build.py

It downloads its two sources into `.build/airports/` the first time:

| Source | What it gives | Licence |
| --- | --- | --- |
| [OurAirports](https://ourairports.com/data/) `airports.csv` | the list, size, city, country, scheduled service | public domain |
| [mwgg/Airports](https://github.com/mwgg/Airports) `airports.json` | the time zone, and the city where OurAirports names a neighbouring town | MIT, © mwgg |

The app credits both in Settings › Airport data. `AirportTableTests` checks the result: every row
reads, every time zone is one the system knows, and the airports people fly through say the city
and zone people expect. Run the tests after rebuilding the table.
