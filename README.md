# Shelf (Apple TV)

Shelf is a personal Apple TV client for [Sunshine](https://github.com/LizardByte/Sunshine)
built on this fork of [Moonlight for iOS/tvOS](https://github.com/moonlight-stream/moonlight-ios).
It replaces the flat app grid with **pick a platform → pick a game → play**.
The pairing, HTTP and streaming engine is Moonlight's, unchanged; only the tvOS
interface is new. GPLv3, like Moonlight.

How it groups games: Sunshine app names are expected to be `<Platform> · <Title>`
(middle dot, U+00B7). The text before the dot becomes the platform tile; the rest
is the game. Names without a dot land under "Other". The Monochrome host writes
names in that form from its RomM catalog.

## Build and run on an Apple TV

1. Mac with Xcode 16 or newer. Clone **with submodules**:

       git clone --recurse-submodules https://github.com/oliviacpu/moonlight-ios
       cd moonlight-ios && git checkout shelf

2. Open `Moonlight.xcodeproj`. Wait for Swift packages (OpenSSL) to resolve.
3. Select the **Moonlight TV** target → Signing & Capabilities → pick your Team.
   The bundle identifier is `zone.olivia.shelf`; change it if Xcode complains.
4. Pair the Apple TV: on the TV, Settings → Remotes and Devices → Remote App and
   Devices; in Xcode, Window → Devices and Simulators → pair, enter the code.
5. Choose the Apple TV as the run destination and press Run.

First launch: Shelf looks for Sunshine over Bonjour. Pick the PC (or type its
address), a PIN appears; enter it in Sunshine's web UI under PIN. After that the
app opens straight to the platform rail.

Controls: Menu/Back goes up one level. In a stream, press Play/Pause (or press
Menu twice) to come back to the shelf; the host keeps the game running, and
tapping its card again resumes it.

The tvOS simulator shows the rail and shelves (it can discover, pair and fetch
the game list over your LAN) but cannot stream.

New code lives in `Moonlight TV/Shelf/`. Changes to upstream files are limited to
`AppDelegate.m` (window setup), `StreamFrameViewController.h/.m` (an exit
callback), the bridging header, `Moonlight TV/Info.plist`, and the project file.

---

# Moonlight iOS/tvOS

[![CI](https://github.com/moonlight-stream/moonlight-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/moonlight-stream/moonlight-ios/actions/workflows/ci.yml)

[Moonlight for iOS/tvOS](https://moonlight-stream.org) is an open source client for [Sunshine](https://github.com/LizardByte/Sunshine) and NVIDIA GameStream. Moonlight for iOS/tvOS allows you to stream your full collection of games and apps from your powerful desktop computer to your iOS device or Apple TV.

Moonlight also has a [PC client](https://github.com/moonlight-stream/moonlight-qt) and [Android client](https://github.com/moonlight-stream/moonlight-android).

Check out [the Moonlight wiki](https://github.com/moonlight-stream/moonlight-docs/wiki) for more detailed project information, setup guide, or troubleshooting steps.

[![Moonlight for iOS and tvOS](https://moonlight-stream.org/images/App_Store_Badge_135x40.svg)](https://apps.apple.com/us/app/moonlight-game-streaming/id1000551566)

## Building
* Install Xcode from the [App Store page](https://apps.apple.com/us/app/xcode/id497799835)
* Run `git clone --recursive https://github.com/moonlight-stream/moonlight-ios.git`
  *  If you've already clone the repo without `--recursive`, run `git submodule update --init --recursive`
* Open Moonlight.xcodeproj in Xcode
* To run on a real device, you will need to locally modify the signing options:
    * Click on "Moonlight" at the top of the left sidebar
    * Click on the "Signing & Capabilities" tab
    * Under "Targets", select "Moonlight" (for iOS/iPadOS) or "Moonlight TV" (for tvOS)
    * In the "Team" dropdown, select your name. If your name doesn't appear, you may need to sign into Xcode with your Apple account.
    * Change the "Bundle Identifier" to something different. You can add your name or some random letters to make it unique.
    * Now you can select your Apple device in the top bar as a target and click the Play button to run.
