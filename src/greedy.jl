# The benchmark: a rule of thumb a dispatcher could follow without any optimization.

"""
Rule of thumb. Drive to the fullest station and load the truck, leaving the station
half full. Drive to the emptiest station and unload until it is half full; continue to
the next emptiest until the truck is empty. Repeat until the next round no longer fits
in the shift. No station is visited twice.
"""
function greedy_plan(truck::Truck, stations::Vector{Station}, bikes::Vector{Int})
    half = [station.capacity ÷ 2 for station in stations]
    fill_level(i) = bikes[i] / stations[i].capacity
    open = trues(length(stations))
    visits = Pair{Int,Int}[]

    while true
        donors = [i for i in eachindex(stations) if open[i] && bikes[i] > half[i]]
        isempty(donors) && break
        donor = argmax(fill_level, donors)
        round = nothing
        # Take as many bikes as fit in the truck; take fewer if the round would not fit.
        for take in min(truck.capacity, bikes[donor] - half[donor]):-1:1
            candidate = [donor => -take]
            used, load = falses(length(stations)), take
            while load > 0
                receivers = [i for i in eachindex(stations)
                             if open[i] && !used[i] && i != donor && bikes[i] < half[i]]
                isempty(receivers) && break
                receiver = argmin(fill_level, receivers)
                put = min(load, half[receiver] - bikes[receiver])
                push!(candidate, receiver => put)
                used[receiver] = true
                load -= put
            end
            if load == 0 && timed_plan(truck, stations, vcat(visits, candidate)).minutes <= truck.shift
                round = candidate
                break
            end
        end
        round === nothing && break
        append!(visits, round)
        for (station, _) in round
            open[station] = false
        end
    end
    return timed_plan(truck, stations, visits)
end
