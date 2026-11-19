# Third model: how far ahead should the night plan look?
#
#   julia --project=. scripts/look_ahead.jl run 2 4        # 4 trucks, plans look 2 days ahead
#   julia --project=. scripts/look_ahead.jl run 2 4 0.5    # the same, with the second day at half weight
#   julia --project=. scripts/look_ahead.jl table          # the runs made so far
#
# The base model in fleet_size.jl values a plan by the riders it spares the coming day.
# Here each station's curve covers several days: the riders let down from 01:00 until the
# end of the last day if no truck touches the station again. Everything else is as in
# fleet_size.jl except the solver's stopping rule (see SOLVER below), so `run 1 <trucks>`
# is the base model under the same rule as the others.
#
# A curve for two days ahead is learned from pairs of consecutive days in the training
# period, grouped by which of the two are weekdays. No curve uses a replay day.
#
# Each run writes results/look_ahead/days_<d>_trucks_<n>.json (with _w<weight> added when
# the later days are not counted in full).

using CityBike
using Dates
using Gurobi
using JSON
using Printf

const ROOT = joinpath(@__DIR__, "..")
const TRAINING = Date(2026, 6, 1):Day(1):Date(2026, 8, 16)
const REPLAY = Date(2026, 8, 17):Day(1):Date(2026, 9, 13)
const FLEET = 3000
const TRUCK = Truck()
const OUT = joinpath(ROOT, "results", "look_ahead")
# fleet_size.jl lets the solver stop early once its plan is proven to be within 2% of the
# best possible, measured on the riders let down at the stations it considers. Curves that
# cover more days are higher, which makes that 2% a looser test the further ahead the plan
# looks. Here the test is switched off, so every truck gets the full 10 seconds unless its
# plan is proven best before that.
const SOLVER = (per_side = 15, time_limit = 10.0, gap = 0.0, km_penalty = 0.05,
                attributes = Dict{String,Any}("Threads" => 2))

function replay(horizon::Integer, trucks::Integer, later::Real)
    name = "days_$(horizon)_trucks_$(trucks)" * (later == 1 ? "" : "_w$(later)")
    target = joinpath(OUT, name * ".json")
    isfile(target) && return println("have ", target)
    case = load_case(ROOT, TRAINING, REPLAY; horizon, later)
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), case.stations, TRUCK)
    environment = Gurobi.Env()
    seconds = @elapsed results, nights = night_replay(case, roads.travel, TRUCK, collect(REPLAY); trucks, fleet = FLEET,
                                                      optimizer = () -> Gurobi.Optimizer(environment), solver = SOLVER)
    total, failed = sum(result.trips for result in results), sum(let_down(result) for result in results)
    @printf("%d days ahead (later days at %.2f), %d trucks: %d of %d riders let down (%.1f%%), %.0f s\n",
            horizon, later, trucks, failed, total, 100 * failed / total, seconds)
    mkpath(OUT)
    open(target, "w") do io
        JSON.print(io, Dict("horizon" => horizon, "later" => later, "trucks" => trucks, "days" => day_records(results, nights)))
    end
end

function table()
    runs = [JSON.parsefile(joinpath(OUT, file)) for file in readdir(OUT) if endswith(file, ".json")]
    sort!(runs; by = run -> (run["trucks"], run["horizon"], -run["later"]))
    println("trucks  days ahead  weight  let down   share   bikes moved per truck  km per truck")
    for run in runs
        days = run["days"]
        total, failed = sum(day["trips"] for day in days), sum(day["noBike"] + day["noDock"] for day in days)
        shifts = [truck for day in days for truck in day["trucks"]]
        moved = sum(sum(max(Int(stop[2]), 0) for stop in truck["stops"]; init = 0) for truck in shifts; init = 0)
        @printf("%6d  %10d  %6.2f  %8d  %5.1f%%  %21.0f  %12.1f\n", run["trucks"], run["horizon"], run["later"], failed,
                100 * failed / total, moved / max(length(shifts), 1), sum(truck["km"] for truck in shifts; init = 0.0) / max(length(shifts), 1))
    end
end

if length(ARGS) in (3, 4) && ARGS[1] == "run"
    replay(parse(Int, ARGS[2]), parse(Int, ARGS[3]), length(ARGS) == 4 ? parse(Float64, ARGS[4]) : 1.0)
elseif ARGS == ["table"]
    table()
else
    error("usage: look_ahead.jl run <days ahead> <trucks> [weight on later days]   or   look_ahead.jl table")
end
