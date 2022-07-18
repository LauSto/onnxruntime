// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "orttraining/training_ops/cuda/activation/bias_gelu_grad_impl.h"

#include "core/providers/cuda/cu_inc/common.cuh"
#include "core/providers/cuda/shared_inc/fast_divmod.h"
#include "orttraining/training_ops/cpu/activation/gelu_computation_mode.h"
#include "orttraining/training_ops/cuda/activation/gelu_grad_impl_common.cuh"

namespace onnxruntime {
namespace cuda {

template <typename T, typename GeluComputationMode, int num_elements_per_thread>
__global__ void BiasGeluGradDxKernel(int64_t bias_size, const T* dY, const T* X, const T* B, T* dX) {
  const auto num_elements_per_block = num_elements_per_thread * blockDim.x;
  const auto input_base_idx = bias_size * (blockIdx.y + gridDim.y * blockIdx.z) + num_elements_per_block * blockIdx.x + threadIdx.x;
  const auto bias_base_idx = num_elements_per_block * blockIdx.x + threadIdx.x;
  const auto element_stride = blockDim.x;

  T reg_dY[num_elements_per_thread];
  T reg_X[num_elements_per_thread];
  T reg_B[num_elements_per_thread];

  {
    auto input_idx = input_base_idx;
    auto bias_idx = bias_base_idx;
#pragma unroll
    for (int element_idx = 0; element_idx < num_elements_per_thread; ++element_idx) {
      if (bias_idx < bias_size) {
        reg_dY[element_idx] = dY[input_idx];
        reg_X[element_idx] = X[input_idx];
        reg_B[element_idx] = B[bias_idx];

        input_idx += element_stride;
        bias_idx += element_stride;
      }
    }
  }

  {
    auto input_idx = input_base_idx;
    auto bias_idx = bias_base_idx;
#pragma unroll
    for (int element_idx = 0; element_idx < num_elements_per_thread; ++element_idx) {
      if (bias_idx < bias_size) {
        dX[input_idx] = ComputeGeluGradScalar(
            reg_dY[element_idx], reg_X[element_idx] + reg_B[element_idx], GeluComputationMode{});

        input_idx += element_stride;
        bias_idx += element_stride;
      }
    }
  }
}

template <typename T, typename GeluComputationMode>
void LaunchBiasGeluGradDxKernel(
    cudaStream_t stream,
    const cudaDeviceProp& prop,
    int64_t input_size, int64_t bias_size,
    const T* dY, const T* X, const T* B, T* dX) {
  // Given a logical 2D grid of blocks:
  //   each grid row handles bias_size elements
  //   there are input_size / bias_size rows
  // For cases having many rows in the 2D grid (bigger than the upper limit of dimension of grid),
  // 3D grid is used, e.g. the first two dimensions will be used as the logical "row".

  const uint32_t maxGridY = static_cast<uint32_t>(prop.maxGridSize[1]);
  const int num_elements_per_thread = GridDim::maxElementsPerThread;

#ifdef USE_ROCM
  // Optimization for ROCm MI100
  const int max_threads_per_block = 512;
#else
  const int max_threads_per_block = GridDim::maxThreadsPerBlock;
#endif

  int num_threads_per_block =
      std::min<int>(static_cast<int>(CeilDiv(bias_size, num_elements_per_thread)), max_threads_per_block);
  const auto grid_width = CeilDiv(bias_size, num_elements_per_thread * num_threads_per_block);
  uint32_t grid_height = static_cast<uint32_t>(input_size / bias_size);
  uint32_t grid_depth = 1;
  if (grid_height >= maxGridY) {
    grid_depth = static_cast<uint32_t>(CeilDiv(grid_height, maxGridY));
    grid_height = maxGridY;
  }

  const dim3 grid_dim{static_cast<uint32_t>(grid_width), grid_height, grid_depth};

  BiasGeluGradDxKernel<T, GeluComputationMode, num_elements_per_thread>
      <<<grid_dim, num_threads_per_block, 0, stream>>>(bias_size, dY, X, B, dX);
}

// explicit instantiations
#define SPECIALIZED_BIAS_GELU_GRAD_IMPL(T, GeluComputationMode)                               \
  template void LaunchBiasGeluGradDxKernel<T, GeluComputationMode>(                           \
      cudaStream_t stream, const cudaDeviceProp& prop, int64_t input_size, int64_t bias_size, \
      const T* dY, const T* X, const T* B, T* dX)

SPECIALIZED_BIAS_GELU_GRAD_IMPL(half, gelu_computation_mode::Default);
SPECIALIZED_BIAS_GELU_GRAD_IMPL(float, gelu_computation_mode::Default);
SPECIALIZED_BIAS_GELU_GRAD_IMPL(double, gelu_computation_mode::Default);

SPECIALIZED_BIAS_GELU_GRAD_IMPL(half, gelu_computation_mode::Approximation);
SPECIALIZED_BIAS_GELU_GRAD_IMPL(float, gelu_computation_mode::Approximation);
SPECIALIZED_BIAS_GELU_GRAD_IMPL(double, gelu_computation_mode::Approximation);

SPECIALIZED_BIAS_GELU_GRAD_IMPL(BFloat16, gelu_computation_mode::Default);
SPECIALIZED_BIAS_GELU_GRAD_IMPL(BFloat16, gelu_computation_mode::Approximation);

#undef SPECIALIZED_BIAS_GELU_GRAD_IMPL

}  // namespace cuda
}  // namespace onnxruntime
