struct SubProblem <: ProblemType
    type::CutType # TODO eliminar -- ahora en ::Cut
    cut::Cut
    scenario::Int64
    model::Model
    metrics::Metrics
end

"""
    SubProblem(::Optimality)

Subproblem to get the optimality cut for a given scenario
"""
function SubProblem(
    cut_type::Optimality,
    solver::SOLVER,
    instance::Instance,
    master::MasterProblem,
    scenario::Int64,
)
    subproblem = Model(solver)
    sites = 1:nb_sites(instance)
    teams = 1:nb_teams(instance)
    M = maximum_capacity(instance)
    probability = get_probability(instance, scenario)

    @variable(subproblem, is_assigned[sites, sites] >= 0) # relaxed to access duals
    @variable(subproblem, nb_rescues[sites, sites] >= 0)

    # Maximize the number of people rescued
    @objective(
        subproblem,
        Min,
        - sum(
            nb_rescues[s, n]
            for (s, site) in enumerate(instance.sites)
            for n in get_neighbor_idxs(instance, site)
        )
    )
    
    # One team rescues per site constraint
    @constraint(
        subproblem,
        exclusive_assignment[s in sites],
        sum(is_assigned[n, s] for n in get_neighbor_idxs(instance, s)) <= 1
    )

    # Demand satisfaction per site constraint
    @constraint(
        subproblem,
        demand_satisfaction[s in sites],
        sum(nb_rescues[n, s] for n in get_neighbor_idxs(instance, s)) <= get_demand(instance, scenario, s)
    )

    # Rescue capacity constraint
    @constraint(
        subproblem,
        rescue_capacity[s in sites],
        sum(
            nb_rescues[s, n]
            for n in get_neighbor_idxs(instance, s)
        ) <= sum(
            instance.teams[t].capacity * master.allocations[s, t]
            for t in teams
        )
    )

    # Only assigned teams can rescue constraint
    @constraint(
        subproblem,
        only_assigned_teams_can_rescue[s in sites, n in get_neighbor_idxs(instance, s)],
        nb_rescues[n, s] <= M * is_assigned[n, s]
    )

    execution_time = @elapsed solve!(subproblem)
    metrics = Metrics(
        objective_value=objective_value(subproblem),
        execution_time=execution_time,
    )

    duals = dual.(subproblem[:rescue_capacity])
    
    cut = Cut(
        cut_type,
        probability * build_cut(master, metrics.objective_value, duals, instance),
        metrics.objective_value,
    )

    return SubProblem(cut_type, cut, scenario, subproblem, metrics)
end

"""
    SubProblem(::Feasibility)

Auxiliary subproblem to get the feasibility cut for a given scenario
"""
function SubProblem(
    cut_type::Feasibility,
    solver::SOLVER,
    instance::Instance,
    master::MasterProblem,
    scenario::Int64
)
    auxiliary = Model(solver)
    sites = 1:nb_sites(instance)
    teams = 1:nb_teams(instance)
    constraints = 1:SUBPROBLEM_CONSTRAINTS
    M = maximum_capacity(instance)

    @variable(auxiliary, is_assigned[sites, sites] >= 0) # relaxed to access duals
    @variable(auxiliary, nb_rescues[sites, sites] >= 0)

    # Auxiliary
    @variable(auxiliary, deficit[sites, constraints] >= 0)
    @variable(auxiliary, surplus[sites, constraints] >= 0)

    # Objective function: minimize the sum of deficit and surplus
    @objective(
        auxiliary,
        Min,
        sum(
            deficit[s, c] + surplus[s, c]
            for s in sites, c in constraints
        )
    )

    # One team rescues per site constraint
    @constraint(
        auxiliary,
        exclusive_assignment[s in sites],
        sum(is_assigned[n, s] for n in get_neighbor_idxs(instance, s)) + deficit[s, 1] - surplus[s, 1]
        <= 1
    )

    # Demand satisfaction per site constraint
    @constraint(
        auxiliary,
        demand_satisfaction[s in sites],
        sum(nb_rescues[n, s] for n in get_neighbor_idxs(instance, s)) + deficit[s, 2] - surplus[s, 2]
        <= get_demand(instance, scenario, s)
    )
    
    # Rescue capacity constraint
    @constraint(
        auxiliary,
        rescue_capacity[s in sites],
        sum(
            nb_rescues[s, n]
            for n in get_neighbor_idxs(instance, s)
        ) + deficit[s, 3] - surplus[s, 3]
        <= sum(
            instance.teams[t].capacity * master.allocations[s, t]
            for t in teams
        )
    )

    # Only assigned teams can rescue constraint
    @constraint(
        auxiliary,
        only_assigned_teams_can_rescue[s in sites, n in get_neighbor_idxs(instance, s)],
        nb_rescues[n, s] + deficit[s, 4] - surplus[s, 4]
        <= M * is_assigned[n, s]
    )

    execution_time = @elapsed solve!(auxiliary)
    metrics = Metrics(
        objective_value=objective_value(auxiliary),
        execution_time=execution_time,
    )
    is_feasible(cut_type, metrics.objective_value) && return nothing

    duals = dual.(auxiliary[:rescue_capacity])
    cut = Cut(
        cut_type,
        build_cut(master, metrics.objective_value, duals, instance),
        NaN,
    )

    return SubProblem(cut_type, cut, scenario, auxiliary, metrics)
end

is_feasible(::Feasibility, objective_value::Real)::Bool = isapprox(objective_value, 0)

function build_cut(master::MasterProblem, objective_value::Real, duals, instance::Instance)::AffExpr
    expression = AffExpr(objective_value)

    for s in 1:nb_sites(instance)
        expression += duals[s] * total_capacity(instance, master, s)
    end

    return expression
end

function total_capacity(instance::Instance, master::MasterProblem, site_idx::Int64)::AffExpr
    return sum(
        capacity(team) * master.model[:is_allocated][site_idx, team_idx]
        for (team_idx, team) in enumerate(instance.teams)
    )
end