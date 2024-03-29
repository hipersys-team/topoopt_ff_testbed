/* Copyright 2020 Stanford
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "model.h"
#include "cuda_helper.h"

Tensor FFModel::embedding(const Tensor& input,
                          int num_entries,
                          int out_dim,
                          AggrMode aggr,
                          const Op* shared_op,
                          Initializer* kernel_initializer,
                          const char* name)
{
  //assert(config.strategies.find(name) != config.strategies.end());
  //ParallelConfig pc = config.strategies[name];
  //IndexSpaceT<2> task_is = IndexSpaceT<2>(get_or_create_task_is(pc));
  Embedding* embed = new Embedding(*this, input, num_entries,
      out_dim, aggr, shared_op, kernel_initializer, name);
  layers.push_back(embed);
  return embed->outputs[0];
}

Embedding::Embedding(FFModel& model,
                     const Tensor& _input,
                     //std::stirng name,
                     int _num_entries, int outDim,
                     AggrMode _aggr,
                     const Op* shared_op,
                     Initializer* _kernel_initializer,
                     const char* name)
: Op(model, OP_EMBEDDING, shared_op, name, _input),
  num_entries(_num_entries), out_channels(outDim), aggr(_aggr),
  kernel_initializer(_kernel_initializer)
{
  assert(_input.numDim == 2);
  outputs[0].data_type = DT_FLOAT;
  if (aggr == AGGR_MODE_NONE) {
    outputs[0].numDim = 3;
    outputs[0].adim[0] = out_channels;
    outputs[0].adim[1] = inputs[0].adim[0];
    outputs[0].adim[2] = inputs[0].adim[1];
  } else {
    outputs[0].numDim = 2;
    outputs[0].adim[0] = out_channels;
    outputs[0].adim[1] = inputs[0].adim[1];
  }
  weights[0].numDim = 2;
  weights[0].adim[0] = out_channels;
  weights[0].adim[1] = num_entries;
  numWeights = 1;
}

void Embedding::create_weights(FFModel& model)
{
  // Retrive the task indexspace
  int dim = outputs[0].numDim;
  switch (dim) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      create_weights_with_dim<DIM>(model); \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
    {
      // Unsupported dim for BatchMatmul operator
      assert(false);
    }
  }
}

template<int NDIM>
void Embedding::create_weights_with_dim(FFModel& model)
{
  // Retrive the task indexspace for the op
  std::string pcname = name;
  task_is = IndexSpaceT<NDIM>(model.get_or_create_task_is(NDIM, pcname));
#ifdef FF_USE_NCCL
  ParameterSyncType comm_type = ParameterSyncType::NCCL;  
#else
  ParameterSyncType comm_type = ParameterSyncType::PS;
#endif
  {
    const int dims[2] = {num_entries, out_channels};
    // Embeddding weights and linear weights can be partitioned in the same way
    weights[0] = model.create_linear_weight<2, NDIM>(this, dims, DT_FLOAT, kernel_initializer, true/*create_grad*/, comm_type);
    assert(numWeights == 1);
  }
}

void Embedding::create_output_and_partition(FFModel& model)
{
  // Retrive the task indexspace
  int dim = outputs[0].numDim;
  switch (dim) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      create_output_and_partition_with_dim<DIM>(model); \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
    {
      // Unsupported dim for BatchMatmul operator
      assert(false);
    }
  }
}

template<int NDIM>
void Embedding::create_output_and_partition_with_dim(FFModel& model)
{
  // Retrive the task indexspace for the op
  std::string pcname = name;
  task_is = IndexSpaceT<NDIM>(model.get_or_create_task_is(NDIM, pcname));
  Context ctx = model.config.lg_ctx;
  Runtime* runtime = model.config.lg_hlr;
  Domain part_rect = runtime->get_index_space_domain(ctx, task_is);
  // Currently assume we can only partition over the sample dim
  assert(part_rect.lo()[0] == part_rect.hi()[0]);
  {
    //const int dims[2] = {inputs[0].adim[1], out_channels};
    int dims[MAX_TENSOR_DIM];
    int ndims = outputs[0].numDim;
    for (int i = 0; i < outputs[0].numDim; i++)
      dims[i] = outputs[0].adim[ndims-1-i];
    outputs[0] = model.create_tensor<NDIM>(dims, outputs[0].data_type, this); \
    outputs[0].owner_op = this;
    outputs[0].owner_idx = 0;
  }
  // Compute partition bound for input
  Domain input_rect = runtime->get_index_partition_color_space(
      ctx, inputs[0].part.get_index_partition());
  if (input_rect == part_rect) {
    input_lps[0] = inputs[0].part;
    input_grad_lps[0] = inputs[0].part_grad;
  } else if (NDIM == 2) {
    model.create_disjoint_partition<2>(
      inputs[0], (IndexSpaceT<2>)task_is, input_lps[0], input_grad_lps[0]);
  } else {
    model.create_data_parallel_partition_with_diff_dims<2, NDIM>(
      inputs[0], (IndexSpaceT<NDIM>)task_is, input_lps[0], input_grad_lps[0]);
  }
}

__host__
OpMeta* Embedding::init_task(const Task *task,
                             const std::vector<PhysicalRegion> &regions,
                             Context ctx, Runtime* runtime)
{
  const Embedding* embed = (Embedding*) task->args;
  FFHandler handle = *((const FFHandler*) task->local_args);
  EmbeddingMeta* m = new EmbeddingMeta(handle);
  m->input_data_type = embed->inputs[0].data_type;
  m->profiling = embed->profiling;
  m->aggr = embed->aggr;
  return m;
}

void Embedding::init(const FFModel& ff)
{
  // Retrive the task indexspace
  int dim = outputs[0].numDim;
  switch (dim) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      init_with_dim<DIM>(ff); \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
    {
      // Unsupported dim for BatchMatmul operator
      assert(false);
    }
  }
}

template<int NDIM>
void Embedding::init_with_dim(const FFModel& ff)
{
  ArgumentMap argmap;
  Context ctx = ff.config.lg_ctx;
  Runtime* runtime = ff.config.lg_hlr;
  Rect<NDIM> rect = runtime->get_index_space_domain(ctx, task_is);
  ParallelConfig pc;
  std::string pcname = name;
  ff.config.find_parallel_config(NDIM, pcname, pc);
  int idx = 0;
  for (PointInRectIterator<NDIM> it(rect); it(); it++) {
    FFHandler handle = ff.handlers[pc.device_ids[idx++]];
#ifdef FF_USE_NCCL
    handle.ncclComm = pc.nccl_comms[idx-1];
#endif
    argmap.set_point(*it, TaskArgument(&handle, sizeof(FFHandler)));
  }
  IndexLauncher launcher(EMBED_INIT_TASK_ID, task_is,
                         TaskArgument(this, sizeof(Embedding)), argmap,
                         Predicate::TRUE_PRED, false/*must*/, 0/*mapper_id*/,
                         FFConfig::get_hash_id(std::string(name)));
  // regions[0]: input
  //launcher.add_region_requirement(
  //  RegionRequirement(input_lps[0], 0/*projection*/,
  //    READ_ONLY, EXCLUSIVE, inputs[0].region));
  //launcher.add_field(0, FID_DATA);
  // regions[1]: output
  launcher.add_region_requirement(
    RegionRequirement(outputs[0].part, 0/*projection*/,
      WRITE_ONLY, EXCLUSIVE, outputs[0].region));
  launcher.add_field(0, FID_DATA);
  // regions[2]: weight
  launcher.add_region_requirement(
    RegionRequirement(weights[0].part, 0/*projection*/,
      READ_ONLY, EXCLUSIVE, weights[0].region));
  launcher.add_field(1, FID_DATA);
  // regions[3]: input_grad
  //launcher.add_region_requirement(
  //  RegionRequirement(input_grad_lps[0], 0/*projection*/,
  //    WRITE_ONLY, EXCLUSIVE, inputs[0].region_grad));
  //launcher.add_field(2, FID_DATA);
  FutureMap fm = runtime->execute_index_space(ctx, launcher);
  fm.wait_all_results();
  idx = 0;
  for (PointInRectIterator<NDIM> it(rect); it(); it++) {
    meta[idx++] = fm.get_result<OpMeta*>(*it);
  }
}

template<typename TI>
__global__
void embed_forward_no_aggr(
    const TI* input,
    float* output,
    const float* embed,
    int out_dim,
    int batch_size)
{
  CUDA_KERNEL_LOOP(i, batch_size * out_dim)
  {
    output[i] = 0;
    int idx = i / out_dim;
    int off = i % out_dim;
    TI wordIdx = input[idx];
    output[i] = embed[wordIdx * out_dim + off];
  }
}


template<typename TI>
__global__
void embed_forward_with_aggr(
    const TI* input,
    float* output,
    const float* embed,
    int out_dim,
    int in_dim,
    int batch_size,
    AggrMode aggr)
{
  CUDA_KERNEL_LOOP(i, batch_size * out_dim)
  {
    output[i] = 0;
    int idx = i / out_dim;
    int off = i % out_dim;
    for (int j = 0; j < in_dim; j++) {
      TI wordIdx = input[idx * in_dim + j];
      output[i] += embed[wordIdx * out_dim + off];
      if (aggr == AGGR_MODE_SUM) {
      } else {
        assert(aggr == AGGR_MODE_AVG);
        output[i] /= in_dim;
      }
    }
  }
}

template<typename TI>
__global__
void embed_backward_no_aggr(
    const TI* input,
    const float* output,
    float* embed,
    int out_dim,
    int batch_size) {
  CUDA_KERNEL_LOOP(i, batch_size * out_dim)
  {
    int idx = i / out_dim;
    int off = i % out_dim;
    TI wordIdx = input[idx];
    atomicAdd(embed + wordIdx * out_dim + off, output[i]);
  }
}

template<typename TI>
__global__
void embed_backward_with_aggr(
    const TI* input,
    const float* output,
    float* embed,
    int out_dim,
    int in_dim,
    int batch_size,
    AggrMode aggr)
{
  CUDA_KERNEL_LOOP(i, batch_size * out_dim)
  {
    int idx = i / out_dim;
    int off = i % out_dim;
    float gradient;
    if (aggr == AGGR_MODE_SUM) {
       gradient = output[i];
    } else {
      assert(aggr == AGGR_MODE_AVG);
      gradient = output[i] / in_dim;
    }
    for (int j = 0; j < in_dim; j++) {
      TI wordIdx = input[idx * in_dim + j];
      atomicAdd(embed + wordIdx * out_dim + off, gradient);
    }
  }
}

template<typename TI>
void Embedding::forward_kernel(const TI* input_ptr,
                               float *output_ptr,
                               float const *weight_ptr,
                               int in_dim,
                               int out_dim,
                               int batch_size,
                               AggrMode aggr,
                               int outputSize,
                               cudaStream_t stream)
{
  if (aggr == AGGR_MODE_NONE) {
    embed_forward_no_aggr<TI><<<GET_BLOCKS(outputSize), CUDA_NUM_THREADS, 0, stream>>>(
        input_ptr, output_ptr, weight_ptr,out_dim, batch_size);
  } else {
    embed_forward_with_aggr<TI><<<GET_BLOCKS(outputSize), CUDA_NUM_THREADS, 0, stream>>>(
        input_ptr, output_ptr, weight_ptr, out_dim, in_dim, batch_size, aggr);
  }
}

/*
  regions[0](I): input
  regions[1](O): output
  regions[2](I): kernel
*/

void Embedding::forward_task(const Task*task,
                             const std::vector<PhysicalRegion>& regions,
                             Context ctx, Runtime* runtime)
{
  const EmbeddingMeta* m = *((EmbeddingMeta**) task->local_args);
  if (m->input_data_type == DT_INT32) {
    forward_task_with_type<int32_t>(task, regions, ctx, runtime);
  } else if (m->input_data_type == DT_INT64) {
    forward_task_with_type<int64_t>(task, regions, ctx, runtime);
  } else {
    assert(false && "Unsupported data type in Embedding forward");
  }
}

template<typename TI>
void Embedding::forward_task_with_type(const Task *task,
                                       const std::vector<PhysicalRegion> &regions,
                                       Context ctx, Runtime* runtime)
{
  assert(regions.size() == 3);
  assert(task->regions.size() == 3);
  //const Embedding* embed = (Embedding*) task->args;
  const EmbeddingMeta* m = *((EmbeddingMeta**) task->local_args);
  Domain input_domain = runtime->get_index_space_domain(
    ctx, task->regions[0].region.get_index_space());
  Domain output_domain = runtime->get_index_space_domain(
    ctx, task->regions[1].region.get_index_space());
  Domain kernel_domain = runtime->get_index_space_domain(
    ctx, task->regions[2].region.get_index_space());
  if (m->aggr == AGGR_MODE_NONE) {
    assert(kernel_domain.get_dim() == 2);
    for (size_t i = 0; i < input_domain.get_dim(); i++) {
      assert(input_domain.hi()[i] == output_domain.hi()[i+1]);
      assert(input_domain.lo()[i] == output_domain.lo()[i+1]);
    }
    assert(kernel_domain.hi()[0] - kernel_domain.lo()[0]
        == output_domain.hi()[0] - output_domain.lo()[0]);
  } else {
    assert(kernel_domain.get_dim() == 2);
    for (size_t i = 1; i < input_domain.get_dim(); i++) {
      assert(input_domain.hi()[i] == output_domain.hi()[i]);
      assert(input_domain.lo()[i] == output_domain.lo()[i]);
    }
    assert(kernel_domain.hi()[0] - kernel_domain.lo()[0]
        == output_domain.hi()[0] - output_domain.lo()[0]);
  }
  const TI* input_ptr = helperGetTensorPointerRO<TI>(
      regions[0], task->regions[0], FID_DATA, ctx, runtime);
  float* output_ptr = helperGetTensorPointerWO<float>(
      regions[1], task->regions[1], FID_DATA, ctx, runtime);
  const float* kernel_ptr = helperGetTensorPointerRO<float>(
      regions[2], task->regions[2], FID_DATA, ctx, runtime);

  int in_dim, out_dim, effective_batch_size;
  if (m->aggr == AGGR_MODE_NONE) {
    in_dim = 1;
    out_dim = output_domain.hi()[0] - output_domain.lo()[0] + 1;
    effective_batch_size = output_domain.get_volume() / out_dim;
    assert(effective_batch_size * in_dim == input_domain.get_volume());
  } else {
    in_dim = input_domain.hi()[0] - input_domain.lo()[0] + 1;
    out_dim = output_domain.hi()[0] - output_domain.lo()[0] + 1;
    effective_batch_size = output_domain.get_volume() / out_dim;
    assert(effective_batch_size * in_dim == input_domain.get_volume());
  }
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  forward_kernel<TI>(input_ptr, output_ptr, kernel_ptr,
      in_dim, out_dim, effective_batch_size,
      m->aggr, output_domain.get_volume(), stream);

  if (m->profiling) {
    checkCUDA(cudaDeviceSynchronize());
    //print_tensor<TI>(input_ptr, input_domain.get_volume(), "[Embedding:forward:input]");
    //print_tensor<float>(kernel_ptr, kernel_domain.get_volume(), "[Embedding:forward:weight]");
    //print_tensor<float>(output_ptr, output_domain.get_volume(), "[Embedding:forward:output]");
  }
}

void Embedding::forward(const FFModel& ff)
{
  // Retrive the task indexspace
  int dim = outputs[0].numDim;
  switch (dim) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      forward_with_dim<DIM>(ff); \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
    {
      // Unsupported dim for BatchMatmul operator
      assert(false);
    }
  }
}

template<int NDIM>
void Embedding::forward_with_dim(const FFModel& ff)
{
  ArgumentMap argmap;
  Context ctx = ff.config.lg_ctx;
  Runtime* runtime = ff.config.lg_hlr;
  Rect<NDIM> rect = runtime->get_index_space_domain(ctx, task_is);
  int idx = 0;
  for (PointInRectIterator<NDIM> it(rect); it(); it++) {
    OpMeta* mp = meta[idx++];
    argmap.set_point(*it, TaskArgument(&mp, sizeof(OpMeta*)));
  }
  IndexLauncher launcher(EMBED_FWD_TASK_ID, task_is,
                         TaskArgument(NULL, 0), argmap,
                         Predicate::TRUE_PRED, false/*must*/, 0/*mapper_id*/,
                         FFConfig::get_hash_id(std::string(name)));
  // regions[0]: input
  launcher.add_region_requirement(
      RegionRequirement(input_lps[0], 0/*projection*/,
                        READ_ONLY, EXCLUSIVE, inputs[0].region));
  launcher.add_field(0, FID_DATA);
  // regions[1]: output
  launcher.add_region_requirement(
      RegionRequirement(outputs[0].part, 0/*projection*/,
                        WRITE_ONLY, EXCLUSIVE, outputs[0].region,
                        MAP_TO_ZC_MEMORY));
  launcher.add_field(1, FID_DATA);
  // regions[2]: weight
  launcher.add_region_requirement(
      RegionRequirement(weights[0].part, 0/*projection*/,
                        READ_ONLY, EXCLUSIVE, weights[0].region));
  launcher.add_field(2, FID_DATA);
  runtime->execute_index_space(ctx, launcher);
}

template<typename TI>
void Embedding::backward_kernel(const TI *input_ptr,
                                float const *output_ptr,
                                float *weight_grad_ptr,
                                int in_dim,
                                int out_dim,
                                int batch_size,
                                AggrMode aggr,
                                int outputSize,
                                cudaStream_t stream)
{
  if (aggr == AGGR_MODE_NONE) {
    embed_backward_no_aggr<TI><<<GET_BLOCKS(outputSize), CUDA_NUM_THREADS, 0, stream>>>(
        input_ptr, output_ptr, weight_grad_ptr, out_dim, batch_size);
  } else {
    embed_backward_with_aggr<TI><<<GET_BLOCKS(outputSize), CUDA_NUM_THREADS, 0, stream>>>(
        input_ptr, output_ptr, weight_grad_ptr, out_dim, in_dim, batch_size, aggr);
  }
}

__host__
void Embedding::backward_task(const Task*task,
                             const std::vector<PhysicalRegion>& regions,
                             Context ctx, Runtime* runtime)
{
  const EmbeddingMeta* m = *((EmbeddingMeta**) task->local_args);
  if (m->input_data_type == DT_INT32) {
    backward_task_with_type<int32_t>(task, regions, ctx, runtime);
  } else if (m->input_data_type == DT_INT64) {
    backward_task_with_type<int64_t>(task, regions, ctx, runtime);
  } else {
    assert(false && "Unsupported data type in Embedding forward");
  }
}

template<typename TI>
void Embedding::backward_task_with_type(const Task *task,
                                        const std::vector<PhysicalRegion> &regions,
                                        Context ctx, Runtime *runtime)
{
  assert(regions.size() == 3);
  assert(task->regions.size() == 3);
  //const Embedding* embed = (Embedding*) task->args;
  const EmbeddingMeta* m = *((EmbeddingMeta**) task->local_args);
  Domain input_domain = runtime->get_index_space_domain(
    ctx, task->regions[0].region.get_index_space());
  Domain output_grad_domain = runtime->get_index_space_domain(
    ctx, task->regions[1].region.get_index_space());
  Domain kernel_grad_domain = runtime->get_index_space_domain(
    ctx, task->regions[2].region.get_index_space());
  if (m->aggr == AGGR_MODE_NONE) {
    assert(kernel_grad_domain.get_dim() == 2);
    for (size_t i = 0; i < input_domain.get_dim(); i++) {
      assert(input_domain.hi()[i] == output_grad_domain.hi()[i+1]);
      assert(input_domain.lo()[i] == output_grad_domain.lo()[i+1]);
    }
    assert(kernel_grad_domain.hi()[0] - kernel_grad_domain.lo()[0]
        == output_grad_domain.hi()[0] - output_grad_domain.lo()[0]);
  } else {
    assert(kernel_grad_domain.get_dim() == 2);
    for (size_t i = 1; i < input_domain.get_dim(); i++) {
      assert(input_domain.hi()[i] == output_grad_domain.hi()[i]);
      assert(input_domain.lo()[i] == output_grad_domain.lo()[i]);
    }
    assert(kernel_grad_domain.hi()[0] - kernel_grad_domain.lo()[0]
        == output_grad_domain.hi()[0] - output_grad_domain.lo()[0]);
  }
  const TI* input_ptr = helperGetTensorPointerRO<TI>(
      regions[0], task->regions[0], FID_DATA, ctx, runtime);
  const float* output_grad_ptr = helperGetTensorPointerWO<float>(
      regions[1], task->regions[1], FID_DATA, ctx, runtime);
  float* kernel_grad_ptr = helperGetTensorPointerRW<float>(
      regions[2], task->regions[2], FID_DATA, ctx, runtime);

  int in_dim, out_dim, effective_batch_size;
  if (m->aggr == AGGR_MODE_NONE) {
    in_dim = 1;
    out_dim = output_grad_domain.hi()[0] - output_grad_domain.lo()[0] + 1;
    effective_batch_size = output_grad_domain.get_volume() / out_dim;
    assert(effective_batch_size * in_dim == input_domain.get_volume());
  } else {
    in_dim = input_domain.hi()[0] - input_domain.lo()[0] + 1;
    out_dim = output_grad_domain.hi()[0] - output_grad_domain.lo()[0] + 1;
    effective_batch_size = output_grad_domain.get_volume() / out_dim;
    assert(effective_batch_size * in_dim == input_domain.get_volume());
  }

  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  backward_kernel<TI>(input_ptr, output_grad_ptr, kernel_grad_ptr,
      in_dim, out_dim, effective_batch_size,
      m->aggr, output_grad_domain.get_volume(), stream);

  if (m->profiling) {
    checkCUDA(cudaDeviceSynchronize());
    //print_tensor<float>(output_grad_ptr, output_grad_domain.volume(), "[Embedding:backward:output_grad]");
    //print_tensor<float>(kernel_grad_ptr, kernel_grad_domain.get_volume(), "[Embedding:backward:weight_grad]");
    //print_tensor<TI>(input_ptr, input_domain.get_volume(), "[Embedding:backward:input]");
  }
}

void Embedding::backward(const FFModel& ff)
{
  // Retrive the task indexspace
  int dim = outputs[0].numDim;
  switch (dim) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      backward_with_dim<DIM>(ff); \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
    {
      // Unsupported dim for BatchMatmul operator
      assert(false);
    }
  }
}

template<int NDIM>
void Embedding::backward_with_dim(const FFModel& ff)
{
  ArgumentMap argmap;
  Context ctx = ff.config.lg_ctx;
  Runtime* runtime = ff.config.lg_hlr;
  Rect<NDIM> rect = runtime->get_index_space_domain(ctx, task_is);
  int idx = 0;
  for (PointInRectIterator<NDIM> it(rect); it(); it++) {
    OpMeta* mp = meta[idx++];
    argmap.set_point(*it, TaskArgument(&mp, sizeof(OpMeta*)));
  }
  IndexLauncher launcher(EMBED_BWD_TASK_ID, task_is,
                         TaskArgument(NULL, 0), argmap,
                         Predicate::TRUE_PRED, false/*must*/, 0/*mapper_id*/,
                         FFConfig::get_hash_id(std::string(name)));
  // regions[0]: input
  launcher.add_region_requirement(
      RegionRequirement(input_lps[0], 0/*projection*/,
                        READ_ONLY, EXCLUSIVE, inputs[0].region));
  launcher.add_field(0, FID_DATA);
  // regions[1]: output_grad
  launcher.add_region_requirement(
      RegionRequirement(outputs[0].part_grad, 0/*projection*/,
                        READ_ONLY, EXCLUSIVE, outputs[0].region_grad,
                        MAP_TO_ZC_MEMORY));
  launcher.add_field(1, FID_DATA);
  // regions[2]: weight_grad
  launcher.add_region_requirement(
      RegionRequirement(weights[0].part_grad, 0/*projection*/,
                        READ_WRITE, EXCLUSIVE, weights[0].region_grad));
  launcher.add_field(2, FID_DATA);
  runtime->execute_index_space(ctx, launcher);
}

__global__
void rand_generate_int64(int64_t* ptr, size_t size, int64_t p)
{
  CUDA_KERNEL_LOOP(i, size)
  {
    ptr[i] = i % p;
  }
}

bool Embedding::measure_operator_cost(Simulator* sim,
                                      const ParallelConfig& pc,
                                      CostMetrics& cost_metrics)
{
  Tensor sub_input, sub_output;
  if (!outputs[0].get_output_sub_tensor(pc, sub_output, op_type)) {
    return false;
  }
  if (!inputs[0].get_input_sub_tensor(pc, sub_input, op_type)) {
    return false;
  }

  sim->free_all();
  int64_t *input_ptr = (int64_t *)sim->allocate(sub_input.get_volume(), DT_INT64);
  assert (input_ptr != NULL);
  checkCUDA(cudaMemset(input_ptr, 0, sub_input.get_volume()));
  float *output_ptr = (float *)sim->allocate(sub_output.get_volume(), DT_FLOAT);
  assert (output_ptr != NULL);
  float *weight_ptr = (float *)sim->allocate(num_entries * out_channels, DT_FLOAT);
  assert (weight_ptr != NULL);
  int in_dim = sub_input.adim[0];
  int out_dim = sub_input.adim[0];
  assert (sub_input.adim[1] == sub_output.adim[1]);
  int batch_size = sub_input.adim[1];

  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  // Randomly initialize the intput tensor to avoid out of index range issues
  rand_generate_int64<<<GET_BLOCKS(sub_input.get_volume()), CUDA_NUM_THREADS, 0, stream>>>(
      input_ptr, sub_input.get_volume(), num_entries);
  std::function<void()> forward, backward;
  forward = [&] {
    forward_kernel(input_ptr, output_ptr, weight_ptr, in_dim, out_dim, batch_size, this->aggr, sub_output.get_volume(), stream);
  };
  if (sim->computationMode == COMP_MODE_TRAINING) {
    float *weight_grad_ptr = (float *)sim->allocate(num_entries * out_channels, DT_FLOAT);
    assert (weight_grad_ptr != NULL);
    float *output_grad_ptr = (float *)sim->allocate(sub_output.get_volume(), DT_FLOAT);
    assert (output_grad_ptr != NULL);
    int64_t *input_grad_ptr = (int64_t *)sim->allocate(sub_input.get_volume(), DT_INT64);
    assert (input_grad_ptr != NULL);

    backward = [&] {
      backward_kernel(input_grad_ptr, output_grad_ptr, weight_grad_ptr, in_dim, out_dim, batch_size,
        this->aggr, sub_output.get_volume(), stream);
    };
  }

  inner_measure_operator_cost(sim, forward, backward, cost_metrics);

  if (sim->computationMode == COMP_MODE_TRAINING) {
    printf("[Measure Embedding] name(%s) forward_time(%.4lf) backward_time(%.4lf)\n",
        name,
        cost_metrics.forward_time,
        cost_metrics.backward_time);
  } else {
    printf("[Measure Embedding] name(%s) forward_time(%.4lf)\n",
        name,
        cost_metrics.forward_time);
  }

  return true;
}
