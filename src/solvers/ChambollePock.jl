@doc raw"""
    ChambollePock(M, N, cost, x0, ξ0, m, n, prox_F, prox_G_dual, forward_operator, adjoint_DΛ)

Perform the Riemannian Chambolle–Pock algorithm.

Given a `cost` function $\mathcal E\colon\mathcal M \to ℝ$ of the form
```math
\mathcal E(x) = F(x) + G( Λ(x) ),
```
where $F\colon\mathcal M \to ℝ$, $G\colon\mathcal N \to ℝ$,
and $\Lambda\colon\mathcal M \to \mathcal N$. The remaining input parameters are

* `x,ξ` primal and dual start points $x\in\mathcal M$ and $\xi\in T_n\mathcal N$
* `m,n` base points on $\mathcal M$ and $\mathcal N$, respectively.
* `forward_operator` the operator $Λ(⋅)$ or its linearization $DΛ(⋅)[⋅]$, depending on whether `:exact` or `:linearized` is chosen.
* `adjoint_linearized_operator` the adjoint $DΛ^*$ of the linearized operator $DΛ(m)\colon T_{m}\mathcal M \to T_{Λ(m)}\mathcal N$
* `prox_F, prox_G_Dual` the proximal maps of $F$ and $G^\ast_n$

By default, this performs the exact Riemannian Chambolle Pock algorithm, see the opional parameter
`DΛ` for ther linearized variant.

For more details on the algorithm, see[^BHLSTVN2020].

# Optional Parameters

* `acceleration` – (`0.05`)
* `dual_stepsize` – (`1/sqrt(8)`)
* `Λ` (`missing`) the exact operator, that is required if the forward operator is linearized;
  `missing` indicates, that the forward operator is exact.
* `primal_stepsize` – (`1/sqrt(8)`)
* `relaxation` – (`1.`)
* `relax` – (`:primal`) whether to relax the primal or dual
* `type` - (`:exact` if `Λ` is missing, otherwise `:linearized`) variant to use.
  Note that this changes the arguments the `forward_operator` will be called with ()
* `stopping_criterion` – (`stopAtIteration(100)`) a [`StoppingCriterion`](@ref)
* `update_primal_base` – (`missing`) function to update `m` (identity by default/missing)
* `update_dual_base` – (`missing`) function to update `n` (identity by default/missing)

[^BHLSTVN2020]:
    > R. Bergmann, R. Herzog, M. Silva Louzeiro, D. Tenbrinck, J. Vidal-Núñez:
    > Fenchel Duality Theory and a Primal-Dual Algorithm on Riemannian Manifolds
    > arXiv: [1908.02022](http://arxiv.org/abs/1908.02022)
    > accepted for publication in Foundadtions of Computational Mathematics
"""
function ChambollePock(
    M::mT,
    N::nT,
    cost::Function,
    x::P,
    ξ::T,
    m::P,
    n::Q,
    prox_F::Function,
    prox_G_dual::Function,
    forward_operator::Function,
    adjoint_DΛ::Function;
    acceleration = 0.05,
    dual_stepsize = 1/sqrt(8),
    Λ::Union{Function,Missing}=missing,
    primal_stepsize = 1/sqrt(8),
    relaxation = 1.0,
    relax::Symbol = :primal,
    stopping_criterion::StoppingCriterion = stopAfterIteration(200),
    update_primal_base::Union{Function,Missing} = missing,
    update_dual_base::Union{Function,Missing} = missing,
    type = ismissing(Λ) ? :exact : :linearized,
    return_options=false,
    kwargs...
) where {mT <: Manifold, nT <: Manifold,P,Q,T}
    p = PrimalDualProblem(M, N, cost, prox_F, prox_G_dual, forward_operator, adjoint_DΛ, Λ)
    o = ChambollePockOptions(m,n,x,ξ, primal_stepsize, dual_stepsize;
        acceleration = acceleration,
        relaxation= relaxation,
        stopping_criterion = stopping_criterion,
        relax = relax,
        update_primal_base = update_primal_base,
        update_dual_base = update_dual_base,
        type = type
    )
    o = decorate_options(o; kwargs...)
    resultO = solve(p, o)
    if return_options
        return resultO
    else
        return get_solver_result(resultO)
    end
end

function initialize_solver!(::PrimalDualProblem, ::ChambollePockOptions)
end

function step_solver!(p::PrimalDualProblem, o::ChambollePockOptions, iter)
   primal_dual_step!(p, o, Val(o.relax))
   o.m = ismissing(o.update_primal_base) ? o.m : o.update_primal_base(p, o, iter)
   if !ismissing(o.update_dual_base)
        n_old = deepcopy(o.n)
        o.n = o.update_dual_base(p, o, iter)
        vector_transport_to!(p.N, o.ξ, n_old, o.ξ, o.n,)
        vector_transport_to!(p.N, o.ξbar, n_old, o.ξbar, o.nTransport())
   end
   return o
end
#
# Variant 1: primal relax
#
function primal_dual_step!(
    p::PrimalDualProblem,
    o::ChambollePockOptions,
    ::Val{:primal}
    )
    dual_update!(p, o, o.xbar, Val(o.type))
    ptξn = ismissing(p.Λ) ? o.ξ : vector_transport_to(p.N, o.n, o.ξ, p.Λ(o.m))
    xOld = o.x
    o.x = o.prox_F(p.M, o.m, o.primal_stepsize,
        exp(
            p.M,
            o.x,
            vector_transport_to(
                p.M,
                o.m,
                - o.primal_stepsize * ( p.adjoint_linearized_operator(o.m, ptξn) ),
                o.x
            )
        )
    )
    update_prox_parameters!(o)
    o.xbar = exp(p.M,o.x, - o.relaxation * log(p.M, o.x, xOld ) )
    return o
end
#
# Variant 2: dual relax
#
function primal_dual_step!(
    p::PrimalDualProblem,
    o::ChambollePockOptions,
    ::Val{:dual}
    )
    ptξbar = ismissing(p.Λ) ? o.ξbar : vector_transport_to(p.N, o.n, o.ξbar, p.Λ(o.m))
    o.x = p.prox_F(
        p.M,
        o.m,
        o.primal_stepsize,
        exp(
            p.M,
            o.x,
            vector_transport_to(
                p.M,
                o.m,
                - o.primal_stepsize * ( p.adjoint_linearized_operator(o.m, ptξbar) ),
                o.x,
            )
        )
    )
    ξ_old = o.ξ
    dual_update!(p, o, o.x, Val(o.type))
    update_prox_parameters!(o)
    o.ξbar = o.ξ + o.relaxation * (o.ξ - ξ_old)
    return o
end
#
# Dual step: linearized
# depending on whether its primal relaxed or dual relaxed we start from start=o.x or start=o.xbar here
#
function dual_update!(p::PrimalDualProblem, o::ChambollePockOptions, start::P, ::Val{:linearized}) where {P}
    # (1) compute update direction
    ξUpdate = p.forward_operator(o.m, log(p.M, o.m, start))
    # (2) if p.Λ is missing, we assume that n = Λ(m) and do  not PT, otherwise we do
    ξUpdate = ismissing(p.Λ) ? ξUpdate : vector_transport_to(p.N,p.Λ(o.m),ξUpdate,o.n)
    # (3) to the dual update
    o.ξ = p.prox_G_dual(p.N, o.n, o.dual_stepsize, o.ξ + o.dual_stepsize * ξUpdate)
    return o
end
#
# Dual step: exact
# depending on whether its primal relaxed or dual relaxed we start from start=o.x or start=o.xbar here
#
function dual_update!(p::PrimalDualProblem, o::ChambollePockOptions, start::P, ::Val{:exact}) where {P}
    o.ξ = p.prox_G_dual(
        p.N,
        o.n,
        o.dual_stepsize,
        o.ξ + o.dual_stepsize * log(p.N,o.n, p.forward_operator(start))
    )
    return o
end

@doc raw"""
    update_prox_parameters!(o)
update the prox parameters as described in Algorithm 2 of Chambolle, Pock, 2010, i.e.
1. $\theta_{n} = \frac{1}{\sqrt{1+2\gamma\tau_n}}$
2. $\tau_{n+1} = \theta_n\tau_n$
3. $\sigma_{n+1} = \frac{\sigma_n}{\theta_n}$
"""
function update_prox_parameters!(o::O) where {O <: PrimalDualOptions}
    if o.acceleration > 0
        o.relaxation = 1/sqrt(1+2*o.acceleration * o.primal_stepsize)
        o.primal_stepsize = o.primal_stepsize * o.relaxation
        o.dual_stepsize = o.dual_stepsize/o.relaxation
    end
    return o
end