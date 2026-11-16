# Second model: how many trucks? Several trucks per night on real streets, replayed over
# four weeks for one fleet size at a time.
#
#   julia --project=. scripts/fleet_size.jl run optimal 3    # 3 optimized trucks
#   julia --project=. scripts/fleet_size.jl run greedy 3     # 3 rule-of-thumb trucks
#   julia --project=. scripts/fleet_size.jl run none 0       # no trucks
#   julia --project=. scripts/fleet_size.jl run oracle 3     # 3 trucks that know tomorrow's trips
#   julia --project=. scripts/fleet_size.jl page             # collect the runs for the page
#
# Each run writes results/fleet_size/<policy>_<trucks>.json. The runs are independent, so
# several can be started at the same time. `page` writes report/fleet-size/data.js.
#
# Trucks are planned one at a time: each gets the best plan given what the trucks before
# it will already have done. Driving times follow the street network from the operator's
# base at Kværnerveien 5.

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
const OUT = joinpath(ROOT, "results", "fleet_size")
# One kilometre of driving weighs as much as this many riders let down. It keeps routes
# short where riders are not affected; see the page for costs in kroner.
const KM_PENALTY = 0.05
const SOLVER = (per_side = 15, time_limit = 10.0, gap = 0.02, km_penalty = KM_PENALTY,
                attributes = Dict{String,Any}("Threads" => 2))

function replay(policy::AbstractString, trucks::Integer)
    target = joinpath(OUT, "$(policy)_$(trucks).json")
    isfile(target) && return println("have ", target)
    case = load_case(ROOT, TRAINING, REPLAY)
    stations = case.stations
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), stations, TRUCK)
    environment = Gurobi.Env()
    seconds = @elapsed results, nights = night_replay(case, roads.travel, TRUCK, collect(REPLAY); trucks, policy = Symbol(policy),
                                                      fleet = FLEET, optimizer = () -> Gurobi.Optimizer(environment), solver = SOLVER)
    total, failed = sum(result.trips for result in results), sum(let_down(result) for result in results)
    @printf("%s with %d trucks: %d of %d riders let down (%.1f%%), %.0f s\n", policy, trucks, failed, total, 100 * failed / total, seconds)

    mkpath(OUT)
    open(target, "w") do io
        JSON.print(io, Dict("policy" => policy, "trucks" => trucks, "days" => day_records(results, nights)))
    end
end

function page()
    stations = load_stations(joinpath(ROOT, "data", "raw", "oslo", "gbfs", "station_information.json"))
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), stations, TRUCK)
    runs = [JSON.parsefile(joinpath(OUT, file)) for file in readdir(OUT) if endswith(file, ".json")]
    sort!(runs; by = run -> (run["policy"], run["trucks"]))

    # The page maps the optimized trucks only; the other runs keep their totals.
    legs = Dict{String,Vector{Int}}()
    for run in runs
        if run["policy"] in ("optimal", "none")
            collect_legs!(legs, roads, run["days"])
        else
            for day in run["days"]
                delete!(day, "levels")
                foreach(truck -> truck["stops"] = length(truck["stops"]), day["trucks"])
            end
        end
    end
    summary = runs

    data = Dict(
        "days" => string.(collect(REPLAY)), "fleet" => FLEET,
        "truck" => Dict("capacity" => TRUCK.capacity, "shift" => TRUCK.shift, "stopMinutes" => TRUCK.stop_minutes,
                        "bikeMinutes" => TRUCK.bike_minutes, "depot" => [TRUCK.depot_lat, TRUCK.depot_lon]),
        "stations" => [[station.name, round(station.lat; digits = 5), round(station.lon; digits = 5), station.capacity]
                       for station in stations],
        "runs" => summary, "legs" => legs)
    target = joinpath(ROOT, "report", "fleet-size")
    mkpath(target)
    file = joinpath(target, "data.js")
    open(file, "w") do io
        print(io, "window.FLEET_SIZE = ")
        JSON.print(io, data)
        println(io, ";")
    end
    cp(joinpath(ROOT, "report", "map", "oslo.js"), joinpath(target, "map.js"); force = true)
    cp(joinpath(ROOT, "report", "shared", "player.js"), joinpath(target, "player.js"); force = true)
    @printf("%d runs, %d street legs, %.1f MB in %s\n", length(runs), length(legs), filesize(file) / 1e6, file)
end

if length(ARGS) == 3 && ARGS[1] == "run"
    replay(ARGS[2], parse(Int, ARGS[3]))
elseif ARGS == ["page"]
    page()
else
    error("usage: fleet_size.jl run <optimal|greedy|oracle|none> <trucks>   or   fleet_size.jl page")
end
