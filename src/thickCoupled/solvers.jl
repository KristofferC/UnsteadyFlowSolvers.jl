function transpCoupled(surf::TwoDSurfThickBL, curfield::TwoDFlowField, ncell::Int64, nsteps::Int64 = 300, dtstar::Float64 = 0.015, startflag = 0, writeflag = 0, writeInterval = 1000., delvort = delNone(); maxwrite = 50, nround=6)

    # If a restart directory is provided, read in the simulation data
    if startflag == 0
        mat = zeros(0, 12)
        t = 0.

    elseif startflag == 1
        dirvec = readdir()
        dirresults = map(x->(v = tryparse(Float64,x); typeof(v) == Nothing ? 0.0 : v),dirvec)
        latestTime = maximum(dirresults)
        mat = DelimitedFiles.readdlm("resultsSummary")
        t = mat[end,1]
    else
        throw("invalid start flag, should be 0 or 1")
    end
    mat = mat'

    dt = dtstar*surf.c/surf.uref

    # if writeflag is on, determine the timesteps to write at
    if writeflag == 1
        writeArray = Int64[]
        tTot = nsteps*dt
        for i = 1:maxwrite
            tcur = writeInterval*real(i)
            if t > tTot
                break
            else
                push!(writeArray, Int(round(tcur/dt)))
            end
        end
    end

    vcore = 0.02*surf.c

    int_wax = zeros(surf.ndiv)
    int_c = zeros(surf.ndiv)
    int_t = zeros(surf.ndiv)

    for istep = 1:nsteps

        t = t + dt

        #Update kinematic parameters
        update_kinem(surf, t)

        #Update flow field parameters if any
        update_externalvel(curfield, t)

        #Update bound vortex positions
        update_boundpos(surf, dt)

        #Update incduced velocities on airfoil
        update_indbound(surf, curfield)

        #Set up the matrix problem
        surf, xloc_tev, zloc_tev = update_thickLHS(surf, curfield, dt, vcore)

        #Construct RHS vector
        update_thickRHS(surf, curfield)

        #Place dummy  TEV
        push!(curfield.tev, TwoDVort(xloc_tev, zloc_tev, 0.0, vcore, 0., 0.))

        if istep == 1
            surf.qu[:], surf.ql[:] = calc_edgeVel(surf, [curfield.u[1], curfield.w[1]])
            surf.quprev[:] = surf.qu[:]
            surf.qlprev[:] = surf.ql[:]
        end

        #Initial condition for iteration
        x_init = [surf.aterm[:]; surf.bterm[:]; curfield.tev[end].s]

        iter = iterIBLsolve(surf, curfield, dt)

        soln = nlsolve(not_in_place(iter), x_init, iterations=10)

        xsoln = soln.zero

        println("here")

        #Assign solution
        surf.aterm[:] = xsoln[1:surf.naterm]
        surf.bterm[:] = xsoln[surf.naterm+1:2*surf.naterm]
        curfield.tev[end].s = xsoln[2*surf.naterm+1]

        #Update BL solution
        #Derivatives of edge velocity
        quInter = Spline1D(surf.x, surf.qu)
        qx = derivative(quInter, surf.x)
        qt = (surf.qu .- surf.quprev)./dt
        xfvm, w0, quf, qut, qux = mappingAerofoilToFVGrid(surf.delu, surf.Eu, surf.qu, qx, qt, surf.theta, surf.nfvm)

        w, j1 ,j2 = FVMIBL(w0, quf, qut, qux, xfvm, dt);
        delf = w[:,1]
        Ef = (w[:,2]./w[:,1]) .- 1.0

        #Reconstruct back to airfoil coordinates

        delInter = Spline1D(xfvm, delf)
        surf.delu[:] = evaluate(delInter, surf.theta)
        surf.dell[:] = surf.delu[:]


        #Calculate adot
        update_atermdot(surf, dt)

        #Set previous values of aterm to be used for derivatives in next time step
        surf.a0prev[1] = surf.a0[1]
        for ia = 1:3
            surf.aprev[ia] = surf.aterm[ia]
        end

        surf.quprev[:] = surf.qu[:]
        surf.qlprev[:] = surf.ql[:]

        #Calculate bound vortex strengths
        update_bv_src(surf)

        #Add effect of transpiration to sources and vortices

        #Wake rollup
        wakeroll(surf, curfield, dt)

        #Force calculation
        cnc, cnnc, cn, cs, cl, cd, int_wax, int_c, int_t = calc_forces(surf, int_wax, int_c, int_t, dt)

        vle = surf.qu[1]

        if vle > 0.
            qspl = Spline1D(surf.x, surf.ql)
            stag = try
                roots(qspl, maxn=1)[1]
            catch
                0.
            end
        else
            qspl = Spline1D(surf.x, surf.qu)
            stag = try
                roots(qspl, maxn=1)[1]
            catch
                0.
            end
        end

        mat = hcat(mat,[t, surf.kinem.alpha, surf.kinem.h, surf.kinem.u, vle,
                     cl, cd, cnc, cnnc, cn, cs, stag])



    end

    mat = mat'

    f = open("resultsSummary", "w")
    Serialization.serialize(f, ["#time \t", "alpha (deg) \t", "h/c \t", "u/uref \t", "A0 \t", "Cl \t", "Cd \t", "Cm \n"])
    DelimitedFiles.writedlm(f, mat)
    close(f)

    return mat, surf, curfield

end
