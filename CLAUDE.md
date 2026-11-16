# CLAUDE.md

Personal optimization project: overnight rebalancing of city bikes. During the night, one
or more vehicles move bikes between stations (and possibly swap or recharge e-bike
batteries) so that as few stations as possible are empty or full in the morning. We start
with Oslo Bysykkel, one night and one vehicle, then extend.

This is not coursework. Claude writes the formulation, code and analysis, and the user
steers the modeling choices. The language, solver and exact formulation have not been
chosen yet.

## Layout

- `src/` — model, algorithm and visualization code
- `tests/` — tests for `src/`
- `data/` — small input data files, with their source documented; raw downloads go in
  `data/raw/` (git-ignored)
- `notebooks/` — exploration and experiments
- `results/` — generated output; git-ignored except `.gitkeep`
- `report/` — written report, slides and the final animation

## Data

- Historical trips (monthly CSV/JSON, April 2016 onward):
  `https://data.urbansharing.com/oslobysykkel.no/trips/v1/YYYY/MM.csv`
- Station locations and capacities (GBFS):
  `https://gbfs.urbansharing.com/oslobysykkel.no/station_information.json`
- Live station status (GBFS):
  `https://gbfs.urbansharing.com/oslobysykkel.no/station_status.json`
- GBFS requests need a `Client-Identifier` header of the form `<org>-<app>`.
- Licence: Norwegian Licence for Open Government Data (NLOD) 2.0. Attribute Oslo
  Bysykkel wherever the data or anything derived from it is shown.

## Conventions

- Decide modeling choices with the user before implementing them: propose, explain the
  trade-off, then build. Do not start implementing until the stack is chosen.
- Once a stack is chosen, record the build, run and test commands here and in
  `README.md`.
- Always compare against a simple benchmark (a greedy rule such as "move from the
  fullest station to the emptiest") so results have a baseline.
- Keep generated artifacts in `results/`. Anything meant to be seen on GitHub (final
  figures, the animation, the report) goes in `report/`.
- **This repository is public.** Never commit secrets, solver licences, API keys,
  personal data or third-party material we do not have the right to publish. Do not
  commit large raw data files; commit the script that downloads them.
