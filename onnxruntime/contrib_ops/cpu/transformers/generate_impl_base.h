// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once
#include <memory>
#include <vector>
#include <utility>
#include "contrib_ops/cpu/transformers/beam_search_shared.h"

namespace onnxruntime {
namespace contrib {

namespace transformers {

class GenerateBase {
 public:
  GenerateBase(OpKernelContextInternal& context,
               const SessionState& decoder_session_state,
               concurrency::ThreadPool* thread_pool,
               void* cuda_stream,
               IConsoleDumper* cuda_dumper,
               const BeamSearchDeviceHelper::TopkFunc& topk_func,
               const BeamSearchDeviceHelper::DeviceCopyFunc<float>& device_copy_func)
      : context_(context),
        decoder_session_state_(decoder_session_state),
        thread_pool_(thread_pool),
        implicit_inputs_(context_.GetImplicitInputs()),
        cuda_stream_(cuda_stream),
        cuda_dumper_(cuda_dumper),
        cpu_allocator_(nullptr),
        temp_space_allocator_(nullptr),
        topk_func_(topk_func),
        device_copy_func_(device_copy_func) {
    cpu_allocator_ = decoder_session_state.GetExecutionProviders()
                         .Get(onnxruntime::kCpuExecutionProvider)
                         ->GetAllocator(0, OrtMemTypeDefault);
  }

  // Initialize by validating all the inputs, and allocating the output tensors.
  virtual Status Initialize() = 0;

  // Validate inputs.
  virtual Status CheckInputs(const OpKernelContextInternal& context) = 0;

  Status CheckScalarInput(const std::string& name, int index, bool required) const {
    auto* scalar_tensor = context_.Input<Tensor>(index);
      if (scalar_tensor) {
        if (!scalar_tensor->Shape().IsScalar()) {
          return ORT_MAKE_STATUS(ONNXRUNTIME,
                                 FAIL,
                                 "'BeamSearch' input ", name, " should be a scalar. Got shape of ",
                                 scalar_tensor->Shape());
        }
      } else if (required) {
        return ORT_MAKE_STATUS(ONNXRUNTIME,
                               FAIL,
                               "'BeamSearch' input ", name, " is required");
      }
      return Status::OK();
  }

 protected:

  bool IsCuda() const { return cuda_stream_ != nullptr; }

  const IConsoleDumper* GetConsoleDumper() const { return IsCuda() ? cuda_dumper_ : &(cpu_dumper_); }

  OpKernelContextInternal& context_;

  const SessionState& decoder_session_state_;

  concurrency::ThreadPool* thread_pool_;

  const std::vector<const OrtValue*>& implicit_inputs_;

  void* cuda_stream_;

  IConsoleDumper* cuda_dumper_;
  CpuTensorConsoleDumper cpu_dumper_;

  LogitsProcessorList logits_processors_;

  AllocatorPtr cpu_allocator_;
  AllocatorPtr temp_space_allocator_;

  // Device specific functions
  BeamSearchDeviceHelper::TopkFunc topk_func_;
  BeamSearchDeviceHelper::DeviceCopyFunc<float> device_copy_func_;
};

}  // namespace transformers
}  // namespace contrib
}  // namespace onnxruntime
