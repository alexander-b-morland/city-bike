# Shared set-up for the replay experiments in scripts/.

"""
The stations, the trips, and the demand curves learned from the training period. There
is one set of curves per planning window, for weekdays and for weekends.
"""
struct Case
    stations::Vector{Station}
    trips::Vector{Trip}
    weekday_curves::Vector{Vector{Vector{Float64}}}
    weekend_curves::Vector{Vector{Vector{Float64}}}
end

"""
Load the Oslo data under `root` and learn the demand curves from the `training` days.
The trips cover both the training days and the `replay` days that follow them.

`windows` lists the stretches of the service day, as (from, until) minutes after 01:00,
that plans are made for. The default is one plan for the whole day.
"""
function load_case(root::AbstractString, training, replay; windows = [(0, 1440)])
    stations = load_stations(joinpath(root, "data", "raw", "oslo", "gbfs", "station_information.json"))
    trips = load_trips(joinpath(root, "data", "raw", "oslo", "trips"), stations, first(training), last(replay))
    learn(days) = [failure_curves(trips, stations, days; from, until) for (from, until) in windows]
    weekday, weekend = learn(filter(is_weekday, collect(training))), learn(filter(!is_weekday, collect(training)))
    all(is_convex, Iterators.flatten(weekday)) && all(is_convex, Iterators.flatten(weekend)) ||
        error("a demand curve is not convex")
    return Case(stations, trips, weekday, weekend)
end

"The curves that describe `day` (weekday or weekend) for the given planning window."
curves_for(case::Case, day::Date, window::Integer = 1) =
    (is_weekday(day) ? case.weekday_curves : case.weekend_curves)[window]

"Spread `fleet` bikes over the stations in proportion to their docks."
function even_start(stations::Vector{Station}, fleet::Integer)
    share = fleet .* [station.capacity for station in stations] ./ sum(station.capacity for station in stations)
    bikes = floor.(Int, share)
    for index in sortperm(share .- bikes; rev = true)[1:fleet - sum(bikes)]
        bikes[index] += 1
    end
    return bikes
end

const LETTERS = ['0':'9'; 'a':'z'; 'A':'Z']

"Inventory snapshots as text, one character per station and snapshot, for the result pages."
encode_levels(snapshots::Matrix{Int}) = join(LETTERS[level + 1] for level in permutedims(snapshots))

"""
A replay as plain data for JSON: one entry per day with the riders let down, what each
truck did and the inventory snapshots. `nights[(day, shift)]` holds the solver's result
for each shift that was planned.
"""
function day_records(results::Vector{DayResult}, nights::Dict{Tuple{Date,Int},Solution})
    return [Dict(
        "day" => string(result.day), "trips" => result.trips, "noBike" => result.no_bike, "noDock" => result.no_dock,
        "expected" => round(sum(night.expected_saved for ((day, _), night) in nights if day == result.day; init = 0.0); digits = 1),
        "gap" => round(maximum(night.gap for ((day, _), night) in nights if day == result.day; init = 0.0); digits = 4),
        "seconds" => round(sum(night.seconds for ((day, _), night) in nights if day == result.day; init = 0.0); digits = 1),
        "trucks" => [Dict("start" => round(start; digits = 1), "km" => round(plan.km; digits = 2),
                          "minutes" => round(plan.minutes; digits = 1),
                          "stops" => [[stop.station - 1, stop.change, round(stop.done; digits = 1)] for stop in stops])
                     for (plan, start, stops) in zip(result.plans, result.starts, result.stops)],
        "levels" => encode_levels(result.snapshots)) for result in results]
end

"""
Replay `days` with `trucks` trucks working each night, all planned at 01:00.

`policy` is `:optimal`, `:greedy` (the rule of thumb), `:oracle` (optimal, but planning
with the coming day's real trips instead of history, to see what perfect foresight would
be worth) or `:none`. Every run starts with `fleet` bikes spread evenly. `solver` holds
keywords for `optimal_plan`. Returns the day results and each night's solver result.
"""
function night_replay(case::Case, travel::Travel, truck::Truck, days::Vector{Date}; trucks::Integer,
                      policy::Symbol = :optimal, fleet::Integer = 3000, optimizer = nothing, solver = (;))
    stations = case.stations
    nights = Dict{Tuple{Date,Int},Solution}()
    function planner(day, bikes, shift)
        (trucks == 0 || policy == :none) && return Plan[]
        curves = policy == :oracle ? failure_curves(case.trips, stations, [day]) : curves_for(case, day)
        night = policy == :greedy ?
                plan_night(truck, stations, travel, bikes, curves; trucks, method = :greedy) :
                plan_night(truck, stations, travel, bikes, curves; trucks, optimizer, solver...)
        isempty(problems(night.plans, truck, stations, bikes)) || error("invalid plan on $day")
        nights[(day, shift)] = night
        return night.plans
    end
    results = simulate!(even_start(stations, fleet), stations, case.trips, days, truck, planner)
    return results, nights
end

"A street route as whole numbers: the first point in 1e-5 degrees, then the step to each next point."
function encode_route(points::Vector{Tuple{Float64,Float64}})
    points = thin_line(points, 6.0)
    xs = [round(Int, lon * 1e5) for (_, lon) in points]
    ys = [round(Int, lat * 1e5) for (lat, _) in points]
    numbers = [xs[1], ys[1]]
    for k in 2:length(points)
        push!(numbers, xs[k] - xs[k - 1], ys[k] - ys[k - 1])
    end
    return numbers
end

"""
Add to `legs` the street route of every leg driven by the trucks in `days`, which are
day records as written by `day_records`. Legs are keyed "from>to" by station number
counted from zero, with the base as the number after the last station.
"""
function collect_legs!(legs::Dict{String,Vector{Int}}, roads::Roads, days)
    home = length(roads.node)
    for day in days, truck in day["trucks"]
        previous = home
        for stop in vcat(collect(truck["stops"]), [[home - 1, 0, 0]])
            place = Int(stop[1]) + 1
            previous == place || get!(() -> encode_route(route(roads, previous, place)), legs, "$(previous - 1)>$(place - 1)")
            previous = place
        end
    end
    return legs
end
