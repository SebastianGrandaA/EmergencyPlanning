# Callback version

"""
    solve(::LShaped, instance, solver, ::Callback)

Callback version of the L-Shaped method.
Use Gurobi Lazy Constraints Callback to add the cuts to the master problem as soon as they are found.
"""
function solve(
    method::LShaped,
    instance::Instance,
    solver::SOLVER,
    usage::Callback,
)::Solution
    key = get_key(method, usage)
    scenarios = 1:nb_scenarios(instance)
    optimality_type, feasibility_type = Optimality(), Feasibility()

    master = MasterProblem(solver, instance)

    function add_cuts!(callback_data)
        callback_node_status(callback_data, master.model) != MOI.CALLBACK_NODE_STATUS_INTEGER && return
        
        master.allocations = callback_value.(callback_data, master.model[:is_allocated]) .> 0.5
        master.rescues = callback_value.(callback_data, master.model[:θ])
        master.metrics.objective_value = nb_rescues(master)
        push!(master.history, deepcopy(master.metrics))

        for s in scenarios
            nb_cuts = 0
            feasibility = SubProblem(feasibility_type, solver, instance, master, s)
            
            if !(isnothing(feasibility))
                nb_cuts += 1
                MOI.submit(
                    master.model,
                    MOI.LazyConstraint(callback_data),
                    get_cut(usage, feasibility_type, s, master, feasibility.cut.expression)
                )
            end

            optimality = SubProblem(optimality_type, solver, instance, master, s)

            if has_improved(optimality, master, s)
                nb_cuts += 1
                MOI.submit(
                    master.model,
                    MOI.LazyConstraint(callback_data),
                    get_cut(usage, optimality_type, s, master, optimality.cut.expression)
                )
            end

            @info "$(key) | Scenario $(s) | $(nb_cuts) cuts added | Master metrics" master.metrics
        end

        return
    end

    MOI.set(master.model, MOI.LazyConstraintCallback(), add_cuts!)

    # set_attribute(master.model, MOI.LazyConstraintCallback(), add_cuts!)
    # solve!(master)
    # return Solution(method, master, instance, master.metrics.execution_time)

    optimize!(master.model)
    @info "BORRAR " master.model master.model[:is_allocated] master.model[:θ] termination_status(master.model)
    # update metrics
    master.allocations = value.(master.model[:is_allocated]) .> 0.5
    master.rescues = value.(master.model[:θ])
    # master.metrics.execution_time = execution_time
    master.metrics.objective_value = nb_rescues(master)
    push!(master.history, deepcopy(master.metrics))

    return Solution(method, master, instance, execution_time)
end

"""
    has_improved(subproblem, master)

Check if the subproblem solution is better than the current master solution.
"""
function has_improved(subproblem::SubProblem, master::MasterProblem, scenario_idx::Int64)::Bool
    return true
    # TODO debemos comparar objective_value(subproblem) con el valor del master para ese escenario?
    # return abs(objective_value(subproblem)) > abs(master.metrics.objective_value)
end

function get_cut(::Callback, ::Optimality, scenario::Int64, master::MasterProblem, expression::AffExpr)
    @info "BORRAR Optimality cut" expression
    factor = -1 # because of the objective (min -x)
    
    return @build_constraint(expression <= factor * master.model[:θ][scenario])
end


function get_cut(::Callback, ::Feasibility, scenario::Int64, master::MasterProblem, expression::AffExpr)
    @info "BORRAR Feasibility cut" expression
    return @build_constraint(expression <= 0)
end

# Iterative version

"""
    solve(::LShaped, instance, solver, ::Iterative)

Iterative version of the L-Shaped method in which the subproblems are solved in parallel for each scenario.
The cuts are added to the master problem in the same batch after all subproblems are solved.


TODO!! Importante: actualmente se estanca en la segunda iteracion... facil que porque ya se agregan todos los cuts (todos los escenarios). El chiste es entonces agregar uno por uno y resolver el master?
"""
function solve(
    method::LShaped,
    instance::Instance,
    solver::SOLVER,
    usage::Iterative,
)::Solution
    key = get_key(method, usage)
    start_time = time()
    iteration = 1
    scenarios = 1:nb_scenarios(instance)
    optimality_type, feasibility_type = Optimality(), Feasibility()
    nworkers() < last(scenarios) && addprocs(min(last(scenarios) - nworkers(), 10))

    master = MasterProblem(solver, instance)

    while should_continue(iteration, master)
        @info "$(key) | Instance $(name(instance)) | Iteration $(iteration)"
        tasks = []
        solve!(master) 

        # Search for new cuts (parallel)
        for s in scenarios
            task = @async begin
                cuts = Cut[]
                feasibility = SubProblem(feasibility_type, solver, instance, master, s)
                !(isnothing(feasibility)) && push!(cuts, feasibility.cut)
    
                optimality = SubProblem(optimality_type, solver, instance, master, s)
                has_improved(optimality, master, s) && push!(cuts, optimality.cut)

                return cuts
            end

            push!(tasks, task)
        end

        for task in tasks
            cuts = fetch(task)
            push!(master.cuts, cuts)
        end

        # Add cuts to master in the same batch
        for s in scenarios
            to_add = master.cuts[s]
            @info "$(key) | Iteration $(iteration) | Scenario $(s) | $(length(to_add)) cuts to add"

            for cut in to_add
                add_cut!(usage, cut.type, s, master, cut.expression)
                @debug "$(key) | Iteration $(iteration) | Scenario $(s) | Cut : $(cut)"
            end
        end

        iteration += 1
    end

    solve!(master)
    @info "$(key) | Instance $(name(instance)) | History" master.history

    return Solution(method, master, instance, time() - start_time)
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
    isempty(allocations) && error("No allocations found")

    for scenario_idx in scenarios
        scenario_id = "$(SCENARIO_PREFIX)$(scenario_idx)"
        nb_rescues = master.rescues[scenario_idx]
        nb_rescues <= 0 && continue

        for s in sites
            allocation = filter(a -> a.site == instance.sites[s], allocations)
            isempty(allocation) && continue

            push!(assignments, Assignment(scenario_id, first(allocation), nb_rescues))
        end
        # TODO introduce site-dissagregation by passing the subproblem
    end

    metrics = Metrics(
        objective_value=objective_value(master),
        execution_time=execution_time,
    )
    solution = Solution(method, allocations, assignments, metrics)
    validate(solution)

    return solution
end

"""
    should_continue(iteration, master)

Stop criteria based on:
    * Maximum number of iterations
    * Maximum number of iterations without improvement
"""
function should_continue(iteration::Int64, master::MasterProblem)::Bool
    iteration > MAX_ITERATIONS && return false

    if length(master.history) > MAX_ITERATIONS_NO_IMPROVEMENT
        improvements = diff([element.objective_value for element in master.history[end - MAX_ITERATIONS_NO_IMPROVEMENT:end]])
        all(improvement -> improvement < 1, improvements) && return false
    end

    return true

    # TODO: no more cuts, gap...
    # TODO MAX_ITERATIONS deberia ser param de usuario
    # TODO implement ideas from tabu search / simmulated annealing?
end

function add_cut!(::Iterative, ::Optimality, scenario::Int64, master::MasterProblem, expression::AffExpr)
    factor = -1 # because of the objective (min -x)
    @constraint(master.model, expression <= factor * master.model[:θ][scenario])
end

function add_cut!(::Iterative, ::Feasibility, scenario::Int64, master::MasterProblem, expression::AffExpr)
    @constraint(master.model, expression <= 0)
end
