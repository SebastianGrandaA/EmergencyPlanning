function solve(method::Base, instance::Instance, solver::SOLVER)::Solution
    model = Model(solver)

    sites = 1:nb_sites(instance)
    scenarios = 1:nb_scenarios(instance) # k index
    teams = 1:nb_teams(instance)
    M = maximum_capacity(instance)

    @variable(model, is_allocated[sites, teams], Bin)
    @variable(model, is_assigned[sites, sites, scenarios], Bin)
    @variable(model, nb_rescues[sites, sites, scenarios] >= 0)

    # Maximize the expected number of people rescued in all scenarios (Min negative)
    @objective(
        model,
        Min,
        - sum(
            get_probability(instance, k) * nb_rescues[s, n, k]
            for (s, site) in enumerate(instance.sites)
            for n in get_neighbor_idxs(instance, site)
            for k in scenarios
        )
    )

    # One team per site constraint
    @constraint(model, exclusive_allocation[s in sites], sum(is_allocated[s, :]) <= 1)

    # Budget constraint
    @constraint(
        model,
        budget_limit,
        sum(instance.teams[t].cost * is_allocated[s, t] for s in sites, t in teams) <= instance.budget
    )

    # One team rescues per site constraint
    @constraint(
        model,
        exclusive_assignment[s in sites, k in scenarios],
        sum(is_assigned[n, s, k] for n in get_neighbor_idxs(instance, s)) <= 1
    )

    # Demand satisfaction per site constraint
    @constraint(
        model,
        demand_satisfaction[s in sites, k in scenarios],
        sum(nb_rescues[n, s, k] for n in get_neighbor_idxs(instance, s)) <= get_demand(instance, k, s)
    )

    # Rescue capacity constraint
    @constraint(
        model,
        rescue_capacity[s in sites, k in scenarios],
        sum(nb_rescues[s, n, k] for n in get_neighbor_idxs(instance, s))
        <= sum(capacity(instance, t) * is_allocated[s, t] for t in teams)
    )

    # Only assigned teams can rescue constraint
    @constraint(
        model,
        only_assigned_teams_can_rescue[s in sites, n in get_neighbor_idxs(instance, s), k in scenarios],
        nb_rescues[n, s, k] <= M * is_assigned[n, s, k]
    )

    execution_time = @elapsed solve!(model)

    return Solution(
        method,
        instance,
        model,
        execution_time,
    )
end

function Solution(
    method::Base,
    instance::Instance,
    model::Model,
    execution_time::Float64,
)
    sites = 1:nb_sites(instance)
    scenarios = 1:nb_scenarios(instance)
    teams = 1:nb_teams(instance)

    allocations = [
        Allocation(instance.teams[t], instance.sites[s])
        for s in sites, t in teams
        if value(model[:is_allocated][s, t]) > 0.5
    ]
    isempty(allocations) && error("No allocations found")
    assignments = Assignment[]

    for scenario_idx in scenarios
        scenario_id = "$(SCENARIO_PREFIX)$(scenario_idx)"
        for s in sites
            for n in get_neighbor_idxs(instance, instance.sites[s])
                if value(model[:is_assigned][n, s, scenario_idx]) > 0.5
                    nb_rescue = value(model[:nb_rescues][n, s, scenario_idx])

                    if nb_rescue > 0
                        allocation = first(filter(a -> a.site == instance.sites[n], allocations))
                        push!(assignments, Assignment(scenario_id, allocation, nb_rescue))
                    end
                end
            end
        end
    end
    
    metrics = Metrics(
        objective_value=-objective_value(model),
        execution_time=execution_time,
    )
    solution = Solution(method, model, allocations, assignments, metrics)
    validate(solution)

    return solution
end