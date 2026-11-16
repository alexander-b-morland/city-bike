# First model: one truck, one night at a time, replayed over four weeks.
#
#   julia --project=. scripts/first_model.jl
#
# Learns each station's demand from 1 June to 16 August 2026, then replays the real trips
# of 17 August to 13 September three times: with no truck, with a rule-of-thumb truck and
# with an optimized truck. The planner never sees the trips of the day it plans for.
#
# Writes results/first_model/summary.csv and the data file for the page in
# report/first-model/.

using CityBike
using Dates
using Gurobi
using JSON
using Printf

const ROOT = joinpath(@__DIR__, "..")
const TRAINING = Date(2026, 6, 1):Day(1):Date(2026, 8, 16)
const REPLAY = Date(2026, 8, 17):Day(1):Date(2026, 9, 13)
const FLEET = 3000          # bikes, the operator's own figure
const TRUCK = Truck()
const LETTERS = ['0':'9'; 'a':'z'; 'A':'Z']   # one character per inventory level

"Spread the fleet over the stations in proportion to their docks."
function even_start(stations, fleet)
    share = fleet .* [station.capacity for station in stations] ./ sum(station.capacity for station in stations)
    bikes = floor.(Int, share)
    for index in sortperm(share .- bikes; rev = true)[1:fleet - sum(bikes)]
        bikes[index] += 1
    end
    return bikes
end

expected_saved(plan, curves, bikes) =
    sum(curves[stop.station][bikes[stop.station] + 1] - curves[stop.station][bikes[stop.station] + stop.change + 1]
        for stop in plan.stops; init = 0.0)

function main()
    stations = load_stations(joinpath(ROOT, "data", "raw", "oslo", "gbfs", "station_information.json"))
    trips = load_trips(joinpath(ROOT, "data", "raw", "oslo", "trips"), stations, first(TRAINING), last(REPLAY))
    weekday_curves = failure_curves(trips, stations, filter(is_weekday, collect(TRAINING)))
    weekend_curves = failure_curves(trips, stations, filter(!is_weekday, collect(TRAINING)))
    all(is_convex, weekday_curves) && all(is_convex, weekend_curves) || error("a demand curve is not convex")
    curves_for(day) = is_weekday(day) ? weekday_curves : weekend_curves

    environment = Gurobi.Env()
    optimizer() = Gurobi.Optimizer(environment)
    nights = Dict{Tuple{String,Date},NamedTuple}()   # what each planner expected and how it solved

    function planner(policy)
        return function (day, bikes)
            curves = curves_for(day)
            if policy == "none"
                plan, gap, seconds = Plan(), 0.0, 0.0
            elseif policy == "greedy"
                plan, gap, seconds = greedy_plan(TRUCK, stations, bikes), 0.0, 0.0
            else
                solution = optimal_plan(TRUCK, stations, bikes, curves; optimizer)
                plan, gap, seconds = solution.plan, solution.gap, solution.seconds
            end
            isempty(problems(plan, TRUCK, stations, bikes)) || error("invalid plan on $day: $(problems(plan, TRUCK, stations, bikes))")
            nights[(policy, day)] = (expected = expected_saved(plan, curves, bikes), gap = gap, seconds = seconds)
            return plan
        end
    end

    days = collect(REPLAY)
    results = Dict{String,Vector{DayResult}}()
    for policy in ("none", "greedy", "optimal")
        seconds = @elapsed results[policy] =
            simulate!(even_start(stations, FLEET), stations, trips, days, TRUCK, planner(policy))
        total = sum(result.trips for result in results[policy])
        failed = sum(let_down(result) for result in results[policy])
        @printf("%-8s %6d of %d riders let down (%.1f%%), %.0f s\n", policy, failed, total, 100 * failed / total, seconds)
    end

    out = joinpath(ROOT, "results", "first_model")
    mkpath(out)
    open(joinpath(out, "summary.csv"), "w") do io
        println(io, "day,policy,trips,no_bike,no_dock,stops,bikes_moved,km,minutes,expected_saved,gap,solve_seconds")
        for policy in ("none", "greedy", "optimal"), result in results[policy]
            night = nights[(policy, result.day)]
            @printf(io, "%s,%s,%d,%d,%d,%d,%d,%.1f,%.1f,%.1f,%.4f,%.1f\n", result.day, policy, result.trips,
                    result.no_bike, result.no_dock, length(result.plan.stops), bikes_moved(result.plan),
                    result.plan.km, result.plan.minutes, night.expected, night.gap, night.seconds)
        end
    end

    encode(snapshots) = join(LETTERS[level + 1] for level in permutedims(snapshots))
    page = Dict(
        "training" => [string(first(TRAINING)), string(last(TRAINING))],
        "days" => string.(days),
        "fleet" => FLEET,
        "truck" => Dict("capacity" => TRUCK.capacity, "shift" => TRUCK.shift, "stopMinutes" => TRUCK.stop_minutes,
                        "bikeMinutes" => TRUCK.bike_minutes, "speed" => TRUCK.speed_kmh, "detour" => TRUCK.detour,
                        "depot" => [TRUCK.depot_lat, TRUCK.depot_lon]),
        "stations" => [[station.name, round(station.lat; digits = 5), round(station.lon; digits = 5), station.capacity]
                       for station in stations],
        "weekdayCurves" => [round.(curve; digits = 2) for curve in weekday_curves],
        "policies" => Dict(policy => [Dict(
            "trips" => result.trips, "noBike" => result.no_bike, "noDock" => result.no_dock,
            "km" => round(result.plan.km; digits = 1), "minutes" => round(result.plan.minutes),
            "expected" => round(nights[(policy, result.day)].expected; digits = 1),
            "stops" => [[stop.station - 1, stop.change, round(stop.done; digits = 1)] for stop in result.stops],
            "levels" => encode(result.snapshots)) for result in results[policy]]
            for policy in ("none", "greedy", "optimal")),
    )
    target = joinpath(ROOT, "report", "first-model")
    mkpath(target)
    open(joinpath(target, "data.js"), "w") do io
        print(io, "window.FIRST_MODEL = ")
        JSON.print(io, page)
        println(io, ";")
    end
    println("wrote ", joinpath(out, "summary.csv"), " and ", joinpath(target, "data.js"))
end

main()
