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
`days`. `events[station][k]` holds the events of `days[k]`. Only events from `from` to
`until` minutes after the service day starts are kept.
"""
function station_events(trips::Vector{Trip}, n_stations::Integer, days::Vector{Date};
                        from::Real = 0, until::Real = 1440)
    slot = Dict(day => index for (index, day) in enumerate(days))
    timed = [[Tuple{DateTime,Int8}[] for _ in days] for _ in 1:n_stations]
    function record!(station, time, change)
        day = service_day(time)
        k = get(slot, day, 0)
        k > 0 || return
        minute = (time - (DateTime(day) + DAY_START)) / Millisecond(60_000)
        from <= minute < until && push!(timed[station][k], (time, Int8(change)))
    end
    for trip in trips
        record!(trip.from, trip.start, -1)
        record!(trip.to, trip.stop, 1)
    end
    return [[Int8[change for (_, change) in sort!(day)] for day in station] for station in timed]
end

"""
For every station, the average number of riders let down per day for each possible
starting level. `curves[station][b + 1]` is the average when the station holds `b` bikes
`from` minutes into the service day and nobody rebalances it before `until`, taken over
the given `days` of history.
"""
function failure_curves(trips::Vector{Trip}, stations::Vector{Station}, days::Vector{Date};
                        from::Real = 0, until::Real = 1440)
    events = station_events(trips, length(stations), days; from, until)
    return [[sum(failures(day, start, station.capacity) for day in events[index]; init = 0) /
             length(days) for start in 0:station.capacity]
            for (index, station) in enumerate(stations)]
end

"True if every step of the curve is at least as steep as the one before it."
is_convex(curve; tolerance = 1e-9) =
    all(curve[k + 1] - curve[k] >= curve[k] - curve[k - 1] - tolerance for k in 2:length(curve) - 1)
