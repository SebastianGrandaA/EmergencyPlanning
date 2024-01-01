struct Cut
    type::CutType
    expression::AffExpr
end

"""
    MasterProblem

The Master Problem (MP) consists of determing the first-stage decisions (`allocations`) and ...
    [Implementation] it stores the second-stage decisions (`rescues`) determined in the SubProblems (SP). Initially, the set of `rescues` is empty.
"""
mutable struct MasterProblem <: ProblemType
    model::Model
    allocations::Matrix{Int64} # = DEFAULT_MATRIX
    rescues#:: # = DEFAULT_MATRIX
    metrics::Metrics # = Metrics()
    history::Vector{Metrics}
    cuts::Vector{Vector{Cut}} # [feasibility, optimality] per scenario
end

"""
Builds the initial MasterProblem without solving it.
"""
function MasterProblem(solver::SOLVER, instance::Instance)
    master = Model(solver)

    sites = 1:nb_sites(instance)
    scenarios = 1:nb_scenarios(instance) # k index
    teams = 1:nb_teams(instance)

    @variable(master, is_allocated[sites, teams], Bin)
    @variable(master, θ[scenarios] >= 0) # 2nd-stage nb of rescues

    # Maximize the expected number of people rescued in all scenarios (Min negative)
    @objective(
        master,
        Min,
        - sum(
            get_probability(instance, k) * θ[k]
            for k in scenarios
        )
    )

    # One team per site constraint
    @constraint(master, exclusive_allocation[s in sites], sum(is_allocated[s, :]) <= 1)

    # Budget constraint
    @constraint(
        master,
        budget_limit,
        sum(instance.teams[t].cost * is_allocated[s, t] for s in sites, t in teams) <= instance.budget
    )

    return MasterProblem(master, DEFAULT_MATRIX, [], Metrics(), [], []) # TODO no son kwdef?
end

"""
Solve master problem and update the allocations.

For LShaped iterative exclusively.
TODO hacer mutable o que devuelva un nuevo master?
"""
function solve!(master::MasterProblem)::Nothing
    execution_time = @elapsed solve!(master.model)

    master.allocations = value.(master.model[:is_allocated]) .> 0.5
    master.rescues = value.(master.model[:θ])

    master.metrics.execution_time = execution_time
    master.metrics.objective_value = nb_rescues(master)
    push!(master.history, deepcopy(master.metrics))

    master.cuts = [] # reset cuts

    @info "MasterProblem solved and updated | Metrics $(str(master.metrics))"

    return nothing
end

nb_allocations(master::MasterProblem)::Real = sum(master.allocations)

nb_rescues(master::MasterProblem)::Real = sum(master.rescues)
