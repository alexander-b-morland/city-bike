# The rebalancing truck and the plan it follows during one night.

"The vehicle and its working conditions. Times are in minutes."
Base.@kwdef struct Truck
    capacity::Int = 20            # bikes on board at most
    shift::Float64 = 300.0        # 01:00 to 06:00
    stop_minutes::Float64 = 3.0   # parking and walking at each station
    bike_minutes::Float64 = 0.5   # loading or unloading one bike
    speed_kmh::Float64 = 25.0
    detour::Float64 = 1.4         # road distance per straight-line distance
    depot_lat::Float64 = 59.9309  # assumed depot at Økern
    depot_lon::Float64 = 10.8019
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

road_km(truck::Truck, a::Station, b::Station) = truck.detour * haversine(a, b)
road_km(truck::Truck, a::Station) = truck.detour * haversine(a.lat, a.lon, truck.depot_lat, truck.depot_lon)
drive_minutes(truck::Truck, km) = 60 * km / truck.speed_kmh
visit_minutes(truck::Truck, bikes) = truck.stop_minutes + truck.bike_minutes * abs(bikes)

"Turn an ordered list of `station => change` visits into a plan with times and distance."
function timed_plan(truck::Truck, stations::Vector{Station}, visits::Vector{Pair{Int,Int}})
    isempty(visits) && return Plan()
    stops, minutes, km = Stop[], 0.0, 0.0
    previous = 0
    for (station, change) in visits
        leg = previous == 0 ? road_km(truck, stations[station]) :
              road_km(truck, stations[previous], stations[station])
        km += leg
        minutes += drive_minutes(truck, leg) + visit_minutes(truck, change)
        push!(stops, Stop(station, change, minutes))
        previous = station
    end
    leg = road_km(truck, stations[previous])
    return Plan(stops, minutes + drive_minutes(truck, leg), km + leg)
end

"""
Check that the truck can carry out `plan` starting from the inventories `bikes`: it
never carries a negative load or more than its capacity, ends empty, keeps every station
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
