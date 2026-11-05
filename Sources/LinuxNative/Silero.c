#include "LinuxNative.h"
#include <dlfcn.h>
#include <math.h>
#include <onnxruntime_c_api.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
static const OrtApi *ort;
static OrtEnv *environment;
static void *library;
static pthread_once_t initialize = PTHREAD_ONCE_INIT;
static int good(OrtStatus *status) {
  if (!status)
    return 1;
  ort->ReleaseStatus(status);
  return 0;
}
static void load_runtime(void) {
  library = dlopen("libonnxruntime.so.1", RTLD_NOW | RTLD_LOCAL);
  if (!library)
    return;
  const OrtApiBase *(*base)(void) = dlsym(library, "OrtGetApiBase");
  if (!base)
    return;
  ort = base()->GetApi(ORT_API_VERSION);
  if (!ort || !good(ort->CreateEnv(ORT_LOGGING_LEVEL_FATAL, "StillePostVAD",
                                   &environment)))
    ort = NULL;
}
struct sp_silero {
  OrtSession *session;
  OrtMemoryInfo *memory;
  float state[256], context[64];
};
void sp_silero_free(sp_silero *value) {
  if (!value)
    return;
  if (value->session)
    ort->ReleaseSession(value->session);
  if (value->memory)
    ort->ReleaseMemoryInfo(value->memory);
  memset(value, 0, sizeof(*value));
  free(value);
}
sp_silero *sp_silero_new(const char *path) {
  pthread_once(&initialize, load_runtime);
  if (!ort)
    return NULL;
  sp_silero *value = calloc(1, sizeof(*value));
  OrtSessionOptions *options = NULL;
  if (!value)
    return NULL;
  int ok = good(ort->CreateSessionOptions(&options));
  if (ok)
    ok =
        good(ort->SetIntraOpNumThreads(options, 1)) &&
        good(ort->SetInterOpNumThreads(options, 1)) &&
        good(ort->SetSessionGraphOptimizationLevel(options,
                                                   ORT_ENABLE_EXTENDED)) &&
        good(ort->SetSessionLogSeverityLevel(options, ORT_LOGGING_LEVEL_FATAL));
  if (ok)
    ok =
        good(ort->CreateSession(environment, path, options, &value->session)) &&
        good(ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault,
                                      &value->memory));
  if (options)
    ort->ReleaseSessionOptions(options);
  if (!ok) {
    sp_silero_free(value);
    return NULL;
  }
  return value;
}
static int tensor_size(OrtValue *value, size_t expected) {
  OrtTensorTypeAndShapeInfo *info = NULL;
  size_t count = 0;
  ONNXTensorElementDataType type;
  int ok = good(ort->GetTensorTypeAndShape(value, &info));
  if (ok)
    ok = good(ort->GetTensorShapeElementCount(info, &count)) &&
         good(ort->GetTensorElementType(info, &type)) && count == expected &&
         type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
  if (info)
    ort->ReleaseTensorTypeAndShapeInfo(info);
  return ok;
}
int sp_silero_probability(sp_silero *value, const float samples[4096],
                          float *probability) {
  if (!value || !samples || !probability)
    return 0;
  for (int i = 0; i < 4096; i++)
    if (!isfinite(samples[i]))
      return 0;
  const char *inputs[] = {"input", "state", "sr"},
             *outputs[] = {"output", "stateN"};
  const int64_t audio_shape[] = {1, 576}, state_shape[] = {2, 1, 128};
  int64_t rate = 16000;
  float product = 1;
  for (int frame = 0; frame < 8; frame++) {
    float audio[576];
    memcpy(audio, value->context, sizeof(value->context));
    memcpy(audio + 64, samples + frame * 512, 512 * sizeof(float));
    OrtValue *input[3] = {NULL, NULL, NULL}, *output[2] = {NULL, NULL};
    int ok = good(ort->CreateTensorWithDataAsOrtValue(
                 value->memory, audio, sizeof(audio), audio_shape, 2,
                 ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input[0])) &&
             good(ort->CreateTensorWithDataAsOrtValue(
                 value->memory, value->state, sizeof(value->state), state_shape,
                 3, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input[1])) &&
             good(ort->CreateTensorWithDataAsOrtValue(
                 value->memory, &rate, sizeof(rate), NULL, 0,
                 ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &input[2]));
    if (ok)
      ok = good(ort->Run(value->session, NULL, inputs,
                         (const OrtValue *const *)input, 3, outputs, 2,
                         output)) &&
           tensor_size(output[0], 1) && tensor_size(output[1], 256);
    float *chance = NULL, *state = NULL;
    if (ok)
      ok = good(ort->GetTensorMutableData(output[0], (void **)&chance)) &&
           good(ort->GetTensorMutableData(output[1], (void **)&state));
    if (ok) {
      ok = isfinite(*chance) && *chance >= 0 && *chance <= 1;
      for (int i = 0; i < 256 && ok; i++)
        if (!isfinite(state[i]))
          ok = 0;
      if (ok) {
        product *= 1 - *chance;
        memcpy(value->state, state, sizeof(value->state));
        memcpy(value->context, audio + 512, sizeof(value->context));
      }
    }
    for (int i = 0; i < 3; i++)
      if (input[i])
        ort->ReleaseValue(input[i]);
    for (int i = 0; i < 2; i++)
      if (output[i])
        ort->ReleaseValue(output[i]);
    if (!ok)
      return 0;
  }
  *probability = 1 - product;
  return isfinite(*probability);
}
