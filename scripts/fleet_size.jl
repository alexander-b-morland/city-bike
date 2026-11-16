# Second model: how many trucks? Several trucks per night on real streets, replayed over
# four weeks for one fleet size at a time.
#
#   julia --project=. scripts/fleet_size.jl run optimal 3    # 3 optimized trucks
#   julia --project=. scripts/fleet_size.jl run greedy 3     # 3 rule-of-thumb trucks
#   julia --project=. scripts/fleet_size.jl run none 0       # no trucks
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
    case = load_case(ROOT, TRAINING, REPLAY)
    stations = case.stations
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), stations, TRUCK)
    environment = Gurobi.Env()
    optimizer() = Gurobi.Optimizer(environment)
    nights = Dict{Date,Solution}()
    function planner(day, bikes)
        trucks == 0 && return Plan[]
        night = policy == "greedy" ?
                plan_night(TRUCK, stations, roads.travel, bikes, curves_for(case, day); trucks, method = :greedy) :
                plan_night(TRUCK, stations, roads.travel, bikes, curves_for(case, day); trucks, optimizer, SOLVER...)
        isempty(problems(night.plans, TRUCK, stations, bikes)) || error("invalid plan on $day")
        nights[day] = night
        return night.plans
    end
    seconds = @elapsed results = simulate!(even_start(stations, FLEET), stations, case.trips, collect(REPLAY), TRUCK, planner)
    total, failed = sum(result.trips for result in results), sum(let_down(result) for result in results)
    @printf("%s with %d trucks: %d of %d riders let down (%.1f%%), %.0f s\n", policy, trucks, failed, total, 100 * failed / total, seconds)

    night_of(day) = get(nights, day, Solution())
    mkpath(OUT)
    open(joinpath(OUT, "$(policy)_$(trucks).json"), "w") do io
        JSON.print(io, Dict(
            "policy" => policy, "trucks" => trucks,
            "days" => [Dict(
                "day" => string(result.day), "trips" => result.trips, "noBike" => result.no_bike, "noDock" => result.no_dock,
                "expected" => round(night_of(result.day).expected_saved; digits = 1),
                "gap" => round(night_of(result.day).gap; digits = 4), "seconds" => round(night_of(result.day).seconds; digits = 1),
                "trucks" => [Dict("km" => round(plan.km; digits = 2), "minutes" => round(plan.minutes; digits = 1),
                                  "stops" => [[stop.station - 1, stop.change, round(stop.done; digits = 1)] for stop in stops])
                             for (plan, stops) in zip(result.plans, result.stops)],
                "levels" => encode_levels(result.snapshots)) for result in results]))
    end
end

"A street route as whole numbers: the first point in 1e-5 degrees, then the step to each next point."
function encode_route(points)
    points = thin_line(points, 6.0)
    xs = [round(Int, lon * 1e5) for (_, lon) in points]
    ys = [round(Int, lat * 1e5) for (lat, _) in points]
    numbers = [xs[1], ys[1]]
    for k in 2:length(points)
        push!(numbers, xs[k] - xs[k - 1], ys[k] - ys[k - 1])
    end
    return numbers
end

function page()
    stations = load_stations(joinpath(ROOT, "data", "raw", "oslo", "gbfs", "station_information.json"))
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), stations, TRUCK)
    home = length(stations) + 1
    runs = [JSON.parsefile(joinpath(OUT, file)) for file in readdir(OUT) if endswith(file, ".json")]
    sort!(runs; by = run -> (run["policy"], run["trucks"]))

    # The street route of every leg that a truck on the map drives, stored once.
    legs = Dict{String,Vector{Int}}()
    summary = []
    for run in runs
        mapped = run["policy"] != "greedy"      # the page maps the optimized trucks only
        for day in run["days"]
            mapped || delete!(day, "levels")
            for truck in day["trucks"]
                mapped || (truck["stops"] = length(truck["stops"]); continue)
                previous = home
                for stop in vcat(truck["stops"], [[home - 1, 0, 0]])
                    place = stop[1] + 1
                    previous == place || get!(() -> encode_route(route(roads, previous, place)), legs, "$(previous - 1)>$(place - 1)")
                    previous = place
                end
            end
        end
        push!(summary, run)
    end

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
    @printf("%d runs, %d street legs, %.1f MB in %s\n", length(runs), length(legs), filesize(file) / 1e6, file)
end

if length(ARGS) == 3 && ARGS[1] == "run"
    replay(ARGS[2], parse(Int, ARGS[3]))
elseif ARGS == ["page"]
    page()
else
    error("usage: fleet_size.jl run <optimal|greedy|none> <trucks>   or   fleet_size.jl page")
end
