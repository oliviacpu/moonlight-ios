//
//  ShelfCore.h
//  Shelf (Moonlight TV)
//
//  The whole Objective-C engine surface the SwiftUI shelf talks to.
//  Everything here runs on the main thread and reports state changes through
//  `onChange`; the blocking Moonlight calls run on background queues inside.
//  Swift never sees TemporaryHost/TemporaryApp or Core Data types, which keeps
//  the bridging header tiny and avoids name collisions with SwiftUI.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ShelfPhase) {
    ShelfPhaseBooting,
    ShelfPhaseNeedsHost,
    ShelfPhasePairing,
    ShelfPhaseReady,
    ShelfPhaseHostOffline,
};

@interface ShelfHostInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, copy, nullable) NSString *address;
@property (nonatomic) BOOL online;
@property (nonatomic) BOOL paired;
/// Sunshine app ID of the running game, or nil when nothing is running.
@property (nonatomic, copy, nullable) NSString *runningAppID;
@end

@interface ShelfAppInfo : NSObject
@property (nonatomic, copy) NSString *appID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL hidden;
@end

@interface ShelfCore : NSObject

@property (class, nonatomic, readonly) ShelfCore *shared NS_SWIFT_NAME(shared);

@property (nonatomic, readonly) ShelfPhase phase;
@property (nonatomic, readonly, nullable) NSString *pairingPIN;
@property (nonatomic, readonly, nullable) NSString *statusMessage;
@property (nonatomic, readonly, nullable) ShelfHostInfo *host;
@property (nonatomic, readonly) NSArray<ShelfAppInfo *> *apps;
@property (nonatomic, readonly) NSArray<ShelfHostInfo *> *discoveredHosts;
@property (nonatomic, readonly) BOOL isStreaming;
/// Increments whenever box art arrives, so cover views know to reload.
@property (nonatomic, readonly) NSInteger artworkVersion;

/// Called on the main thread after any of the properties above change.
@property (nonatomic, copy, nullable) void (^onChange)(void);

- (void)boot;
- (void)refresh;
- (void)pairDiscoveredHostWithUUID:(NSString *)uuid NS_SWIFT_NAME(pairDiscoveredHost(uuid:));
- (void)addHostWithAddress:(NSString *)address completion:(void (^)(NSString *_Nullable error))completion NS_SWIFT_NAME(addHost(address:completion:));
- (void)cancelPairing;
- (void)forgetHost;
- (void)quitRunningAppWithCompletion:(void (^)(NSString *_Nullable error))completion NS_SWIFT_NAME(quitRunningApp(completion:));

/// Builds the stream configuration for the app, stops discovery, and returns the
/// stream view controller ready to be pushed on a UINavigationController.
/// `onExit` fires on the main thread once the stream controller has been popped.
- (nullable UIViewController *)streamViewControllerForAppID:(NSString *)appID onExit:(void (^)(void))onExit NS_SWIFT_NAME(streamViewController(appID:onExit:));
/// Call after the stream controller has gone: restarts discovery and refreshes.
- (void)streamDidEnd;

/// Path to Moonlight's cached box art for the app, or nil until it has downloaded.
- (nullable NSString *)boxArtPathForAppID:(NSString *)appID NS_SWIFT_NAME(boxArtPath(appID:));

@end

NS_ASSUME_NONNULL_END
