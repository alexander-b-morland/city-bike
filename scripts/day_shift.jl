# Third model: when should the trucks work? Some trucks work at night (01:00 to 06:00)
# and some at midday (10:00 to 15:00), replayed over four weeks.
#
#   julia --project=. scripts/day_shift.jl run 2 2 split   # 2 night trucks, 2 midday trucks
#   julia --project=. scripts/day_shift.jl run 4 0 full    # 4 night trucks, none at midday
#
# The last word says what each shift plans for:
#   full   every shift minimises riders let down over the rest of the service day
#   split  the night shift only looks as far as 10:00, when the midday shift takes over
#
# Writes results/day_shift/night<a>_day<b>_<mode>.json. Midday driving takes 30% longer
# than at night, to allow for traffic.
#
#   julia --project=. scripts/day_shift.jl page             # collect the runs for the page

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
const MIDDAY = 540.0            # 10:00, in minutes after 01:00
const DAY_TRAFFIC = 1.3         # midday driving time relative to night
const SOLVER = (per_side = 15, time_limit = 10.0, gap = 0.02, km_penalty = 0.05,
                attributes = Dict{String,Any}("Threads" => 2))

function replay(night_trucks::Integer, day_trucks::Integer, mode::AbstractString)
    mode in ("full", "split") || error("mode must be full or split")
    target = joinpath(ROOT, "results", "day_shift", "night$(night_trucks)_day$(day_trucks)_$(mode).json")
    isfile(target) && return println("have ", target)
    windows = [(0, mode == "split" && day_trucks > 0 ? MIDDAY : 1440), (MIDDAY, 1440)]
    case = load_case(ROOT, TRAINING, REPLAY; windows)
    stations = case.stations
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), stations, TRUCK)
    travel = [roads.travel, Travel(DAY_TRAFFIC .* roads.travel.minutes, roads.travel.km)]
    trucks = [night_trucks, day_trucks]
    environment = Gurobi.Env()
    optimizer() = Gurobi.Optimizer(environment)
    nights = Dict{Tuple{Date,Int},Solution}()
    function planner(day, bikes, shift)
        trucks[shift] == 0 && return Plan[]
        night = plan_night(TRUCK, stations, travel[shift], bikes, curves_for(case, day, shift);
                           trucks = trucks[shift], optimizer, SOLVER...)
        isempty(problems(night.plans, TRUCK, stations, bikes)) || error("invalid plan on $day")
        nights[(day, shift)] = night
        return night.plans
    end
    seconds = @elapsed results = simulate!(even_start(stations, FLEET), stations, case.trips, collect(REPLAY), TRUCK,
                                           planner; shifts = [0.0, MIDDAY])
    total, failed = sum(result.trips for result in results), sum(let_down(result) for result in results)
    @printf("%d night + %d midday trucks (%s): %d of %d riders let down (%.1f%%), %.0f s\n",
            night_trucks, day_trucks, mode, failed, total, 100 * failed / total, seconds)

    mkpath(dirname(target))
    open(target, "w") do io
        JSON.print(io, Dict("night" => night_trucks, "day" => day_trucks, "mode" => mode, "midday" => MIDDAY,
                            "days" => day_records(results, nights)))
    end
end

"""
Collect the runs for the page in report/day-shift/. Night-only runs come from
scripts/fleet_size.jl. Runs with 4 or 8 trucks in total where every shift plans for the rest
of the day are kept in full for the map; the others keep their totals only.
"""
function page()
    stations = load_stations(joinpath(ROOT, "data", "raw", "oslo", "gbfs", "station_information.json"))
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), stations, TRUCK)
    runs = [JSON.parsefile(joinpath(ROOT, "results", "day_shift", file))
            for file in readdir(joinpath(ROOT, "results", "day_shift")) if endswith(file, ".json")]
    filter!(run -> haskey(run, "days"), runs)
    fleet = joinpath(ROOT, "results", "fleet_size")
    for file in readdir(fleet)
        startswith(file, "optimal_") || file == "none_0.json" || continue
        run = JSON.parsefile(joinpath(fleet, file))
        push!(runs, Dict("night" => run["trucks"], "day" => 0, "mode" => "full", "days" => run["days"]))
    end
    # The shift times chosen by scripts/shift_times.jl, if that search has been made.
    times = joinpath(ROOT, "results", "shift_times")
    shift_times = nothing
    if isfile(joinpath(times, "search.json")) && isdir(joinpath(times, "test"))
        search = JSON.parsefile(joinpath(times, "search.json"))
        tests = [JSON.parsefile(joinpath(times, "test", file)) for file in readdir(joinpath(times, "test")) if endswith(file, ".json")]
        shift_times = Dict("starts" => search["starts"], "chosen" => search["chosen"], "traffic" => search["traffic"],
                           "shiftCost" => search["shiftCost"],
                           "steps" => [Dict("counts" => step["counts"], "cost" => step["cost"], "share" => step["share"]) for step in search["steps"]],
                           "test" => [Dict(key => test[key] for key in ("method", "counts", "share", "down", "km", "trucks", "cost")) for test in tests])
        for test in tests
            test["method"] == "optimal" && test["counts"] == search["chosen"] || continue
            starts = Int.(test["starts"])
            push!(runs, Dict("night" => sum(n for (n, s) in zip(test["counts"], starts) if s < 300; init = 0),
                             "day" => sum(n for (n, s) in zip(test["counts"], starts) if s >= 300; init = 0),
                             "mode" => "chosen", "days" => test["days"]))
        end
    end
    sort!(runs; by = run -> (run["night"] + run["day"], -run["night"], run["mode"]))
    legs = Dict{String,Vector{Int}}()
    for run in runs
        if (run["night"] + run["day"] in (4, 8) && run["mode"] == "full") || run["mode"] == "chosen"
            collect_legs!(legs, roads, run["days"])
        else
            for day in run["days"]
                delete!(day, "levels")
                foreach(truck -> truck["stops"] = length(truck["stops"]), day["trucks"])
            end
        end
    end
    data = Dict(
        "days" => string.(collect(REPLAY)), "midday" => MIDDAY,
        "truck" => Dict("capacity" => TRUCK.capacity, "shift" => TRUCK.shift, "stopMinutes" => TRUCK.stop_minutes,
                        "bikeMinutes" => TRUCK.bike_minutes, "depot" => [TRUCK.depot_lat, TRUCK.depot_lon]),
        "stations" => [[station.name, round(station.lat; digits = 5), round(station.lon; digits = 5), station.capacity]
                       for station in stations],
        "runs" => runs, "shiftTimes" => shift_times, "legs" => legs)
    target = joinpath(ROOT, "report", "day-shift")
    mkpath(target)
    file = joinpath(target, "data.js")
    open(file, "w") do io
        print(io, "window.DAY_SHIFT = ")
        JSON.print(io, data)
        println(io, ";")
    end
    cp(joinpath(ROOT, "report", "map", "oslo.js"), joinpath(target, "map.js"); force = true)
    cp(joinpath(ROOT, "report", "shared", "player.js"), joinpath(target, "player.js"); force = true)
    @printf("%d runs, %d street legs, %.1f MB in %s
", length(runs), length(legs), filesize(file) / 1e6, file)
end

if length(ARGS) == 4 && ARGS[1] == "run"
    replay(parse(Int, ARGS[2]), parse(Int, ARGS[3]), ARGS[4])
elseif ARGS == ["page"]
    page()
else
    error("usage: day_shift.jl run <night trucks> <midday trucks> <full|split>   or   day_shift.jl page")
end
