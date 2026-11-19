# Fourth model: when should the trucks work? Up to five trucks are on the road at once,
# and a five-hour shift can start at 01, 04, 07, 10, 13, 16 or 19 o'clock. Pay depends on
# the hours worked and driving times on the traffic. The search adds one shift at a time,
# where it lowers the total cost a day most, and stops when no shift lowers it.
#
#   julia -t 8 --project=. scripts/shift_times.jl search              # choose the shifts
#   julia -t 4 --project=. scripts/shift_times.jl run optimal 2-0-0-1-0-0-0
#   julia -t 4 --project=. scripts/shift_times.jl run greedy 2-0-0-1-0-0-0
#   julia --project=. scripts/shift_times.jl table
#
# A schedule is written as the number of trucks starting at each of the seven times, so
# 2-0-0-1-0-0-0 is two trucks from 01:00 and one from 10:00. `run` replays a schedule on
# the four test weeks, with optimized plans or with the rule of thumb.
#
# The search must not see the test weeks, so it learns its curves from 1 June to 2 August
# and compares schedules on the two weeks from 3 to 16 August. Only the chosen schedule is
# then replayed on the test weeks, with curves learned from 1 June to 16 August as in the
# other experiments.
#
# Every plan looks two days ahead (see scripts/look_ahead.jl): from the start of its shift
# to the end of the next service day. A shift that starts while earlier trucks are still
# out plans as if their remaining stops will be made.
#
# Writes results/shift_times/<validation|test>/<optimal|greedy>_<schedule>.json and
# results/shift_times/search.json.

using CityBike
using Dates
using Gurobi
using JSON
using Printf

const ROOT = joinpath(@__DIR__, "..")
const OUT = joinpath(ROOT, "results", "shift_times")
const PERIODS = Dict(
    "validation" => (Date(2026, 6, 1):Day(1):Date(2026, 8, 2), Date(2026, 8, 3):Day(1):Date(2026, 8, 16)),
    "test" => (Date(2026, 6, 1):Day(1):Date(2026, 8, 16), Date(2026, 8, 17):Day(1):Date(2026, 9, 13)))
const FLEET = 3000
const TRUCK = Truck()
const SOLVER = (per_side = 15, time_limit = 10.0, gap = 0.0, km_penalty = 0.05)
const HORIZON = 2

# Shift starts in minutes after 01:00, that is 01, 04, 07, 10, 13, 16 and 19 o'clock.
const STARTS = [0, 180, 360, 540, 720, 900, 1080]
const AT_ONCE = 5                       # trucks that can be on the road at the same time

# Driving time relative to the night, by hour of the day (Oslo time). Our assumption:
# rush hours 07-09 and 15-17, ordinary daytime traffic otherwise, quiet from 21 to 06.
function traffic_at(hour)
    hour in (7, 8, 15, 16) && return 1.6
    (hour in 9:14 || hour in (17, 18)) && return 1.3
    hour in (6, 19, 20) && return 1.15
    return 1.0
end
on_road(start) = [mod(1 + start ÷ 60 + k, 24) for k in 0:4]     # the five hours of a shift
traffic(start) = sum(traffic_at, on_road(start)) / 5
night_share(start) = count(hour -> hour >= 21 || hour < 6, on_road(start)) / 5

# Costs, as in scripts/figures.jl: 5.5 paid hours at 250 kr, 40% more for night hours
# (21-06), 30% social costs, 10% overhead; 3 kr per km plus overhead; 25 kr per rider let down.
shift_cost(start) = 5.5 * 250 * (1 + 0.4 * night_share(start)) * 1.30 * 1.10
const PER_KM, RIDER = 3.0 * 1.10, 25.0

schedule_name(counts) = join(counts, "-")
parse_schedule(text) = parse.(Int, split(text, "-"))
clock(start) = @sprintf("%02d:00", 1 + start ÷ 60)
allowed(counts) = all(>=(0), counts) && all(counts[k] + counts[k + 1] <= AT_ONCE for k in 1:length(counts) - 1)

"Replay one schedule. Returns the day results and each shift's solver result."
function replay(case::Case, travel::Travel, counts::Vector{Int}, method::Symbol, days::Vector{Date})
    stations = case.stations
    used = findall(>(0), counts)
    times = [Travel(traffic(STARTS[i]) .* travel.minutes, travel.km) for i in used]
    environment = Gurobi.Env()
    optimizer() = Gurobi.Optimizer(environment)
    nights = Dict{Tuple{Date,Int},Solution}()
    made = Tuple{Float64,Plan}[]         # the plans made so far today, with their start
    today = Ref(Date(0))
    function planner(day, bikes, shift)
        day == today[] || (empty!(made); today[] = day)
        index = used[shift]
        start = STARTS[index]
        # Stops that trucks already out will still make.
        for (begun, plan) in made, stop in plan.stops
            begun + stop.done > start || continue
            bikes[stop.station] = clamp(bikes[stop.station] + stop.change, 0, stations[stop.station].capacity)
        end
        curves = curves_for(case, day, index)
        night = method == :greedy ?
                plan_night(TRUCK, stations, times[shift], bikes, curves; trucks = counts[index], method = :greedy) :
                plan_night(TRUCK, stations, times[shift], bikes, curves; trucks = counts[index],
                           optimizer, attributes = Dict{String,Any}("Threads" => 2), SOLVER...)
        isempty(problems(night.plans, TRUCK, stations, bikes)) || error("invalid plan on $day")
        nights[(day, shift)] = night
        append!(made, [(Float64(start), plan) for plan in night.plans])
        return night.plans
    end
    results = simulate!(even_start(stations, FLEET), stations, case.trips, days, TRUCK, planner;
                        shifts = Float64[STARTS[i] for i in used])
    return results, nights
end

"Riders let down, kilometres driven and total cost, all per day."
function summary(counts, results)
    days = length(results)
    down = sum(let_down(result) for result in results) / days
    km = sum((plan.km for result in results for plan in result.plans); init = 0.0) / days
    trucks = sum(counts[i] * shift_cost(STARTS[i]) for i in eachindex(counts))
    return (; down, km, trucks, cost = down * RIDER + trucks + km * PER_KM,
            share = 100 * sum(let_down(result) for result in results) / sum(result.trips for result in results))
end

"Replay a schedule and save it, unless it has been saved already. Returns the summary."
function evaluate(period, case, travel, counts, method)
    target = joinpath(OUT, period, "$(method)_$(schedule_name(counts)).json")
    if isfile(target)
        run = JSON.parsefile(target)
        return (; down = run["down"], km = run["km"], trucks = run["trucks"], cost = run["cost"], share = run["share"])
    end
    results, nights = replay(case, travel, counts, Symbol(method), collect(last(PERIODS[period])))
    result = summary(counts, results)
    mkpath(dirname(target))
    open(target, "w") do io
        JSON.print(io, Dict("period" => period, "method" => method, "counts" => counts, "starts" => STARTS,
                            "down" => result.down, "km" => result.km, "trucks" => result.trucks, "cost" => result.cost,
                            "share" => result.share, "days" => day_records(results, nights)))
    end
    @printf("%-10s %-7s %s: %.1f%% let down, %.0f kr a day\n", period, method, schedule_name(counts), result.share, result.cost)
    flush(stdout)
    return result
end

load(period) = load_case(ROOT, first(PERIODS[period]), last(PERIODS[period]);
                         windows = [(start, 1440) for start in STARTS], horizon = HORIZON)

function search()
    for start in STARTS
        @printf("%s  driving x%.2f  night share %.1f  shift %.0f kr
", clock(start), traffic(start), night_share(start), shift_cost(start))
    end
    case = load("validation")
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), case.stations, TRUCK)
    counts = zeros(Int, length(STARTS))
    best = evaluate("validation", case, roads.travel, counts, "optimal")
    steps = Any[Dict("counts" => copy(counts), "cost" => best.cost, "share" => best.share, "options" => [])]
    while true
        options = [counts .+ (1:length(STARTS) .== k) for k in eachindex(STARTS)]
        filter!(allowed, options)
        isempty(options) && break
        tasks = [Threads.@spawn evaluate("validation", case, roads.travel, option, "optimal") for option in options]
        tried = fetch.(tasks)
        pick = argmin(result -> result.cost, tried)
        push!(steps, Dict("counts" => options[findfirst(==(pick), tried)], "cost" => pick.cost, "share" => pick.share,
                          "options" => [Dict("counts" => option, "cost" => result.cost, "share" => result.share)
                                        for (option, result) in zip(options, tried)]))
        pick.cost < best.cost || break
        counts, best = options[findfirst(==(pick), tried)], pick
        println("chosen ", schedule_name(counts), @sprintf(": %.1f%% let down, %.0f kr a day", best.share, best.cost))
        flush(stdout)
    end
    open(joinpath(OUT, "search.json"), "w") do io
        JSON.print(io, Dict("starts" => STARTS, "chosen" => counts, "steps" => steps,
                            "traffic" => traffic.(STARTS), "nightShare" => night_share.(STARTS),
                            "shiftCost" => shift_cost.(STARTS)), 2)
    end
    println("best schedule ", schedule_name(counts))
end

function test(method, schedules)
    case = load("test")
    roads = load_roads(joinpath(ROOT, "data", "raw", "osm", "roads.json"), case.stations, TRUCK)
    tasks = [Threads.@spawn evaluate("test", case, roads.travel, parse_schedule(text), method) for text in schedules]
    foreach(fetch, tasks)
end

function table()
    for period in ("validation", "test")
        folder = joinpath(OUT, period)
        isdir(folder) || continue
        runs = [JSON.parsefile(joinpath(folder, file)) for file in readdir(folder) if endswith(file, ".json")]
        sort!(runs; by = run -> run["cost"])
        println(period)
        for run in runs
            @printf("  %-7s %-14s %5.1f%% let down  %6.0f riders a day  %6.0f kr a day\n", run["method"],
                    schedule_name(Int.(run["counts"])), run["share"], run["down"], run["cost"])
        end
    end
end

if length(ARGS) >= 3 && ARGS[1] == "run"
    test(ARGS[2], ARGS[3:end])
elseif ARGS == ["search"]
    search()
elseif ARGS == ["table"]
    table()
else
    error("usage: shift_times.jl search | run <optimal|greedy> <schedule>... | table")
end
