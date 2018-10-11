# ------------------------------------------------------------------
# Copyright (c) 2015, Júlio Hoffimann Mendes <juliohm@stanford.edu>
# Licensed under the ISC License. See LICENCE in the project root.
# ------------------------------------------------------------------

"""
    iqsim(trainimg::AbstractArray{T,N},
          tilesize::Dims{N}, gridsize::Dims{N};
          overlap::NTuple{N,Float64}=ntuple(i->1/6,N),
          soft::AbstractVector=[], hard::HardData=HardData(), tol::Real=.1,
          cut::Symbol=:boykov, path::Symbol=:rasterup, nreal::Integer=1,
          threads::Integer=cpucores(), gpu::Bool=false,
          debug::Bool=false, showprogress::Bool=false)

Performs image quilting simulation as described in Hoffimann et al. 2017.

## Parameters

### Required

* `trainimg` is any 3D array (add ghost dimension for 2D)
* `tilesize` is the tile size (or pattern size)
* `gridsize` is the size of the simulation grid

### Optional

* `overlap` is the percentage of overlap
* `soft` is a vector of `(data,dataTI)` pairs
* `hard` is an instance of `HardData`
* `tol` is the initial relaxation tolerance in (0,1] (default to .1)
* `cut` is the cut algorithm (`:dijkstra` or `:boykov`)
* `path` is the simulation path (`:rasterup`, `:rasterdown`, `:dilation` or `:random`)
* `nreal` is the number of realizations
* `threads` is the number of threads for the FFT (default to all CPU cores)
* `gpu` informs whether to use the GPU or the CPU
* `debug` informs whether to export or not the boundary cuts and voxel reuse
* `showprogress` informs whether to show or not estimated time duration

The main output `reals` consists of a list of 3D realizations that can be indexed with
`reals[1], reals[2], ..., reals[nreal]`. If `debug=true`, additional output is generated:

```julia
reals, cuts, voxs = iqsim(..., debug=true)
```

`cuts[i]` is the boundary cut for `reals[i]` and `voxs[i]` is the associated voxel reuse.
"""
function iqsim(trainimg::AbstractArray{T,N},
               tilesize::Dims{N}, gridsize::Dims{N};
               overlap::NTuple{N,Float64}=ntuple(i->1/6,N),
               soft::AbstractVector=[], hard::HardData=HardData(), tol::Real=.1,
               cut::Symbol=:boykov, path::Symbol=:rasterup, nreal::Integer=1,
               threads::Integer=cpucores(), gpu::Bool=false,
               debug::Bool=false, showprogress::Bool=false) where {T,N}

  # number of threads in FFTW
  set_num_threads(threads)

  # sanity checks
  @assert ndims(trainimg) == 3 "image is not 3D (add ghost dimension for 2D)"
  @assert all(0 .< tilesize .≤ size(trainimg)) "invalid tile size"
  @assert all(gridsize .≥ tilesize) "invalid grid size"
  @assert all(0 .< overlap .< 1) "overlaps must be in range (0,1)"
  @assert 0 < tol ≤ 1 "tolerance must be in range (0,1]"
  @assert cut ∈ [:dijkstra,:boykov] "invalid cut algorithm"
  @assert path ∈ [:rasterup,:rasterdown,:dilation,:random] "invalid simulation path"
  @assert nreal > 0 "invalid number of realizations"

  # soft data checks
  if !isempty(soft)
    for (aux, auxTI) in soft
      @assert ndims(aux) == 3 "soft data is not 3D (add ghost dimension for 2D)"
      @assert all(size(aux) .≥ gridsize) "soft data size < grid size"
      @assert size(auxTI) == size(trainimg) "auxiliary TI must have the same size as TI"
    end
  end

  # hard data checks
  if !isempty(hard)
    coordinates = [coord[i] for i in 1:N, coord in coords(hard)]
    @assert all(maximum(coordinates, dims=2) .≤ gridsize) "hard data coordinates outside of grid"
    @assert all(minimum(coordinates, dims=2) .> 0) "hard data coordinates must be positive indices"
  end

  # calculate the overlap size from given percentage
  ovlsize = @. ceil(Int, overlap*tilesize)

  # spacing in raster path
  spacing = @. tilesize - ovlsize

  # calculate the number of tiles from grid size
  ntiles = @. ceil(Int, gridsize / max(spacing, 1))

  # simulation grid dimensions
  padsize = @. ntiles*(tilesize - ovlsize) + ovlsize

  # total overlap volume in simulation grid
  ovlvol = prod(padsize) - prod(@. padsize - (ntiles - 1)*ovlsize)

  # warn in case of 1-voxel overlaps
  if any((tilesize .>  1) .& (ovlsize .== 1))
    @warn "Overlaps with only 1 voxel, check tilesize/overlap configuration"
  end

  # always work with floating point
  TI = Float64.(trainimg)
  TIsize = size(trainimg)

  # inactive voxels in the training image
  NaNTI = isnan.(TI); TI[NaNTI] .= 0

  # disable tiles in the training image if they contain inactive voxels
  disabled = Vector{CartesianIndex{N}}()
  for ind in findall(NaNTI)
    start  = @. max(ind.I - tilesize + 1, 1)
    finish = @. min(ind.I, TIsize - tilesize + 1)
    tile   = CartesianIndices(ntuple(i -> start[i]:finish[i], N))
    append!(disabled, tile)
  end

  # keep track of hard data and inactive voxels
  datum = Vector{CartesianIndex{N}}()
  skipped = Set{CartesianIndex{N}}()
  if !isempty(hard)
    # hard data in grid format
    hardgrid = zeros(padsize)
    preset = falses(padsize)
    activated = trues(padsize)
    for coord in coords(hard)
      if isnan(hard[coord])
        activated[coord] = false
      else
        hardgrid[coord] = hard[coord]
        preset[coord] = true
      end
    end

    # deactivate voxels beyond true grid size
    activated[gridsize[1]+1:padsize[1],:,:] .= false
    activated[:,gridsize[2]+1:padsize[2],:] .= false
    activated[:,:,gridsize[3]+1:padsize[3]] .= false

    # grid must contain active voxels
    any_activated = any(activated[CartesianIndices(gridsize)])
    @assert any_activated "simulation grid has no active voxel"

    # determine tiles that should be skipped and tiles with data
    for tileind in CartesianIndices(ntiles)
      # tile corners are given by start and finish
      start  = @. (tileind.I - 1)*spacing + 1
      finish = @. start + tilesize - 1
      tile   = CartesianIndices(ntuple(i -> start[i]:finish[i], N))

      if all(.!activated[tile])
        push!(skipped, tileind)
      else
        if any(preset[tile])
          push!(datum, tileind)
        end
      end
    end
  end

  # preprocess soft data
  softgrid = Vector{Array{Float64,N}}()
  softTI   = Vector{Array{Float64,N}}()
  if !isempty(soft)
    for (aux, auxTI) in soft
      auxpad = padsize .- min.(padsize, size(aux))

      AUX = padarray(aux, Pad(:symmetric, ntuple(i->0,N), auxpad))
      AUX = parent(AUX)
      AUX[isnan.(AUX)] .= 0

      AUXTI = copy(auxTI)
      AUXTI[NaNTI] .= 0

      # always work with floating point
      AUX   = Float64.(AUX)
      AUXTI = Float64.(AUXTI)

      push!(softgrid, AUX)
      push!(softTI, AUXTI)
    end
  end

  # overwrite path option if data is available
  !isempty(datum) && (path = :datum)

  # select cut algorithm
  boundary_cut = cut == :dijkstra ? dijkstra_cut : boykov_kolmogorov_cut

  # main output is a vector of 3D grids
  realizations = Vector{Array{Float64,N}}()

  # for each realization we have:
  boundarycuts = Vector{Array{Float64,N}}()
  voxelreuse   = Vector{Float64}()

  # show progress and estimated time duration
  showprogress && (progress = Progress(nreal))

  # preallocate memory for distance calculations
  distance = Array{Float64}(undef, TIsize .- tilesize .+ 1)

  for real=1:nreal
    # allocate memory for current simulation
    simgrid = zeros(padsize)
    debug && (cutgrid = zeros(padsize))

    # keep track of pasted tiles
    pasted = Set{CartesianIndex{N}}()

    # construct simulation path
    simpath = genpath(ntiles, path, datum)

    # loop simulation grid tile by tile
    for ind in simpath
      tileind = lin2cart(ntiles, ind)

      # skip tile if all voxels are inactive
      tileind ∈ skipped && continue

      # if not skipped, proceed and paste tile
      push!(pasted, tileind)

      # tile corners are given by start and finish
      start  = @. (tileind.I - 1)*spacing + 1
      finish = @. start + tilesize - 1
      tile   = CartesianIndices(ntuple(i -> start[i]:finish[i], N))

      # current simulation dataevent
      simdev = view(simgrid, tile)

      i, j, k = Tuple(tileind) # TODO: remove this line

      # compute overlap distance
      distance .= 0
      if ovlsize[1] > 1 && CartesianIndex(i-1,j,k) ∈ pasted
        ovx = view(simdev,1:ovlsize[1],:,:)
        D = convdist(TI, ovx)
        distance .+= view(D,1:TIsize[1]-tilesize[1]+1,:,:)
      end
      if ovlsize[1] > 1 && CartesianIndex(i+1,j,k) ∈ pasted
        ovx = view(simdev,spacing[1]+1:tilesize[1],:,:)
        D = convdist(TI, ovx)
        distance .+= view(D,spacing[1]+1:TIsize[1]-ovlsize[1]+1,:,:)
      end
      if ovlsize[2] > 1 && CartesianIndex(i,j-1,k) ∈ pasted
        ovy = view(simdev,:,1:ovlsize[2],:)
        D = convdist(TI, ovy)
        distance .+= view(D,:,1:TIsize[2]-tilesize[2]+1,:)
      end
      if ovlsize[2] > 1 && CartesianIndex(i,j+1,k) ∈ pasted
        ovy = view(simdev,:,spacing[2]+1:tilesize[2],:)
        D = convdist(TI, ovy)
        distance .+= view(D,:,spacing[2]+1:TIsize[2]-ovlsize[2]+1,:)
      end
      if ovlsize[3] > 1 && CartesianIndex(i,j,k-1) ∈ pasted
        ovz = view(simdev,:,:,1:ovlsize[3])
        D = convdist(TI, ovz)
        distance .+= view(D,:,:,1:TIsize[3]-tilesize[3]+1)
      end
      if ovlsize[3] > 1 && CartesianIndex(i,j,k+1) ∈ pasted
        ovz = view(simdev,:,:,spacing[3]+1:tilesize[3])
        D = convdist(TI, ovz)
        distance .+= view(D,:,:,spacing[3]+1:TIsize[3]-ovlsize[3]+1)
      end

      # disable dataevents that contain inactive voxels
      distance[disabled] .= Inf

      # compute hard and soft distances
      auxdistances = Vector{Array{Float64,N}}()
      if !isempty(hard) && any(preset[tile])
        harddev = hardgrid[tile]
        D = convdist(TI, harddev, weights=preset[tile])

        # disable dataevents that contain inactive voxels
        D[disabled] .= Inf

        # swap overlap and hard distances
        push!(auxdistances, distance)
        distance = D
      end
      for n=1:length(softTI)
        softdev = softgrid[n][tile]
        D = convdist(softTI[n], softdev)

        # disable dataevents that contain inactive voxels
        D[disabled] .= Inf

        push!(auxdistances, D)
      end

      # current pattern database
      patterndb = isempty(auxdistances) ? findall(vec(distance .≤ (1+tol)minimum(distance))) :
                                          relaxation(distance, auxdistances, tol)

      # pattern probability
      patternprobs = tau_model(patterndb, distance, auxdistances)

      # pick a pattern at random from the database
      rind = sample(patterndb, weights(patternprobs))
      start  = lin2cart(size(distance), rind)
      finish = @. start.I + tilesize - 1
      rtile  = CartesianIndices(ntuple(i -> start[i]:finish[i], N))

      # selected training image dataevent
      TIdev = view(TI, rtile)

      # boundary cut mask
      M = falses(size(simdev))
      if ovlsize[1] > 1 && CartesianIndex(i-1,j,k) ∈ pasted
        A = view(simdev,1:ovlsize[1],:,:); B = view(TIdev,1:ovlsize[1],:,:)
        M[1:ovlsize[1],:,:] .|= boundary_cut(A, B, :x)
      end
      if ovlsize[1] > 1 && CartesianIndex(i+1,j,k) ∈ pasted
        A = view(simdev,spacing[1]+1:tilesize[1],:,:); B = view(TIdev,spacing[1]+1:tilesize[1],:,:)
        M[spacing[1]+1:tilesize[1],:,:] .|= reverse(boundary_cut(reverse(A, dims=1), reverse(B, dims=1), :x), dims=1)
      end
      if ovlsize[2] > 1 && CartesianIndex(i,j-1,k) ∈ pasted
        A = view(simdev,:,1:ovlsize[2],:); B = view(TIdev,:,1:ovlsize[2],:)
        M[:,1:ovlsize[2],:] .|= boundary_cut(A, B, :y)
      end
      if ovlsize[2] > 1 && CartesianIndex(i,j+1,k) ∈ pasted
        A = view(simdev,:,spacing[2]+1:tilesize[2],:); B = view(TIdev,:,spacing[2]+1:tilesize[2],:)
        M[:,spacing[2]+1:tilesize[2],:] .|= reverse(boundary_cut(reverse(A, dims=2), reverse(B, dims=2), :y), dims=2)
      end
      if ovlsize[3] > 1 && CartesianIndex(i,j,k-1) ∈ pasted
        A = view(simdev,:,:,1:ovlsize[3]); B = view(TIdev,:,:,1:ovlsize[3])
        M[:,:,1:ovlsize[3]] .|= boundary_cut(A, B, :z)
      end
      if ovlsize[3] > 1 && CartesianIndex(i,j,k+1) ∈ pasted
        A = view(simdev,:,:,spacing[3]+1:tilesize[3]); B = view(TIdev,:,:,spacing[3]+1:tilesize[3])
        M[:,:,spacing[3]+1:tilesize[3]] .|= reverse(boundary_cut(reverse(A, dims=3), reverse(B, dims=3), :z), dims=3)
      end

      # paste quilted pattern from training image
      simdev[.!M] = TIdev[.!M]

      # save boundary cut
      debug && (cutgrid[tile] = M)
    end

    # save voxel reuse
    debug && push!(voxelreuse, sum(cutgrid)/ovlvol)

    # hard data and shape correction
    if !isempty(hard)
      simgrid[preset] = hardgrid[preset]
      simgrid[.!activated] .= NaN
      debug && (cutgrid[.!activated] .= NaN)
    end

    # throw away voxels that are outside of the grid
    simgrid = view(simgrid,1:gridsize[1],1:gridsize[2],1:gridsize[3])
    debug && (cutgrid = view(cutgrid,1:gridsize[1],1:gridsize[2],1:gridsize[3]))

    # save and continue
    push!(realizations, simgrid)
    debug && push!(boundarycuts, cutgrid)

    # update progress bar
    showprogress && next!(progress)
  end

  debug ? (realizations, boundarycuts, voxelreuse) : realizations
end
