import Polynomials
using Base.MathConstants

function E₁_cfpoly_approx(n::Integer, pstart::Polynomials.Polynomial{T}, ::Type{T}=BigInt) where {T<:Real}
    q = Polynomials.Polynomial(T[1])
    p = pstart
    x = Polynomials.Polynomial(T[0,1])
    for i = n:-1:1
        p, q = x*p+(1+i)*q, p # from cf = x + (1+i)/cf = x + (1+i)*q/p
        p, q = p + i*q, p     # from cf = 1 + i/cf = 1 + i*q/p
    end
    # do final 1/(x + inv(cf)) = 1/(x + q/p) = p/(x*p + q)
    return p, x*p + q
end

macro E₁_cf64(x, n::Integer, start)
    pstart = Polynomials.Polynomial(eval(start))
    # consider using BigFloat?
    p, q = E₁_cfpoly_approx(n, pstart, Float64)
    xesc = esc(x)
    
    num_expr =  :(@evalpoly $xesc)
    append!(num_expr.args, Float64.(Polynomials.coeffs(p)))
    den_expr = :(@evalpoly $xesc)
    append!(den_expr.args, Float64.(Polynomials.coeffs(q)))
    :( exp(-$xesc) * $num_expr / $den_expr )
end


function E₁_taylor_coefficients(::Type{T}, n::Integer) where {T<:Number}
    n < 0 && throw(ArgumentError("$n ≥ 0 is required"))
    n == 0 && return T[]
    n == 1 && return T[-eulergamma]
    # iteratively compute the terms in the series, starting with k=1
    term::T = 1
    terms = T[-eulergamma, term]
    for k=2:n
        term = -term * (k-1) / (k * k)
        push!(terms, term)
    end
    return terms
end

# inline the Taylor expansion for a given order n, in double precision
macro E₁_taylor64(z, n::Integer)
    c = E₁_taylor_coefficients(Float64, n)
    zesc = esc(z)
    taylor = :(@evalpoly $zesc)
    append!(taylor.args, c)
    :( $taylor - log($zesc) )
end

E₁(x::Real) = E₁(float(x))

function E₁(x::Float64)
    x < 0 && throw(DomainError(x, "negative argument"))
    x == 0 && return Inf
    if x > 2.15
        # specially chosen approximants for faster convergence
        x < 3.0   && return @E₁_cf64(x, 18, [6.267445506556548, -2.278962735947262, 0.5577231261815463, -0.05413049191473329])
        x < 4.0   && return @E₁_cf64(x, 16, [5.114292670961982, -1.2789140459431323, 0.22066200334871455, -0.015067049382830766])
        x < 6.1   && return @E₁_cf64(x, 14, [4.194988480897909, -0.7263593325667503, 0.08956574399359891, -0.00434973529065973])
        x < 8.15  && return @E₁_cf64(x, 9,  [3.0362016309948228, -0.33793806630590445, 0.029410409377178114, -0.0010060498260648586])
        x < 25.0  && return @E₁_cf64(x, 8,  [2.5382065303376895, -0.18352177433259526, 0.011141562002742184, -0.0002634921890930066])
        x < 200.0 && return @E₁_cf64(x, 8,  [0.0, 1.0])
        return x < 740.0 ? @E₁_cf64(x, 4, [0.0, 1.0]) : 0.0 # underflow
    else
        # crossover point to taylor should be tuned more
        return x ≤ 0.6 ? (x ≤ 0.053 ? (x ≤ 4.4e-3 ? @E₁_taylor64(x,4) :
                                                       @E₁_taylor64(x,8)) :
                                       @E₁_taylor64(x,15)) :
                          @E₁_taylor64(x,37)
    end
end

# Continued fraction for En(ν, z) that doesn't use a term with
# the gamma function: https://functions.wolfram.com/GammaBetaErf/ExpIntegralE/10/0001/
function En_cf_nogamma(ν::Number, z::Number, n::Int=1000)
    B = float(z + ν)
    Bprev::typeof(B) = z
    A::typeof(B) = 1
    Aprev::typeof(B) = 1
    ϵ = 10*eps(real(B))
    
    # two recurrence steps / loop
    iters = 0
    for i = 2:n
        iters += 1

        A′ = A
        A = z*A + (i-1) * Aprev
        Aprev = A′
        B′ = B
        B = z*B + (i-1) * Bprev
        Bprev = B′
        
        A′ = A
        A = A + (ν+i-1) * Aprev
        Aprev = A′
        B′ = B
        B = B + (ν+i-1) * Bprev
        Bprev = B′
        
        conv = abs(Aprev*B - A*Bprev) < ϵ*abs(B*Bprev)
        conv && break
        
        # rescale 
        if max(abs(real(A)), abs(imag(A))) > 1e50
            A /= 1e50
            Aprev /= 1e50
            B /= 1e50
            Bprev /= 1e50
        end
    end
    
    cfpart = A/B
    exppart = exp(-z)
    if abs(real(exppart)) == Inf && abs(imag(exppart)) == Inf
        # "factor" out Inf to avoid NaN
        factor = sign(real(exppart)) + sign(imag(exppart))*im
        return Inf * (factor * cfpart), iters
    else
        return cfpart * exppart, iters
    end
end

# Calculate Γ(1 - ν) * z^(ν-1) safely
function En_safe_gamma_term(ν::Number, z::Number)
    g = gamma(1 - ν)
    p = float(z)^(ν - 1)
    if abs(g) == Inf || abs(p) == Inf
        return exp((ν - 1)*log(complex(z)) + loggamma(1 - ν))
    else
        if g == 0
            return 0
        else
            return g*p
        end
    end
end

# continued fraction for En(ν, z) that uses the gamma function:
# https://functions.wolfram.com/GammaBetaErf/ExpIntegralE/10/0005/
# returns the two terms from the above equation separately
function En_cf_gamma(ν::Number, z::Number, n::Int=1000)
    A = float(1 - ν)
    B::typeof(A) = 1
    Bprev::typeof(A) = 0
    Aprev::typeof(A) = 1
    ϵ = 10*eps(real(B))
    
    iters = 0
    j = 1
    for i = 2:n
        iters += 1

        A′ = A
        term = iseven(i) ? (i - 1 - ν)*z : z
        A = (i - ν)*A - term * Aprev
        Aprev = A′
        B′ = B
        B = (i - ν)*B - term * Bprev
        Bprev = B′
        
        conv = abs(Aprev*B - A*Bprev) < ϵ*abs(B*Bprev)
        conv && break

        if max(abs(real(A)), abs(imag(A))) > 1e50
            A /= 1e50
            Aprev /= 1e50
            B /= 1e50
            Bprev /= 1e50
        end
    end
    
    gammapart = En_safe_gamma_term(ν, z)
    cfpart = -exp(-z)*A/B
    return gammapart, cfpart, iters
end

# picks between continued fraction representations in 
# En_cf_nogamma and En_cf_gamma
# returns (evaluated result, # iterations used, whether En_cf_gamma was chosen)
function En_cf(ν::Number, z::Number, niter::Int=1000)
    gammapart, cfpart, iters = En_cf_gamma(ν, z, niter)
    gammaabs, cfabs = abs(gammapart), abs(cfpart)
    if gammaabs != Inf && gammaabs > 1.0 && gammaabs > cfabs
        # significant gamma part, use this
        return gammapart + cfpart, iters, true
    else
        return En_cf_nogamma(ν, z, niter)..., false
    end
end

# Compute expint(ν, z₀+Δ) given start = expint(ν, z₀), as described by [Amos 1980]
function En_taylor(ν::Number, start::Number, z₀::Number, Δ::Number)
    a = exp(z₀) * start
    k, iters = 0, 0
    asum = a
    Δ_prod_fact = -Δ
    ϵ = 10*eps(real(asum))
    
    for k = 0:100
        a_pre = Δ_prod_fact + a*Δ*(ν - k - 1)/(k + 1)
        a = a_pre / z₀
        asum_prev = asum
        asum += a
        
        if abs(asum_prev - asum) < ϵ
            break
        end
        
        Δ_prod_fact *= -Δ / (k + 2)
        
        #iters += 1
        #k += 1
    end

    res = exp(-z₀) * asum
    return res
end

# series about origin, general ν
# https://functions.wolfram.com/GammaBetaErf/ExpIntegralE/06/01/04/01/01/0003/
function En_expand_origin(ν::Number, z::Number)
    if isinteger(ν)
        # go to special case for integer ν
        return En_expand_origin(Int(ν), z)
    end
    gammaterm = En_safe_gamma_term(ν, z)
    frac = 1
    sumterm = frac / (1 - ν)
    k, maxiter = 1, 100
    ϵ = 10*eps(real(sumterm))
    while k < maxiter
        frac *= -z / k
        prev = sumterm
        sumterm += frac / (k + 1 - ν)
        if abs(sumterm - prev) < ϵ
            break
        end
        k += 1
    end
    
    return gammaterm - sumterm
end

# series about the origin, special case for integer n
# https://functions.wolfram.com/GammaBetaErf/ExpIntegralE/06/01/04/01/02/0005/
function En_expand_origin(n::Integer, z::Number)
    gammaterm = 1
    # (-z)^(n-1) / (n-1)!
    for i = 1:n-1
        gammaterm *= -x / i
    end

    gammaterm *= digamma(n) - log(z)
    sumterm = n == 1 ? 0 : 1 / (1 - n)
    frac = 1
    k, maxiter = 1, 100
    ϵ = 10*eps(real(sumterm))
    while k < maxiter
        frac *= -z / k
        # skip term with zero denominator
        if k != n-1
            prev = sumterm
            sumterm += frac / (k + 1 - n)
            if abs(sumterm - prev) < ϵ
                break
            end
        end
        k += 1
    end
    return gammaterm - sumterm
end

# can find imaginary part of E_ν(x) for x on negative real axis analytically
# https://functions.wolfram.com/GammaBetaErf/ExpIntegralE/04/05/01/0003/
function En_imagbranchcut(ν::Number, z::Number)
    a = real(z)
    impart = π * im * exp(-π*im*ν) * a^(ν-1) / gamma(ν)
    # exp(n*log(z) - loggamma(n))
    return imag(impart) * im # get rid of any real error
end

const ORIGIN_EXPAND_THRESH = 3
"""
    En(ν, z)

Compute the exponential integral of complex `z` with complex order `ν`.
"""
function En(ν::Number, z::Number, niter::Int=1000)
    if z == 0.0
        if real(ν) > 0
            return 1.0 / (ν - 1)
        else
            return Inf
        end
    end
    if ν == 0
        return exp(-z) / z
    end
    # asymptotic test for |z| → ∞
    # https://functions.wolfram.com/GammaBetaErf/ExpIntegralE/06/02/0003/
    if exp(-z) / z == 0
        return zero(z)
    end

    if abs(z) < ORIGIN_EXPAND_THRESH
        # use Taylor series about the origin for small z
        return En_expand_origin(ν, z)
    end
    E_guess, _, g = En_cf(ν, z, niter)
    if g
        return E_guess
    end
    if real(z) > 0
        res, i, _ = En_cf(ν, z, niter)
        return res
    elseif real(z) < 0
        doconj = imag(z) < 0
        rez, imz = real(z), abs(imag(z))
        z = doconj ? conj(z) : z
        ν = doconj ? conj(ν) : ν
        
        # empirical boundary for 500 iterations
        boundary = min(1 + 0.5*abs(ν), 50)
        if imz > boundary
            res, i, _ = En_cf(ν, z, niter)
            return doconj ? conj(res) : res
        else
            # iterate with taylor
            # first find starting point
            # TODO: switch back to CF for large ν
            imstart = boundary
            z₀ = rez + imstart*im
            E_start, i, _ = En_cf(ν, z₀, niter)
            while i >= niter
                imstart *= 2
                z₀ = rez + imstart*im
                E_start, i, _ = En_cf(ν, z₀, niter)
            end
            
            # nsteps chosen so |Δ| ≤ 0.5
            nsteps = ceil(2 * (imstart - imz))
            Δ = (imz - imstart)*im / nsteps

            for j = 1:nsteps
                # take Δ sized steps towards the desired z
                E_start = En_taylor(ν, E_start, z₀, Δ)
                z₀ += Δ
            end
            
            # more exact imaginary part available for non-integer ν
            if imz == 0
                E_start = real(E_start) + En_imagbranchcut(ν, z)
            end
            
            return doconj ? conj(E_start) : E_start
        end
    end
end
