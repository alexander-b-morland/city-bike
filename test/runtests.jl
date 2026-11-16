using CityBike
using Dates
using Gurobi
using JuMP
using Test

const ENV_GRB = Gurobi.Env()
optimizer() = Gurobi.Optimizer(ENV_GRB)

# Four stations in a row, about 1 km apart, with the depot at the west end.
stations = [Station(k, "S$k", 59.9309, 10.8019 + 0.018 * k, 10) for k in 1:4]
truck = Truck(capacity = 5, shift = 120.0, depot_lat = 59.9309, depot_lon = 10.8019)
travel = straight_line_travel(truck, stations)
moves(plans) = [[stop.station => stop.change for stop in plan.stops] for plan in plans]

@testset "riders let down at one station" begin
    @test failures(Int8[-1, -1, 1], 1, 10) == 1          # second rider finds it empty
    @test failures(Int8[1, 1], 9, 10) == 1               # second return finds it full
    @test failures(Int8[-1, 1, -1, 1], 1, 10) == 0
    @test failures(Int8[], 5, 10) == 0
end

@testset "failure curves and convexity" begin
    day = Date(2026, 6, 1)
    at(h, m) = DateTime(day) + Hour(h) + Minute(m)
    trips = [Trip(1, 2, at(8, m), at(8, m + 10)) for m in 0:2:10]   # six rides 1 -> 2
    curves = failure_curves(trips, stations, [day])
    @test curves[1] == [6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0]            # wants six bikes
    @test curves[2] == [0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6]            # wants six free docks
    @test all(is_convex, curves)
    # The rides leave between 08:00 and 08:10, that is 420 to 430 minutes after 01:00.
    @test failure_curves(trips, stations, [day]; until = 420)[1] == zeros(11)
    @test failure_curves(trips, stations, [day]; from = 424)[1][1] == 4
    @test !is_convex([0.0, 1.0, 1.0, 3.0, 3.0])
    @test convex_envelope([3.0, 0.0, 2.0, 0.0, 3.0]) == [3.0, 0.0, 0.0, 0.0, 3.0]
end

@testset "plans" begin
    bikes = [10, 5, 5, 0]
    plan = timed_plan(truck, travel, [1 => -5, 4 => 5])
    @test isempty(problems(plan, truck, stations, bikes))
    @test bikes_moved(plan) == 5
    @test after(bikes, plan) == [5, 5, 5, 5]
    @test plan.stops[1].done < plan.stops[2].done < plan.minutes
    @test !isempty(problems(timed_plan(truck, travel, [4 => 5, 1 => -5]), truck, stations, bikes))
    @test !isempty(problems(timed_plan(truck, travel, [1 => -5]), truck, stations, bikes))
end

@testset "rule of thumb" begin
    bikes = [10, 5, 5, 0]
    plan = greedy_plan(truck, stations, travel, bikes)
    @test isempty(problems(plan, truck, stations, bikes))
    @test moves([plan]) == [[1 => -5, 4 => 5]]
    @test isempty(greedy_plan(truck, stations, travel, [5, 5, 5, 5]).stops)
end

@testset "optimization model" begin
    # Station 1 is let down by every bike above 4; station 4 by every bike below 6.
    surplus = [max(0.0, b - 4) for b in 0:10]
    shortage = [max(0.0, 6 - b) for b in 0:10]
    flat = zeros(11)
    curves = [surplus, flat, flat, shortage]
    bikes = [10, 5, 5, 0]
    solution = optimal_plan(truck, stations, travel, bikes, curves; optimizer)
    @test isempty(problems(solution.plans, truck, stations, bikes))
    @test moves(solution.plans) == [[1 => -5, 4 => 5]]
    @test solution.expected_saved ≈ 10
    # With no time to drive, the best plan is to stay home.
    hurried = Truck(capacity = 5, shift = 1.0, depot_lat = 59.9309, depot_lon = 10.8019)
    @test isempty(optimal_plan(hurried, stations, travel, bikes, curves; optimizer).plans)
end

@testset "several trucks" begin
    # Two stations with too many bikes, two with too few. In a 40-minute shift a truck has
    # time for one round of 5 bikes, so each truck fixes half of the problem.
    short = Truck(capacity = 5, shift = 40.0, depot_lat = 59.9309, depot_lon = 10.8019)
    curves = [[max(0.0, b - 5) for b in 0:10], [max(0.0, b - 5) for b in 0:10],
              [max(0.0, 5 - b) for b in 0:10], [max(0.0, 5 - b) for b in 0:10]]
    bikes = [10, 10, 0, 0]
    one = plan_night(short, stations, travel, bikes, curves; trucks = 1, optimizer)
    two = plan_night(short, stations, travel, bikes, curves; trucks = 2, optimizer)
    together = optimal_plan(short, stations, travel, bikes, curves; trucks = 2, optimizer)
    @test one.expected_saved ≈ 10
    @test two.expected_saved ≈ 20
    @test together.expected_saved ≈ 20
    @test length(two.plans) == 2 && length(together.plans) == 2
    @test isempty(problems(two.plans, short, stations, bikes))
    @test all(isempty(problems(plan, short, stations, bikes)) for plan in together.plans)
    # A third truck has nothing left to do and stays home.
    @test length(plan_night(short, stations, travel, bikes, curves; trucks = 3, optimizer).plans) == 2
    rule = plan_night(short, stations, travel, bikes, curves; trucks = 2, method = :greedy)
    @test isempty(problems(rule.plans, short, stations, bikes))
end

@testset "driving along streets" begin
    # A two-way street A - B - C and a one-way shortcut from C straight back to A.
    point(lat, lon) = Dict("lat" => lat, "lon" => lon)
    a, b, c = point(59.90, 10.70), point(59.90, 10.72), point(59.91, 10.72)
    ways = [Dict("type" => "way", "nodes" => [1, 2, 3], "geometry" => [a, b, c],
                 "tags" => Dict("highway" => "residential", "maxspeed" => "30")),
            Dict("type" => "way", "nodes" => [3, 1], "geometry" => [c, a],
                 "tags" => Dict("highway" => "residential", "maxspeed" => "30", "oneway" => "yes"))]
    file = joinpath(mktempdir(), "roads.json")
    write(file, CityBike.JSON.json(Dict("elements" => ways)))
    places = [Station(1, "A", 59.90, 10.70, 10), Station(2, "C", 59.91, 10.72, 10)]
    roads = load_roads(file, places, Truck(depot_lat = 59.90, depot_lon = 10.72))
    km = roads.travel.km
    @test km[2, 1] < km[1, 2]                      # the shortcut only works one way
    @test km[1, 2] ≈ km[1, 3] + km[3, 2]           # A to C goes through B, where the depot is
    @test route(roads, 1, 2) == [(59.90, 10.70), (59.90, 10.72), (59.91, 10.72)]
    @test route(roads, 2, 1) == [(59.91, 10.72), (59.90, 10.70)]
    @test thin_line([(59.90, 10.70), (59.90, 10.71), (59.90, 10.72)], 1.0) == [(59.90, 10.70), (59.90, 10.72)]
end

@testset "simulation keeps every bike" begin
    day = Date(2026, 6, 1)
    at(h, m) = DateTime(day) + Hour(h) + Minute(m)
    trips = [Trip(4, 1, at(7, 0), at(7, 10)),     # station 4 is empty: rider gives up
             Trip(2, 1, at(8, 0), at(8, 10)),     # station 1 is full: rider rides on
             Trip(3, 4, at(9, 0), at(9, 10))]
    bikes = [10, 5, 5, 0]
    idle = simulate!(bikes, stations, trips, [day], truck, (day, bikes, shift) -> Plan[])
    @test sum(bikes) == 20
    @test (idle[1].trips, idle[1].no_bike, idle[1].no_dock) == (3, 1, 1)
    @test size(idle[1].snapshots) == (48, 4)

    bikes = [10, 5, 5, 0]
    rule(day, bikes, shift) = [greedy_plan(truck, stations, travel, bikes)]
    moved = simulate!(bikes, stations, trips, [day], truck, rule)
    @test sum(bikes) == 20
    @test let_down(moved[1]) == 0                 # the truck fixed both stations overnight
    @test [stop.change for stop in only(moved[1].stops)] == [-5, 5]

    # Two trucks working the same night each keep their own load.
    bikes = [10, 10, 0, 0]
    pair(day, bikes, shift) = [timed_plan(truck, travel, [1 => -5, 3 => 5]), timed_plan(truck, travel, [2 => -5, 4 => 5])]
    both = simulate!(bikes, stations, Trip[], [day], truck, pair)
    @test bikes == [5, 5, 5, 5]
    @test length(both[1].stops) == 2

    # A second shift at 10:00 sees what riders did in the morning and fixes it.
    bikes = [10, 5, 5, 0]
    late = simulate!(bikes, stations, trips, [day], truck, rule; shifts = [0.0, 540.0])
    @test late[1].starts == [0.0, 540.0]
    @test all(540 < stop.done < 660 for stop in late[1].stops[2])
    @test sum(bikes) == 20
end
