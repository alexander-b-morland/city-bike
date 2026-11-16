using CityBike
using Gurobi
using JuMP
using Test

@testset "Gurobi solves a toy model through JuMP" begin
    # Two stations, move bikes from the full one to the empty one.
    model = Model(Gurobi.Optimizer)
    set_silent(model)
    @variable(model, 0 <= moved <= 5, Int)
    @objective(model, Min, (8 - moved - 4)^2 + (0 + moved - 4)^2)
    optimize!(model)
    @test termination_status(model) == OPTIMAL
    @test value(moved) ≈ 4
end
