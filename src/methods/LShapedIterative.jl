"""
    solve(::LShaped, instance, solver, ::Iterative)

Iterative version of the L-Shaped method in which the subproblems are solved in parallel for each scenario.
The cuts are added to the master problem in the same batch after all subproblems are solved.
"""
function solve(
    method::LShaped,
    instance::Instance,
    solver::SOLVER,
    usage::Iterative,
)::Solution
    key = get_key(method, usage)
    start = time()
    iteration = 1
    
    master = MasterProblem(solver, instance)

    while should_continue(method, iteration, master)
        @info "$(key) | Iteration $(iteration)"

        solve!(master)
        register_cuts!(master, instance, solver)
        add_cuts!(usage, master, instance, iteration)

        iteration += 1
    end

    solve!(master)
    @info "$(key) | History" master.history

    return Solution(method, master, instance, time() - start)
end

function Solution(
    method::LShaped,
    master::MasterProblem,
    instance::Instance,
    execution_time::Float64,
)
    sites = 1:nb_sites(instance)
    scenarios = 1:nb_scenarios(instance)
    teams = 1:nb_teams(instance)
    assignments = Assignment[]
    allocations = [
        Allocation(instance.teams[t], instance.sites[s])
        for s in sites, t in teams
        if master.allocations[s, t] == 1
    ]
    isempty(allocations) && @error("No allocations found")

    for scenario_idx in scenarios
        scenario_id = "$(SCENARIO_PREFIX)$(scenario_idx)"
        nb_rescues = master.rescues[scenario_idx]
        nb_rescues <= 0 && continue

        for s in sites
            allocation = filter(a -> a.site == instance.sites[s], allocations)
            isempty(allocation) && continue

            push!(assignments, Assignment(scenario_id, first(allocation), nb_rescues))
        end
    end

    metrics = Metrics(
        objective_value=objective_value(master),
        execution_time=execution_time,
    )
    solution = Solution(method, master.model, allocations, assignments, metrics)
    validate(solution)

    return solution
end

"""
    should_continue(::LShaped, iteration, master)

The stop criteria for the iterative L-shaped method is based on the converage,
which is the difference between the objective value of the master problem and the expected recourse,
the maximum number of iterations and the maximum number of iterations without improvement.
"""
function should_continue(::LShaped, iteration::Int64, master::MasterProblem)::Bool
    iteration > MAX_ITERATIONS && return false

    if length(master.history) > MAX_ITERATIONS_NO_IMPROVEMENT
        improvements = diff([element.objective_value for element in master.history[end - MAX_ITERATIONS_NO_IMPROVEMENT:end]])
        all(improvement -> improvement < 1, improvements) && return false
    end

    converange_validation = has_converged(master)
    converange_validation && return false

    return true
end

"""
Add registered cuts to the master problem.
"""
function add_cuts!(usage::Iterative, master::MasterProblem, instance::Instance, iteration::Int64)
    scenarios = 1:nb_scenarios(instance)
    
    for s in scenarios
        to_add = master.cuts[s]
        @debug " | Iteration $(iteration) | Scenario $(s) | Cuts to add" to_add

        for cut in to_add
            is_optimality_cut = !(isnan(cut.objective_value)) # consider only optimality cuts
            master.metrics.expected_recourse += is_optimality_cut ? cut.objective_value : 0

            add_cut!(usage, cut.type, s, master, cut.expression)
            @debug " | Iteration $(iteration) | Scenario $(s) | Cut : $(cut)"
        end
    end

    master.cuts = [] # reset cuts
end

function add_cut!(::Iterative, ::Optimality, scenario::Int64, master::MasterProblem, expression::AffExpr)
    factor = -1 # because of the objective (min -x)
    @constraint(master.model, expression <= factor * master.model[:θ][scenario])
end

function add_cut!(::Iterative, ::Feasibility, scenario::Int64, master::MasterProblem, expression::AffExpr)
    @constraint(master.model, expression <= 0)
end
