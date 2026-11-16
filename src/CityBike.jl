"""
Overnight rebalancing of city bikes: data loading, demand curves, a day simulator, a
rule-of-thumb benchmark and an optimization model for one night and one truck.
"""
module CityBike

using CSV
using DataStructures: BinaryMinHeap
using Dates
using JSON
using JuMP

export Station, Trip, Truck, Stop, Plan, Solution, DayResult
export load_stations, load_trips, service_day, is_weekday, haversine, oslo_time, parse_utc
export failures, failure_curves, is_convex, convex_envelope
export timed_plan, problems, bikes_moved, greedy_plan, optimal_plan, simulate!, let_down

include("data.jl")
include("demand.jl")
include("plan.jl")
include("greedy.jl")
include("model.jl")
include("simulate.jl")

end
