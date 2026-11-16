# Replaying real trips against a set of station inventories, with trucks at work.

"What happened on one simulated service day."
struct DayResult
    day::Date
    trips::Int                    # riders who wanted a bike
    no_bike::Int                  # of those, found the station empty and gave up
    no_dock::Int                  # riders who found their destination full and rode on
    plans::Vector{Plan}           # what each truck was asked to do
    starts::Vector{Float64}       # when each truck's shift began, in minutes after 01:00
    stops::Vector{Vector{Stop}}   # what each truck actually did, timed in minutes after 01:00
    snapshots::Matrix{Int}        # bikes per station (columns) at regular times (rows)
end

let_down(result::DayResult) = result.no_bike + result.no_dock

# Event kinds, in the order they are handled when they share a timestamp.
const SNAPSHOT, SHIFT, TRUCK, RETURN, PICKUP = 1, 2, 3, 4, 5

"""
Replay `trips` over the service `days`, starting from the inventories `bikes`.

A shift starts at each of `shifts`, given in minutes after 01:00. At that moment
`planner(day, bikes, shift)` is asked for one `Plan` per truck, where `shift` is the
shift's number, and the trucks then carry the plans out stop by stop. A rider who finds
no bike gives up. A rider who finds no free dock rides on to the nearest station with
room. Returns one `DayResult` per day; `bikes` is updated in place.
"""
function simulate!(bikes::Vector{Int}, stations::Vector{Station}, trips::Vector{Trip},
                   days::Vector{Date}, truck::Truck, planner;
                   shifts::Vector{<:Real} = [0.0], snapshot_every::Period = Minute(30), bike_kmh::Real = 12.0)
    n = length(stations)
    nearest = [sortperm([haversine(a, b) for b in stations]) for a in stations]
    by_day = Dict(day => Trip[] for day in days)
    for trip in trips
        day = service_day(trip.start)
        haskey(by_day, day) && push!(by_day[day], trip)
    end

    # Events are (time, kind, sequence, station, a, b). For a pickup, `a` is the trip's
    # number. For a return, `b` is 1 once the rider has been counted as let down. For a
    # truck stop, `a` is the planned change and `b` the truck; station 0 ends its shift.
    # For a shift start, `a` is the shift's number. Bikes still on the road at 01:00 stay
    # in the queue and arrive during the next day.
    queue = BinaryMinHeap{Tuple{DateTime,Int,Int,Int,Int,Int}}()
    sequence = 0
    add!(time, kind, station, a = 0, b = 0) = push!(queue, (time, kind, sequence += 1, station, a, b))
    later(time, minutes) = time + Millisecond(round(Int, 60_000 * minutes))

    results = DayResult[]
    for day in days
        opening = DateTime(day) + DAY_START
        closing = opening + Day(1)
        minutes_in(time) = (time - opening) / Millisecond(60_000)
        for (number, start) in enumerate(shifts)
            add!(later(opening, start), SHIFT, 0, number)
        end
        today = by_day[day]
        for (index, trip) in enumerate(today)
            add!(trip.start, PICKUP, trip.from, index)
        end
        ticks = collect(opening:snapshot_every:closing - snapshot_every)
        foreach(tick -> add!(tick, SNAPSHOT, 0), ticks)

        snapshots = zeros(Int, length(ticks), n)
        row = no_bike = no_dock = 0
        plans, starts, done = Plan[], Float64[], Vector{Stop}[]
        load, last_stop = Int[], Int[]

        while !isempty(queue) && first(queue)[1] < closing
            time, kind, _, station, a, b = pop!(queue)
            if kind == SNAPSHOT
                snapshots[row += 1, :] = bikes
            elseif kind == SHIFT
                for plan in planner(day, copy(bikes), a)
                    push!(plans, plan); push!(starts, minutes_in(time)); push!(done, Stop[])
                    push!(load, 0); push!(last_stop, 0)
                    for stop in plan.stops
                        add!(later(time, stop.done), TRUCK, stop.station, stop.change, length(plans))
                    end
                    add!(later(time, plan.minutes), TRUCK, 0, 0, length(plans))
                end
            elseif kind == PICKUP
                if bikes[station] == 0
                    no_bike += 1
                else
                    bikes[station] -= 1
                    add!(today[a].stop, RETURN, today[a].to)
                end
            elseif kind == RETURN
                if bikes[station] < stations[station].capacity
                    bikes[station] += 1
                else
                    b == 0 && (no_dock += 1)
                    other = nearest[station][findfirst(j -> bikes[j] < stations[j].capacity, nearest[station])]
                    extra = 3_600_000 * haversine(stations[station], stations[other]) / bike_kmh
                    add!(time + Millisecond(round(Int, extra)), RETURN, other, 0, 1)
                end
            elseif station > 0
                # The truck does what the plan says, as far as the station and its load allow.
                change = a > 0 ? min(a, load[b], stations[station].capacity - bikes[station]) :
                         -min(-a, bikes[station], truck.capacity - load[b])
                bikes[station] += change
                load[b] -= change
                last_stop[b] = station
                push!(done[b], Stop(station, change, minutes_in(time)))
            elseif load[b] > 0
                # End of shift: any bikes still on board go to the nearest stations with room.
                for other in nearest[last_stop[b]]
                    load[b] == 0 && break
                    put = min(load[b], stations[other].capacity - bikes[other])
                    put > 0 || continue
                    bikes[other] += put
                    load[b] -= put
                    push!(done[b], Stop(other, put, minutes_in(time)))
                end
            end
        end
        push!(results, DayResult(day, length(today), no_bike, no_dock, plans, starts, done, snapshots))
    end
    return results
end
