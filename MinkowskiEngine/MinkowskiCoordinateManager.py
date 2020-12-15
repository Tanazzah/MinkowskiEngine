# Copyright (c) 2020 NVIDIA CORPORATION.
# Copyright (c) 2018-2020 Chris Choy (chrischoy@ai.stanford.edu).
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Please cite "4D Spatio-Temporal ConvNets: Minkowski Convolutional Neural
# Networks", CVPR'19 (https://arxiv.org/abs/1904.08755) if you use any part
# of the code.
import os
import numpy as np
from collections import Sequence
from typing import Union, List, Tuple
import warnings

import torch
from MinkowskiCommon import convert_to_int_list, convert_to_int_tensor, prep_args
import MinkowskiEngineBackend._C as _C
from MinkowskiEngineBackend._C import (
    CoordinateMapKey,
    GPUMemoryAllocatorType,
    CoordinateMapType,
    RegionType,
    CUDAKernelMapMode,
)

CPU_COUNT = os.cpu_count()
if "OMP_NUM_THREADS" in os.environ:
    CPU_COUNT = int(os.environ["OMP_NUM_THREADS"])

_allocator_type = GPUMemoryAllocatorType.PYTORCH
_coordinate_map_type = (
    CoordinateMapType.CUDA if _C.is_cuda_available() else CoordinateMapType.CPU
)
_kernel_map_mode = CUDAKernelMapMode.SPEED_OPTIMIZED


def set_coordinate_map_type(coordinate_map_type: CoordinateMapType):
    r"""Set the default coordinate map type.

    The MinkowskiEngine automatically set the coordinate_map_type to CUDA if
    a NVIDIA GPU is available. To control the 
    """
    global _coordinate_map_type
    _coordinate_map_type = coordinate_map_type


def set_gpu_allocator(backend: GPUMemoryAllocatorType):
    r"""Set the GPU memory allocator

    By default, the Minkowski Engine will use the pytorch memory pool to
    allocate temporary GPU memory slots. This allows the pytorch backend to
    effectively reuse the memory pool shared between the pytorch backend and
    the Minkowski Engine. It tends to allow training with larger batch sizes
    given a fixed GPU memory. However, pytorch memory manager tend to be slower
    than allocating GPU directly using raw CUDA calls.

    By default, the Minkowski Engine uses
    :attr:`ME.MemoryManagerBackend.PYTORCH` for memory management.

    Example::

       >>> import MinkowskiEngine as ME
       >>> # Set the GPU memory manager backend to raw CUDA calls
       >>> ME.set_gpu_allocator(ME.GPUMemoryAllocatorType.CUDA)
       >>> # Set the GPU memory manager backend to the pytorch c10 allocator
       >>> ME.set_gpu_allocator(ME.GPUMemoryAllocatorType.PYTORCH)

    """
    assert isinstance(
        backend, GPUMemoryAllocatorType
    ), f"Input must be an instance of MemoryManagerBackend not {backend}"
    global _allocator_type
    _allocator_type = backend


def set_memory_manager_backend(backend: GPUMemoryAllocatorType):
    r"""Alias for set_gpu_allocator. Deprecated and will be removed.
    """
    warnings.warn(
        "`set_memory_manager_backend` has been deprecated. Use `set_gpu_allocator` instead."
    )
    set_gpu_allocator(backend)


class CoordsManager:
    def __init__(*args, **kwargs):
        raise DeprecationWarning(
            "`CoordsManager` has been deprecated. Use `CoordinateManager` instead."
        )


class CoordinateManager:
    def __init__(
        self,
        D: int = 0,
        num_threads: int = -1,
        coordinate_map_type: CoordinateMapType = None,
        allocator_type: GPUMemoryAllocatorType = None,
        kernel_map_mode: CUDAKernelMapMode = None,
    ):
        r"""

        :attr:`D`: The order, or dimension of the coordinates.
        """
        global _coordinate_map_type, _allocator_type, _kernel_map_mode
        if D < 1:
            raise ValueError(f"Invalid rank D > 0, D = {D}.")
        if num_threads < 0:
            num_threads = min(CPU_COUNT, 20)
        if coordinate_map_type is None:
            coordinate_map_type = _coordinate_map_type
        if allocator_type is None:
            allocator_type = _allocator_type
        if kernel_map_mode is None:
            kernel_map_mode = _kernel_map_mode

        postfix = ""
        if coordinate_map_type == CoordinateMapType.CPU:
            postfix = "CPU"
        else:
            postfix = "GPU" + (
                "_default" if allocator_type == GPUMemoryAllocatorType.CUDA else "_c10"
            )

        self.D = D
        self._CoordinateManagerClass = getattr(_C, "CoordinateMapManager" + postfix)
        self._manager = self._CoordinateManagerClass(kernel_map_mode, num_threads)

    # TODO: insert without remap, unique_map, inverse_mapa
    #
    # def insert() -> CoordinateMapKey

    def insert_and_map(
        self,
        coordinates: torch.IntTensor,
        tensor_stride: Union[int, Sequence, np.ndarray, torch.Tensor],
        string_id: str = "",
    ) -> Tuple[CoordinateMapKey, Tuple[torch.IntTensor, torch.IntTensor]]:
        r"""create a new coordinate map and returns 

        :attr:`coordinates`: `torch.IntTensor` (`CUDA` if coordinate_map_type
        == `CoordinateMapType.GPU`) that defines the coordinates.

        Example::

           >>> manager = CoordinateManager(D=1)
           >>> coordinates = torch.IntTensor([[0, 0], [0, 0], [0, 1], [0, 2]])
           >>> key, (unique_map, inverse_map) = manager.insert(coordinates, [1])
           >>> print(key) # key is tensor_stride, string_id [1]:""
           >>> torch.all(coordinates[unique_map] == manager.get_coordinates(key)) # True
           >>> torch.all(coordinates == coordinates[unique_map][inverse_map]) # True

        """
        return self._manager.insert_and_map(coordinates, tensor_stride, string_id)

    def stride(
        self,
        coordinate_map_key: CoordinateMapKey,
        stride: Union[int, Sequence, np.ndarray, torch.Tensor],
    ) -> CoordinateMapKey:
        r"""Generate a new coordinate map and returns the key.

        :attr:`coordinate_map_key` (:attr:`MinkowskiEngine.CoordinateMapKey`):
        input map to generate the strided map from.

        :attr:`stride`: stride size.
        """
        stride = convert_to_int_list(stride, self.D)
        return self._manager.stride(coordinate_map_key, stride)

    def origin(self):
        return self._manager.origin()

    # def transposed_stride(
    #     self,
    #     coords_key: CoordsKey,
    #     stride: Union[int, Sequence, np.ndarray, torch.Tensor],
    #     kernel_size: Union[int, Sequence, np.ndarray, torch.Tensor],
    #     dilation: Union[int, Sequence, np.ndarray, torch.Tensor],
    #     force_creation: bool = False,
    # ):
    #     assert isinstance(coords_key, CoordsKey)
    #     stride = convert_to_int_list(stride, self.D)
    #     kernel_size = convert_to_int_list(kernel_size, self.D)
    #     dilation = convert_to_int_list(dilation, self.D)
    #     region_type = 0
    #     region_offset = torch.IntTensor()

    #     strided_key = CoordsKey(self.D)
    #     tensor_stride = coords_key.getTensorStride()
    #     strided_key.setTensorStride([int(t / s) for t, s in zip(tensor_stride, stride)])

    #     strided_key.setKey(
    #         self.CPPCoordsManager.createTransposedStridedRegionCoords(
    #             coords_key.getKey(),
    #             coords_key.getTensorStride(),
    #             stride,
    #             kernel_size,
    #             dilation,
    #             region_type,
    #             region_offset,
    #             force_creation,
    #         )
    #     )
    #     return strided_key

    def _get_coordinate_map_key(self, key_or_tensor_strides):
        r"""Helper function that retrieves a coordinate map key from tensor stride.
        """
        assert isinstance(key_or_tensor_strides, CoordinateMapKey) or isinstance(
            key_or_tensor_strides, (Sequence, np.ndarray, torch.IntTensor, int)
        ), f"The input must be either a CoordinateMapKey or tensor_stride of type (int, list, tuple, array, Tensor). Invalid: {key_or_tensor_strides}"
        if isinstance(key_or_tensor_strides, CoordinateMapKey):
            # Do nothing and return the input
            return key_or_tensor_strides
        else:
            tensor_strides = convert_to_int_list(key_or_tensor_strides, self.D)
            key = self.CPPCoordsManager.getCoordsKey(tensor_strides)
            coords_key = CoordsKey(self.D)
            coords_key.setKey(key)
            coords_key.setTensorStride(tensor_strides)
            return coords_key

    def get_coordinates(self, coords_key_or_tensor_strides):
        key = self._get_coordinate_map_key(coords_key_or_tensor_strides)
        return self._manager.get_coordinates(key)

    # def get_batch_size(self):
    #     return self.CPPCoordsManager.getBatchSize()

    # def get_batch_indices(self):
    #     return self.CPPCoordsManager.getBatchIndices()

    # def set_origin_coords_key(self, coords_key: CoordsKey):
    #     self.CPPCoordsManager.setOriginCoordsKey(coords_key.CPPCoordsKey)

    # def get_row_indices_per_batch(self, coords_key, out_coords_key=None):
    #     r"""Return a list of lists of row indices per batch.

    #     The corresponding batch indices are accessible by `get_batch_indices`.

    #     .. code-block:: python

    #        sp_tensor = ME.SparseTensor(features, coords=coordinates)
    #        row_indices = sp_tensor.coords_man.get_row_indices_per_batch(sp_tensor.coords_key)

    #     """
    #     assert isinstance(coords_key, CoordsKey)
    #     if out_coords_key is None:
    #         out_coords_key = CoordsKey(self.D)
    #     return self.CPPCoordsManager.getRowIndicesPerBatch(
    #         coords_key.CPPCoordsKey, out_coords_key.CPPCoordsKey
    #     )

    # def get_row_indices_at(self, coords_key, batch_index):
    #     r"""Return an torch.LongTensor of row indices for the specified batch index

    #     .. code-block:: python

    #        sp_tensor = ME.SparseTensor(features, coords=coordinates)
    #        row_indices = sp_tensor.coords_man.get_row_indices_at(sp_tensor.coords_key, batch_index)

    #     """
    #     assert isinstance(coords_key, CoordsKey)
    #     out_coords_key = CoordsKey(self.D)
    #     return self.CPPCoordsManager.getRowIndicesAtBatchIndex(
    #         coords_key.CPPCoordsKey, out_coords_key.CPPCoordsKey, batch_index
    #     )

    # def get_kernel_map(
    #     self,
    #     in_key_or_tensor_strides,
    #     out_key_or_tensor_strides,
    #     stride=1,
    #     kernel_size=3,
    #     dilation=1,
    #     region_type=0,
    #     region_offset=None,
    #     is_transpose=False,
    #     is_pool=False,
    #     on_gpu=False,
    # ):
    #     r"""Get kernel in-out maps for the specified coords keys or tensor strides.

    #     """
    #     # region type 1 iteration with kernel_size 1 is invalid
    #     if isinstance(kernel_size, torch.Tensor):
    #         assert (kernel_size > 0).all(), f"Invalid kernel size: {kernel_size}"
    #         if (kernel_size == 1).all() == 1:
    #             region_type = 0
    #     elif isinstance(kernel_size, int):
    #         assert kernel_size > 0, f"Invalid kernel size: {kernel_size}"
    #         if kernel_size == 1:
    #             region_type = 0

    #     if isinstance(in_key_or_tensor_strides, CoordsKey):
    #         in_tensor_strides = in_key_or_tensor_strides.getTensorStride()
    #     else:
    #         in_tensor_strides = in_key_or_tensor_strides
    #     if region_offset is None:
    #         region_offset = torch.IntTensor()

    #     in_coords_key = self._get_coordinate_map_key(in_key_or_tensor_strides)
    #     out_coords_key = self._get_coordinate_map_key(out_key_or_tensor_strides)

    #     tensor_strides = convert_to_int_tensor(in_tensor_strides, self.D)
    #     strides = convert_to_int_tensor(stride, self.D)
    #     kernel_sizes = convert_to_int_tensor(kernel_size, self.D)
    #     dilations = convert_to_int_tensor(dilation, self.D)
    #     D = in_coords_key.D
    #     tensor_strides, strides, kernel_sizes, dilations, region_type = prep_args(
    #         tensor_strides, strides, kernel_sizes, dilations, region_type, D
    #     )
    #     if on_gpu:
    #         assert hasattr(
    #             self.CPPCoordsManager, "getKernelMapGPU"
    #         ), f"Function getKernelMapGPU not available. Please compile MinkowskiEngine where `torch.cuda.is_available()` is `True`."
    #         kernel_map_fn = getattr(self.CPPCoordsManager, "getKernelMapGPU")
    #     else:
    #         kernel_map_fn = self.CPPCoordsManager.getKernelMap
    #     kernel_map = kernel_map_fn(
    #         convert_to_int_list(tensor_strides, D),  #
    #         convert_to_int_list(strides, D),  #
    #         convert_to_int_list(kernel_sizes, D),  #
    #         convert_to_int_list(dilations, D),  #
    #         region_type,
    #         region_offset,
    #         in_coords_key.CPPCoordsKey,
    #         out_coords_key.CPPCoordsKey,
    #         is_transpose,
    #         is_pool,
    #     )

    #     return kernel_map

    def origin_map(self, key: CoordinateMapKey):
        return self._manager.origin_map(key)

    # def get_coords_map(self, in_key_or_tensor_strides, out_key_or_tensor_strides):
    #     r"""Extract input coords indices that maps to output coords indices.

    #     .. code-block:: python

    #        sp_tensor = ME.SparseTensor(features, coords=coordinates)
    #        out_sp_tensor = stride_2_conv(sp_tensor)

    #        cm = sp_tensor.coords_man
    #        # cm = out_sp_tensor.coords_man  # doesn't matter which tensor you pick
    #        ins, outs = cm.get_coords_map(1,  # in stride
    #                                      2)  # out stride
    #        for i, o in zip(ins, outs):
    #           print(f"{i} -> {o}")

    #     """
    #     in_coords_key = self._get_coordinate_map_key(in_key_or_tensor_strides)
    #     out_coords_key = self._get_coordinate_map_key(out_key_or_tensor_strides)

    #     return self.CPPCoordsManager.getCoordsMap(
    #         in_coords_key.CPPCoordsKey, out_coords_key.CPPCoordsKey
    #     )

    # def get_union_map(self, in_keys: List[CoordsKey], out_key: CoordsKey):
    #     r"""Generates a union of coordinate sets and returns the mapping from input sets to the new output coordinates.

    #     Args:
    #         :attr:`in_keys` (List[CoordsKey]): A list of coordinate keys to
    #         create a union on.

    #         :attr:`out_key` (CoordsKey): the placeholder for the coords key of
    #         the generated union coords hash map.

    #     Returns:
    #         :attr:`in_maps` (List[Tensor[int]]): A list of long tensors that contain mapping from inputs to the union output. Please see the example for more details.
    #         :attr:`out_maps` (List[Tensor[int]]): A list of long tensors that contain a mapping from input to the union output. Please see the example for more details.

    #     Example::

    #         >>> # Adding two sparse tensors: A, B
    #         >>> out_key = CoordsKey(coords_man.D)
    #         >>> ins, outs = coords_man.get_union_map((A.coords_key, B.coords_key), out_key)
    #         >>> N = coords_man.get_coords_size_by_coords_key(out_key)
    #         >>> out_F = torch.zeros((N, A.F.size(1)), dtype=A.dtype)
    #         >>> out_F[outs[0]] = A.F[ins[0]]
    #         >>> out_F[outs[1]] += B.F[ins[1]]

    #     """
    #     return self.CPPCoordsManager.getUnionMap(
    #         [key.CPPCoordsKey for key in in_keys], out_key.CPPCoordsKey
    #     )

    # def get_coords_size_by_coords_key(self, coords_key):
    #     assert isinstance(coords_key, CoordsKey)
    #     return self.CPPCoordsManager.getCoordsSize(coords_key.CPPCoordsKey)

    # def get_mapping_by_tensor_strides(self, in_tensor_strides, out_tensor_strides):
    #     in_key = self._get_coordinate_map_key(in_tensor_strides)
    #     out_key = self._get_coordinate_map_key(out_tensor_strides)
    #     return self.get_mapping_by_coords_key(in_key, out_key)

    # def permute_label(
    #     self, label, max_label, target_tensor_stride, label_tensor_stride=1
    # ):
    #     if target_tensor_stride == label_tensor_stride:
    #         return label

    #     label_coords_key = self._get_coordinate_map_key(label_tensor_stride)
    #     target_coords_key = self._get_coordinate_map_key(target_tensor_stride)

    #     permutation = self.get_mapping_by_coords_key(
    #         label_coords_key, target_coords_key
    #     )
    #     nrows = self.get_coords_size_by_coords_key(target_coords_key)

    #     label = label.contiguous().numpy()
    #     permutation = permutation.numpy()

    #     counter = np.zeros((nrows, max_label), dtype="int32")
    #     np.add.at(counter, (permutation, label), 1)
    #     return torch.from_numpy(np.argmax(counter, 1))

    # def print_diagnostics(self, coords_key: CoordsKey):
    #     assert isinstance(coords_key, CoordsKey)
    #     self.CPPCoordsManager.printDiagnostics(coords_key.CPPCoordsKey)

    def __repr__(self):
        return "CoordinateManager(\n" + str(self._manager) + "  )\n"
