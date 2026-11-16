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

    out = joinpath(ROOT, "results", "day_shift")
    mkpath(out)
    open(joinpath(out, "night$(night_trucks)_day$(day_trucks)_$(mode).json"), "w") do io
        JSON.print(io, Dict("night" => night_trucks, "day" => day_trucks, "mode" => mode, "midday" => MIDDAY,
                            "days" => day_records(results, nights)))
    end
end

if length(ARGS) == 4 && ARGS[1] == "run"
    replay(parse(Int, ARGS[2]), parse(Int, ARGS[3]), ARGS[4])
else
    error("usage: day_shift.jl run <night trucks> <midday trucks> <full|split>")
end
