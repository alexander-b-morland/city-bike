# city-bike

Optimizing city-bike allocation over-night, as the white collars and latte-drinkers sleep
tight awaiting a full bike rack the next morning.

## The problem

By evening some bike stations are full and others are empty. Overnight, one or more
vehicles drive between stations and move bikes (and possibly swap or recharge e-bike
batteries). Which stations should each vehicle visit, in what order, and how many bikes
should it load or unload at each, so that as few stations as possible are empty or full
when the morning rush starts?

The plan, from simple to rich:

1. **Oslo, one night, one vehicle.** Station inventories at closing time, target
   inventories for the morning, one vehicle with limited capacity and a time budget.
2. **Several vehicles.**
3. **E-bikes** that need recharging or battery swaps, if the data supports it.
4. **Uncertain morning demand**, estimated from historical trips.

Every model is compared against a simple greedy benchmark, for example always moving
bikes from the fullest station to the emptiest.

## Deliverables

- A report and slides in `report/`.
- An animation of the city through one day: stations flash when they run empty or full,
  and at night the vehicles draw their routes across the map.

## Status

The first model is built and solved: one truck, one night at a time, replayed over four
weeks of real trips and compared with a rule of thumb and with no truck at all. The
results and an animated map are in [`report/first-model/`](report/first-model/); open
`index.html` in a browser. More vehicles, e-bikes and uncertain demand come next.

## Data

| Source | What | Where |
|--------|------|-------|
| Oslo Bysykkel historical trips | One row per trip: start and end time, duration, start and end station with coordinates. Monthly files from April 2016. | <https://oslobysykkel.no/en/open-data/historical> |
| Oslo Bysykkel GBFS feeds | Station locations and capacities, live bikes and docks available. | <https://oslobysykkel.no/en/open-data/realtime> |

Both are published under the
[Norwegian Licence for Open Government Data (NLOD) 2.0](https://data.norge.no/nlod/en/2.0).
Trondheim and Bergen publish data in the same format, so the model can be moved to
another city later.

Raw downloads are not committed. They go in `data/raw/`, which is git-ignored.

## Layout

| Path         | Purpose                                                  |
|--------------|----------------------------------------------------------|
| `src/`       | Data loading, demand curves, simulator, benchmark and model (the `CityBike` package) |
| `test/`      | Tests for the code in `src/`                             |
| `data/`      | Input data (small files only; document the source)       |
| `scripts/`   | Command-line scripts: data download and model runs       |
| `notebooks/` | Exploratory analysis and experiments                     |
| `results/`   | Generated output (figures, tables, logs) — not committed |
| `report/`    | Result pages, written report, slides and the final animation |

## Getting started

You need [Julia](https://julialang.org/downloads/) 1.13 or newer and a Gurobi licence
(free for academic use). The Gurobi solver itself is downloaded with the Julia package.

Install the dependencies:

```bash
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

Run the tests:

```bash
julia --project=. -e "using Pkg; Pkg.test()"
```

Download a year of Oslo trips and a snapshot of the station feeds (about 215 MB, into
`data/raw/oslo/`):

```bash
julia --project=. scripts/download_oslo.jl 2025-11 2026-10
```

Print a first look at the data and write per-station summaries to
`results/exploration/`:

```bash
julia --project=. notebooks/explore_oslo.jl
```

Run the first model. It learns station demand from 1 June to 16 August 2026, replays
17 August to 13 September with no truck, a rule-of-thumb truck and an optimized truck,
and writes `results/first_model/summary.csv` and the data behind the page in
`report/first-model/` (about ten minutes):

```bash
julia --project=. scripts/first_model.jl
```

The models are written in JuMP, so another solver such as the open-source HiGHS can be
swapped in where Gurobi is not available.

## Licence

Code is released under the [MIT licence](LICENSE). The bike data belongs to Oslo Bysykkel
and is used under NLOD 2.0.
