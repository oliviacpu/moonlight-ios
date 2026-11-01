//
//  ShelfCore.m
//  Shelf (Moonlight TV)
//
//  Ports of the engine glue that used to live in MainFrameViewController:
//  saved hosts, discovery, pairing, server info + app list refresh, quit,
//  and the StreamConfiguration builder. No UI in here.
//

#import "ShelfCore.h"

#import "AppAssetManager.h"
#import "AppListResponse.h"
#import "Connection.h"
#import "ConnectionHelper.h"
#import "ControllerSupport.h"
#import "CryptoManager.h"
#import "DataManager.h"
#import "DiscoveryManager.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "HttpResponse.h"
#import "IdManager.h"
#import "PairManager.h"
#import "ServerInfoResponse.h"
#import "StreamConfiguration.h"
#import "StreamFrameViewController.h"
#import "TemporaryApp.h"
#import "TemporaryHost.h"
#import "TemporarySettings.h"
#import "Utils.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <sys/utsname.h>

@implementation ShelfHostInfo
@end

@implementation ShelfAppInfo
@end

@interface ShelfCore () <DiscoveryCallback, PairCallback, AppAssetCallback>
@end

@implementation ShelfCore {
    NSMutableArray<TemporaryHost *> *_hosts;   // the instances DiscoveryManager knows; never replace them
    TemporaryHost *_selected;
    DiscoveryManager *_discMan;
    AppAssetManager *_assetMan;
    NSOperationQueue *_opQueue;
    NSData *_clientCert;
    NSTimer *_poll;
    NSTimeInterval _lastRefresh;
    BOOL _discovering;
    BOOL _booted;
}

@synthesize phase = _phase;
@synthesize pairingPIN = _pairingPIN;
@synthesize statusMessage = _statusMessage;
@synthesize host = _host;
@synthesize apps = _apps;
@synthesize discoveredHosts = _discoveredHosts;
@synthesize isStreaming = _isStreaming;
@synthesize artworkVersion = _artworkVersion;

+ (ShelfCore *)shared {
    static ShelfCore *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[ShelfCore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _phase = ShelfPhaseBooting;
        _apps = @[];
        _discoveredHosts = @[];
        _hosts = [NSMutableArray array];
        _opQueue = [[NSOperationQueue alloc] init];
    }
    return self;
}

#pragma mark - Helpers

static void onMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (void)notify {
    onMain(^{
        [self rebuildSnapshot];
        if (self.onChange) {
            self.onChange();
        }
    });
}

- (void)setPhase:(ShelfPhase)phase message:(NSString *)message {
    onMain(^{
        self->_phase = phase;
        self->_statusMessage = message;
        [self notify];
    });
}

// Port of MainFrameViewController retrieveSavedHosts: pick an address to talk to.
+ (void)chooseActiveAddress:(TemporaryHost *)host {
    if (host.activeAddress == nil) {
        host.activeAddress = host.localAddress;
    }
    if (host.activeAddress == nil) {
        host.activeAddress = host.externalAddress;
    }
    if (host.activeAddress == nil) {
        host.activeAddress = host.address;
    }
    if (host.activeAddress == nil) {
        host.activeAddress = host.ipv6Address;
    }
}

+ (ShelfHostInfo *)infoForHost:(TemporaryHost *)host {
    ShelfHostInfo *info = [[ShelfHostInfo alloc] init];
    info.name = host.name ?: @"";
    info.uuid = host.uuid ?: @"";
    info.address = host.activeAddress;
    info.online = host.state == StateOnline;
    info.paired = host.pairState == PairStatePaired;
    NSString *current = host.currentGame;
    info.runningAppID = (current != nil && ![current isEqualToString:@"0"]) ? current : nil;
    return info;
}

- (void)rebuildSnapshot {
    _host = _selected ? [ShelfCore infoForHost:_selected] : nil;

    NSMutableArray<ShelfAppInfo *> *apps = [NSMutableArray array];
    if (_selected) {
        NSArray *sorted = [[_selected.appList allObjects] sortedArrayUsingSelector:@selector(compareName:)];
        for (TemporaryApp *app in sorted) {
            if (app.id == nil || app.name == nil) {
                continue;
            }
            ShelfAppInfo *info = [[ShelfAppInfo alloc] init];
            info.appID = app.id;
            info.name = app.name;
            info.hidden = app.hidden;
            [apps addObject:info];
        }
    }
    _apps = apps;

    NSMutableArray<ShelfHostInfo *> *discovered = [NSMutableArray array];
    NSArray *hosts = [_hosts sortedArrayUsingSelector:@selector(compareName:)];
    for (TemporaryHost *host in hosts) {
        [discovered addObject:[ShelfCore infoForHost:host]];
    }
    _discoveredHosts = discovered;
}

- (TemporaryHost *)hostWithUUID:(NSString *)uuid {
    for (TemporaryHost *host in _hosts) {
        if ([host.uuid isEqualToString:uuid]) {
            return host;
        }
    }
    return nil;
}

- (TemporaryApp *)appWithID:(NSString *)appID {
    for (TemporaryApp *app in _selected.appList) {
        if ([app.id isEqualToString:appID]) {
            return app;
        }
    }
    return nil;
}

#pragma mark - Boot and lifecycle

- (void)boot {
    if (_booted) {
        return;
    }
    _booted = YES;

    // Port of MainFrameViewController viewDidLoad: crypto must exist before pairing.
    [CryptoManager generateKeyPairUsingSSL];
    [IdManager getUniqueId];
    _clientCert = [CryptoManager readCertFromFile];

    _assetMan = [[AppAssetManager alloc] initWithCallback:self];

    DataManager *dataMan = [[DataManager alloc] init];
    for (TemporaryHost *host in [dataMan getHosts]) {
        [ShelfCore chooseActiveAddress:host];
        [_hosts addObject:host];
    }
    _discMan = [[DiscoveryManager alloc] initWithHosts:_hosts andCallback:self];

    TemporaryHost *paired = nil;
    for (TemporaryHost *host in _hosts) {
        if (host.pairState == PairStatePaired) {
            paired = host;
            break;
        }
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];

    // Discovery workers mutate hosts in place from background threads; poll for the UI.
    _poll = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(pollTick:) userInfo:nil repeats:YES];

    if (paired) {
        _selected = paired;
        _phase = ShelfPhaseReady;
        [self startDiscovery];
        [self notify];
        [self refresh];
    } else {
        _phase = ShelfPhaseNeedsHost;
        [self startDiscovery];
        [self notify];
    }
}

- (void)startDiscovery {
    if (_discovering) {
        return;
    }
    _discovering = YES;
    [_discMan resetDiscoveryState];
    [_discMan startDiscovery];
}

- (void)stopDiscovery {
    if (!_discovering) {
        return;
    }
    _discovering = NO;
    [_discMan stopDiscovery];
}

- (void)pollTick:(NSTimer *)timer {
    [self notify];
}

- (void)handleDidBecomeActive {
    if (_isStreaming) {
        return;   // StreamFrameViewController owns the lifecycle while streaming
    }
    [self startDiscovery];
    if (_selected) {
        [self refresh];
    }
}

- (void)handleWillResignActive {
    if (_isStreaming) {
        return;
    }
    [self stopDiscovery];
}

#pragma mark - DiscoveryCallback

- (void)updateAllHosts:(NSArray *)hosts {
    NSArray *copy = [hosts copy];
    onMain(^{
        for (TemporaryHost *host in copy) {
            if ([self hostWithUUID:host.uuid] == nil) {
                [ShelfCore chooseActiveAddress:host];
                [self->_hosts addObject:host];
            }
        }
        [self notify];
    });
}

#pragma mark - Refresh (port of hostClicked: + alreadyPaired, minus UI)

- (void)refresh {
    TemporaryHost *host = _selected;
    if (host == nil || _isStreaming) {
        return;
    }
    // Launch and the did-become-active notification both ask; one round trip is enough.
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastRefresh < 1.0) {
        return;
    }
    _lastRefresh = now;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager *hMan = [[HttpManager alloc] initWithHost:host];
        ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];

        // Exempt this host from discovery while handling the serverinfo request
        [self->_discMan pauseDiscoveryForHost:host];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp
                                                            withUrlRequest:[hMan newServerInfoRequest:false]
                                                             fallbackError:401
                                                           fallbackRequest:[hMan newHttpServerInfoRequest]]];
        [self->_discMan resumeDiscoveryForHost:host];

        if (![serverInfoResp isStatusOk]) {
            host.state = StateOffline;
            [self setPhase:ShelfPhaseHostOffline message:[NSString stringWithFormat:@"%@ is not reachable", host.name]];
            return;
        }

        [serverInfoResp populateHost:host];

        if (host.pairState != PairStatePaired) {
            [self setPhase:ShelfPhaseNeedsHost message:[NSString stringWithFormat:@"%@ is no longer paired", host.name]];
            return;
        }

        [self->_discMan pauseDiscoveryForHost:host];
        AppListResponse *appListResp = [ConnectionHelper getAppListForHost:host];
        [self->_discMan resumeDiscoveryForHost:host];

        if (appListResp == nil || ![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            host.state = StateOffline;
            [self setPhase:ShelfPhaseHostOffline message:@"Could not fetch the game list"];
            return;
        }

        onMain(^{
            [self updateApplist:[appListResp getAppList] forHost:host];
            self->_phase = ShelfPhaseReady;
            self->_statusMessage = nil;
            [self notify];
            [self->_assetMan stopRetrieving];
            [self->_assetMan retrieveAssetsFromHost:host];
        });
    });
}

// Verbatim port of MainFrameViewController updateApplist:forHost:
- (void)updateApplist:(NSSet *)newList forHost:(TemporaryHost *)host {
    DataManager *database = [[DataManager alloc] init];
    NSMutableSet *newHostAppList = [NSMutableSet setWithSet:host.appList];

    for (TemporaryApp *app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp *savedApp in newHostAppList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                savedApp.hdrSupported = app.hdrSupported;
                // Don't propagate hidden, because we want the local data to prevail
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [newHostAppList addObject:app];
        }
    }

    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;

        for (TemporaryApp *app in newHostAppList) {
            appWasRemoved = YES;
            for (TemporaryApp *mergedApp in newList) {
                if ([mergedApp.id isEqualToString:app.id]) {
                    appWasRemoved = NO;
                    break;
                }
            }
            if (appWasRemoved) {
                // Removing the app mutates the list we're iterating (which isn't legal).
                // We need to jump out of this loop and restart enumeration.
                [newHostAppList removeObject:app];

                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];
                break;
            }
        }
        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);

    host.appList = newHostAppList;
    [database updateAppsForExistingHost:host];
}

#pragma mark - Pairing (port of hostClicked: pairing branch + PairCallback)

- (void)pairDiscoveredHostWithUUID:(NSString *)uuid {
    TemporaryHost *host = [self hostWithUUID:uuid];
    if (host == nil) {
        [self setPhase:ShelfPhaseNeedsHost message:@"That PC is no longer listed"];
        return;
    }
    _selected = host;
    [self setPhase:ShelfPhasePairing message:nil];
    _pairingPIN = nil;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Polling the server while pairing causes the server to screw up
        [self->_discMan stopDiscoveryBlocking];
        onMain(^{ self->_discovering = NO; });

        HttpManager *hMan = [[HttpManager alloc] initWithHost:host];
        ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp
                                                            withUrlRequest:[hMan newServerInfoRequest:false]
                                                             fallbackError:401
                                                           fallbackRequest:[hMan newHttpServerInfoRequest]]];
        if (![serverInfoResp isStatusOk]) {
            onMain(^{ [self startDiscovery]; });
            [self setPhase:ShelfPhaseNeedsHost message:[NSString stringWithFormat:@"Could not connect to %@", host.name]];
            return;
        }
        [serverInfoResp populateHost:host];

        if (host.pairState == PairStatePaired) {
            [self alreadyPaired];
            return;
        }

        PairManager *pMan = [[PairManager alloc] initWithManager:hMan clientCert:self->_clientCert callback:self];
        [self->_opQueue addOperation:pMan];
    });
}

- (void)startPairing:(NSString *)PIN {
    onMain(^{
        self->_pairingPIN = PIN;
        self->_phase = ShelfPhasePairing;
        self->_statusMessage = nil;
        [self notify];
    });
}

- (void)pairSuccessful:(NSData *)serverCert {
    onMain(^{
        self->_selected.serverCert = serverCert;
        [self alreadyPaired];
    });
}

- (void)pairFailed:(NSString *)message {
    onMain(^{
        self->_pairingPIN = nil;
        [self startDiscovery];
        [self setPhase:ShelfPhaseNeedsHost message:message ?: @"Pairing failed"];
    });
}

- (void)alreadyPaired {
    onMain(^{
        TemporaryHost *host = self->_selected;
        if (host == nil) {
            return;
        }
        host.pairState = PairStatePaired;
        [[[DataManager alloc] init] updateHost:host];
        self->_pairingPIN = nil;
        self->_phase = ShelfPhaseReady;
        self->_statusMessage = nil;
        [self startDiscovery];
        [self notify];
        [self refresh];
    });
}

- (void)cancelPairing {
    _pairingPIN = nil;
    [self startDiscovery];
    [self setPhase:ShelfPhaseNeedsHost message:nil];
}

#pragma mark - Manual host (port of addHostClicked)

- (void)addHostWithAddress:(NSString *)address completion:(void (^)(NSString *_Nullable))completion {
    NSString *trimmed = [address stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        completion(@"Enter an IP address or hostname");
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self->_discMan discoverHost:trimmed withCallback:^(TemporaryHost *host, NSString *error) {
            onMain(^{
                if (host != nil) {
                    [ShelfCore chooseActiveAddress:host];
                    if ([self hostWithUUID:host.uuid] == nil) {
                        [self->_hosts addObject:host];
                    }
                    [[[DataManager alloc] init] updateHost:host];
                    [self notify];
                    completion(nil);
                } else {
                    completion(error ?: @"Could not reach that address");
                }
            });
        }];
    });
}

- (void)forgetHost {
    TemporaryHost *host = _selected;
    if (host) {
        [_discMan removeHostFromDiscovery:host];
        [[[DataManager alloc] init] removeHost:host];
        [_hosts removeObject:host];
    }
    _selected = nil;
    [self setPhase:ShelfPhaseNeedsHost message:nil];
}

#pragma mark - Quit (port of appLongClicked: quit action)

- (void)quitRunningAppWithCompletion:(void (^)(NSString *_Nullable))completion {
    TemporaryHost *host = _selected;
    if (host == nil) {
        completion(@"No PC selected");
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager *hMan = [[HttpManager alloc] initWithHost:host];
        HttpResponse *quitResponse = [[HttpResponse alloc] init];
        HttpRequest *quitRequest = [HttpRequest requestForResponse:quitResponse withUrlRequest:[hMan newQuitAppRequest]];

        // Exempt this host from discovery while handling the quit operation
        [self->_discMan pauseDiscoveryForHost:host];
        [hMan executeRequestSynchronously:quitRequest];
        if (quitResponse.statusCode == 200) {
            ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp
                                                                withUrlRequest:[hMan newServerInfoRequest:false]
                                                                 fallbackError:401
                                                               fallbackRequest:[hMan newHttpServerInfoRequest]]];
            if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
                // On newer GFE versions, the quit request succeeds even though the app doesn't
                // really quit if another client tries to kill your app. We'll patch the response
                // to look like the old error in that case, so the UI behaves.
                quitResponse.statusCode = 599;
            } else {
                [serverInfoResp populateHost:host];
            }
        }
        [self->_discMan resumeDiscoveryForHost:host];

        onMain(^{
            if (quitResponse.statusCode != 200) {
                [self notify];
                completion(@"Failed to quit the game. If it was started by another device, quit it from there.");
            } else {
                host.currentGame = @"0";
                [self notify];
                completion(nil);
            }
        });
    });
}

#pragma mark - Streaming

- (nullable UIViewController *)streamViewControllerForAppID:(NSString *)appID onExit:(void (^)(void))onExit {
    TemporaryApp *app = [self appWithID:appID];
    if (app == nil || _selected == nil) {
        return nil;
    }
    StreamConfiguration *config = [ShelfCore streamConfigurationForApp:app];

    // Mirror MainFrameViewController viewDidDisappear: nothing polls while we stream.
    [_assetMan stopRetrieving];
    [self stopDiscovery];
    _isStreaming = YES;

    StreamFrameViewController *streamFrame = [[StreamFrameViewController alloc] init];
    streamFrame.streamConfig = config;
    streamFrame.onStreamExit = onExit;
    return streamFrame;
}

- (void)streamDidEnd {
    _isStreaming = NO;
    [self startDiscovery];
    [self notify];
    [self refresh];
}

// Verbatim port of MainFrameViewController prepareToStreamApp:
+ (StreamConfiguration *)streamConfigurationForApp:(TemporaryApp *)app {
    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    streamConfig.host = app.host.activeAddress;
    streamConfig.httpsPort = app.host.httpsPort;
    streamConfig.appID = app.id;
    streamConfig.appName = app.name;
    streamConfig.serverCert = app.host.serverCert;

    DataManager *dataMan = [[DataManager alloc] init];
    TemporarySettings *streamSettings = [dataMan getSettings];

    streamConfig.frameRate = [streamSettings.framerate intValue];
    // Don't stream more FPS than the display can show
    if (streamConfig.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
        streamConfig.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
        Log(LOG_W, @"Clamping FPS to maximum refresh rate: %d", streamConfig.frameRate);
    }

    streamConfig.height = [streamSettings.height intValue];
    streamConfig.width = [streamSettings.width intValue];
    // Don't allow streaming 4K on the Apple TV HD
    struct utsname systemInfo;
    uname(&systemInfo);
    if (strcmp(systemInfo.machine, "AppleTV5,3") == 0 && streamConfig.height >= 2160) {
        Log(LOG_W, @"4K streaming not supported on Apple TV HD");
        streamConfig.width = 1920;
        streamConfig.height = 1080;
    }

    streamConfig.bitRate = [streamSettings.bitrate intValue];
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    streamConfig.useFramePacing = streamSettings.useFramePacing;
    streamConfig.swapABXYButtons = streamSettings.swapABXYButtons;

    // multiController must be set before calling getConnectedGamepadMask
    streamConfig.multiController = streamSettings.multiController;
    streamConfig.gamepadMask = [ControllerSupport getConnectedGamepadMask:streamConfig];

    // Probe for supported channel configurations
    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    Log(LOG_I, @"Audio device supports %d channels", physicalOutputChannels);

    int numberOfChannels = MIN([streamSettings.audioConfig intValue], physicalOutputChannels);
    Log(LOG_I, @"Selected number of audio channels %d", numberOfChannels);
    if (numberOfChannels >= 8) {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    }
    else if (numberOfChannels >= 6) {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    }
    else {
        streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }

    streamConfig.serverCodecModeSupport = app.host.serverCodecModeSupport;

    switch (streamSettings.preferredCodec) {
        case CODEC_PREF_AV1:
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
#endif
            // Fall-through

        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through

        case CODEC_PREF_H264:
            streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }

    // HEVC is supported if the user wants it (or it's required by the chosen resolution) and the SoC supports it
    if ((streamConfig.width > 4096 || streamConfig.height > 4096 || streamSettings.enableHdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265;

        // HEVC Main10 is supported if the user wants it and the display supports it
        if (streamSettings.enableHdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
            streamConfig.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    // Add the AV1 Main10 format if AV1 and HDR are both enabled and supported
    if ((streamConfig.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && streamSettings.enableHdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
        streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }
#endif

    return streamConfig;
}

#pragma mark - Box art (AppAssetCallback)

- (void)receivedAssetForApp:(TemporaryApp *)app {
    onMain(^{
        self->_artworkVersion += 1;
        [self notify];
    });
}

- (nullable NSString *)boxArtPathForAppID:(NSString *)appID {
    TemporaryApp *app = [self appWithID:appID];
    if (app == nil) {
        return nil;
    }
    NSString *path = [AppAssetManager boxArtPathForApp:app];
    if (path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }
    return path;
}

@end
