# Replaying real trips against a set of station inventories, with a truck at night.

"What happened on one simulated service day."
struct DayResult
    day::Date
    trips::Int              # riders who wanted a bike
    no_bike::Int            # of those, found the station empty and gave up
    no_dock::Int            # riders who found their destination full and rode on
    plan::Plan              # what the truck was asked to do
    stops::Vector{Stop}     # what it actually did
    snapshots::Matrix{Int}  # bikes per station (columns) at regular times (rows)
end

let_down(result::DayResult) = result.no_bike + result.no_dock

# Event kinds, in the order they are handled when they share a timestamp.
const SNAPSHOT, TRUCK, RETURN, PICKUP = 1, 2, 3, 4

"""
Replay `trips` over the service `days`, starting from the inventories `bikes`.

At 01:00 each night `planner(day, bikes)` is asked for a `Plan`, and the truck then
carries it out stop by stop during the night. A rider who finds no bike gives up. A rider
who finds no free dock rides on to the nearest station with room. Returns one `DayResult`
per day; `bikes` is updated in place.
"""
function simulate!(bikes::Vector{Int}, stations::Vector{Station}, trips::Vector{Trip},
                   days::Vector{Date}, truck::Truck, planner;
                   snapshot_every::Period = Minute(30), bike_kmh::Real = 12.0)
    n = length(stations)
    nearest = [sortperm([haversine(a, b) for b in stations]) for a in stations]
    by_day = Dict(day => Trip[] for day in days)
    for trip in trips
        day = service_day(trip.start)
        haskey(by_day, day) && push!(by_day[day], trip)
    end

    # Events are (time, kind, sequence, station, amount, counted). `amount` is the trip's
    # number for a pickup and the planned change for a truck stop. Bikes still on the road
    # at 01:00 stay in the queue and arrive during the next day.
    queue = BinaryMinHeap{Tuple{DateTime,Int,Int,Int,Int,Bool}}()
    sequence = 0
    add!(time, kind, station, amount = 0, counted = false) =
        push!(queue, (time, kind, sequence += 1, station, amount, counted))

    results = DayResult[]
    for day in days
        opening = DateTime(day) + DAY_START
        closing = opening + Day(1)
        plan = planner(day, copy(bikes))
        for stop in plan.stops
            add!(opening + Millisecond(round(Int, 60_000 * stop.done)), TRUCK, stop.station, stop.change)
        end
        isempty(plan.stops) || add!(opening + Millisecond(round(Int, 60_000 * plan.minutes)), TRUCK, 0)
        today = by_day[day]
        for (index, trip) in enumerate(today)
            add!(trip.start, PICKUP, trip.from, index)
        end
        ticks = collect(opening:snapshot_every:closing - snapshot_every)
        foreach(tick -> add!(tick, SNAPSHOT, 0), ticks)

        snapshots = zeros(Int, length(ticks), n)
        row, load, last_stop = 0, 0, 0
        no_bike = no_dock = 0
        done = Stop[]

        while !isempty(queue) && first(queue)[1] < closing
            time, kind, _, station, amount, counted = pop!(queue)
            if kind == SNAPSHOT
                snapshots[row += 1, :] = bikes
            elseif kind == PICKUP
                if bikes[station] == 0
                    no_bike += 1
                else
                    bikes[station] -= 1
                    trip = today[amount]
                    add!(trip.stop, RETURN, trip.to)
                end
            elseif kind == RETURN
                if bikes[station] < stations[station].capacity
                    bikes[station] += 1
                else
                    counted || (no_dock += 1)
                    other = nearest[station][findfirst(j -> bikes[j] < stations[j].capacity, nearest[station])]
                    extra = 3_600_000 * haversine(stations[station], stations[other]) / bike_kmh
                    add!(time + Millisecond(round(Int, extra)), RETURN, other, 0, true)
                end
            elseif station > 0
                # The truck does what the plan says, as far as the station and its load allow.
                change = amount > 0 ? min(amount, load, stations[station].capacity - bikes[station]) :
                         -min(-amount, bikes[station], truck.capacity - load)
                bikes[station] += change
                load -= change
                last_stop = station
                push!(done, Stop(station, change, (time - opening) / Millisecond(60_000)))
            else
                # End of shift: any bikes still on board go to the nearest stations with room.
                for other in nearest[last_stop]
                    load == 0 && break
                    put = min(load, stations[other].capacity - bikes[other])
                    put > 0 || continue
                    bikes[other] += put
                    load -= put
                    push!(done, Stop(other, put, (time - opening) / Millisecond(60_000)))
                end
            end
        end
        push!(results, DayResult(day, length(today), no_bike, no_dock, plan, done, snapshots))
    end
    return results
end
