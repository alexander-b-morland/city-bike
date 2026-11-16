# What history says about each station: how many riders are let down over a day, as a
# function of how many bikes the station holds when the day starts.

"""
Riders let down at one station over one day if it starts with `start` bikes and nobody
rebalances it. `changes` lists the day's events in time order: -1 for a rider who wants
a bike, +1 for a rider who wants to park one. A rider is let down when the station is
empty at pickup or full at return.
"""
function failures(changes::AbstractVector{<:Integer}, start::Integer, capacity::Integer)
    bikes, failed = start, 0
    for change in changes
        if change < 0
            bikes == 0 ? (failed += 1) : (bikes -= 1)
        else
            bikes == capacity ? (failed += 1) : (bikes += 1)
        end
    end
    return failed
end

"""
The time-ordered pickup and return events at every station on every service day in
`days`. `events[station][k]` holds the events of `days[k]`.
"""
function station_events(trips::Vector{Trip}, n_stations::Integer, days::Vector{Date})
    slot = Dict(day => index for (index, day) in enumerate(days))
    timed = [[Tuple{DateTime,Int8}[] for _ in days] for _ in 1:n_stations]
    for trip in trips
        k = get(slot, service_day(trip.start), 0)
        k > 0 && push!(timed[trip.from][k], (trip.start, Int8(-1)))
        k = get(slot, service_day(trip.stop), 0)
        k > 0 && push!(timed[trip.to][k], (trip.stop, Int8(1)))
    end
    return [[Int8[change for (_, change) in sort!(day)] for day in station] for station in timed]
end

"""
For every station, the average number of riders let down per day for each possible
starting level. `curves[station][b + 1]` is the average when the day starts with `b`
bikes, taken over the given `days` of history.
"""
function failure_curves(trips::Vector{Trip}, stations::Vector{Station}, days::Vector{Date})
    events = station_events(trips, length(stations), days)
    return [[sum(failures(day, start, station.capacity) for day in events[index]; init = 0) /
             length(days) for start in 0:station.capacity]
            for (index, station) in enumerate(stations)]
end

"True if every step of the curve is at least as steep as the one before it."
is_convex(curve; tolerance = 1e-9) =
    all(curve[k + 1] - curve[k] >= curve[k] - curve[k - 1] - tolerance for k in 2:length(curve) - 1)
