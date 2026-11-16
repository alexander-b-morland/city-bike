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

Only the project structure exists so far. The language, solver and formulation have not
been chosen.

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
| `src/`       | Model, algorithm and visualization code                  |
| `tests/`     | Tests for the code in `src/`                             |
| `data/`      | Input data (small files only; document the source)       |
| `notebooks/` | Exploratory analysis and experiments                     |
| `results/`   | Generated output (figures, tables, logs) — not committed |
| `report/`    | Written report, slides and the final animation           |

## Getting started

To be filled in once the language and dependencies are decided.

## Licence

Code is released under the [MIT licence](LICENSE). The bike data belongs to Oslo Bysykkel
and is used under NLOD 2.0.
