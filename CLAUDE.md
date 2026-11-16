# CLAUDE.md

Personal optimization project: overnight rebalancing of city bikes. During the night, one
or more vehicles move bikes between stations (and possibly swap or recharge e-bike
batteries) so that as few stations as possible are empty or full in the morning. We start
with Oslo Bysykkel, one night and one vehicle, then extend.

This is not coursework. Claude writes the formulation, code and analysis, and the user
steers the modeling choices. The exact formulation has not been chosen yet.

## Stack

Julia with JuMP and Gurobi. The repository root is the Julia package `CityBike`
(`Project.toml`, `src/CityBike.jl`, `test/runtests.jl`).

- Install dependencies: `julia --project=. -e "using Pkg; Pkg.instantiate()"`
- Run tests: `julia --project=. -e "using Pkg; Pkg.test()"`
- Add a dependency: `julia --project=. -e "using Pkg; Pkg.add(\"Name\")"`

Gurobi needs a licence file on the machine; it is never committed. The tool for the
animation has not been chosen. The model should write its routes and inventories to
plain files in `results/` so the animation can be built in any tool.

## Layout

- `src/` — model, algorithm and data code
- `test/` — tests for `src/`
- `data/` — small input data files, with their source documented; raw downloads go in
  `data/raw/` (git-ignored)
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
