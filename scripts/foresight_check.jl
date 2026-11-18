# Why does planning with tomorrow's real rides not beat planning from history?
#
#   julia --project=. scripts/foresight_check.jl 4      # with 4 night trucks
#
# Every night, from the same inventories, two plans are made: one from history and one
# from the coming day's real rides. Each is carried out and the coming day replayed, so
# the two plans are compared on equal terms for that one day. We also record how well each
# plan leaves the system for the day after: the riders history expects to be let down the
# next day if no truck came. The replay then continues from the history plan's outcome.
#
# Writes results/foresight_check/trucks_<n>.json.

using CityBike
using Dates
using Gurobi
using JSON
using Printf

const ROOT = joinpath(@__DIR__, "..")
const TRAINING = Date(2026, 6, 1):Day(1):Date(2026, 8, 16)
const REPLAY = Date(2026, 8, 17):Day(1):Date(2026, 9, 13)
const TRUCK = Truck()
const SOLVER = (per_side = 15, time_limit = 10.0, gap = 0.02, km_penalty = 0.05,
                attributes = Dict{String,Any}("Threads" => 2))

function main(trucks::Integer)
    case = load_case(ROOT, TRAINING, REPLAY)
    stations = case.stations
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), stations, TRUCK)
    environment = Gurobi.Env()
    optimizer() = Gurobi.Optimizer(environment)
    by_day = Dict(day => Trip[] for day in REPLAY)
    for trip in case.trips
        haskey(by_day, service_day(trip.start)) && push!(by_day[service_day(trip.start)], trip)
    end

    "Carry out `plans` from `bikes` and replay `day`; bikes still on the road land the next morning."
    function one_day(bikes, plans, day)
        state = copy(bikes)
        results = simulate!(state, stations, by_day[day], [day, day + Day(1)], TRUCK,
                            (d, b, shift) -> d == day ? plans : Plan[])
        return sum(let_down, results), state
    end
    "Riders history expects to be let down the day after `day`, starting from `bikes`, if no truck came."
    left_behind(bikes, day) = sum(curves_for(case, day + Day(1))[i][bikes[i] + 1] for i in eachindex(bikes))

    bikes = even_start(stations, 3000)
    rows = []
    for day in REPLAY
        history = plan_night(TRUCK, stations, roads.travel, bikes, curves_for(case, day); trucks, optimizer, SOLVER...)
        foresight = plan_night(TRUCK, stations, roads.travel, bikes, failure_curves(case.trips, stations, [day]); trucks, optimizer, SOLVER...)
        down_history, after_history = one_day(bikes, history.plans, day)
        down_foresight, after_foresight = one_day(bikes, foresight.plans, day)
        push!(rows, Dict("day" => string(day), "trips" => length(by_day[day]),
                         "letDownHistory" => down_history, "letDownForesight" => down_foresight,
                         "leftBehindHistory" => round(left_behind(after_history, day); digits = 1),
                         "leftBehindForesight" => round(left_behind(after_foresight, day); digits = 1)))
        bikes = after_history
    end
    mean_of(key) = sum(row[key] for row in rows) / length(rows)
    @printf("%d trucks, same starting point each night:\n", trucks)
    @printf("  riders let down that day:        history %.0f, foresight %.0f\n", mean_of("letDownHistory"), mean_of("letDownForesight"))
    @printf("  expected let down the day after: history %.0f, foresight %.0f\n", mean_of("leftBehindHistory"), mean_of("leftBehindForesight"))
    out = joinpath(ROOT, "results", "foresight_check")
    mkpath(out)
    open(joinpath(out, "trucks_$(trucks).json"), "w") do io
        JSON.print(io, Dict("trucks" => trucks, "days" => rows))
    end
end

main(parse(Int, ARGS[1]))
