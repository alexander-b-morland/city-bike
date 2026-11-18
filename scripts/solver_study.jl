# How much do the results change if the solver gets more time?
#
#   julia --project=. scripts/solver_study.jl 4 60     # 4 night trucks, 60 seconds per truck
#
# Replays the four weeks with optimized night trucks, as scripts/fleet_size.jl does, but
# with the given time limit per truck, a tighter target gap of 0.5% and four solver
# threads. The base case in fleet_size.jl uses 10 seconds, 2% and two threads.
#
# Writes results/solver_study/trucks_<n>_<seconds>s.json.

using CityBike
using Dates
using Gurobi
using JSON
using Printf

const ROOT = joinpath(@__DIR__, "..")
const TRAINING = Date(2026, 6, 1):Day(1):Date(2026, 8, 16)
const REPLAY = Date(2026, 8, 17):Day(1):Date(2026, 9, 13)
const TRUCK = Truck()

function main(trucks::Integer, seconds::Real)
    target = joinpath(ROOT, "results", "solver_study", "trucks_$(trucks)_$(round(Int, seconds))s.json")
    isfile(target) && return println("have ", target)
    case = load_case(ROOT, TRAINING, REPLAY)
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), case.stations, TRUCK)
    environment = Gurobi.Env()
    solver = (per_side = 15, time_limit = Float64(seconds), gap = 0.005, km_penalty = 0.05,
              attributes = Dict{String,Any}("Threads" => 4))
    results, nights = night_replay(case, roads.travel, TRUCK, collect(REPLAY); trucks,
                                   optimizer = () -> Gurobi.Optimizer(environment), solver)
    total, failed = sum(result.trips for result in results), sum(let_down(result) for result in results)
    gaps = sort([night.gap for night in values(nights)])
    @printf("%d trucks, %d s per truck: %d of %d riders let down (%.1f%%), median worst gap %.1f%%\n",
            trucks, seconds, failed, total, 100 * failed / total, 100 * gaps[(length(gaps) + 1) ÷ 2])
    mkpath(dirname(target))
    open(target, "w") do io
        JSON.print(io, Dict("trucks" => trucks, "seconds" => seconds, "days" => day_records(results, nights)))
    end
end

main(parse(Int, ARGS[1]), parse(Float64, ARGS[2]))
