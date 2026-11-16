# The optimization model for one night.

"Result of one optimization: the plans, one per truck, and how well the solver did."
struct Solution
    plans::Vector{Plan}
    expected_saved::Float64   # riders let down tomorrow, without the trucks minus with them
    gap::Float64              # relative gap between the plan and the solver's bound
    seconds::Float64
end

Solution() = Solution(Plan[], 0.0, 0.0, 0.0)

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

"Riders the plan is expected to spare tomorrow, read off the stations' curves."
expected_saved(plan::Plan, curves, bikes::Vector{Int}) =
    sum(curves[stop.station][bikes[stop.station] + 1] - curves[stop.station][bikes[stop.station] + stop.change + 1]
        for stop in plan.stops; init = 0.0)

"""
Choose the routes and the number of bikes to load or unload at each stop so that as few
riders as possible are let down tomorrow.

`curves[i][b + 1]` is the expected number of riders let down at station `i` if it starts
the day with `b` bikes (see `failure_curves`); the curves must be convex. `bikes` are
tonight's inventories. Only the `per_side` most promising donors and receivers are
considered, and each is visited by one truck at most. `km_penalty` is the cost of driving
one kilometre, counted in riders let down. `optimizer` is a JuMP optimizer factory.

With `trucks = 1` this is the single-truck model. With more, all trucks are planned
together, which is much harder to solve; `plan_night` plans them one at a time instead.
"""
function optimal_plan(truck::Truck, stations::Vector{Station}, travel::Travel, bikes::Vector{Int}, curves;
                      optimizer, trucks::Integer = 1, per_side::Integer = 20, time_limit::Real = 60.0,
                      gap::Real = 0.01, km_penalty::Real = 0.0, attributes = Dict{String,Any}())
    donors, receivers = candidates(truck, curves, bikes, per_side)
    (isempty(donors) || isempty(receivers)) && return Solution()
    chosen = vcat(donors, receivers)
    n = length(chosen)
    nodes = 1:n                    # node 0 is the depot
    is_donor = [k <= length(donors) for k in nodes]
    capacity = [stations[i].capacity for i in chosen]
    start = bikes[chosen]
    Q, T = truck.capacity, truck.shift
    place(a) = a == 0 ? depot(travel) : chosen[a]
    minutes(a, b) = travel.minutes[place(a), place(b)]
    arcs = [(a, b) for a in 0:n for b in 0:n if a != b]
    into(k) = [(a, k) for a in 0:n if a != k]
    outof(k) = [(k, b) for b in 0:n if b != k]

    model = Model(optimizer)
    set_silent(model)
    set_time_limit_sec(model, time_limit)
    set_optimizer_attribute(model, "MIPGap", gap)
    for (name, value) in attributes
        set_optimizer_attribute(model, name, value)
    end

    @variable(model, drive[arcs], Bin)                      # a truck drives a -> b
    @variable(model, visit[nodes], Bin)
    @variable(model, 0 <= pickup[k in nodes] <= (is_donor[k] ? min(Q, start[k]) : 0), Int)
    @variable(model, 0 <= dropoff[k in nodes] <= (is_donor[k] ? 0 : min(Q, capacity[k] - start[k])), Int)
    @variable(model, 0 <= load[arcs] <= Q)                  # bikes on board along a -> b
    @variable(model, let_down[nodes] >= 0)                  # expected riders let down tomorrow

    # At most `trucks` tours leave the depot, and each visited station is entered and left once.
    @constraint(model, sum(drive[arc] for arc in outof(0)) <= trucks)
    @constraint(model, sum(drive[arc] for arc in outof(0)) == sum(drive[arc] for arc in into(0)))
    @constraint(model, [k in nodes], sum(drive[arc] for arc in outof(k)) == visit[k])
    @constraint(model, [k in nodes], sum(drive[arc] for arc in into(k)) == visit[k])

    # A stop must move at least one bike, and bikes only move at visited stations.
    @constraint(model, [k in nodes], pickup[k] + dropoff[k] >= visit[k])
    @constraint(model, [k in nodes], pickup[k] + dropoff[k] <= Q * visit[k])

    # The load on board changes by what is picked up or dropped, and fits in the truck.
    @constraint(model, [arc in arcs], load[arc] <= Q * drive[arc])
    @constraint(model, [k in nodes],
                sum(load[arc] for arc in outof(k)) - sum(load[arc] for arc in into(k)) == pickup[k] - dropoff[k])
    @constraint(model, [k in nodes], load[(0, k)] == 0)     # leaves the depot empty
    @constraint(model, [k in nodes], load[(k, 0)] == 0)     # returns empty

    @expression(model, service[k in nodes],
                truck.stop_minutes * visit[k] + truck.bike_minutes * (pickup[k] + dropoff[k]))
    driving = @expression(model, sum(minutes(a, b) * drive[(a, b)] for (a, b) in arcs))
    if trucks == 1
        # One tour: driving, stopping and handling bikes all fit in the shift.
        @constraint(model, driving + sum(service) <= T)
        # One unit of "order" is delivered to each visited station from the depot. This
        # rules out loops that are not connected to the depot.
        @variable(model, 0 <= order[arcs] <= n)
        @constraint(model, [arc in arcs], order[arc] <= n * drive[arc])
        @constraint(model, [k in nodes],
                    sum(order[arc] for arc in into(k)) - sum(order[arc] for arc in outof(k)) == visit[k])
    else
        # Several tours: a clock runs along each tour. `clock[a -> b]` is the time the truck
        # reaches b. It grows with every leg and stop, so it also rules out loose loops, and
        # every tour must be back at the depot before the shift ends.
        @variable(model, clock[arcs] >= 0)
        @constraint(model, [(a, b) in arcs],
                    clock[(a, b)] <= (T - (b == 0 ? 0.0 : minutes(b, 0))) * drive[(a, b)])
        @constraint(model, [k in nodes], clock[(0, k)] == minutes(0, k) * drive[(0, k)])
        @constraint(model, [k in nodes],
                    sum(clock[arc] for arc in outof(k)) - sum(clock[arc] for arc in into(k)) ==
                    service[k] + sum(minutes(k, b) * drive[(k, b)] for b in 0:n if b != k))
    end

    # Each station's curve is convex, so it is the highest of the lines through its steps.
    @expression(model, level[k in nodes], start[k] + dropoff[k] - pickup[k])
    for k in nodes
        curve = curves[chosen[k]]
        for b in max(0, start[k] - Q):min(capacity[k], start[k] + Q) - 1
            slope = curve[b + 2] - curve[b + 1]
            @constraint(model, let_down[k] >= curve[b + 1] + slope * (level[k] - b))
        end
    end

    # Fewest riders let down, then least driving; among equal plans, the shortest shifts.
    distance = @expression(model, sum(travel.km[place(a), place(b)] * drive[(a, b)] for (a, b) in arcs))
    @objective(model, Min, sum(let_down) + km_penalty * distance + 1e-4 * (driving + sum(service)))
    seconds = @elapsed optimize!(model)
    has_values(model) || return Solution(Plan[], 0.0, 1.0, seconds)

    # Follow the chosen arcs out of the depot to read off each tour.
    next = Dict(a => b for (a, b) in arcs if a != 0 && value(drive[(a, b)]) > 0.5)
    plans = Plan[]
    for first_stop in nodes
        value(drive[(0, first_stop)]) > 0.5 || continue
        visits, node = Pair{Int,Int}[], first_stop
        while node != 0
            push!(visits, chosen[node] => round(Int, value(dropoff[node]) - value(pickup[node])))
            node = next[node]
        end
        push!(plans, timed_plan(truck, travel, visits))
    end
    saved = sum(expected_saved(plan, curves, bikes) for plan in plans; init = 0.0)
    return Solution(plans, saved, relative_gap(model), seconds)
end

"""
Plan a night for `trucks` trucks, one truck at a time: each truck gets the best plan
given what the trucks before it will already have done. With `method = :greedy` every
truck follows the rule of thumb instead. Extra keywords go to `optimal_plan`.
"""
function plan_night(truck::Truck, stations::Vector{Station}, travel::Travel, bikes::Vector{Int}, curves;
                    trucks::Integer, method::Symbol = :optimal, kwargs...)
    plans, saved, gap, seconds = Plan[], 0.0, 0.0, 0.0
    for _ in 1:trucks
        if method == :greedy
            plan = greedy_plan(truck, stations, travel, bikes)
        else
            solution = optimal_plan(truck, stations, travel, bikes, curves; kwargs...)
            plan = isempty(solution.plans) ? Plan() : only(solution.plans)
            gap, seconds = max(gap, solution.gap), seconds + solution.seconds
        end
        isempty(plan.stops) && break
        saved += expected_saved(plan, curves, bikes)
        push!(plans, plan)
        bikes = after(bikes, plan)
    end
    return Solution(plans, saved, gap, seconds)
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
