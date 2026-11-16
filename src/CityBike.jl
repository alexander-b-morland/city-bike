"""
Overnight rebalancing of city bikes: data loading, demand curves, real driving times, a
day simulator, a rule-of-thumb benchmark and an optimization model for the night trucks.
"""
module CityBike

using CSV
using DataStructures: BinaryMinHeap
using Dates
using JSON
using JuMP

export Station, Trip, Truck, Travel, Roads, Stop, Plan, Solution, DayResult, Case
export load_stations, load_trips, service_day, is_weekday, haversine, oslo_time, parse_utc
export failures, failure_curves, is_convex, convex_envelope
export straight_line_travel, load_roads, route, thin_line, depot
export timed_plan, after, problems, bikes_moved, expected_saved
export greedy_plan, optimal_plan, plan_night, simulate!, let_down
export load_case, curves_for, even_start, encode_levels

include("data.jl")
include("demand.jl")
include("plan.jl")
include("roads.jl")
include("greedy.jl")
include("model.jl")
include("simulate.jl")
include("experiment.jl")

end
