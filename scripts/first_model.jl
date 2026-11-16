# First model: one truck, one night at a time, replayed over four weeks.
#
#   julia --project=. scripts/first_model.jl
#
# Learns each station's demand from 1 June to 16 August 2026, then replays the real trips
# of 17 August to 13 September three times: with no truck, with a rule-of-thumb truck and
# with an optimized truck. The planner never sees the trips of the day it plans for.
#
# This first model drives in straight lines from an assumed depot at Økern; the later
# models use real streets and the operator's real base (see scripts/fleet_size.jl).
#
# Writes results/first_model/summary.csv and the data file for the page in
# report/first-model/. Pass a number of days to replay fewer and skip the page data.

using CityBike
using Dates
using Gurobi
using JSON
using Printf

const ROOT = joinpath(@__DIR__, "..")
const TRAINING = Date(2026, 6, 1):Day(1):Date(2026, 8, 16)
const REPLAY = Date(2026, 8, 17):Day(1):Date(2026, 9, 13)
const FLEET = 3000          # bikes, the operator's own figure
const TRUCK = Truck(depot_lat = 59.9309, depot_lon = 10.8019)
const POLICIES = ("none", "greedy", "optimal")

function main(args)
    days = isempty(args) ? collect(REPLAY) : collect(REPLAY)[1:parse(Int, args[1])]
    case = load_case(ROOT, TRAINING, REPLAY)
    stations = case.stations
    travel = straight_line_travel(TRUCK, stations)
    environment = Gurobi.Env()
    optimizer() = Gurobi.Optimizer(environment)
    nights = Dict{Tuple{String,Date},Solution}()

    planner(policy) = function (day, bikes)
        policy == "none" && return Plan[]
        night = plan_night(TRUCK, stations, travel, bikes, curves_for(case, day);
                           trucks = 1, method = policy == "greedy" ? :greedy : :optimal, optimizer)
        isempty(problems(night.plans, TRUCK, stations, bikes)) || error("invalid plan on $day")
        nights[(policy, day)] = night
        return night.plans
    end

    results = Dict{String,Vector{DayResult}}()
    for policy in POLICIES
        seconds = @elapsed results[policy] =
            simulate!(even_start(stations, FLEET), stations, case.trips, days, TRUCK, planner(policy))
        total = sum(result.trips for result in results[policy])
        failed = sum(let_down(result) for result in results[policy])
        @printf("%-8s %6d of %d riders let down (%.1f%%), %.0f s\n", policy, failed, total, 100 * failed / total, seconds)
    end

    night_of(policy, day) = get(nights, (policy, day), Solution())
    plan_of(result) = isempty(result.plans) ? Plan() : only(result.plans)
    out = joinpath(ROOT, "results", "first_model")
    mkpath(out)
    open(joinpath(out, "summary.csv"), "w") do io
        println(io, "day,policy,trips,no_bike,no_dock,stops,bikes_moved,km,minutes,expected_saved,gap,solve_seconds")
        for policy in POLICIES, result in results[policy]
            night, plan = night_of(policy, result.day), plan_of(result)
            @printf(io, "%s,%s,%d,%d,%d,%d,%d,%.1f,%.1f,%.1f,%.4f,%.1f\n", result.day, policy, result.trips,
                    result.no_bike, result.no_dock, length(plan.stops), bikes_moved(plan), plan.km, plan.minutes,
                    night.expected_saved, night.gap, night.seconds)
        end
    end
    println("wrote ", joinpath(out, "summary.csv"))
    isempty(args) || return

    page = Dict(
        "training" => [string(first(TRAINING)), string(last(TRAINING))],
        "days" => string.(days),
        "fleet" => FLEET,
        "truck" => Dict("capacity" => TRUCK.capacity, "shift" => TRUCK.shift, "stopMinutes" => TRUCK.stop_minutes,
                        "bikeMinutes" => TRUCK.bike_minutes, "speed" => TRUCK.speed_kmh, "detour" => TRUCK.detour,
                        "depot" => [TRUCK.depot_lat, TRUCK.depot_lon]),
        "stations" => [[station.name, round(station.lat; digits = 5), round(station.lon; digits = 5), station.capacity]
                       for station in stations],
        "weekdayCurves" => [round.(curve; digits = 2) for curve in case.weekday_curves],
        "policies" => Dict(policy => [Dict(
            "trips" => result.trips, "noBike" => result.no_bike, "noDock" => result.no_dock,
            "km" => round(plan_of(result).km; digits = 1), "minutes" => round(plan_of(result).minutes),
            "expected" => round(night_of(policy, result.day).expected_saved; digits = 1),
            "stops" => [[stop.station - 1, stop.change, round(stop.done; digits = 1)]
                        for stops in result.stops for stop in stops],
            "levels" => encode_levels(result.snapshots)) for result in results[policy]]
            for policy in POLICIES),
    )
    target = joinpath(ROOT, "report", "first-model")
    mkpath(target)
    open(joinpath(target, "data.js"), "w") do io
        print(io, "window.FIRST_MODEL = ")
        JSON.print(io, page)
        println(io, ";")
    end
    println("wrote ", joinpath(target, "data.js"))
end

main(ARGS)
