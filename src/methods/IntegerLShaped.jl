struct Node
    ID::Int64
    master::Model
    metrics::Metrics
end

"""
    solve(::IntegerLShaped)

Solve the problem using the Integer L-shaped method, which considers the integrality constraint.
This method is based on the branch-and-cut algorithm.
We start by solving the linear relaxation of the master problem.
If the solution is integer, then we have found the optimal solution.
Otherwise, we select a branching variable and create two nodes, one for each subproblem with the upper and lower bound constraints.

This new subproblems are solved, evaluate if they should be pruned or not, and repeat the process until all nodes are pruned.
Therefore, the stop criteria is based on the quantity of pendant nodes and on the number of iterations.
To determine whether a node should be pruned or not, we use three criteria: infeasibility, bound and integrality.
In other words, we prune a node if it is infeasible or unbounded, or if the all variables are integer or if there exists a better solution (lower bound).
The search criteria is breadth-first search, which means that we select the node with the best objective value over the set of pendant nodes.
Finally, we use a random criteria to select the non-integer variable to branch on.
"""
function solve(method::IntegerLShaped, instance::Instance, solver::SOLVER)::Solution
    start = time()
    best_solution = nothing
    initial_solution = solve(LShaped(), instance, solver, Iterative())
    is_feasible(method, initial_solution.model) && return initial_solution

    iteration, node_id = 1, 1
    pendant_nodes = [Node(node_id, initial_solution.model, initial_solution.metrics)]
    historical_nodes = deepcopy(pendant_nodes)

    while should_continue(method, iteration, pendant_nodes)
        key = "$(str(method)) | Iteration $(iteration)"
        @info "$(key) | Pendant nodes" IDs(pendant_nodes)

        best_solution = get_best_node(historical_nodes).metrics.objective_value
        
        # Breadth-first search: select the node with the best objective value
        sort!(pendant_nodes, by=node -> node.metrics.objective_value, rev=false)
        current_node = first(pendant_nodes) # "Current Problem"

        if should_prune(method, current_node.master, best_solution)
            prune!(current_node, pendant_nodes)

            @info "$(key) | Node $(current_node.ID) has been pruned"
            continue
        end

        # Branching procedure: evaluate new nodes
        add_cuts!(method, current_node, best_solution, pendant_nodes, historical_nodes, node_id)
        @info "$(key) | Iteration $(iteration) completed | Cuts added"
        iteration += 1
    end

    best_solution = get_best_node(historical_nodes)
    solve!(method, best_solution, best_solution.metrics.objective_value, pendant_nodes, historical_nodes)
    @info "$(str(method)) | Tree search completed | Best solution"
    
    return Solution(
        method,
        best_solution,
        instance,
        time() - start,
    )
end

"""
    solve!(::Node)

Solve the master problem of a given node.
"""
function solve!(
    method::IntegerLShaped,
    node::Node,
    best_solution::Real,
    pendant_nodes::Vector{Node},
    historical_nodes::Vector{Node}
)::Nothing
    try
        solve!(node.master)
    catch err
        @error "Node $(node.ID) : $(err)"

        return nothing
    end

    if !(should_prune(method, node.master, best_solution))
        push!(pendant_nodes, node)
        push!(historical_nodes, node)

        @info " | Node $(node.ID) created and added to pendant nodes"
    else
        @info " | Node $(node.ID) has been pruned"
    end

    return nothing
end

"""
    add_cuts!(::IntegerLShaped)

Contains the branching procedure of (randomly) selecting a branching variable, creating two nodes
for each subproblem and solving them.
"""
function add_cuts!(method::IntegerLShaped, current_node::Node, best_solution::Real, pendant_nodes::Vector{Node}, historical_nodes::Vector{Node}, node_id::Int64)::Nothing
    # Select branching variable
    branching_variable = select_branching_variable(current_node.master)
    variable_value = value(branching_variable)
    @info " | Branching on $(branching_variable)<>$(variable_value)"

    # Add two new nodes to the tree: lower and upper
    node_id += 1
    lower_node = Node(node_id, copy(current_node.master), deepcopy(current_node.metrics))
    node_id += 1
    upper_node = Node(node_id, copy(current_node.master), deepcopy(current_node.metrics))

    # Add constraints to the lower nodes and solve it
    @constraint(
        lower_node.master,
        variable_by_name(lower_node.master, string(branching_variable))
        <= floor(variable_value)
    )
    solve!(method, lower_node, best_solution, pendant_nodes, historical_nodes)

    # Add constraints to the upper nodes and solve it
    @constraint(
        upper_node.master,
        variable_by_name(upper_node.master, string(branching_variable))
        >= ceil(variable_value)
    )
    solve!(method, upper_node, best_solution, pendant_nodes, historical_nodes)

    return nothing
end

"""
    should_prune(::IntegerLShaped)

Determine if a node should be pruned from the tree based on the three criteria: infeasibility, bound and integrality.
In other words, we prune a node if it is infeasible or unbounded, or if the all variables are integer or if there exists a better solution (lower bound).
"""
function should_prune(method::IntegerLShaped, model::Model, best_solution::Real)::Bool
    is_unfeasible = termination_status(model) == MOI.INFEASIBLE_OR_UNBOUNDED
    is_unfeasible && return true

    all_integer = is_feasible(method, model)
    all_integer && return true

    current_value = objective_value(model)
    current_value > best_solution && return true

    return false
end

"""
    is_feasible(::IntegerLShaped)

Integrality check for the master problem.
"""
function is_feasible(::IntegerLShaped, model::Model)::Bool
    is_allocated_integer = is_integer(value.(model[:is_allocated]))
    is_rescues_integer = is_integer(value.(model[:θ]))

    return is_allocated_integer && is_rescues_integer
end

"""
    select_branching_variable(::IntegerLShaped)

Randomly selects a branching variable from the set of non-integer variable values.
"""
function select_branching_variable(model::Model)::VariableRef
    alternatives = filter(
        variable -> !(is_integer(value.(variable))),
        all_variables(model)
    )

    return first(sample(alternatives, 1, replace=false))
end

"""
    should_continue(::IntegerLShaped)

The stop criteria for the Integer L-shaped method is based on the number of iterations and the number of pendant nodes.
"""
function should_continue(::IntegerLShaped, iteration::Int64, pendant_nodes::Vector{Node})::Bool
    iteration > MAX_SEARCH_ITERATIONS && return false

    is_search_complete = isempty(pendant_nodes)
    is_search_complete && return false

    return true
end

function prune!(node::Node, pendant_nodes::Vector{Node})
    initial_length = length(pendant_nodes)
    filter!(n -> n.ID != node.ID, pendant_nodes)

    is_pruned = length(pendant_nodes) == initial_length - 1
    !(is_pruned) && error("Node $(node.ID) could not be pruned from $(IDs(pendant_nodes))")
end

function get_best_node(nodes::Vector{Node})::Node
    _, idx = findmin(node -> node.metrics.objective_value, nodes)

    return nodes[idx]
end

IDs(nodes::Vector{Node}) = [node.ID for node in nodes]

function Solution(
    method::IntegerLShaped,
    node::Node,
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
        if value(node.master[:is_allocated][s, t]) > 0.5
    ]

    for scenario_idx in scenarios
        scenario_id = "$(SCENARIO_PREFIX)$(scenario_idx)"
        nb_rescues = value(node.master[:θ][scenario_idx])
        nb_rescues <= 0 && continue

        for s in sites
            allocation = filter(a -> a.site == instance.sites[s], allocations)
            isempty(allocation) && continue

            push!(assignments, Assignment(scenario_id, first(allocation), nb_rescues))
        end
    end
    
    metrics = Metrics(
        objective_value=round(Int64, node.metrics.objective_value),
        execution_time=execution_time,
    )
    solution = Solution(method, node.master, allocations, assignments, metrics)
    validate(solution)

    return solution
end
