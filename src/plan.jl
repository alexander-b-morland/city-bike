# The rebalancing truck and the plan it follows during one night.

"""
Driving minutes and kilometres between places. Places are the stations in order,
followed by the depot as the last index.
"""
struct Travel
    minutes::Matrix{Float64}
    km::Matrix{Float64}
end

depot(travel::Travel) = size(travel.minutes, 1)

"The vehicle and its working conditions. Times are in minutes."
Base.@kwdef struct Truck
    capacity::Int = 20            # bikes on board at most
    shift::Float64 = 300.0        # 01:00 to 06:00
    stop_minutes::Float64 = 3.0   # parking and walking at each station
    bike_minutes::Float64 = 0.5   # loading or unloading one bike
    depot_lat::Float64 = 59.9059  # the operator's base, Kværnerveien 5
    depot_lon::Float64 = 10.7787
    speed_kmh::Float64 = 25.0     # only used for straight-line travel
    detour::Float64 = 1.4         # road distance per straight-line distance, likewise
end

"One visit. `change` is the number of bikes added to the station (negative: taken away)."
struct Stop
    station::Int
    change::Int
    done::Float64   # minutes after the shift starts when the truck leaves the station
end

struct Plan
    stops::Vector{Stop}
    minutes::Float64   # whole shift, back at the depot
    km::Float64
end

Plan() = Plan(Stop[], 0.0, 0.0)
bikes_moved(plan::Plan) = sum(max(stop.change, 0) for stop in plan.stops; init = 0)
visit_minutes(truck::Truck, bikes) = truck.stop_minutes + truck.bike_minutes * abs(bikes)

"Turn an ordered list of `station => change` visits into a plan with times and distance."
function timed_plan(truck::Truck, travel::Travel, visits::Vector{Pair{Int,Int}})
    isempty(visits) && return Plan()
    stops, minutes, km = Stop[], 0.0, 0.0
    previous = depot(travel)
    for (station, change) in visits
        km += travel.km[previous, station]
        minutes += travel.minutes[previous, station] + visit_minutes(truck, change)
        push!(stops, Stop(station, change, minutes))
        previous = station
    end
    return Plan(stops, minutes + travel.minutes[previous, depot(travel)], km + travel.km[previous, depot(travel)])
end

"The inventories after the plan has been carried out."
function after(bikes::Vector{Int}, plan::Plan)
    result = copy(bikes)
    for stop in plan.stops
        result[stop.station] += stop.change
    end
    return result
end

"""
Check that a truck can carry out `plan` starting from the inventories `bikes`: it never
carries a negative load or more than its capacity, ends empty, keeps every station
within its docks, visits no station twice and finishes within the shift. Returns a list
of problems, empty if the plan is valid.
"""
function problems(plan::Plan, truck::Truck, stations::Vector{Station}, bikes::Vector{Int})
    found, load = String[], 0
    allunique(stop.station for stop in plan.stops) || push!(found, "a station is visited twice")
    for stop in plan.stops
        load -= stop.change
        0 <= load <= truck.capacity || push!(found, "load $load at station $(stop.station)")
        level = bikes[stop.station] + stop.change
        0 <= level <= stations[stop.station].capacity ||
            push!(found, "station $(stop.station) would hold $level bikes")
    end
    load == 0 || push!(found, "truck ends with $load bikes on board")
    plan.minutes <= truck.shift + 1e-6 || push!(found, "shift takes $(round(plan.minutes; digits = 1)) minutes")
    return found
end

"Check several trucks' plans, each starting from what the trucks before it leave behind."
function problems(plans::Vector{Plan}, truck::Truck, stations::Vector{Station}, bikes::Vector{Int})
    found = String[]
    for plan in plans
        append!(found, problems(plan, truck, stations, bikes))
        bikes = after(bikes, plan)
    end
    return found
end
