# The optimization model for one night and one truck.

"Result of one night's optimization: the plan, and how well the solver did."
struct Solution
    plan::Plan
    expected_saved::Float64   # riders let down tomorrow, without the truck minus with it
    gap::Float64              # relative gap between the plan and the solver's bound
    seconds::Float64
end

"Largest reduction of a station's curve from moving up to `reach` bikes in one direction."
function best_gain(curve, bikes, reach, direction)
    levels = direction > 0 ? (bikes:min(length(curve) - 1, bikes + reach)) :
             (max(0, bikes - reach):bikes)
    return curve[bikes + 1] - minimum(curve[level + 1] for level in levels)
end

"""
The stations worth considering tonight: those where adding bikes helps most (receivers)
and those where removing bikes helps most (donors), `count` of each at most.
"""
function candidates(truck::Truck, curves, bikes::Vector{Int}, count::Integer)
    add = [best_gain(curves[i], bikes[i], truck.capacity, +1) for i in eachindex(bikes)]
    remove = [best_gain(curves[i], bikes[i], truck.capacity, -1) for i in eachindex(bikes)]
    receivers = [i for i in sortperm(add; rev = true) if add[i] > 1e-6 && add[i] >= remove[i]]
    donors = [i for i in sortperm(remove; rev = true) if remove[i] > 1e-6 && remove[i] > add[i]]
    return first(donors, count), first(receivers, count)
end

"""
Choose the truck's route and the number of bikes to load or unload at each stop so that
as few riders as possible are let down tomorrow.

`curves[i][b + 1]` is the expected number of riders let down at station `i` if it starts
the day with `b` bikes (see `failure_curves`); the curves must be convex. `bikes` are
tonight's inventories. Only the `per_side` most promising donors and receivers are
considered. `optimizer` is a JuMP optimizer factory.
"""
function optimal_plan(truck::Truck, stations::Vector{Station}, bikes::Vector{Int}, curves;
                      optimizer, per_side::Integer = 20, time_limit::Real = 60.0,
                      gap::Real = 0.01)
    donors, receivers = candidates(truck, curves, bikes, per_side)
    (isempty(donors) || isempty(receivers)) && return Solution(Plan(), 0.0, 0.0, 0.0)
    chosen = vcat(donors, receivers)
    n = length(chosen)
    nodes = 1:n                    # node 0 is the depot
    is_donor = [k <= length(donors) for k in nodes]
    capacity = [stations[i].capacity for i in chosen]
    start = bikes[chosen]
    Q = truck.capacity

    km(a, b) = a == 0 ? road_km(truck, stations[chosen[b]]) :
               b == 0 ? road_km(truck, stations[chosen[a]]) :
               road_km(truck, stations[chosen[a]], stations[chosen[b]])
    arcs = [(a, b) for a in 0:n for b in 0:n if a != b]

    model = Model(optimizer)
    set_silent(model)
    set_time_limit_sec(model, time_limit)
    set_optimizer_attribute(model, "MIPGap", gap)

    @variable(model, drive[arcs], Bin)                      # truck drives a -> b
    @variable(model, visit[nodes], Bin)
    @variable(model, 0 <= pickup[k in nodes] <= (is_donor[k] ? min(Q, start[k]) : 0), Int)
    @variable(model, 0 <= dropoff[k in nodes] <= (is_donor[k] ? 0 : min(Q, capacity[k] - start[k])), Int)
    @variable(model, 0 <= load[arcs] <= Q)                  # bikes on board along a -> b
    @variable(model, 0 <= order[arcs] <= n)                 # ties the route into one tour
    @variable(model, let_down[nodes] >= 0)                  # expected riders let down tomorrow

    # The tour leaves the depot once, returns once, and enters and leaves each visited station.
    @constraint(model, sum(drive[(0, b)] for b in nodes) == 1)
    @constraint(model, sum(drive[(a, 0)] for a in nodes) == 1)
    @constraint(model, [k in nodes], sum(drive[(k, b)] for b in 0:n if b != k) == visit[k])
    @constraint(model, [k in nodes], sum(drive[(a, k)] for a in 0:n if a != k) == visit[k])

    # A stop must move at least one bike, and bikes only move at visited stations.
    @constraint(model, [k in nodes], pickup[k] + dropoff[k] >= visit[k])
    @constraint(model, [k in nodes], pickup[k] + dropoff[k] <= Q * visit[k])

    # The load on board changes by what is picked up or dropped, and fits in the truck.
    @constraint(model, [arc in arcs], load[arc] <= Q * drive[arc])
    @constraint(model, [k in nodes],
                sum(load[(k, b)] for b in 0:n if b != k) - sum(load[(a, k)] for a in 0:n if a != k) ==
                pickup[k] - dropoff[k])
    @constraint(model, [k in nodes], load[(0, k)] == 0)     # leaves the depot empty
    @constraint(model, [k in nodes], load[(k, 0)] == 0)     # returns empty

    # One unit of "order" is delivered to each visited station from the depot. This rules
    # out loops that are not connected to the depot.
    @constraint(model, [arc in arcs], order[arc] <= n * drive[arc])
    @constraint(model, [k in nodes],
                sum(order[(a, k)] for a in 0:n if a != k) - sum(order[(k, b)] for b in 0:n if b != k) ==
                visit[k])

    # Driving, stopping and handling bikes all fit in the shift.
    minutes = @expression(model,
        sum(drive_minutes(truck, km(a, b)) * drive[(a, b)] for (a, b) in arcs) +
        truck.stop_minutes * sum(visit) + truck.bike_minutes * sum(pickup[k] + dropoff[k] for k in nodes))
    @constraint(model, minutes <= truck.shift)

    # Each station's curve is convex, so it is the highest of the lines through its steps.
    @expression(model, level[k in nodes], start[k] + dropoff[k] - pickup[k])
    for k in nodes
        curve = curves[chosen[k]]
        for b in max(0, start[k] - Q):min(capacity[k], start[k] + Q) - 1
            slope = curve[b + 2] - curve[b + 1]
            @constraint(model, let_down[k] >= curve[b + 1] + slope * (level[k] - b))
        end
    end

    # Fewest riders let down; among equal plans, the shortest shift.
    @objective(model, Min, sum(let_down) + 1e-4 * minutes)
    seconds = @elapsed optimize!(model)
    has_values(model) || return Solution(Plan(), 0.0, 1.0, seconds)

    # Follow the chosen arcs from the depot to read off the route.
    next = Dict(a => b for (a, b) in arcs if value(drive[(a, b)]) > 0.5)
    visits, node = Pair{Int,Int}[], next[0]
    while node != 0
        push!(visits, chosen[node] => round(Int, value(dropoff[node]) - value(pickup[node])))
        node = next[node]
    end
    plan = timed_plan(truck, stations, visits)
    saved = sum(curves[i][bikes[i] + 1] - curves[i][bikes[i] + change + 1] for (i, change) in visits; init = 0.0)
    return Solution(plan, saved, relative_gap(model), seconds)
end

"The lower convex envelope of a curve, for curves that are convex up to sampling noise."
function convex_envelope(curve::Vector{Float64})
    hull = Int[]                   # indices of the lower hull, left to right
    for k in eachindex(curve)
        while length(hull) >= 2
            a, b = hull[end - 1], hull[end]
            (curve[b] - curve[a]) * (k - a) <= (curve[k] - curve[a]) * (b - a) && break
            pop!(hull)
        end
        push!(hull, k)
    end
    envelope = similar(curve)
    for (a, b) in zip(hull, hull[2:end]), k in a:b
        envelope[k] = curve[a] + (curve[b] - curve[a]) * (k - a) / (b - a)
    end
    length(curve) == 1 && (envelope[1] = curve[1])
    return envelope
end
