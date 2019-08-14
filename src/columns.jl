# to get rid of eventually
const Columns = StructVector

# IndexedTable-like API

"""
    colnames(itr)

Returns the names of the "columns" in `itr`.

# Examples:

    colnames(1:3)
    colnames(Columns([1,2,3], [3,4,5]))
    colnames(table([1,2,3], [3,4,5]))
    colnames(Columns(x=[1,2,3], y=[3,4,5]))
    colnames(table([1,2,3], [3,4,5], names=[:x,:y]))
    colnames(ndsparse(Columns(x=[1,2,3]), Columns(y=[3,4,5])))
    colnames(ndsparse(Columns(x=[1,2,3]), [3,4,5]))
    colnames(ndsparse(Columns(x=[1,2,3]), [3,4,5]))
    colnames(ndsparse(Columns([1,2,3], [4,5,6]), Columns(x=[6,7,8])))
    colnames(ndsparse(Columns(x=[1,2,3]), Columns([3,4,5],[6,7,8])))

"""
function colnames end

Base.@pure colnames(t::AbstractVector) = (1,)
columns(v::AbstractVector) = v

Base.@pure colnames(t::Columns) = fieldnames(eltype(t))
Base.@pure colnames(t::Columns{<:Pair}) = colnames(t.first) => colnames(t.second)

"""
    columns(itr, select::Selection = All())

Select one or more columns from an iterable of rows as a tuple of vectors.

`select` specifies which columns to select. Refer to the [`select`](@ref) function for the
available selection options and syntax.

`itr` can be `NDSparse`, `Columns`, `AbstractVector`, or their distributed counterparts.

# Examples

    t = table(1:2, 3:4; names = [:x, :y])

    columns(t)
    columns(t, :x)
    columns(t, (:x,))
    columns(t, (:y, :x => -))
"""
function columns end

columns(c::Columns) = fieldarrays(c)
columns(c::Columns{<:Tuple}) = Tuple(fieldarrays(c))
columns(c::Columns{<:Pair}) = c.first => c.second

"""
    ncols(itr)

Returns the number of columns in `itr`.

# Examples

    ncols([1,2,3]) == 1
    ncols(rows(([1,2,3],[4,5,6]))) == 2
"""
function ncols end
ncols(c::Columns{T, C}) where {T, C} = fieldcount(C)
ncols(c::Columns{<:Pair}) = ncols(c.first) => ncols(c.second)
ncols(c::AbstractArray) = 1

summary(c::Columns{D}) where {D<:Tuple} = "$(length(c))-element Columns{$D}"

_sizehint!(c::Columns, n::Integer) = (foreach(x->_sizehint!(x,n), columns(c)); c)

function _strip_pair(c::Columns{<:Pair})
    f, s = map(columns, fieldarrays(c))
    (f isa AbstractVector) && (f = (f,))
    (s isa AbstractVector) && (s = (s,))
    Columns((f..., s...))
end

# fused indexing operations
# these can be implemented for custom vector types like PooledVector where
# you can get big speedups by doing indexing and an operation in one step.

@inline copyelt!(a, i, j) = (@inbounds a[i] = a[j])
@inline copyelt!(a, i, b, j) = (@inbounds a[i] = b[j])
@inline copyelt!(a::PooledArray, i, j) = (a.refs[i] = a.refs[j])

# row operations

copyrow!(I::Columns, i, src) = foreach(c->copyelt!(c, i, src), columns(I))
copyrow!(I::Columns, i, src::Columns, j) = foreach((c1,c2)->copyelt!(c1, i, c2, j), columns(I), columns(src))
copyrow!(I::AbstractArray, i, src::AbstractArray, j) = (@inbounds I[i] = src[j])
pushrow!(to::Columns, from::Columns, i) = foreach((a,b)->push!(a, b[i]), columns(to), columns(from))
pushrow!(to::AbstractArray, from::AbstractArray, i) = push!(to, from[i])

# test that the row on the right is "as of" the row on the left, i.e.
# all columns are equal except left >= right in last column.
# Could be generalized to some number of trailing columns, but I don't
# know whether that has applications.
@generated function row_asof(c::Columns{D,C}, i, d::Columns{D,C}, j) where {D,C}
    N = length(C.parameters)
    if N == 1
        ex = :(!isless(getfield(fieldarrays(c),1)[i], getfield(fieldarrays(d),1)[j]))
    else
        ex = :(isequal(getfield(fieldarrays(c),1)[i], getfield(fieldarrays(d),1)[j]))
    end
    for n in 2:N
        if N == n
            ex = :(($ex) && !isless(getfield(fieldarrays(c),$n)[i], getfield(fieldarrays(d),$n)[j]))
        else
            ex = :(($ex) && isequal(getfield(fieldarrays(c),$n)[i], getfield(fieldarrays(d),$n)[j]))
        end
    end
    ex
end

# map

"""
    map_rows(f, c...)

Transform collection `c` by applying `f` to each element. For multiple collection arguments, apply `f`
elementwise. Collect output as `Columns` if `f` returns
`Tuples` or `NamedTuples` with constant fields, as `Array` otherwise.

# Examples

    map_rows(i -> (exp = exp(i), log = log(i)), 1:5)
"""
function map_rows(f, iters...)
    collect_columns(f(i...) for i in zip(iters...))
end

# 1-arg case
map_rows(f, iter) = collect_columns(f(i) for i in iter)

## Special selectors to simplify column selector

"""
    Not(cols::Union{Symbol, Int}...)

Select the complementary of the selection in `cols`. `Not` can accept several arguments,
in which case it returns the complementary of the union of the selections.

# Examples

    t = table([1,1,2,2], [1,2,1,2], [1,2,3,4], names=[:a,:b,:c], pkey = (:a, :b))
    select(t, Not(:a))
    select(t, Not(:a, (:a, :b)))
"""
struct Not{T}
    cols::T
end

@deprecate Not(args...) Not(All(args...))

"""
    Keys()

Select the primary keys.

# Examples

    t = table([1,1,2,2], [1,2,1,2], [1,2,3,4], names=[:a,:b,:c], pkey = (:a, :b))
    select(t, Keys())
"""
struct Keys; end

const SpecialSelector = Union{Not, All, Keys, Between, Function, Regex, Type}

hascolumns(t, s) = true
hascolumns(t, s::Symbol) = s in colnames(t)
hascolumns(t, s::Int) = s in 1:length(columns(t))
hascolumns(t, s::Tuple) = all(hascolumns(t, x) for x in s)
hascolumns(t, s::Not) = hascolumns(t, s.cols)
hascolumns(t, s::Between) = hascolumns(t, s.first) && hascolumns(t, s.last)
hascolumns(t, s::All) = all(hascolumns(t, x) for x in s.cols)
hascolumns(t, s::Type) = any(x -> eltype(x) <: s, columns(t))

lowerselection(t, s)                     = s
lowerselection(t, s::Union{Int, Symbol}) = colindex(t, s)
lowerselection(t, s::Tuple)              = map(x -> lowerselection(t, x), s)
lowerselection(t, s::Not)                = excludecols(t, lowerselection(t, s.cols))
lowerselection(t, s::Keys)               = lowerselection(t, IndexedTables.pkeynames(t))
lowerselection(t, s::Between)            = Tuple(colindex(t, s.first):colindex(t, s.last))
lowerselection(t, s::Function)           = colindex(t, Tuple(filter(s, collect(colnames(t)))))
lowerselection(t, s::Regex)              = lowerselection(t, x -> occursin(s, string(x)))
lowerselection(t, s::Type)               = Tuple(findall(x -> eltype(x) <: s, columns(t)))

function lowerselection(t, s::All)
    s.cols == () && return lowerselection(t, valuenames(t))
    ls = (isa(i, Tuple) ? i : (i,) for i in lowerselection(t, s.cols))
    ls |> Iterators.flatten |> union |> Tuple
end

### Iteration API

# For `columns(t, names)` and `rows(t, ...)` to work, `t`
# needs to support `colnames` and `columns(t)`

Base.@pure function colindex(t, col::Tuple)
    fns = colnames(t)
    map(x -> _colindex(fns, x), col)
end

Base.@pure function colindex(t, col)
    _colindex(colnames(t), col)
end

function colindex(t, col::SpecialSelector)
    colindex(t, lowerselection(t, col))
end

function _colindex(fnames::Union{Tuple, AbstractArray}, col, default=nothing)
    if isa(col, Int) && 1 <= col <= length(fnames)
        return col
    elseif isa(col, Symbol)
        idx = something(findfirst(isequal(col), fnames), 0)
        idx > 0 && return idx
    elseif isa(col, Pair{<:Any, <:AbstractArray})
        return 0
    elseif isa(col, Tuple)
        return 0
    elseif isa(col, Pair{Symbol, <:Pair}) # recursive pairs
        return _colindex(fnames, col[2])
    elseif isa(col, Pair{<:Any, <:Any})
        return _colindex(fnames, col[1])
    elseif isa(col, AbstractArray)
        return 0
    end
    default !== nothing ? default : error("column $col not found.")
end

# const ColPicker = Union{Int, Symbol, Pair{Symbol=>Function}, Pair{Symbol=>AbstractVector}, AbstractVector}
column(c, x) = columns(c)[colindex(c, x)]

# optimized method
@inline function column(c::Columns, x::Union{Int, Symbol})
    getfield(fieldarrays(c), x)
end

column(t, a::AbstractArray) = a
column(t, a::Pair{Symbol, <:AbstractArray}) = column(t, a[2])
column(t, a::Pair{Symbol, <:Pair}) = rows(t, a[2]) # renaming a selection
column(t, a::Pair{<:Any, <:Any}) = map(a[2], rows(t, a[1]))
column(t, s::SpecialSelector) = rows(t, lowerselection(t, s))

function columns(c, sel::Union{Tuple, SpecialSelector})
    which = lowerselection(c, sel)
    cnames = colnames(c, which)
    if all(x->isa(x, Symbol), cnames)
        tuplewrap = namedtuple(cnames...)∘tuple
    else
        tuplewrap = tuple
    end
    tuplewrap((rows(c, w) for w in which)...)
end

"""
`columns(itr, which)`

Returns a vector or a tuple of vectors from the iterator.

"""
columns(t, which) = column(t, which)

function colnames(c, cols::Union{Tuple, AbstractArray})
    map(x->colname(c, x), cols)
end

colnames(c, cols::SpecialSelector) = colnames(c, lowerselection(c, cols))

function colname(c, col)
    if isa(col, Union{Int, Symbol})
        col == 0 && return 0
        i = colindex(c, col)
        return colnames(c)[i]
    elseif isa(col, Pair{<:Any, <:Any})
        return col[1]
    elseif isa(col, Tuple)
        #ns = map(x->colname(c, x), col)
        return 0
    elseif isa(col, SpecialSelector)
        return 0
    elseif isa(col, AbstractVector)
        return 0
    end
    error("column named $col not found")
end

"""
    rows(itr, select = All())

Select one or more fields from an iterable of rows as a vector of their values.  Refer to
the [`select`](@ref) function for selection options and syntax.

`itr` can be [`NDSparse`](@ref), `StructArrays.StructVector`, `AbstractVector`, or their distributed counterparts.

# Examples

    t = table([1,2],[3,4], names=[:x,:y])
    rows(t)
    rows(t, :x)
    rows(t, (:x,))
    rows(t, (:y, :x => -))
"""
function rows end

rows(x::AbstractVector) = x
rows(cols::Tup) = Columns(cols)

rows(t, which...) = rows(columns(t, which...))

# Replace empty Columns object with one of correct length and eltype
replace_placeholder(t, ::Columns{Tuple{}}) = fill(Tuple(), length(t))
replace_placeholder(t, ::Columns{NamedTuple{(), Tuple{}}}) = fill(NamedTuple(), length(t))
replace_placeholder(t, cols) = cols

_cols_tuple(xs::Columns) = columns(xs)
_cols_tuple(xs::AbstractArray) = (xs,)
concat_cols(xs, ys) = rows(concat_tup(_cols_tuple(xs), _cols_tuple(ys)))

## Mutable Columns Dictionary

mutable struct ColDict{T}
    pkey::Vector{Int}
    src::T
    names::Vector
    columns::Vector
    copy::Union{Nothing, Bool}
end

"""
    d = ColDict(t)

Create a mutable dictionary of columns in `t`.

To get the immutable iterator of the same type as `t`
call `d[]`
"""
function ColDict(t; copy=nothing)
    cnames = colnames(t)
    if cnames isa AbstractArray
        cnames = Base.copy(cnames)
    end
    ColDict(Int[], t, convert(Array{Any}, collect(cnames)), Any[columns(t)...], copy)
end

Base.keys(d::ColDict) = d.names
Base.values(d::ColDict) = d.columns

function Base.getindex(d::ColDict{<:Columns})
    Columns(Tuple(d.columns); names=d.names)
end

Base.getindex(d::ColDict, key) = rows(d[], key)
Base.getindex(d::ColDict, key::AbstractArray) = key

function Base.setindex!(d::ColDict, x, key::Union{Symbol, Integer})
    k = _colindex(d.names, key, 0)
    col = d[x]
    if k == 0
        push!(d.names, key)
        push!(d.columns, col)
    elseif k in d.pkey
        # primary key column has been modified.
        # copy the table as this results in a shuffle
        if d.copy === nothing
            d.copy = true
        end
        d.columns[k] = col
    else
        d.columns[k] = col
    end
end

Base.@deprecate set!(d::ColDict, key, x) setindex!(d, x, key)

transform!(d::ColDict, changes::Pair...) = transform!(d, changes)

function transform!(d::ColDict, changes)
    Base.foreach(changes) do (key, val)::Pair
        d[key] = val
    end
end

function Base.haskey(d::ColDict, key)
    _colindex(d.names, key, 0) != 0
end

function Base.insert!(d::ColDict, index::Integer, (key, col)::Pair)
    if haskey(d, key)
        error("Key $key already exists. Use dict[key] = col instead of inserting.")
    else
        insert!(d.names, index, key)
        insert!(d.columns, index, rows(d.src, col))
        for (i, pk) in enumerate(d.pkey)
            if pk >= index
                d.pkey[i] += 1 # moved right
            end
        end
    end
end

function Base.insert!(d::ColDict, index::Integer, newcols)
    for new::Pair in newcols
        insert!(d, index, new)
        index += 1
    end
end

Base.insert!(d::ColDict, index::Integer, newcols::Pair...) = insert!(d, index, newcols)

function insertafter!(d::ColDict, i, args...)
    k = _colindex(d.names, i, 0)
    if k == 0
        error("$i not found. Cannot insert column after $i")
    end
    insert!(d, k+1, args...)
end

function insertbefore!(d::ColDict, i, args...)
    k = _colindex(d.names, i, 0)
    if k == 0
        error("$i not found. Cannot insert column after $i")
    end
    insert!(d, k, args...)
end

function rename!(d::ColDict, (col, newname)::Pair)
    k = _colindex(d.names, col, 0)
    if k == 0
        error("$col not found. Cannot rename it.")
    end
    d.names[k] = newname
end

@deprecate rename!(t::ColDict, col::Union{Symbol, Integer}, newname) rename!(t, col => newname)

rename!(t::ColDict, changes) = Base.foreach(change::Pair -> rename!(t, change), changes)
rename!(t::ColDict, changes::Pair...) = rename!(t, changes)

function Base.push!(d::ColDict, (key, x)::Pair)
    push!(d.names, key)
    push!(d.columns, rows(d.src, x))
end

function _cols(expr)
    if expr.head == :call
        dict = :(dict = ColDict($(expr.args[2])))
        expr.args[2] = :dict
        quote
            let $dict
                $expr
                dict[]
            end
        end |> esc
    else
        error("This form of @cols is not implemented. Use `@cols f(t,args...)` where `t` is the collection.")
    end
end

macro cols(expr)
    _cols(expr)
end

# Modifying columns

"""
    transform(t::Table, changes::Pair...)

Transform columns of `t`. For each pair `col => value` in `changes` the column `col` is replaced
by the `AbstractVector` `value`. If `col` is not an existing column, a new column is created.

# Examples:

    t = table([1,2], [3,4], names=[:x, :y])

    # change second column to [5,6]
    transform(t, 2 => [5,6])
    transform(t, :y => :y => x -> x + 2)

    # add [5,6] as column :z
    transform(t, :z => 5:6)
    transform(t, :z => :y => x -> x + 2)

    # replacing the primary key results in a re-sorted copy
    t = table([0.01, 0.05], [1,2], [3,4], names=[:t, :x, :y], pkey=:t)
    t2 = transform(t, :t => [0.1,0.05])

    # the column :z is not part of t so a new column is added
    t = table([0.01, 0.05], [2,1], [3,4], names=[:t, :x, :y], pkey=:t)
    pushcol(t, :z => [1//2, 3//4])
"""
transform(t, args...) = @cols transform!(t, args...)

@deprecate setcol(t, args::Pair...) transform(t, args...)
@deprecate setcol(t, key::Union{Int, Symbol}, val) transform(t, key => val)
@deprecate setcol(t, args) transform(t, args)

@deprecate pushcol(t, args::Pair...) transform(t, args...)
@deprecate pushcol(t, key::Union{Int, Symbol}, val) transform(t, key => val)
@deprecate pushcol(t, args) transform(t, args)

@deprecate popcol(t, args...) select(t, Not(args...))
@deprecate popcol(t) select(t, Not(ncols(t)))

"""
    insertcols(t, position::Integer, map::Pair...)

For each pair `name => col` in `map`, insert a column `col` named `name` starting at `position`.
Returns a new table.

# Example

    t = table([0.01, 0.05], [2,1], [3,4], names=[:t, :x, :y], pkey=:t)
    insertcol(t, 2, :w => [0,1])
"""
insertcols(t, i::Integer, args...) = @cols insert!(t, i, args...)

@deprecate insertcol(t, i, name, x) insertcols(t, i, name => x)

"""
    insertcolsafter(t, after, map::Pair...)

For each pair `name => col` in `map`, insert a column `col` named `name` after `after`.
Returns a new table.

# Example

    t = table([0.01, 0.05], [2,1], [3,4], names=[:t, :x, :y], pkey=:t)
    insertcolsafter(t, :t, :w => [0,1])
"""
insertcolsafter(t, after, args...) = @cols insertafter!(t, after, args...)

@deprecate insertcolafter(t, i, name, x) insertcolsafter(t, i, name => x)

"""
insertcolsbefore(t, before, map::Pair...)

For each pair `name => col` in `map`, insert a column `col` named `name` before `before`.
Returns a new table.

# Example

    t = table([0.01, 0.05], [2,1], [3,4], names=[:t, :x, :y], pkey=:t)
    insertcolsbefore(t, :x, :w => [0,1])
"""
insertcolsbefore(t, before, args...) = @cols insertbefore!(t, before, args...)

@deprecate insertcolbefore(t, i, name, x) insertcolsbefore(t, i, name => x)

"""
    rename(t, map::Pair...)

For each pair `col => newname` in `map`, set `newname` as the new name for column `col` in `t`.
Returns a new table.

# Example

    t = table([0.01, 0.05], [2,1], names=[:t, :x])
    rename(t, :t => :time)
"""
rename(t, args...) = @cols rename!(t, args...)

@deprecate renamecol(t, args...) rename(t, args...)

## Utilities for mapping and reduction with many functions / OnlineStats

@inline _apply(f::OnlineStat, g, x) = (fit!(g, x); g)
@inline _apply(f::Tup, y::Tup, x::Tup) = _apply(astuple(f), astuple(y), astuple(x))
@inline _apply(f::Tuple, y::Tuple, x::Tuple) = map(_apply, f, y, x)
@inline _apply(f::NamedTuple, y::NamedTuple, x::NamedTuple) = map(_apply, f, y, x)
@inline _apply(f, y, x) = f(y, x)
@inline _apply(f::Tup, x::Tup) = _apply(astuple(f), astuple(x))
@inline _apply(f::NamedTuple, x::NamedTuple) = map(_apply, f, x)
@inline _apply(f::Tuple, x::Tuple) = map(_apply, f, x)
@inline _apply(f, x) = f(x)

@inline init_first(f, x) = x
@inline init_first(f::OnlineStat, x) = (g=copy(f); fit!(g, x); g)
@inline init_first(f::Tup, x::Tup) = map(init_first, f, x)

# Initialize functions to apply and input vectors

function init_inputs(f, x, isvec) # normal functions
    f, x
end

nicename(f::Function) = typeof(f).name.mt.name
nicename(f) = Symbol(last(split(string(f), ".")))
nicename(o::OnlineStat) = Symbol(typeof(o).name.name)

init_funcs(f, isvec) = init_funcs((f,), isvec)

function init_funcs(f::Tup, isvec)
    if isa(f, NamedTuple)
        return init_funcs((map(Pair, fieldnames(typeof(f)), f)...,), isvec)
    end

    funcmap = map(f) do g
        if isa(g, Pair)
            name = g[1]
            if isa(g[2], Pair)
                sel, fn = g[2]
            else
                sel = nothing
                fn = g[2]
            end
            (name, sel, fn)
        else
            (nicename(g), nothing, g)
        end
    end

    ns = map(x->x[1], funcmap)
    ss = map(x->x[2], funcmap)
    fs = map(map(x->x[3], funcmap)) do f
        f
    end

    NamedTuple{(ns...,)}((fs...,)), ss
end

function init_inputs(f::Tup, input, isvec)
    if isa(f, NamedTuple)
        return init_inputs((map(Pair, fieldnames(typeof(f)), f)...,), input, isvec)
    end
    fs, selectors = init_funcs(f, isvec)

    xs = map(s->s === nothing ? input : rows(input, s), selectors)

    ns = fieldnames(typeof(fs))
    NT = namedtuple(ns...)

    # functions and input
    NT((fs...,)), rows(NT((xs...,)))
end

# utils
refs(v::Columns) = Columns(map(refs, fieldarrays(v)))
compact_mem(v::Columns) = replace_storage(compact_mem, v)
