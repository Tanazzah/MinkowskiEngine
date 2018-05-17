#ifndef SPARSE_POOLING_CUH
#define SPARSE_POOLING_CUH

#include <array>
#include <vector>

#include "src/gpu.cuh"
#include "src/math_functions.hpp"

template <typename Dtype>
void SparseMaxPoolingForwardGPU(const Dtype *d_in_feat, Dtype *d_out_feat,
                                int64_t out_nrows, int64_t *d_max_index,
                                int64_t nchannel,
                                const std::vector<std::vector<int64_t>> in_map,
                                const std::vector<std::vector<int64_t>> out_map,
                                cudaStream_t stream);

template <typename Dtype>
void SparseMaxPoolingBackwardGPU(Dtype *d_grad_in_feat, int64_t in_nrows,
                                 const Dtype *d_grad_out_feat,
                                 int64_t out_nrows, const int64_t *d_max_index,
                                 int64_t nchannel, cudaStream_t stream);
#endif
