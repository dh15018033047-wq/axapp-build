//
//  AXMainViewController.m
//  远控2 (Mika 远控 v3.0) 主界面与「AI控制中」全局悬浮窗控制器
//
#import "AXMainViewController.h"
#import "AXLogViewerViewController.h"
#import "AXStream.h"
#import "UITheme.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <string.h>

extern BOOL AXAgentIsReady(void);
extern NSString *AXAgentLastError(void);
extern NSString *AXAgentLogPath(void);
extern void AXAgentStartSticky(void);
extern BOOL AXAgentIsBootstrapping(void);
extern BOOL AXAgentPressHome(void);
extern void AXAgentSetHIDTap(int on);
extern int  AXAgentGetHIDTap(void);

static NSString *const kFloatOverlayKey = @"yk2.float.overlay.enabled";
static NSString *const kBgKeepAliveKey  = @"yk2.bg.keepalive.enabled";

static NSString *AXBuildTag(void) {
    NSString *b = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"200";
    NSString *s = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"3.0";
    return [NSString stringWithFormat:@"v%@-b%@", s, b];
}

static NSString *AXLanIP(void) {
    struct ifaddrs *addrs = NULL;
    NSString *result = @"未连接WiFi";
    if (getifaddrs(&addrs) == 0) {
        for (struct ifaddrs *a = addrs; a; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
            if (strcmp(a->ifa_name, "en0") != 0) continue;
            char buf[INET_ADDRSTRLEN] = {0};
            struct sockaddr_in *sin = (struct sockaddr_in *)a->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                result = [NSString stringWithUTF8String:buf];
            }
        }
        freeifaddrs(addrs);
    }
    return result;
}

#pragma mark - UI 基础组件

@interface AXChipBadge : UILabel
+ (instancetype)badgeWithText:(NSString *)t fg:(UIColor *)fg bg:(UIColor *)bg;
@end
@implementation AXChipBadge
+ (instancetype)badgeWithText:(NSString *)t fg:(UIColor *)fg bg:(UIColor *)bg {
    UILabel *l = [UILabel new];
    l.text = t;
    l.textColor = fg;
    l.backgroundColor = bg;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.layer.cornerRadius = 6;
    l.layer.masksToBounds = YES;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}
@end

@interface AXCardView : UIView
+ (instancetype)card;
@end
@implementation AXCardView
+ (instancetype)card {
    UIView *v = [UIView new];
    v.backgroundColor = ATCard();
    v.layer.cornerRadius = AT_CARD_RADIUS;
    v.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    v.layer.borderColor = ATDivider().CGColor;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    return v;
}
@end

@interface AXInfoRow : UIView
@property (nonatomic, strong) UILabel *keyLabel;
@property (nonatomic, strong) UILabel *valueLabel;
- (instancetype)initWithKey:(NSString *)key;
@end
@implementation AXInfoRow
- (instancetype)initWithKey:(NSString *)key {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _keyLabel = [UILabel new];
        _keyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _keyLabel.text = key;
        _keyLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _keyLabel.textColor = ATSubText();
        [self addSubview:_keyLabel];

        _valueLabel = [UILabel new];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.text = @"-";
        _valueLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _valueLabel.textColor = ATText();
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.adjustsFontSizeToFitWidth = YES;
        _valueLabel.minimumScaleFactor = 0.75;
        [self addSubview:_valueLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_keyLabel.topAnchor      constraintEqualToAnchor:self.topAnchor],
            [_keyLabel.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
            [_keyLabel.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
            [_keyLabel.widthAnchor    constraintEqualToConstant:118],

            [_valueLabel.topAnchor    constraintEqualToAnchor:self.topAnchor],
            [_valueLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_valueLabel.leadingAnchor  constraintEqualToAnchor:_keyLabel.trailingAnchor constant:8],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
    }
    return self;
}
@end

#pragma mark - AXMainViewController

@interface AXMainViewController () <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *content;

/* 顶部标题栏 */
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;

/* 软件内可拖动「AI控制中」悬浮框胶囊 */
@property (nonatomic, strong) UIView  *inAppFloatingPill;
@property (nonatomic, strong) UIView  *pillDot;
@property (nonatomic, strong) UILabel *pillLabel;

/* 系统级后台画中画悬浮框 (AVPictureInPictureController) */
@property (nonatomic, strong) UIView *pipContainerView;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *pipLayer;
@property (nonatomic, strong) AVPictureInPictureController *pipController;

/* 四大功能卡片 */
@property (nonatomic, strong) AXCardView *cardConnect;
@property (nonatomic, strong) AXCardView *cardFloating;
@property (nonatomic, strong) AXCardView *cardFeatures;
@property (nonatomic, strong) AXCardView *cardTools;

/* 卡片1：电脑连接与运行状态 */
@property (nonatomic, strong) UIView   *connBanner;
@property (nonatomic, strong) UIView   *statusDot;
@property (nonatomic, strong) UILabel  *statusMainLabel;
@property (nonatomic, strong) UILabel  *statusSubLabel;
@property (nonatomic, strong) UIButton *connectPCBtn;
@property (nonatomic, strong) UIButton *goBgBtn;

/* 卡片2：悬浮框与后台运行开关 */
@property (nonatomic, strong) UISwitch *floatSwitch;
@property (nonatomic, strong) UISwitch *bgKeepSwitch;
@property (nonatomic, strong) UIButton *popPiPBtn;
@property (nonatomic, strong) UILabel  *floatStateHint;

/* 卡片3：全功能状态行 */
@property (nonatomic, strong) AXInfoRow *rowScreen;
@property (nonatomic, strong) AXInfoRow *rowTouch;
@property (nonatomic, strong) AXInfoRow *rowClipboard;
@property (nonatomic, strong) AXInfoRow *rowNetwork;
@property (nonatomic, strong) AXInfoRow *rowDevice;

/* 卡片4：工具按钮 */
@property (nonatomic, strong) UIButton *logsBtn;
@property (nonatomic, strong) UIButton *restartBtn;

/* 定时器与状态 */
@property (nonatomic, strong) NSTimer *uiTimer;
@property (nonatomic, assign) NSTimeInterval startTimestamp;
@property (nonatomic, assign) NSTimeInterval connectingUntil;
@property (nonatomic, assign) BOOL pulseToggle;
@end

@implementation AXMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ATBg();
    self.startTimestamp = [NSDate date].timeIntervalSince1970;
    self.connectingUntil = 0;

    /* 默认开启「显示悬浮框」与「后台常驻运行」 */
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:kFloatOverlayKey] == nil) {
        [ud setBool:YES forKey:kFloatOverlayKey];
    }
    if ([ud objectForKey:kBgKeepAliveKey] == nil) {
        [ud setBool:YES forKey:kBgKeepAliveKey];
    }
    AXSetKeepAliveEnabled([ud boolForKey:kBgKeepAliveKey]);
    AXAgentSetHIDTap(1);

    [self buildUI];
    [self setupSystemFloatingPiP];
    [self refreshAll];

    self.uiTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                    target:self
                                                  selector:@selector(onTimerTick)
                                                  userInfo:nil
                                                   repeats:YES];

    /* 监听退到后台通知：若开启了悬浮框，确保画中画与音频保活激活 */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onAppWillResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL s_booted = NO;
    if (!s_booted) {
        s_booted = YES;
        /* 启动即自动连接电脑并开启投屏服务 */
        [self triggerConnectPCWithToast:NO];
    }
    [self renderAndEnqueuePiPFrame];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.pipLayer && self.pipContainerView) {
        self.pipLayer.frame = self.pipContainerView.bounds;
    }
}

#pragma mark - 构建主界面

- (void)buildUI {
    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.showsVerticalScrollIndicator = NO;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    self.content = [UIView new];
    self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.content];

    /* 顶部标题区 */
    self.titleLabel = [UILabel new];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"远控2 · AI 智能远控中心";
    self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightHeavy];
    self.titleLabel.textColor = ATText();
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.content addSubview:self.titleLabel];

    self.subtitleLabel = [UILabel new];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.text = [NSString stringWithFormat:@"免越狱全功能版 %@  ·  后台常驻不退出", AXBuildTag()];
    self.subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.subtitleLabel.textColor = ATSubText();
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.content addSubview:self.subtitleLabel];

    self.cardConnect  = [AXCardView card];
    self.cardFloating = [AXCardView card];
    self.cardFeatures = [AXCardView card];
    self.cardTools    = [AXCardView card];

    [self.content addSubview:self.cardConnect];
    [self.content addSubview:self.cardFloating];
    [self.content addSubview:self.cardFeatures];
    [self.content addSubview:self.cardTools];

    [self buildCardConnect];
    [self buildCardFloating];
    [self buildCardFeatures];
    [self buildCardTools];
    [self buildInAppFloatingPill];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor      constraintEqualToAnchor:g.topAnchor],
        [self.scroll.bottomAnchor   constraintEqualToAnchor:g.bottomAnchor],
        [self.scroll.leadingAnchor  constraintEqualToAnchor:g.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [self.content.topAnchor      constraintEqualToAnchor:self.scroll.topAnchor],
        [self.content.bottomAnchor   constraintEqualToAnchor:self.scroll.bottomAnchor],
        [self.content.leadingAnchor  constraintEqualToAnchor:self.scroll.leadingAnchor],
        [self.content.trailingAnchor constraintEqualToAnchor:self.scroll.trailingAnchor],
        [self.content.widthAnchor    constraintEqualToAnchor:self.scroll.widthAnchor],

        [self.titleLabel.topAnchor      constraintEqualToAnchor:self.content.topAnchor constant:48],
        [self.titleLabel.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:16],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-16],

        [self.subtitleLabel.topAnchor      constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.subtitleLabel.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:16],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-16],

        [self.cardConnect.topAnchor      constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:14],
        [self.cardConnect.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardConnect.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],

        [self.cardFloating.topAnchor      constraintEqualToAnchor:self.cardConnect.bottomAnchor constant:12],
        [self.cardFloating.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardFloating.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],

        [self.cardFeatures.topAnchor      constraintEqualToAnchor:self.cardFloating.bottomAnchor constant:12],
        [self.cardFeatures.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardFeatures.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],

        [self.cardTools.topAnchor      constraintEqualToAnchor:self.cardFeatures.bottomAnchor constant:12],
        [self.cardTools.leadingAnchor  constraintEqualToAnchor:self.content.leadingAnchor constant:AT_PAD],
        [self.cardTools.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor constant:-AT_PAD],
        [self.cardTools.bottomAnchor   constraintEqualToAnchor:self.content.bottomAnchor constant:-28],
    ]];
}

#pragma mark - 卡片1：电脑连接与运行状态

- (void)buildCardConnect {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  💻 电脑连接与远控状态  " fg:ATBlue() bg:ATBlueBg()];
    [self.cardConnect addSubview:badge];

    self.connBanner = [UIView new];
    self.connBanner.translatesAutoresizingMaskIntoConstraints = NO;
    self.connBanner.backgroundColor = ATGreenBg();
    self.connBanner.layer.cornerRadius = 12;
    [self.cardConnect addSubview:self.connBanner];

    self.statusDot = [UIView new];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.backgroundColor = ATGreen();
    self.statusDot.layer.cornerRadius = 7;
    [self.connBanner addSubview:self.statusDot];

    self.statusMainLabel = [UILabel new];
    self.statusMainLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusMainLabel.text = @"正在连接电脑中...";
    self.statusMainLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    self.statusMainLabel.textColor = ATGreen();
    [self.connBanner addSubview:self.statusMainLabel];

    self.statusSubLabel = [UILabel new];
    self.statusSubLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusSubLabel.text = @"正在同步高清屏幕流与 AI 触控服务...";
    self.statusSubLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.statusSubLabel.textColor = ATText();
    self.statusSubLabel.numberOfLines = 2;
    [self.connBanner addSubview:self.statusSubLabel];

    self.connectPCBtn = [self buildBigButton:@"🔗 连接电脑" bg:ATBlue() fg:[UIColor whiteColor]];
    [self.connectPCBtn addTarget:self action:@selector(didTapConnectPC) forControlEvents:UIControlEventTouchUpInside];

    self.goBgBtn = [self buildBigButton:@"🏠 退到后台运行" bg:ATGreen() fg:[UIColor whiteColor]];
    [self.goBgBtn addTarget:self action:@selector(didTapGoBackground) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *btnRow = [self stackWith:@[self.connectPCBtn, self.goBgBtn]];
    [self.cardConnect addSubview:btnRow];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor     constraintEqualToAnchor:self.cardConnect.topAnchor constant:14],
        [badge.leadingAnchor constraintEqualToAnchor:self.cardConnect.leadingAnchor constant:16],
        [badge.heightAnchor  constraintEqualToConstant:26],

        [self.connBanner.topAnchor      constraintEqualToAnchor:badge.bottomAnchor constant:12],
        [self.connBanner.leadingAnchor  constraintEqualToAnchor:self.cardConnect.leadingAnchor constant:16],
        [self.connBanner.trailingAnchor constraintEqualToAnchor:self.cardConnect.trailingAnchor constant:-16],

        [self.statusDot.widthAnchor   constraintEqualToConstant:14],
        [self.statusDot.heightAnchor  constraintEqualToConstant:14],
        [self.statusDot.topAnchor     constraintEqualToAnchor:self.connBanner.topAnchor constant:14],
        [self.statusDot.leadingAnchor constraintEqualToAnchor:self.connBanner.leadingAnchor constant:14],

        [self.statusMainLabel.centerYAnchor  constraintEqualToAnchor:self.statusDot.centerYAnchor],
        [self.statusMainLabel.leadingAnchor  constraintEqualToAnchor:self.statusDot.trailingAnchor constant:10],
        [self.statusMainLabel.trailingAnchor constraintEqualToAnchor:self.connBanner.trailingAnchor constant:-12],

        [self.statusSubLabel.topAnchor      constraintEqualToAnchor:self.statusMainLabel.bottomAnchor constant:6],
        [self.statusSubLabel.leadingAnchor  constraintEqualToAnchor:self.statusDot.leadingAnchor],
        [self.statusSubLabel.trailingAnchor constraintEqualToAnchor:self.connBanner.trailingAnchor constant:-12],
        [self.statusSubLabel.bottomAnchor   constraintEqualToAnchor:self.connBanner.bottomAnchor constant:-12],

        [btnRow.topAnchor      constraintEqualToAnchor:self.connBanner.bottomAnchor constant:14],
        [btnRow.leadingAnchor  constraintEqualToAnchor:self.cardConnect.leadingAnchor constant:16],
        [btnRow.trailingAnchor constraintEqualToAnchor:self.cardConnect.trailingAnchor constant:-16],
        [btnRow.heightAnchor   constraintEqualToConstant:46],
        [btnRow.bottomAnchor   constraintEqualToAnchor:self.cardConnect.bottomAnchor constant:-16],
    ]];
}

#pragma mark - 卡片2：悬浮框与后台常驻设置（默认开启）

- (void)buildCardFloating {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  🤖 悬浮框与后台运行设置（默认开启）  " fg:ATPurple() bg:ATPurpleBg()];
    [self.cardFloating addSubview:badge];

    /* 开关1：显示「AI控制中」悬浮框 */
    UILabel *sw1Title = [UILabel new];
    sw1Title.translatesAutoresizingMaskIntoConstraints = NO;
    sw1Title.text = @"🪟 显示「AI 控制中」悬浮框";
    sw1Title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    sw1Title.textColor = ATText();
    [self.cardFloating addSubview:sw1Title];

    UILabel *sw1Sub = [UILabel new];
    sw1Sub.translatesAutoresizingMaskIntoConstraints = NO;
    sw1Sub.text = @"默认打开：退到手机桌面或微信时悬浮显示「AI控制中 · 已连接电脑」状态窗";
    sw1Sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    sw1Sub.textColor = ATSubText();
    sw1Sub.numberOfLines = 2;
    [self.cardFloating addSubview:sw1Sub];

    self.floatSwitch = [UISwitch new];
    self.floatSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.floatSwitch.onTintColor = ATGreen();
    self.floatSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:kFloatOverlayKey];
    [self.floatSwitch addTarget:self action:@selector(didToggleFloatSwitch:) forControlEvents:UIControlEventValueChanged];
    [self.cardFloating addSubview:self.floatSwitch];

    UIView *div1 = [UIView new];
    div1.translatesAutoresizingMaskIntoConstraints = NO;
    div1.backgroundColor = ATDivider();
    [self.cardFloating addSubview:div1];

    /* 开关2：后台不退出常驻运行 */
    UILabel *sw2Title = [UILabel new];
    sw2Title.translatesAutoresizingMaskIntoConstraints = NO;
    sw2Title.text = @"🔋 后台常驻运行（切出软件不退出）";
    sw2Title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    sw2Title.textColor = ATText();
    [self.cardFloating addSubview:sw2Title];

    UILabel *sw2Sub = [UILabel new];
    sw2Sub.translatesAutoresizingMaskIntoConstraints = NO;
    sw2Sub.text = @"开启后按 Home 键退回桌面或打开其它软件时，远控与投屏持续后台运行";
    sw2Sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    sw2Sub.textColor = ATSubText();
    sw2Sub.numberOfLines = 2;
    [self.cardFloating addSubview:sw2Sub];

    self.bgKeepSwitch = [UISwitch new];
    self.bgKeepSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.bgKeepSwitch.onTintColor = ATGreen();
    self.bgKeepSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:kBgKeepAliveKey];
    [self.bgKeepSwitch addTarget:self action:@selector(didToggleBgSwitch:) forControlEvents:UIControlEventValueChanged];
    [self.cardFloating addSubview:self.bgKeepSwitch];

    /* 实时悬浮框画面容器（承载 AVSampleBufferDisplayLayer，退后台自动弹出为桌面悬浮框） */
    self.pipContainerView = [UIView new];
    self.pipContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.pipContainerView.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.16 alpha:1.0];
    self.pipContainerView.layer.cornerRadius = 12;
    self.pipContainerView.layer.masksToBounds = YES;
    [self.cardFloating addSubview:self.pipContainerView];

    self.popPiPBtn = [self buildBigButton:@"🪟 立即在屏幕弹出/收起「AI控制中」悬浮框" bg:ATPurpleBg() fg:ATPurple()];
    self.popPiPBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [self.popPiPBtn addTarget:self action:@selector(didTapPopPiP) forControlEvents:UIControlEventTouchUpInside];
    [self.cardFloating addSubview:self.popPiPBtn];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor     constraintEqualToAnchor:self.cardFloating.topAnchor constant:14],
        [badge.leadingAnchor constraintEqualToAnchor:self.cardFloating.leadingAnchor constant:16],
        [badge.heightAnchor  constraintEqualToConstant:26],

        [sw1Title.topAnchor     constraintEqualToAnchor:badge.bottomAnchor constant:14],
        [sw1Title.leadingAnchor constraintEqualToAnchor:self.cardFloating.leadingAnchor constant:16],
        [sw1Title.trailingAnchor constraintEqualToAnchor:self.floatSwitch.leadingAnchor constant:-10],

        [sw1Sub.topAnchor      constraintEqualToAnchor:sw1Title.bottomAnchor constant:4],
        [sw1Sub.leadingAnchor  constraintEqualToAnchor:sw1Title.leadingAnchor],
        [sw1Sub.trailingAnchor constraintEqualToAnchor:sw1Title.trailingAnchor],

        [self.floatSwitch.centerYAnchor  constraintEqualToAnchor:sw1Title.bottomAnchor constant:2],
        [self.floatSwitch.trailingAnchor constraintEqualToAnchor:self.cardFloating.trailingAnchor constant:-16],

        [div1.topAnchor      constraintEqualToAnchor:sw1Sub.bottomAnchor constant:12],
        [div1.leadingAnchor  constraintEqualToAnchor:self.cardFloating.leadingAnchor constant:16],
        [div1.trailingAnchor constraintEqualToAnchor:self.cardFloating.trailingAnchor constant:-16],
        [div1.heightAnchor   constraintEqualToConstant:1],

        [sw2Title.topAnchor     constraintEqualToAnchor:div1.bottomAnchor constant:12],
        [sw2Title.leadingAnchor constraintEqualToAnchor:self.cardFloating.leadingAnchor constant:16],
        [sw2Title.trailingAnchor constraintEqualToAnchor:self.bgKeepSwitch.leadingAnchor constant:-10],

        [sw2Sub.topAnchor      constraintEqualToAnchor:sw2Title.bottomAnchor constant:4],
        [sw2Sub.leadingAnchor  constraintEqualToAnchor:sw2Title.leadingAnchor],
        [sw2Sub.trailingAnchor constraintEqualToAnchor:sw2Title.trailingAnchor],

        [self.bgKeepSwitch.centerYAnchor  constraintEqualToAnchor:sw2Title.bottomAnchor constant:2],
        [self.bgKeepSwitch.trailingAnchor constraintEqualToAnchor:self.cardFloating.trailingAnchor constant:-16],

        [self.pipContainerView.topAnchor      constraintEqualToAnchor:sw2Sub.bottomAnchor constant:12],
        [self.pipContainerView.leadingAnchor  constraintEqualToAnchor:self.cardFloating.leadingAnchor constant:16],
        [self.pipContainerView.trailingAnchor constraintEqualToAnchor:self.cardFloating.trailingAnchor constant:-16],
        [self.pipContainerView.heightAnchor   constraintEqualToConstant:82],

        [self.popPiPBtn.topAnchor      constraintEqualToAnchor:self.pipContainerView.bottomAnchor constant:10],
        [self.popPiPBtn.leadingAnchor  constraintEqualToAnchor:self.cardFloating.leadingAnchor constant:16],
        [self.popPiPBtn.trailingAnchor constraintEqualToAnchor:self.cardFloating.trailingAnchor constant:-16],
        [self.popPiPBtn.heightAnchor   constraintEqualToConstant:40],
        [self.popPiPBtn.bottomAnchor   constraintEqualToAnchor:self.cardFloating.bottomAnchor constant:-14],
    ]];
}

#pragma mark - 卡片3：全功能状态与设备信息

- (void)buildCardFeatures {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  ⚡ 全功能远控模块状态  " fg:ATGreen() bg:ATGreenBg()];
    [self.cardFeatures addSubview:badge];

    self.rowScreen    = [[AXInfoRow alloc] initWithKey:@"📺 屏幕实时投屏"];
    self.rowTouch     = [[AXInfoRow alloc] initWithKey:@"👆 全局硬件触控"];
    self.rowClipboard = [[AXInfoRow alloc] initWithKey:@"📋 剪贴板与按键"];
    self.rowNetwork   = [[AXInfoRow alloc] initWithKey:@"🌐 本机连接地址"];
    self.rowDevice    = [[AXInfoRow alloc] initWithKey:@"📱 手机型号系统"];

    [self.cardFeatures addSubview:self.rowScreen];
    [self.cardFeatures addSubview:self.rowTouch];
    [self.cardFeatures addSubview:self.rowClipboard];
    [self.cardFeatures addSubview:self.rowNetwork];
    [self.cardFeatures addSubview:self.rowDevice];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor     constraintEqualToAnchor:self.cardFeatures.topAnchor constant:14],
        [badge.leadingAnchor constraintEqualToAnchor:self.cardFeatures.leadingAnchor constant:16],
        [badge.heightAnchor  constraintEqualToConstant:26],

        [self.rowScreen.topAnchor      constraintEqualToAnchor:badge.bottomAnchor constant:12],
        [self.rowScreen.leadingAnchor  constraintEqualToAnchor:self.cardFeatures.leadingAnchor constant:16],
        [self.rowScreen.trailingAnchor constraintEqualToAnchor:self.cardFeatures.trailingAnchor constant:-16],
        [self.rowScreen.heightAnchor   constraintEqualToConstant:24],

        [self.rowTouch.topAnchor      constraintEqualToAnchor:self.rowScreen.bottomAnchor constant:8],
        [self.rowTouch.leadingAnchor  constraintEqualToAnchor:self.cardFeatures.leadingAnchor constant:16],
        [self.rowTouch.trailingAnchor constraintEqualToAnchor:self.cardFeatures.trailingAnchor constant:-16],
        [self.rowTouch.heightAnchor   constraintEqualToConstant:24],

        [self.rowClipboard.topAnchor      constraintEqualToAnchor:self.rowTouch.bottomAnchor constant:8],
        [self.rowClipboard.leadingAnchor  constraintEqualToAnchor:self.cardFeatures.leadingAnchor constant:16],
        [self.rowClipboard.trailingAnchor constraintEqualToAnchor:self.cardFeatures.trailingAnchor constant:-16],
        [self.rowClipboard.heightAnchor   constraintEqualToConstant:24],

        [self.rowNetwork.topAnchor      constraintEqualToAnchor:self.rowClipboard.bottomAnchor constant:8],
        [self.rowNetwork.leadingAnchor  constraintEqualToAnchor:self.cardFeatures.leadingAnchor constant:16],
        [self.rowNetwork.trailingAnchor constraintEqualToAnchor:self.cardFeatures.trailingAnchor constant:-16],
        [self.rowNetwork.heightAnchor   constraintEqualToConstant:24],

        [self.rowDevice.topAnchor      constraintEqualToAnchor:self.rowNetwork.bottomAnchor constant:8],
        [self.rowDevice.leadingAnchor  constraintEqualToAnchor:self.cardFeatures.leadingAnchor constant:16],
        [self.rowDevice.trailingAnchor constraintEqualToAnchor:self.cardFeatures.trailingAnchor constant:-16],
        [self.rowDevice.heightAnchor   constraintEqualToConstant:24],
        [self.rowDevice.bottomAnchor   constraintEqualToAnchor:self.cardFeatures.bottomAnchor constant:-14],
    ]];
}

#pragma mark - 卡片4：诊断与维护工具

- (void)buildCardTools {
    AXChipBadge *badge = [AXChipBadge badgeWithText:@"  🛠️ 维护与运行日志  " fg:ATSubText() bg:ATDivider()];
    [self.cardTools addSubview:badge];

    self.restartBtn = [self buildBigButton:@"🔄 重启远控服务" bg:ATPurple() fg:[UIColor whiteColor]];
    [self.restartBtn addTarget:self action:@selector(didTapRestartStream) forControlEvents:UIControlEventTouchUpInside];

    self.logsBtn = [self buildBigButton:@"📄 查看运行日志" bg:ATText() fg:[UIColor whiteColor]];
    [self.logsBtn addTarget:self action:@selector(didTapLogs) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [self stackWith:@[self.restartBtn, self.logsBtn]];
    [self.cardTools addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor     constraintEqualToAnchor:self.cardTools.topAnchor constant:14],
        [badge.leadingAnchor constraintEqualToAnchor:self.cardTools.leadingAnchor constant:16],
        [badge.heightAnchor  constraintEqualToConstant:26],

        [row.topAnchor      constraintEqualToAnchor:badge.bottomAnchor constant:12],
        [row.leadingAnchor  constraintEqualToAnchor:self.cardTools.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:self.cardTools.trailingAnchor constant:-16],
        [row.heightAnchor   constraintEqualToConstant:44],
        [row.bottomAnchor   constraintEqualToAnchor:self.cardTools.bottomAnchor constant:-14],
    ]];
}

#pragma mark - 软件内顶部可拖动「AI控制中」悬浮框胶囊

- (void)buildInAppFloatingPill {
    self.inAppFloatingPill = [UIView new];
    self.inAppFloatingPill.translatesAutoresizingMaskIntoConstraints = NO;
    self.inAppFloatingPill.backgroundColor = [UIColor colorWithRed:0.07 green:0.10 blue:0.18 alpha:0.94];
    self.inAppFloatingPill.layer.cornerRadius = 18;
    self.inAppFloatingPill.layer.borderWidth = 1.2;
    self.inAppFloatingPill.layer.borderColor = ATGreen().CGColor;
    [self.view addSubview:self.inAppFloatingPill];

    self.pillDot = [UIView new];
    self.pillDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.pillDot.backgroundColor = ATGreen();
    self.pillDot.layer.cornerRadius = 5;
    [self.inAppFloatingPill addSubview:self.pillDot];

    self.pillLabel = [UILabel new];
    self.pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.pillLabel.text = @"🤖 AI控制中 · 远控2 | 已连接电脑";
    self.pillLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    self.pillLabel.textColor = [UIColor whiteColor];
    [self.inAppFloatingPill addSubview:self.pillLabel];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.inAppFloatingPill.topAnchor     constraintEqualToAnchor:g.topAnchor constant:6],
        [self.inAppFloatingPill.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.inAppFloatingPill.heightAnchor  constraintEqualToConstant:36],

        [self.pillDot.widthAnchor   constraintEqualToConstant:10],
        [self.pillDot.heightAnchor  constraintEqualToConstant:10],
        [self.pillDot.leadingAnchor constraintEqualToAnchor:self.inAppFloatingPill.leadingAnchor constant:14],
        [self.pillDot.centerYAnchor constraintEqualToAnchor:self.inAppFloatingPill.centerYAnchor],

        [self.pillLabel.leadingAnchor  constraintEqualToAnchor:self.pillDot.trailingAnchor constant:8],
        [self.pillLabel.trailingAnchor constraintEqualToAnchor:self.inAppFloatingPill.trailingAnchor constant:-14],
        [self.pillLabel.centerYAnchor  constraintEqualToAnchor:self.inAppFloatingPill.centerYAnchor],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDragPill:)];
    [self.inAppFloatingPill addGestureRecognizer:pan];
}

- (void)onDragPill:(UIPanGestureRecognizer *)pan {
    CGPoint trans = [pan translationInView:self.view];
    pan.view.center = CGPointMake(pan.view.center.x + trans.x, pan.view.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:self.view];
}

#pragma mark - iOS 15 原生全局画中画「AI控制中」后台悬浮框

- (void)setupSystemFloatingPiP {
    self.pipLayer = [AVSampleBufferDisplayLayer layer];
    self.pipLayer.frame = CGRectMake(0, 0, 360, 82);
    self.pipLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.pipLayer.opaque = YES;
    [self.pipContainerView.layer addSublayer:self.pipLayer];

    /* 先喂一帧初始画面，确保 AVPictureInPictureController 立刻识别出视频源尺寸 */
    [self renderAndEnqueuePiPFrame];

    if ([AVPictureInPictureController isPictureInPictureSupported]) {
        if (@available(iOS 15.0, *)) {
            AVPictureInPictureControllerContentSource *src =
                [[AVPictureInPictureControllerContentSource alloc]
                    initWithSampleBufferDisplayLayer:self.pipLayer
                                    playbackDelegate:self];
            self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:src];
            self.pipController.delegate = self;
            BOOL floatOn = [[NSUserDefaults standardUserDefaults] boolForKey:kFloatOverlayKey];
            self.pipController.canStartPictureInPictureAutomaticallyFromInline = floatOn;
            if ([self.pipController respondsToSelector:@selector(setRequiresLinearPlayback:)]) {
                self.pipController.requiresLinearPlayback = YES;
            }
            @try {
                [self.pipController setValue:@1 forKey:@"controlsStyle"];
            } @catch (NSException *e) {}
        }
    }
}

- (void)renderAndEnqueuePiPFrame {
    if (!self.pipLayer) return;
    if (self.pipLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.pipLayer flush];
    }

    const int W = 480;
    const int H = 110;
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
        return;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, W, H, 8, bpr, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        /* 翻转坐标系以便 UIKit 正向绘制文字 */
        CGContextTranslateCTM(ctx, 0, H);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        UIGraphicsPushContext(ctx);

        BOOL connected = AXIsPCConnected();
        BOOL connecting = ([NSDate date].timeIntervalSince1970 < self.connectingUntil);
        NSString *pcip = AXGetConnectedPCIP();
        if (!pcip.length) pcip = @"192.168.1.34";

        /* 背景与高亮边框 */
        UIColor *bgCol = [UIColor colorWithRed:0.06 green:0.09 blue:0.16 alpha:1.0];
        [bgCol setFill];
        UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, W, H) cornerRadius:14];
        [bgPath fill];

        UIColor *accent = connected ? ATGreen() : (connecting ? [UIColor orangeColor] : ATBlue());
        [accent setStroke];
        UIBezierPath *borderPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, W - 4, H - 4) cornerRadius:12];
        borderPath.lineWidth = 3.0;
        [borderPath stroke];

        /* 呼吸状态圆点 */
        UIColor *dotCol = self.pulseToggle ? accent : [accent colorWithAlphaComponent:0.55];
        [dotCol setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(18, 18, 16, 16)] fill];

        /* 第一行：🤖 AI 控制中 · 远控2 */
        NSString *line1 = @"🤖 AI 控制中 · 远控2（后台常驻）";
        NSDictionary *attr1 = @{
            NSFontAttributeName: [UIFont systemFontOfSize:20 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName: [UIColor whiteColor],
        };
        [line1 drawAtPoint:CGPointMake(42, 13) withAttributes:attr1];

        /* 第二行：电脑连接状态 */
        NSString *line2 = nil;
        if (connecting) {
            line2 = [NSString stringWithFormat:@"🟡 正在连接电脑中 (%@)...", pcip];
        } else if (connected) {
            line2 = [NSString stringWithFormat:@"🟢 已连接电脑 (%@) · 实时控制已激活", pcip];
        } else {
            line2 = [NSString stringWithFormat:@"🔵 等待电脑连接 · 本机 %@", AXLanIP()];
        }
        NSDictionary *attr2 = @{
            NSFontAttributeName: [UIFont systemFontOfSize:16 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: accent,
        };
        [line2 drawAtPoint:CGPointMake(18, 46) withAttributes:attr2];

        /* 第三行：投屏帧数 + 触控数 + 运行时长 */
        int elapsed = (int)MAX(0, [NSDate date].timeIntervalSince1970 - self.startTimestamp);
        NSString *line3 = [NSString stringWithFormat:@"📺 投屏帧数: %d   👆 AI动作: %d次   ⏱ 运行: %02d:%02d",
                           AXStreamSentFrames(), AXGetTotalActionCount(), elapsed / 60, elapsed % 60];
        NSDictionary *attr3 = @{
            NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.78 alpha:1.0],
        };
        [line3 drawAtPoint:CGPointMake(18, 76) withAttributes:attr3];

        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) == noErr && fmt) {
        CMSampleTimingInfo timing;
        timing.duration = CMTimeMake(1, 2);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
        timing.decodeTimeStamp = kCMTimeInvalid;

        CMSampleBufferRef sbuf = NULL;
        if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sbuf) == noErr && sbuf) {
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, YES);
            if (attachments && CFArrayGetCount(attachments) > 0) {
                CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
                CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            }
            [self.pipLayer enqueueSampleBuffer:sbuf];
            CFRelease(sbuf);
        }
        CFRelease(fmt);
    }
    CVPixelBufferRelease(pb);
}

#pragma mark - AVPictureInPictureSampleBufferPlaybackDelegate

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController setPlaying:(BOOL)playing {}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)pictureInPictureController {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)pictureInPictureController {
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController skipByInterval:(CMTime)skipInterval completionHandler:(void (^)(void))completionHandler {
    if (completionHandler) completionHandler();
}

#pragma mark - 定时器与状态刷新

- (void)onTimerTick {
    self.pulseToggle = !self.pulseToggle;
    [self refreshAll];
    [self renderAndEnqueuePiPFrame];
}

- (void)onAppWillResignActive {
    BOOL floatOn = [[NSUserDefaults standardUserDefaults] boolForKey:kFloatOverlayKey];
    if (floatOn && self.pipController && !self.pipController.isPictureInPictureActive) {
        [self.pipController startPictureInPicture];
    }
}

- (void)refreshAll {
    BOOL connected = AXIsPCConnected();
    BOOL connecting = ([NSDate date].timeIntervalSince1970 < self.connectingUntil);
    NSString *pcip = AXGetConnectedPCIP();
    if (!pcip.length) pcip = @"192.168.1.34";
    NSString *myip = AXLanIP();

    /* 1. 更新主连接状态横幅与按钮 */
    if (connecting) {
        self.connBanner.backgroundColor = ATBrownBg();
        self.statusDot.backgroundColor = [UIColor orangeColor];
        self.statusMainLabel.text = @"正在连接电脑中...";
        self.statusMainLabel.textColor = ATBrown();
        self.statusSubLabel.text = [NSString stringWithFormat:@"正在与电脑端 (%@) 同步屏幕流与 AI 控制通道...", pcip];
        [self.connectPCBtn setTitle:@"⏳ 正在连接电脑中..." forState:UIControlStateNormal];
    } else if (connected) {
        self.connBanner.backgroundColor = ATGreenBg();
        self.statusDot.backgroundColor = self.pulseToggle ? ATGreen() : [ATGreen() colorWithAlphaComponent:0.5];
        self.statusMainLabel.text = @"已连接电脑 · AI 控制运行中";
        self.statusMainLabel.textColor = ATGreen();
        self.statusSubLabel.text = [NSString stringWithFormat:@"💻 电脑 IP: %@   |   🔋 后台常驻运行中（切出不退出）", pcip];
        [self.connectPCBtn setTitle:@"🔄 重新连接电脑 / 刷新" forState:UIControlStateNormal];
    } else {
        self.connBanner.backgroundColor = ATBlueBg();
        self.statusDot.backgroundColor = ATBlue();
        self.statusMainLabel.text = @"等待连接电脑（服务运行中）";
        self.statusMainLabel.textColor = ATBlue();
        self.statusSubLabel.text = [NSString stringWithFormat:@"📱 本机: %@:10010   |   请点击下方「连接电脑」", myip];
        [self.connectPCBtn setTitle:@"🔗 连接电脑" forState:UIControlStateNormal];
    }

    /* 2. 更新软件内顶部「AI控制中」悬浮框胶囊 */
    BOOL floatOn = [[NSUserDefaults standardUserDefaults] boolForKey:kFloatOverlayKey];
    self.inAppFloatingPill.hidden = !floatOn;
    self.pipContainerView.hidden = !floatOn;
    if (floatOn) {
        self.pillDot.backgroundColor = connected ? ATGreen() : (connecting ? [UIColor orangeColor] : ATBlue());
        self.pillDot.alpha = self.pulseToggle ? 1.0 : 0.55;
        if (connecting) {
            self.pillLabel.text = @"🟡 AI控制中 · 正在连接电脑中...";
        } else if (connected) {
            self.pillLabel.text = [NSString stringWithFormat:@"🤖 AI控制中 · 已连接电脑 (%@)", pcip];
        } else {
            self.pillLabel.text = [NSString stringWithFormat:@"🤖 AI控制中 · 等待电脑 (%@)", myip];
        }
    }

    /* 3. 更新全功能状态列表 */
    BOOL streamRun = AXStreamIsRunning();
    self.rowScreen.valueLabel.text = streamRun
        ? [NSString stringWithFormat:@"🟢 运行中 (已发 %d 帧)", AXStreamSentFrames()]
        : @"🔴 未启动 (点连接电脑启动)";
    self.rowScreen.valueLabel.textColor = streamRun ? ATGreen() : ATRed();

    self.rowTouch.valueLabel.text = [NSString stringWithFormat:@"🟢 硬件触控已开启 (已执行 %d 次)", AXGetTotalActionCount()];
    self.rowTouch.valueLabel.textColor = ATGreen();

    self.rowClipboard.valueLabel.text = @"🟢 Home键与文字秒传就绪";
    self.rowClipboard.valueLabel.textColor = ATGreen();

    self.rowNetwork.valueLabel.text = [NSString stringWithFormat:@"%@ (端口 10010 / 27184)", myip];
    self.rowDevice.valueLabel.text = [NSString stringWithFormat:@"%@ · %@ %@",
                                      [UIDevice currentDevice].name ?: @"iPhone",
                                      [UIDevice currentDevice].systemName,
                                      [UIDevice currentDevice].systemVersion];
}

#pragma mark - 按钮与开关事件

- (void)triggerConnectPCWithToast:(BOOL)showToast {
    self.connectingUntil = [NSDate date].timeIntervalSince1970 + 1.8;
    [self refreshAll];
    [self renderAndEnqueuePiPFrame];
    AXTriggerConnectPC();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshAll];
        [self renderAndEnqueuePiPFrame];
    });
}

- (void)didTapConnectPC {
    [self triggerConnectPCWithToast:YES];
}

- (void)didTapGoBackground {
    /* 确保后台常驻与悬浮框开启，然后按 Home 键退回桌面展示悬浮框 */
    if (self.floatSwitch.isOn && self.pipController && !self.pipController.isPictureInPictureActive) {
        [self.pipController startPictureInPicture];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AXAgentPressHome();
    });
}

- (void)didToggleFloatSwitch:(UISwitch *)sw {
    BOOL on = sw.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kFloatOverlayKey];
    if (self.pipController) {
        if (@available(iOS 14.2, *)) {
            self.pipController.canStartPictureInPictureAutomaticallyFromInline = on;
        }
        if (!on && self.pipController.isPictureInPictureActive) {
            [self.pipController stopPictureInPicture];
        }
    }
    [self refreshAll];
}

- (void)didToggleBgSwitch:(UISwitch *)sw {
    BOOL on = sw.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kBgKeepAliveKey];
    AXSetKeepAliveEnabled(on);
    [self refreshAll];
}

- (void)didTapPopPiP {
    if (!self.floatSwitch.isOn) {
        [self.floatSwitch setOn:YES animated:YES];
        [self didToggleFloatSwitch:self.floatSwitch];
    }
    [self renderAndEnqueuePiPFrame];
    if (self.pipController) {
        if (self.pipController.isPictureInPictureActive) {
            [self.pipController stopPictureInPicture];
        } else {
            [self.pipController startPictureInPicture];
        }
    }
}

- (void)didTapRestartStream {
    self.restartBtn.enabled = NO;
    AXStreamStop();
    self.connectingUntil = [NSDate date].timeIntervalSince1970 + 1.5;
    [self refreshAll];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;
        AXTriggerConnectPC();
        ss.restartBtn.enabled = YES;
        [ss refreshAll];
    });
}

- (void)didTapLogs {
    AXLogViewerViewController *vc = [AXLogViewerViewController new];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 布局工具

- (UIStackView *)stackWith:(NSArray<UIView *> *)views {
    UIStackView *s = [UIStackView new];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.axis = UILayoutConstraintAxisHorizontal;
    s.distribution = UIStackViewDistributionFillEqually;
    s.alignment = UIStackViewAlignmentFill;
    s.spacing = 12;
    for (UIView *v in views) [s addArrangedSubview:v];
    return s;
}

- (UIButton *)buildBigButton:(NSString *)title bg:(UIColor *)bg fg:(UIColor *)fg {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    [b setTitleColor:[fg colorWithAlphaComponent:0.5] forState:UIControlStateHighlighted];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 14;
    b.layer.masksToBounds = YES;
    return b;
}

@end

#pragma mark - 根控制器

UIViewController *AXMakeRootController(void) {
    AXMainViewController *main = [AXMainViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:main];
    nav.navigationBar.hidden = YES;
    return nav;
}
