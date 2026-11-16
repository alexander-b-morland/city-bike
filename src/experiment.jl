# Shared set-up for the replay experiments in scripts/.

"The stations, the trips, and the demand curves learned from the training period."
struct Case
    stations::Vector{Station}
    trips::Vector{Trip}
    weekday_curves::Vector{Vector{Float64}}
    weekend_curves::Vector{Vector{Float64}}
end

"""
Load the Oslo data under `root` and learn the demand curves from the `training` days.
The trips cover both the training days and the `replay` days that follow them.
"""
function load_case(root::AbstractString, training, replay)
    stations = load_stations(joinpath(root, "data", "raw", "oslo", "gbfs", "station_information.json"))
    trips = load_trips(joinpath(root, "data", "raw", "oslo", "trips"), stations, first(training), last(replay))
    weekday = failure_curves(trips, stations, filter(is_weekday, collect(training)))
    weekend = failure_curves(trips, stations, filter(!is_weekday, collect(training)))
    all(is_convex, weekday) && all(is_convex, weekend) || error("a demand curve is not convex")
    return Case(stations, trips, weekday, weekend)
end

"The curves that describe `day`: weekday or weekend."
curves_for(case::Case, day::Date) = is_weekday(day) ? case.weekday_curves : case.weekend_curves

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
