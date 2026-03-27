// =============================================================================
// AudioCapture.cpp — WASAPI Loopback 音频采集实现
// =============================================================================
// 基于 P2.1 Windows Audio Spike 验证结果，WASAPI loopback 可以捕获
// 大多数应用（Chrome、Zoom、Teams 等）的系统音频输出。
// =============================================================================

#include "AudioCapture.h"
#include <iostream>
#include <cmath>
#include <algorithm>

#define REFTIMES_PER_SEC  10000000
#define REFTIMES_PER_MILLISEC 10000

namespace SimultaneousInterpreter {

// =============================================================================
// 构造与析构
// =============================================================================
AudioCapture::AudioCapture() {}
AudioCapture::~AudioCapture() { stop(); }

// =============================================================================
// 启动音频采集
// =============================================================================
bool AudioCapture::start(AudioLevelCallback onLevel, AudioBufferCallback onBuffer) {
    if (m_isCapturing.load()) return true;

    m_onLevel = std::move(onLevel);
    m_onBuffer = std::move(onBuffer);

    m_isCapturing.store(true);
    m_captureThread = std::thread(&AudioCapture::captureThreadFunc, this);

    if (!m_captureThread.joinable()) {
        m_isCapturing.store(false);
        return false;
    }

    std::cout << "[AudioCapture] 音频采集已启动" << std::endl;
    return true;
}

// =============================================================================
// 停止音频采集
// =============================================================================
void AudioCapture::stop() {
    if (!m_isCapturing.load()) return;
    m_isCapturing.store(false);
    if (m_captureThread.joinable()) m_captureThread.join();
    std::cout << "[AudioCapture] 音频采集已停止" << std::endl;
}

// =============================================================================
// 获取默认音频输出设备名称
// =============================================================================
std::string AudioCapture::getDefaultDeviceName() const {
    std::string name = "未知设备";
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool comInitialized = SUCCEEDED(hr);

    IMMDeviceEnumerator* pEnum = nullptr;
    IMMDevice* pDev = nullptr;
    IPropertyStore* pProps = nullptr;

    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
            CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void**)&pEnum))) {
        if (SUCCEEDED(pEnum->GetDefaultAudioEndpoint(eRender, eConsole, &pDev))) {
            if (SUCCEEDED(pDev->OpenPropertyStore(STGM_READ, &pProps))) {
                PROPVARIANT varName;
                PropVariantInit(&varName);
                if (SUCCEEDED(pProps->GetValue(PKEY_Device_FriendlyName, &varName))) {
                    if (varName.vt == VT_LPWSTR) {
                        int len = WideCharToMultiByte(CP_UTF8, 0,
                            varName.pwszVal, -1, nullptr, 0, nullptr, nullptr);
                        if (len > 0) {
                            name.resize(len - 1);
                            WideCharToMultiByte(CP_UTF8, 0,
                                varName.pwszVal, -1, name.data(), len, nullptr, nullptr);
                        }
                    }
                    PropVariantClear(&varName);
                }
                pProps->Release();
            }
            pDev->Release();
        }
        pEnum->Release();
    }
    if (comInitialized) CoUninitialize();
    return name;
}

// =============================================================================
// 采集线程主函数
// =============================================================================
void AudioCapture::captureThreadFunc() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        std::cerr << "[AudioCapture] COM 初始化失败: 0x" << std::hex << hr << std::endl;
        m_isCapturing.store(false);
        return;
    }

    // 获取默认音频渲染设备
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), (void**)&m_pDeviceEnumerator);
    if (FAILED(hr)) {
        std::cerr << "[AudioCapture] 创建设备枚举器失败" << std::endl;
        CoUninitialize();
        m_isCapturing.store(false);
        return;
    }

    hr = m_pDeviceEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &m_pDevice);
    if (FAILED(hr)) {
        std::cerr << "[AudioCapture] 获取默认输出设备失败" << std::endl;
        m_pDeviceEnumerator->Release();
        CoUninitialize();
        m_isCapturing.store(false);
        return;
    }

    // 打印设备名称
    IPropertyStore* pProps = nullptr;
    if (SUCCEEDED(m_pDevice->OpenPropertyStore(STGM_READ, &pProps))) {
        PROPVARIANT varName;
        PropVariantInit(&varName);
        if (SUCCEEDED(pProps->GetValue(PKEY_Device_FriendlyName, &varName))) {
            if (varName.vt == VT_LPWSTR) {
                int len = WideCharToMultiByte(CP_UTF8, 0,
                    varName.pwszVal, -1, nullptr, 0, nullptr, nullptr);
                if (len > 0) {
                    std::string deviceName(len - 1, '\0');
                    WideCharToMultiByte(CP_UTF8, 0,
                        varName.pwszVal, -1, deviceName.data(), len, nullptr, nullptr);
                    std::cout << "[AudioCapture] 采集设备: " << deviceName << std::endl;
                }
            }
            PropVariantClear(&varName);
        }
        pProps->Release();
    }

    // 激活 IAudioClient
    hr = m_pDevice->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&m_pAudioClient);
    if (FAILED(hr)) {
        std::cerr << "[AudioCapture] 激活 IAudioClient 失败" << std::endl;
        m_pDevice->Release(); m_pDeviceEnumerator->Release();
        CoUninitialize(); m_isCapturing.store(false); return;
    }

    // 获取混音格式
    WAVEFORMATEX* pDeviceFormat = nullptr;
    hr = m_pAudioClient->GetMixFormat(&pDeviceFormat);
    if (FAILED(hr)) {
        std::cerr << "[AudioCapture] 获取混音格式失败" << std::endl;
        m_pAudioClient->Release(); m_pDevice->Release(); m_pDeviceEnumerator->Release();
        CoUninitialize(); m_isCapturing.store(false); return;
    }

    std::cout << "[AudioCapture] 设备格式: " << pDeviceFormat->nSamplesPerSec
              << "Hz, " << pDeviceFormat->nChannels << "通道, "
              << pDeviceFormat->wBitsPerSample << "bit" << std::endl;

    // 初始化音频客户端（Loopback 模式）
    hr = m_pAudioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
        AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
        REFTIMES_PER_SEC, 0, pDeviceFormat, nullptr);
    CoTaskMemFree(pDeviceFormat);

    if (FAILED(hr)) {
        std::cerr << "[AudioCapture] 初始化 IAudioClient 失败" << std::endl;
        m_pAudioClient->Release(); m_pDevice->Release(); m_pDeviceEnumerator->Release();
        CoUninitialize(); m_isCapturing.store(false); return;
    }

    hr = m_pAudioClient->GetService(__uuidof(IAudioCaptureClient), (void**)&m_pCaptureClient);
    if (FAILED(hr)) {
        std::cerr << "[AudioCapture] 获取 IAudioCaptureClient 失败" << std::endl;
        m_pAudioClient->Release(); m_pDevice->Release(); m_pDeviceEnumerator->Release();
        CoUninitialize(); m_isCapturing.store(false); return;
    }

    hr = m_pAudioClient->Start();
    if (FAILED(hr)) {
        std::cerr << "[AudioCapture] 启动采集失败" << std::endl;
    }

    // 采集循环
    WAVEFORMATEX* pCaptureFormat = nullptr;
    m_pAudioClient->GetMixFormat(&pCaptureFormat);
    UINT32 packetLength = 0;

    while (m_isCapturing.load()) {
        hr = m_pCaptureClient->GetNextPacketSize(&packetLength);
        if (FAILED(hr)) break;

        while (packetLength > 0 && m_isCapturing.load()) {
            BYTE* pData = nullptr;
            UINT32 numFrames = 0;
            DWORD flags = 0;

            hr = m_pCaptureClient->GetBuffer(&pData, &numFrames, &flags, nullptr, nullptr);
            if (FAILED(hr)) {
                if (hr == AUDCLNT_E_DEVICE_INVALIDATED) m_isCapturing.store(false);
                break;
            }

            if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && pData && numFrames > 0) {
                auto pcmData = resampleTo16kMono(pData, numFrames, pCaptureFormat);
                if (!pcmData.empty()) {
                    std::vector<float> floatSamples(pcmData.size());
                    for (size_t i = 0; i < pcmData.size(); ++i)
                        floatSamples[i] = static_cast<float>(pcmData[i]) / static_cast<float>(INT16_MAX);
                    float level = computeRMSLevel(floatSamples.data(), floatSamples.size());
                    if (m_onLevel) m_onLevel(level);
                    if (m_onBuffer) m_onBuffer(pcmData);
                }
            }

            hr = m_pCaptureClient->ReleaseBuffer(numFrames);
            if (FAILED(hr)) break;
            hr = m_pCaptureClient->GetNextPacketSize(&packetLength);
            if (FAILED(hr)) break;
        }
        if (m_isCapturing.load()) Sleep(1);
    }

    if (m_pAudioClient) m_pAudioClient->Stop();
    if (pCaptureFormat) CoTaskMemFree(pCaptureFormat);
    if (m_pCaptureClient)  { m_pCaptureClient->Release();  m_pCaptureClient = nullptr; }
    if (m_pAudioClient)    { m_pAudioClient->Release();     m_pAudioClient = nullptr; }
    if (m_pDevice)         { m_pDevice->Release();          m_pDevice = nullptr; }
    if (m_pDeviceEnumerator) { m_pDeviceEnumerator->Release(); m_pDeviceEnumerator = nullptr; }
    CoUninitialize();
}

// =============================================================================
// 重采样为 16kHz mono Int16 PCM
// =============================================================================
std::vector<int16_t> AudioCapture::resampleTo16kMono(
    const BYTE* pData, UINT32 numFrames, const WAVEFORMATEX* pFormat) const
{
    if (!pData || !pFormat || numFrames == 0) return {};

    const int channels = pFormat->nChannels;
    const int sampleRate = pFormat->nSamplesPerSec;
    const int bitsPerSample = pFormat->wBitsPerSample;
    if (channels == 0 || sampleRate == 0 || bitsPerSample == 0) return {};

    // 转 float 并混合为 mono
    std::vector<float> monoFloat(numFrames);
    if (bitsPerSample == 32 && pFormat->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        const float* pFloat = reinterpret_cast<const float*>(pData);
        for (UINT32 i = 0; i < numFrames; ++i) {
            float sum = 0.0f;
            for (int ch = 0; ch < channels; ++ch) sum += pFloat[i * channels + ch];
            monoFloat[i] = sum / channels;
        }
    } else if (bitsPerSample == 16) {
        const int16_t* pInt16 = reinterpret_cast<const int16_t*>(pData);
        for (UINT32 i = 0; i < numFrames; ++i) {
            float sum = 0.0f;
            for (int ch = 0; ch < channels; ++ch) sum += static_cast<float>(pInt16[i * channels + ch]);
            monoFloat[i] = (sum / channels) / static_cast<float>(INT16_MAX);
        }
    } else if (bitsPerSample == 24) {
        const BYTE* pBytes = pData;
        int bytesPerFrame = channels * 3;
        for (UINT32 i = 0; i < numFrames; ++i) {
            float sum = 0.0f;
            for (int ch = 0; ch < channels; ++ch) {
                int offset = i * bytesPerFrame + ch * 3;
                int32_t sample = static_cast<int32_t>(pBytes[offset]) |
                    (static_cast<int32_t>(pBytes[offset + 1]) << 8) |
                    (static_cast<int32_t>(pBytes[offset + 2]) << 16);
                if (sample & 0x800000) sample |= 0xFF000000;
                sum += static_cast<float>(sample) / 8388608.0f;
            }
            monoFloat[i] = sum / channels;
        }
    } else {
        return {};
    }

    // 重采样到 16kHz
    if (sampleRate == TARGET_SAMPLE_RATE) {
        std::vector<int16_t> output(numFrames);
        for (UINT32 i = 0; i < numFrames; ++i)
            output[i] = static_cast<int16_t>(std::clamp(
                monoFloat[i] * static_cast<float>(INT16_MAX),
                static_cast<float>(INT16_MIN), static_cast<float>(INT16_MAX)));
        return output;
    }

    double ratio = static_cast<double>(TARGET_SAMPLE_RATE) / sampleRate;
    size_t outputLength = static_cast<size_t>(numFrames * ratio);
    if (outputLength == 0) return {};

    std::vector<int16_t> output(outputLength);
    for (size_t i = 0; i < outputLength; ++i) {
        double srcIndex = static_cast<double>(i) / ratio;
        size_t idx0 = static_cast<size_t>(srcIndex);
        size_t idx1 = std::min(idx0 + 1, static_cast<size_t>(numFrames - 1));
        double frac = srcIndex - idx0;
        float interp = monoFloat[idx0] * static_cast<float>(1.0 - frac)
                     + monoFloat[idx1] * static_cast<float>(frac);
        output[i] = static_cast<int16_t>(std::clamp(
            interp * static_cast<float>(INT16_MAX),
            static_cast<float>(INT16_MIN), static_cast<float>(INT16_MAX)));
    }
    return output;
}

// =============================================================================
// 计算 RMS 音频电平
// =============================================================================
float AudioCapture::computeRMSLevel(const float* samples, size_t count) {
    if (!samples || count == 0) return 0.0f;
    double sum = 0.0;
    for (size_t i = 0; i < count; ++i)
        sum += static_cast<double>(samples[i]) * static_cast<double>(samples[i]);
    double rms = std::sqrt(sum / static_cast<double>(count));
    return static_cast<float>(std::clamp(rms * 10.0, 0.0, 1.0));
}

} // namespace SimultaneousInterpreter
