using CuArrays.CUDNN: @check, libcudnn, cudnnStatus_t, libcudnn_handle,
  cudnnDataType, TensorDesc, FilterDesc

mutable struct DropoutDesc
  ptr::Ptr{Void}
  states::CuVector{UInt8}
end

Base.unsafe_convert(::Type{Ptr{Void}}, dd::DropoutDesc) = dd.ptr

function DropoutDesc(ρ::Real; seed::Integer=0)
  d = [C_NULL]
  s = Csize_t[0]
  @check ccall((:cudnnCreateDropoutDescriptor,libcudnn), cudnnStatus_t, (Ptr{Ptr{Void}},), d)
  @check ccall((:cudnnDropoutGetStatesSize,libcudnn),cudnnStatus_t,(Ptr{Void},Ptr{Csize_t}),libcudnn_handle[],s)
  states = CuArray{UInt8}(s[]) # TODO: can we drop this when ρ=0?
  desc = DropoutDesc(d[], states)
  @check ccall((:cudnnSetDropoutDescriptor,libcudnn),cudnnStatus_t,(Ptr{Void},Ptr{Void},Cfloat,Ptr{Void},Csize_t,Culonglong),
    desc,libcudnn_handle[],ρ,states,length(states),seed)
  finalizer(desc, x ->
    @check ccall((:cudnnDestroyDropoutDescriptor,libcudnn),cudnnStatus_t,(Ptr{Void},),x))
  return desc
end

const RNN_RELU = 0 # Stock RNN with ReLu activation
const RNN_TANH = 1 # Stock RNN with tanh activation
const LSTM = 2     # LSTM with no peephole connections
const GRU = 3      # Using h' = tanh(r * Uh(t-1) + Wx) and h = (1 - z) * h' + z * h(t-1)

const LINEAR_INPUT = 0
const SKIP_INPUT = 1

const UNIDIRECTIONAL = 0
const BIDIRECTIONAL = 1

const RNN_ALGO_STANDARD = 0
const RNN_ALGO_PERSIST_STATIC = 1
const RNN_ALGO_PERSIST_DYNAMIC = 2

mutable struct RNNDesc
  T::Type
  input::Int
  hidden::Int
  ptr::Ptr{Void}
end

Base.unsafe_convert(::Type{Ptr{Void}}, d::RNNDesc) = d.ptr

function RNNDesc(T::Type, mode::Int, input::Int, hidden::Int; layers = 1)
  d = [C_NULL]
  @check ccall((:cudnnCreateRNNDescriptor,libcudnn),cudnnStatus_t,(Ptr{Ptr{Void}},),d)
  rd = RNNDesc(T, input, hidden, d[])
  finalizer(rd, x ->
    @check ccall((:cudnnDestroyRNNDescriptor,libcudnn),cudnnStatus_t,(Ptr{Void},),x))

  dropoutDesc = DropoutDesc(0)
  inputMode = LINEAR_INPUT
  direction = UNIDIRECTIONAL
  algo = RNN_ALGO_STANDARD
  @check ccall((:cudnnSetRNNDescriptor_v6,libcudnn), cudnnStatus_t, (Ptr{Void},Ptr{Void},Cint,Cint,Ptr{Void},Cint,Cint,Cint,Cint,Cint),
    libcudnn_handle[],rd,hidden,layers,dropoutDesc,inputMode,direction,mode,algo,cudnnDataType(rd.T))
  return rd
end

function rnnWorkspaceSize(r::RNNDesc)
  size = Csize_t[0]
  @check ccall((:cudnnGetRNNWorkspaceSize, libcudnn), cudnnStatus_t, (Ptr{Void},Ptr{Void},Cint,Ptr{Ptr{Void}},Ptr{Csize_t}),
    libcudnn_handle[], r, 1, [TensorDesc(r.T, (1,r.input,1))], size)
  return Int(size[])
end

function rnnTrainingReserveSize(r::RNNDesc)
  size = Csize_t[0]
  @check ccall((:cudnnGetRNNTrainingReserveSize,libcudnn), cudnnStatus_t, (Ptr{Void}, Ptr{Void}, Cint, Ptr{Ptr{Void}}, Ptr{Csize_t}),
    libcudnn_handle[], r, 1, [TensorDesc(r.T, (1,r.input,1))], size)
  return Int(size[])
end

function rnnParamSize(r::RNNDesc)
  size = Csize_t[0]
  @check ccall((:cudnnGetRNNParamsSize, libcudnn), cudnnStatus_t, (Ptr{Void},Ptr{Void},Ptr{Void},Ptr{Csize_t},Cint),
    libcudnn_handle[], r, TensorDesc(r.T, (1,r.input,1)), size, cudnnDataType(r.T))
  return Int(size[])÷sizeof(r.T)
end

# param layout:
# RNN: [weight, bias] × [input, hidden]
# GRU: [weight, bias] × [input, hidden] × [reset, update, newmem]
# LSTM: [weight, bias] × [input, hidden] × [input, forget, newmem, output]

function rnnMatrixOffset(r::RNNDesc, w::CuArray, param; layer = 1)
  ptr = [C_NULL]
  desc = FilterDesc(CuArrays.CUDNN.createFilterDesc())
  @check ccall((:cudnnGetRNNLinLayerMatrixParams,libcudnn), cudnnStatus_t, (Ptr{Void},Ptr{Void},Cint,Ptr{Void},Ptr{Void},Ptr{Void},Cint,Ptr{Void},Ptr{Ptr{Void}}),
    libcudnn_handle[], r, layer-1, TensorDesc(r.T, (1,r.input,1)), FilterDesc(reshape(w, 1, 1, :)), w, param-1, desc, ptr)
  offset = ptr[]-Base.cconvert(Ptr{Void},w).ptr
  CuArrays.CUDNN.free(desc)
  return Int(offset)÷sizeof(r.T)
end

function rnnBiasOffset(r::RNNDesc, w::CuArray, param; layer = 1)
  ptr = [C_NULL]
  desc = FilterDesc(CuArrays.CUDNN.createFilterDesc())
  @check ccall((:cudnnGetRNNLinLayerBiasParams,libcudnn), cudnnStatus_t, (Ptr{Void},Ptr{Void},Cint,Ptr{Void},Ptr{Void},Ptr{Void},Cint,Ptr{Void},Ptr{Ptr{Void}}),
    libcudnn_handle[], r, layer-1, TensorDesc(r.T, (1,r.input,1)), FilterDesc(reshape(w, 1, 1, :)), w, param-1, desc, ptr)
  offset = ptr[]-Base.cconvert(Ptr{Void},w).ptr
  dims = size(desc)
  CuArrays.CUDNN.free(desc)
  return Int(offset)÷sizeof(r.T)
end
