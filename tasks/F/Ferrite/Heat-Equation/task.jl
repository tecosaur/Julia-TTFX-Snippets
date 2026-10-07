# Task: Heat Equation
# Package: Ferrite
# Author: @KristofferC
# Created: 2026-10-07
# Sample timings: install in 35.1s, run in 13.582s

__t1 = time()

using Ferrite

__t2 = time()

function solve_heat()
    grid = generate_grid(Quadrilateral, (20, 20))
    ip = Lagrange{RefQuadrilateral, 1}()
    qr = QuadratureRule{RefQuadrilateral}(2)
    cellvalues = CellValues(qr, ip)

dh = DofHandler(grid)
    add!(dh, :u, ip)
    close!(dh)

ch = ConstraintHandler(dh)
    ∂Ω = union(getfacetset(grid, "left"), getfacetset(grid, "right"),
               getfacetset(grid, "top"), getfacetset(grid, "bottom"))
    add!(ch, Dirichlet(:u, ∂Ω, (x, t) -> 0.0))
    close!(ch)

K = allocate_matrix(dh)
    f = zeros(ndofs(dh))
    n = getnbasefunctions(cellvalues)
    Ke = zeros(n, n)
    fe = zeros(n)
    assembler = start_assemble(K, f)
    for cell in CellIterator(dh)
        reinit!(cellvalues, cell)
        fill!(Ke, 0)
        fill!(fe, 0)
        for q in 1:getnquadpoints(cellvalues)
            dΩ = getdetJdV(cellvalues, q)
            for i in 1:n
                δu = shape_value(cellvalues, q, i)
                ∇δu = shape_gradient(cellvalues, q, i)
                fe[i] += δu * dΩ
                for j in 1:n
                    ∇u = shape_gradient(cellvalues, q, j)
                    Ke[i, j] += (∇δu ⋅ ∇u) * dΩ
                end
            end
        end
        assemble!(assembler, celldofs(cell), Ke, fe)
    end
    apply!(K, f, ch)
    u = K \ f

VTKGridFile(joinpath(mktempdir(), "heat"), dh) do vtk
        write_solution(vtk, dh, u)
    end
    return u
end

u = solve_heat()

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

