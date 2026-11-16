using CityBike
using Dates
using Gurobi
using JuMP
using Test

const ENV_GRB = Gurobi.Env()
optimizer() = Gurobi.Optimizer(ENV_GRB)

# Four stations in a row, about 1 km apart, next to the default depot.
stations = [Station(k, "S$k", 59.9309, 10.8019 + 0.018 * k, 10) for k in 1:4]
truck = Truck(capacity = 5, shift = 120.0)

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
    @test !is_convex([0.0, 1.0, 1.0, 3.0, 3.0])
    @test convex_envelope([3.0, 0.0, 2.0, 0.0, 3.0]) == [3.0, 0.0, 0.0, 0.0, 3.0]
end

@testset "plans" begin
    bikes = [10, 5, 5, 0]
    plan = timed_plan(truck, stations, [1 => -5, 4 => 5])
    @test isempty(problems(plan, truck, stations, bikes))
    @test bikes_moved(plan) == 5
    @test plan.stops[1].done < plan.stops[2].done < plan.minutes
    @test !isempty(problems(timed_plan(truck, stations, [4 => 5, 1 => -5]), truck, stations, bikes))
    @test !isempty(problems(timed_plan(truck, stations, [1 => -5]), truck, stations, bikes))
end

@testset "rule of thumb" begin
    bikes = [10, 5, 5, 0]
    plan = greedy_plan(truck, stations, bikes)
    @test isempty(problems(plan, truck, stations, bikes))
    @test [stop.station => stop.change for stop in plan.stops] == [1 => -5, 4 => 5]
    @test isempty(greedy_plan(truck, stations, [5, 5, 5, 5]).stops)
end

@testset "optimization model" begin
    # Station 1 is let down by every bike above 4; station 4 by every bike below 6.
    surplus = [max(0.0, b - 4) for b in 0:10]
    shortage = [max(0.0, 6 - b) for b in 0:10]
    flat = zeros(11)
    curves = [surplus, flat, flat, shortage]
    bikes = [10, 5, 5, 0]
    solution = optimal_plan(truck, stations, bikes, curves; optimizer)
    @test isempty(problems(solution.plan, truck, stations, bikes))
    @test [stop.station => stop.change for stop in solution.plan.stops] == [1 => -5, 4 => 5]
    @test solution.expected_saved ≈ 10
    # With no time to drive, the best plan is to stay home.
    idle = optimal_plan(Truck(capacity = 5, shift = 1.0), stations, bikes, curves; optimizer)
    @test isempty(idle.plan.stops)
end

@testset "simulation keeps every bike" begin
    day = Date(2026, 6, 1)
    at(h, m) = DateTime(day) + Hour(h) + Minute(m)
    trips = [Trip(4, 1, at(7, 0), at(7, 10)),     # station 4 is empty: rider gives up
             Trip(2, 1, at(8, 0), at(8, 10)),     # station 1 is full: rider rides on
             Trip(3, 4, at(9, 0), at(9, 10))]
    bikes = [10, 5, 5, 0]
    idle = simulate!(bikes, stations, trips, [day], truck, (day, bikes) -> Plan())
    @test sum(bikes) == 20
    @test (idle[1].trips, idle[1].no_bike, idle[1].no_dock) == (3, 1, 1)
    @test size(idle[1].snapshots) == (48, 4)

    bikes = [10, 5, 5, 0]
    moved = simulate!(bikes, stations, trips, [day], truck, (day, bikes) -> greedy_plan(truck, stations, bikes))
    @test sum(bikes) == 20
    @test let_down(moved[1]) == 0                 # the truck fixed both stations overnight
    @test [stop.change for stop in moved[1].stops] == [-5, 5]
end
