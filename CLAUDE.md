# CLAUDE.md

Personal optimization project: overnight rebalancing of city bikes. During the night, one
or more vehicles move bikes between stations (and possibly swap or recharge e-bike
batteries) so that as few stations as possible are empty or full in the morning. We start
with Oslo Bysykkel, one night and one vehicle, then extend.

This is not coursework. Claude writes the formulation, code and analysis, and the user
steers the modeling choices.

## Stack

Julia with JuMP and Gurobi. The repository root is the Julia package `CityBike`
(`Project.toml`, `src/CityBike.jl`, `test/runtests.jl`).

- Install dependencies: `julia --project=. -e "using Pkg; Pkg.instantiate()"`
- Run tests: `julia --project=. -e "using Pkg; Pkg.test()"`
- Add a dependency: `julia --project=. -e "using Pkg; Pkg.add(\"Name\")"`
- Run the first model (about ten minutes): `julia --project=. scripts/first_model.jl`

Gurobi needs a licence file on the machine; it is never committed. The tool for the
animation has not been chosen. The model should write its routes and inventories to
plain files in `results/` so the animation can be built in any tool.

## How the models work

- **Demand curves** (`src/demand.jl`): for each station, the average number of riders let
  down over a day as a function of the bikes it holds when the day starts, learned by
  replaying historical days at that station alone. The curves are convex, which keeps
  the model linear. Weekdays and weekends have separate curves.
- **Simulator** (`src/simulate.jl`): replays real trips against station inventories. A
  rider who finds no bike gives up; a rider who finds no dock rides on to the nearest
  station with room. The truck's plan is carried out stop by stop during the night.
- **Benchmark** (`src/greedy.jl`): fullest station to emptiest station, to half full.
- **Model** (`src/model.jl`): one truck, one night. Chooses route and bikes per stop to
  minimise the sum of the demand curves, within the shift and the truck's capacity.
- A service day runs 01:00 to 01:00. The truck works 01:00 to 06:00.
- Planners must only use trips from before the replay period. Never let a planner see
  the trips of the day it plans for.
- Each model gets a script in `scripts/` and a self-contained page in `report/<model>/`
  (`index.html` plus a generated `data.js`).

Assumptions that are not from data: fleet of 3,000 bikes spread evenly at the start,
truck of 20 bikes, 3 minutes per stop, half a minute per bike, 25 km/h, detour factor
1.4, depot at Økern, no daytime rebalancing.

## Layout

- `src/` — model, algorithm and data code
- `test/` — tests for `src/`
- `data/` — small input data files, with their source documented; raw downloads go in
  `data/raw/` (git-ignored)
- `scripts/` — command-line scripts (data download)
- `notebooks/` — exploration and experiments
- `results/` — generated output; git-ignored except `.gitkeep`
- `report/` — written report, slides and the final animation
- `course/` — a course term-project description kept locally as a yardstick;
  git-ignored, never commit it

## Yardstick

We are not bound by any course rules, but we borrow the quality bar of a problem-driven
optimization term project:

- **Good:** a simplified version of the problem, an optimization model for it, and a
  measured gain over a benchmark that could be used in practice without optimization.
- **Very good:** also sensitivity analysis on the main parameters, and a discussion of
  the complexities left out.
- **Excellent:** one or two of those complexities built into the model.

The report (5 to 10 pages) answers: which problem, why it matters, which data, how we
tackled it, the key findings, the impact, and what we would do with another week. The
video is for a general audience and at most 5 minutes.

## Data

- Historical trips (monthly CSV/JSON, April 2016 onward):
  `https://data.urbansharing.com/oslobysykkel.no/trips/v1/YYYY/MM.csv`
- Station locations and capacities (GBFS):
  `https://gbfs.urbansharing.com/oslobysykkel.no/station_information.json`
- Live station status (GBFS):
  `https://gbfs.urbansharing.com/oslobysykkel.no/station_status.json`
- GBFS requests need a `Client-Identifier` header of the form `<org>-<app>`.
- Download with `julia --project=. scripts/download_oslo.jl 2025-11 2026-10`; explore
  with `julia --project=. notebooks/explore_oslo.jl`.

What the data can and cannot tell us (found in the first exploration):

- Trips show user rides only. They hold no station inventories, no bike type and none
  of the operator's own rebalancing moves, so evening inventories must be simulated or
  collected from the live feed. Each run of the download script saves one live snapshot.
- Observed trips are censored demand: an empty station records no departures.
- The live feed splits parked bikes into `bike` and `ebike` per station but gives no
  battery level, so any recharging model needs an assumed battery process.
- The system runs all night. 01:00 to 06:00 holds about 2% of summer weekday trips.
- Trip times are in UTC; convert to Oslo time before any hour-of-day analysis.
- There are no travel times between stations; vehicle travel times must come from a
  road network or from straight-line distance with a detour factor.
- Licence: Norwegian Licence for Open Government Data (NLOD) 2.0. Attribute Oslo
  Bysykkel wherever the data or anything derived from it is shown.

## Conventions

- Decide modeling choices with the user before implementing them: propose, explain the
  trade-off, then build.
- Keep the commands in the Stack section and in `README.md` up to date.
- Always compare against a simple benchmark (a greedy rule such as "move from the
  fullest station to the emptiest") so results have a baseline.
- Keep generated artifacts in `results/`. Anything meant to be seen on GitHub (final
  figures, the animation, the report) goes in `report/`.
- **This repository is public.** Never commit secrets, solver licences, API keys,
  personal data or third-party material we do not have the right to publish. Do not
  commit large raw data files; commit the script that downloads them.
