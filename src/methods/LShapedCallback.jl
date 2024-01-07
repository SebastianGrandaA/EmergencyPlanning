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
            is_infeasible = !(isnothing(feasibility))
            
            if is_infeasible
                feasibility_cut = get_cut(usage, feasibility_type, s, master, feasibility.cut.expression)
                @warn "BORRAR" feasibility_cut
                MOI.submit(
                    master.model,
                    MOI.LazyConstraint(callback_data),
                    feasibility_cut
                )
                nb_cuts += 1
            end

            optimality = SubProblem(optimality_type, solver, instance, master, s)

            if has_improved(optimality, master, s)
                optimality_cut = get_cut(usage, optimality_type, s, master, optimality.cut.expression)
                @warn "BORRAR" optimality_cut
                MOI.submit(
                    master.model,
                    MOI.LazyConstraint(callback_data),
                    optimality_cut,
                )
                nb_cuts += 1
            end

            @info "$(key) | Scenario $(s) | $(nb_cuts) cuts added | Master metrics" master.metrics
        end

        return nothing
    end

    set_attribute(master.model, MOI.LazyConstraintCallback(), add_cuts!)
    # solve!(master)
    # solve!(master.model)
    optimize!(master.model)
    @info "BORRAR" termination_status(master.model)
    # update metrics
    master.allocations = value.(master.model[:is_allocated]) .> 0.5
    master.rescues = value.(master.model[:θ])
    # master.metrics.execution_time = execution_time
    master.metrics.objective_value = nb_rescues(master)
    push!(master.history, deepcopy(master.metrics))

    return Solution(method, master, instance, execution_time)
end

function get_cut(::Callback, ::Optimality, scenario::Int64, master::MasterProblem, expression::AffExpr)
    factor = -1 # because of the objective (min -x)
    
    return @build_constraint(expression <= factor * master.model[:θ][scenario])
end

function get_cut(::Callback, ::Feasibility, scenario::Int64, master::MasterProblem, expression::AffExpr)
    return @build_constraint(expression <= 0)
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

