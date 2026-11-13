#pragma once
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/encodable_value.h>
#include <memory>

void HandleAiInput(const flutter::MethodCall<flutter::EncodableValue>& call,
                   std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
