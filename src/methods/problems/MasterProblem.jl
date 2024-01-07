struct Cut
    type::CutType
    expression::AffExpr
    objective_value::Real
end

"""
    MasterProblem

Master problem to determine the team locations.
"""
mutable struct MasterProblem <: ProblemType
    model::Model
    allocations::Matrix{Int64}
    rescues::Vector{Float64}
    metrics::Metrics
    history::Vector{Metrics}
    cuts::Vector{Vector{Cut}}
end

"""
    MasterProblem(solver, instance)

Formulation of the master problem.
"""
function MasterProblem(solver::SOLVER, instance::Instance)
    master = Model(solver)

    sites = 1:nb_sites(instance)
    teams = 1:nb_teams(instance)
    scenarios = 1:nb_scenarios(instance)

    @variable(master, is_allocated[sites, teams], Bin) # team allocation
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

    return MasterProblem(master, DEFAULT_MATRIX, [], Metrics(), [], [])
end

"""
    solve(::MasterProblem)

Solves master problem and update the allocations. Exclusively for LShaped iterative exclusively.
"""
function solve!(master::MasterProblem)::Nothing
    execution_time = @elapsed solve!(master.model)
    termination_status(master.model) == MOI.INFEASIBLE_OR_UNBOUNDED && error("Master is infeasible or unbounded")

    master.allocations = value.(master.model[:is_allocated]) .> 0.5
    master.rescues = value.(master.model[:θ])

    master.metrics.execution_time = execution_time
    master.metrics.objective_value = nb_rescues(master)
    master.metrics.expected_recourse = 0 # reset expected recourse
    
    push!(master.history, deepcopy(master.metrics))

    master.cuts = [] # reset cuts

    @info "MasterProblem solved and updated | Metrics $(str(master.metrics))"

    return nothing
end

"""
    has_converged(::MasterProblem)

Check if the difference between the objective value of the master problem
and the expected recourse (estimated from the subproblems) falls below a certain threshold.
"""
function has_converged(master::MasterProblem)::Bool
    Δ = objective_value(master) - expected_recourse(master)

    return Δ < GAP
end

"""
    register_cuts!(::MasterProblem)

Find new cuts for each scenario in parallel and register them in the master problem.
"""
function register_cuts!(master::MasterProblem, instance::Instance, solver::SOLVER)
    optimality_type, feasibility_type = Optimality(), Feasibility()
    tasks = []
    scenarios = 1:nb_scenarios(instance)
    nworkers() < last(scenarios) && addprocs(min(last(scenarios) - nworkers(), 10))
    
    for s in scenarios
        task = @async begin
            subproblems = ProblemType[]
            feasibility = SubProblem(feasibility_type, solver, instance, master, s)
            is_infeasible = !(isnothing(feasibility))
            is_infeasible && push!(subproblems, feasibility)

            optimality = SubProblem(optimality_type, solver, instance, master, s)
            has_improved(optimality, master, s) && push!(subproblems, optimality)

            return subproblems
        end

        push!(tasks, task)
    end

    for task in tasks
        subproblems = fetch(task)
        cuts = [subproblem.cut for subproblem in subproblems]

        push!(master.cuts, cuts)
    end

    rmprocs(workers())
    
    return nothing
end

nb_allocations(master::MasterProblem)::Real = sum(master.allocations)

nb_rescues(master::MasterProblem)::Real = sum(master.rescues)

expected_recourse(master::MasterProblem)::Real = master.metrics.expected_recourse
