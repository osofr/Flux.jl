# TODO: broadcasting cat
combine(x::AbstractMatrix, h::AbstractVector) = vcat(x, h .* trues(1, size(x, 2)))
combine(x::AbstractVector, h::AbstractVector) = vcat(x, h)
combine(x::AbstractMatrix, h::AbstractMatrix) = vcat(x, h)

# Stateful recurrence

"""
    Recur(cell)

`Recur` takes a recurrent cell and makes it stateful, managing the hidden state
in the background. `cell` should be a model of the form:

    h, y = cell(h, x...)

For example, here's a recurrent network that keeps a running total of its inputs.

```julia
accum(h, x) = (h+x, x)
rnn = Flux.Recur(accum, 0)
rnn(2) # 2
rnn(3) # 3
rnn.state # 5
rnn.(1:10) # apply to a sequence
rnn.state # 60
```
"""
mutable struct Recur{T}
  cell::T
  init
  state
end

Recur(m, h = hidden(m)) = Recur(m, h, h)

function (m::Recur)(xs...)
  h, y = m.cell(m.state, xs...)
  m.state = h
  return y
end

treelike(Recur)

Base.show(io::IO, m::Recur) = print(io, "Recur(", m.cell, ")")

_truncate(x::AbstractArray) = Tracker.data(x)
_truncate(x::Tuple) = _truncate.(x)

"""
    truncate!(rnn)

Truncates the gradient of the hidden state in recurrent layers. The value of the
state is preserved. See also `reset!`.

Assuming you have a `Recur` layer `rnn`, this is roughly equivalent to

    rnn.state = Tracker.data(rnn.state)
"""
truncate!(m) = prefor(x -> x isa Recur && (x.state = _truncate(x.state)), m)

"""
    reset!(rnn)

Reset the hidden state of a recurrent layer back to its original value. See also
`truncate!`.

Assuming you have a `Recur` layer `rnn`, this is roughly equivalent to

    rnn.state = hidden(rnn.cell)
"""
reset!(m) = prefor(x -> x isa Recur && (x.state = x.init), m)

flip(f, xs) = reverse(f.(reverse(xs)))

# Vanilla RNN

struct RNNCell{D,V}
  d::D
  h::V
end

RNNCell(in::Integer, out::Integer, σ = tanh; initW = glorot_uniform, initb = zeros) =
  RNNCell(Dense(in+out, out, σ, initW = initW, initb = initb), param(initW(out)))

function (m::RNNCell)(h, x)
  h = m.d(combine(x, h))
  return h, h
end

hidden(m::RNNCell) = m.h

treelike(RNNCell)

function Base.show(io::IO, m::RNNCell)
  print(io, "RNNCell(", m.d, ")")
end

"""
    RNN(in::Integer, out::Integer, σ = tanh)

The most basic recurrent layer; essentially acts as a `Dense` layer, but with the
output fed back into the input each time step.
"""
RNN(a...; ka...) = Recur(RNNCell(a...; ka...))

# LSTM

struct LSTMCell{D1,D2,V}
  forget::D1
  input::D1
  output::D1
  cell::D2
  h::V; c::V
end

function LSTMCell(in, out; initW = glorot_uniform, initb = zeros)
  cell = LSTMCell([Dense(in+out, out, σ, initW = initW, initb = initb) for _ = 1:3]...,
                  Dense(in+out, out, tanh, initW = initW, initb = initb),
                  param(initW(out)), param(initW(out)))
  cell.forget.b.data .= 1
  return cell
end

function (m::LSTMCell)(h_, x)
  h, c = h_
  x′ = combine(x, h)
  forget, input, output, cell =
    m.forget(x′), m.input(x′), m.output(x′), m.cell(x′)
  c = forget .* c .+ input .* cell
  h = output .* tanh.(c)
  return (h, c), h
end

hidden(m::LSTMCell) = (m.h, m.c)

treelike(LSTMCell)

Base.show(io::IO, m::LSTMCell) =
  print(io, "LSTMCell(",
        size(m.forget.W, 2) - size(m.forget.W, 1), ", ",
        size(m.forget.W, 1), ')')

"""
    LSTM(in::Integer, out::Integer, σ = tanh)

Long Short Term Memory recurrent layer. Behaves like an RNN but generally
exhibits a longer memory span over sequences.

See [this article](http://colah.github.io/posts/2015-08-Understanding-LSTMs/)
for a good overview of the internals.
"""
LSTM(a...; ka...) = Recur(LSTMCell(a...; ka...))

# GRU

struct GRUCell{D1,D2,V}
  update::D1
  reset::D1
  candidate::D2
  h::V
end

function GRUCell(in, out)
  cell = GRUCell(Dense(in+out, out, σ),
                 Dense(in+out, out, σ),
                 Dense(in+out, out, tanh),
                 param(initn(out)))
  return cell
end

function (m::GRUCell)(h, x)
  x′   = combine(x, h)
  z    = m.update(x′)
  r    = m.reset(x′)
  h̃    = m.candidate(combine(r.*h, x))
  h = (1.-z).*h .+ z.*h̃
  return h, h
end

hidden(m::GRUCell) = m.h

treelike(GRUCell)

Base.show(io::IO, m::GRUCell) =
  print(io, "GRUCell(",
        size(m.update.W, 2) - size(m.update.W, 1), ", ",
        size(m.update.W, 1), ')')

"""
    GRU(in::Integer, out::Integer, σ = tanh)

Gated Recurrent Unit layer. Behaves like an RNN but generally
exhibits a longer memory span over sequences.

See [this article](http://colah.github.io/posts/2015-08-Understanding-LSTMs/)
for a good overview of the internals.
"""
GRU(a...; ka...) = Recur(GRUCell(a...; ka...))
