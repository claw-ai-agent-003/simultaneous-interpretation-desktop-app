// =============================================================================
// AudioCapture.h — WASAPI Loopback 音频采集
// =============================================================================
// 功能说明:
//   使用 Windows Audio Session API (WASAPI) 的 loopback 模式，
//   捕获系统默认音频输出设备的声音（例如 Zoom、Teams 会议音频）。
//   无需安装任何第三方虚拟音频线缆驱动。
//
// 技术要点:
//   - COM 初始化/反初始化 (CoInitializeEx)
//   - IMMDeviceEnumerator 枚举默认渲染设备
//   - IAudioClient + AUDCLNT_STREAMFLAGS_LOOPBACK 启用回环采集
//   - IAudioCaptureClient 获取音频缓冲区
//   - 自动重采样到 16kHz mono（Whisper 要求的输入格式）
//
// 线程模型:
//   采集运行在独立的后台线程上，通过回调通知主线程。
//   所有 COM 操作均在采集线程上执行。
//
// 参考: P2.1 Windows Audio Spike 验证结论
// =============================================================================

#pragma once

#include <Windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functional>
#include <memory>
#include <mutex>
#include <atomic>
#include <thread>
#include <string>
#include <vector>

namespace SimultaneousInterpreter {

// =============================================================================
// 音频数据回调类型
// =============================================================================
// onAudioLevel:  音频电平回调，参数为归一化电平值 [0.0, 1.0]
// onAudioBuffer: 音频数据回调，参数为 16kHz mono Int16 PCM 数据
// =============================================================================
using AudioLevelCallback = std::function<void(float)>;
using AudioBufferCallback = std::function<void(const std::vector<int16_t>&)>;

// =============================================================================
// AudioCapture — WASAPI Loopback 音频采集器
// =============================================================================
class AudioCapture {
public:
    AudioCapture();
    ~AudioCapture();

    // 禁止拷贝和移动（COM 对象管理复杂）
    AudioCapture(const AudioCapture&) = delete;
    AudioCapture& operator=(const AudioCapture&) = delete;

    /// 启动音频采集
    /// @param onLevel  音频电平更新回调（可从 UI 线程调用）
    /// @param onBuffer 音频数据回调（16kHz mono Int16 PCM）
    /// @return 成功返回 true，失败返回 false
    bool start(AudioLevelCallback onLevel, AudioBufferCallback onBuffer);

    /// 停止音频采集，释放所有 COM 资源
    void stop();

    /// 是否正在采集中
    bool isCapturing() const { return m_isCapturing.load(); }

    /// 获取默认音频输出设备的友好名称
    std::string getDefaultDeviceName() const;

private:
    /// 采集线程主函数
    void captureThreadFunc();

    /// 将任意格式的音频重采样为 16kHz mono Int16
    /// @param pData     原始音频数据指针
    /// @param numFrames 帧数
    /// @param pFormat   原始音频格式 (WAVEFORMATEX*)
    /// @return 重采样后的 16kHz mono Int16 PCM 数据
    std::vector<int16_t> resampleTo16kMono(
        const BYTE* pData,
        UINT32 numFrames,
        const WAVEFORMATEX* pFormat
    ) const;

    /// 计算 RMS 音频电平
    /// @param samples 浮点采样数据
    /// @return 归一化电平 [0.0, 1.0]
    static float computeRMSLevel(const float* samples, size_t count);

    // COM 接口指针
    IMMDeviceEnumerator* m_pDeviceEnumerator{nullptr};
    IMMDevice*           m_pDevice{nullptr};
    IAudioClient*        m_pAudioClient{nullptr};
    IAudioCaptureClient* m_pCaptureClient{nullptr};

    // 采集线程
    std::thread          m_captureThread;
    std::atomic<bool>    m_isCapturing{false};

    // 回调函数
    AudioLevelCallback   m_onLevel;
    AudioBufferCallback  m_onBuffer;

    // 目标采样率（Whisper 要求）
    static constexpr int TARGET_SAMPLE_RATE = 16000;
    // 音频缓冲区大小（帧数）
    static constexpr int BUFFER_FRAMES = 4096;
};

} // namespace SimultaneousInterpreter
