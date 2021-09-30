# SCION-WebRTC

WebRTC calls over SCION with advanced path control.

This application was developed as part of my master's thesis at ETH Zürich in 2021. It uses [SCION](https://scion-architecture.net), a next-generation path aware Internet architecture, to transport WebRTC media streams with application-layer path control. WebRTC-specific metrics are used to drive path selection directly from within the app.

<p align="center">
<img src="https://github.com/JonasGessner/SCION-WebRTC/raw/main/app.png" width="400px">
</p>

## Contents

This app contains various components:

- A plain WebRTC build for iOS and macOS.
- A build of the official SCION daemons and libraries (written in Go), compiled for iOS and macOS with gomobile. The SCION libraries were modified in such a way that they could be used as a single library.
- A SCION client library written in Swift, based on primitives provided by the official SCION Go libraries.
- The iOS/macOS app combining all the above components to realize video calls over SCION with advanced path control.
- A very simple peer-to-peer text chat based on SCION, used for debugging purposes.
- Various tests that either test components of the app or perform scenarios on real end-to-end calls.

This repo also contains a signaling server required to manage video calls in the app. This server is not part of the app and has to run on a server that can be reached by both peers taking part in a call.

## Dependencies

First all the dependencies must be built.

### WebRTC
Build using the `build.sh` script in <https://github.com/JonasGessner/WebRTC/tree/scion>. Place resulting `xcframework` into the `Vendor` folder.

### SCIONDarwin
This is the modified SCION daemons+library compiled with gomobile. Building this library requires a patched version of gomobile found here: <https://github.com/JonasGessner/mobile/tree/macos>.

If you are building for macOS on arm64 you will have to also patch the `malloc.go` file in your `GOROOT` (`$ go env GOROOT`): Change `heapAddrBits` to 48!

Using this patched gomobile (and patched `malloc.go`), build using the `build.sh` script in <https://github.com/JonasGessner/scion-apps/tree/pan-darwin>. Place resulting `xcframework` into the `Vendor` folder.

## Building

You must run the signaling server found in `signalingserver` and place the address at which it can be reached into the file `SCIONTest/Options.swift` where it says `ws://put-address-here`. The address is a WebSocket address.

Make sure the dependencies built in the previous step are in the `Vendor` folder, then open the `xccodeproj` file and build either the iOS or macOS app. You may have to adjust your code signing identity.

## Configuration

The app is heavily reliant on the particular test setup I used. However, it can be adjusted to work with other setups. The app identifies on which of two machines I used it is running `isCloud()` and autoconfigures itself based on this setting.

The configuration options can be modified in the `SCIONTest/Options.swift` file. The options listed there are almost all annotated with a comment stating what they control. To make the app run on your custom environment you need to adjust the SCION topology the app uses, see `SCION/SCIONLab/SCIONLabSupport.swift` for example topologies. The SCION stack inside the app is configured in the file `SCIONTest/ContentView.swift` with a call to `SCIONStack.shared.initScionStack(topology:)`. Here you need to make sure the correct topology is provided ([useful reference](https://docs.scionlab.org/content/config/setup_endhost.html)). It is best to set your topology in the `setUpEntryFor(AS:)` function in `SCIONTest/Options.swift` which is used as a helper to provide the topology to the call to `SCIONStack.shared.initScionStack(topology:)`.

## Tests

There are various options to enable tests in `SCIONTest/Options.swift` by changing the `testCase` value. These test cases all use ssh to execute certain commands and are not trivial to reproduce. The instance of the app where `isCloud()` returns `false` runs a command `tc.sh` via SSH which configures traffic shaping on groups of paths. The `tc.sh` command is included in this repo. It requires two local SCION ASes to run on one of the two machines running an instance of the app. These two ASes must be connected by 5 inter-AS links each, and one of them with another 5 to the attachment point (AS that provides connectivity into the used SCION network, e.g. SCIONLab). This is explained in more detail in the thesis report. The configurations of these two local ASes are also included in the handin of the thesis. With the local ASes correctly configured, the `tc.sh` command must be executed on the AS in the center (the AS that is connected with 5 links each to each of the two other ASes).

All the results shown in the thesis report were produced by one of the test cases that can be enabled in `SCIONTest/Options.swift`. Test results are automatically saved to a file. You need to change `resultsBasePath` so that results are saved into a folder that exists on your system.

## License

MIT License.
© Jonas Gessner