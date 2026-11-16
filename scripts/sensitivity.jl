# Sensitivity: how much do the results depend on what we assumed? One assumption is
# changed at a time and the four weeks are replayed with optimized night trucks.
#
#   julia --project=. scripts/sensitivity.jl run capacity 30 4   # trucks that hold 30 bikes, 4 trucks
#   julia --project=. scripts/sensitivity.jl run shift 420 4     # 7-hour shifts
#   julia --project=. scripts/sensitivity.jl run fleet 3600 4    # 3,600 bikes in the system
#   julia --project=. scripts/sensitivity.jl run handling 1.0 4  # one minute to load or unload a bike
#
# Each run writes a one-line summary to results/sensitivity/<parameter>_<value>_<trucks>.json.
# The base case (20 bikes, 300 minutes, 3,000 bikes, half a minute) is scripts/fleet_size.jl.

using CityBike
using Dates
using Gurobi
using JSON
using Printf

const ROOT = joinpath(@__DIR__, "..")
const TRAINING = Date(2026, 6, 1):Day(1):Date(2026, 8, 16)
const REPLAY = Date(2026, 8, 17):Day(1):Date(2026, 9, 13)
const SOLVER = (per_side = 15, time_limit = 10.0, gap = 0.02, km_penalty = 0.05,
                attributes = Dict{String,Any}("Threads" => 2))

function replay(parameter::AbstractString, value::Real, trucks::Integer)
    fleet = parameter == "fleet" ? round(Int, value) : 3000
    truck = parameter == "capacity" ? Truck(capacity = round(Int, value)) :
            parameter == "shift" ? Truck(shift = value) :
            parameter == "handling" ? Truck(bike_minutes = value) :
            parameter == "fleet" ? Truck() : error("unknown parameter $parameter")
    case = load_case(ROOT, TRAINING, REPLAY)
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), case.stations, truck)
    environment = Gurobi.Env()
    results, _ = night_replay(case, roads.travel, truck, collect(REPLAY); trucks, fleet,
                              optimizer = () -> Gurobi.Optimizer(environment), solver = SOLVER)
    total, failed = sum(result.trips for result in results), sum(let_down(result) for result in results)
    moved = sum(sum(bikes_moved, result.plans; init = 0) for result in results) / length(results)
    @printf("%s = %s with %d trucks: %d of %d riders let down (%.1f%%)\n", parameter, value, trucks, failed, total, 100 * failed / total)
    out = joinpath(ROOT, "results", "sensitivity")
    mkpath(out)
    open(joinpath(out, "$(parameter)_$(value)_$(trucks).json"), "w") do io
        JSON.print(io, Dict("parameter" => parameter, "value" => value, "trucks" => trucks, "trips" => total,
                            "letDown" => failed, "share" => round(100 * failed / total; digits = 2),
                            "bikesMovedPerNight" => round(moved; digits = 1)))
    end
end

if length(ARGS) == 4 && ARGS[1] == "run"
    replay(ARGS[2], parse(Float64, ARGS[3]), parse(Int, ARGS[4]))
else
    error("usage: sensitivity.jl run <capacity|shift|fleet|handling> <value> <trucks>")
end
