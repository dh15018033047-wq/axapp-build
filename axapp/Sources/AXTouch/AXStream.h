//
//  AXStream.h
//  H.264 屏幕推流与远控2状态接口
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 启动推流服务（监听 port，默认 27184）
BOOL AXStreamStart(uint16_t port);

/// 停止推流并释放编码器
void AXStreamStop(void);

/// 是否在推流
BOOL AXStreamIsRunning(void);

/// 设置真 UDID（PC 端经 10010 传入；preamble 用它关联真机）
void AXStreamSetUDID(NSString *udid);

/// 用户手填 / PC 下发：写入并持久化（Keychain），此后 preamble 一律用它
void AXStreamSetUDIDPersist(NSString *udid);

/// 当前生效的 UDID（空串＝还没有）
NSString *AXStreamCurrentUDID(void);

/// 采集方案：0=XCUITest(截图) 1=ReplayKit。仅在 Start 之前设置有效。
void AXStreamSetScheme(int s);

/* 测试档位：采集方式 + 截图编码格式 + 质量 的组合 */
int         AXStreamProfileCount(void);
const char *AXStreamProfileName(int idx);
const char *AXStreamProfileDesc(int idx);
int         AXStreamProfileCapture(int idx);
void        AXStreamApplyProfile(int idx);
int  AXStreamGetScheme(void);
/// 实际生效的方案：0=XCUITest 1=ReplayKit 2=ReplayKit 拿不到帧已回退 XCUITest
int  AXStreamActiveScheme(void);

/// 截图质量参数（0~1，默认 1.0）
void AXStreamSetImgQuality(double q);

/// 截图编码格式（UTI）：public.jpeg 或 public.png
void AXStreamSetImgFormat(NSString *uti);

/// 解码路径：0=全解 + CGContext 重采样  1=ImageIO thumbnail 直解  2=GPU
void AXStreamSetDecodeMode(int thumb);

/// 静止画面自动降帧开关
void AXStreamSetStaticDrop(int on);

/// 静止时的下限帧率
void AXStreamSetStaticFps(int fps);

/// 发热定位：分段跑
void AXStreamSetBenchMode(int m);

/// 提交手势后暂停抓图的时长
void AXStreamSetPauseMs(int ms);

/// 统计：fps / 码率 / 客户端数 / 编码尺寸 / 最近错误
NSDictionary *AXStreamStats(void);

/// 设置编码参数（码率 bps、目标帧率、最长边像素）
void AXStreamSetParams(int bitrateBps, int fps, int maxSide);

/// 调 XCTest 的「事件确认间隔」（秒）
void AXSetEventConfirmInterval(double sec);

/// ======== 远控2 新增状态与后台保活接口 ========
/// 标记电脑端刚刚活跃（10010 收到命令或 27184 收到连接）
void AXMarkPCActive(const char * _Nullable ip);

/// 当前是否已连接电脑（27184 有推流客户端 或 20秒内 10010 有电脑通信）
BOOL AXIsPCConnected(void);

/// 当前连接的电脑 IP 地址（例如 "192.168.1.34"）
NSString *AXGetConnectedPCIP(void);

/// 当前 27184 视频流客户端数
int AXStreamClientCount(void);

/// 当前已发送的视频总帧数
int AXStreamSentFrames(void);

/// 累计执行的 AI 触控/按键动作数
int AXGetTotalActionCount(void);

/// 后台常驻保活开关控制
void AXSetKeepAliveEnabled(BOOL enabled);
BOOL AXIsKeepAliveEnabled(void);

/// 主动向电脑端控制中心 (192.168.1.34:18765) 发送握手并刷新投屏
void AXTriggerConnectPC(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
