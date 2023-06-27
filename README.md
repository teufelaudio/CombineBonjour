# Combine Bonjour wrappers

This library implements basic Bonjour Browser functionality using Combine.

## Usage:

On iOS, make sure to fill in the `NSBonjourServices` and `NSLocalNetworkUsageDescription`, i.e.:

```
<key>NSLocalNetworkUsageDescription</key>
<string>Looking for local tcp Bonjour service</string>
<key>NSBonjourServices</key>
<array>
	<string>_airplay._tcp</string>
</array>
```

You will then be able to use the .publisher extension on NWBrowser just like any other Combine publisher:


```
let discovery = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil),  using: .tcp)
            .publisher
            .receive(on: DispatchQueue.main)
            .handleEvents(
                receiveCancel: { print("discovery finished") },
                receiveRequest: { demand in
                    if demand > .zero {
                        print("discovery started")
                    }
                }
            )
            .sink(
                receiveCompletion: { [weak self] completion in
                    print("discovery finished: \(completion.failure)")
                },
                receiveValue: { [weak self] event in
                    switch event {
                    case let .didFind(endpoint, txt):
                        print("discovered: \(endpoint), txt: \(txt)")
                    case let .didRemove(endpoint, _):
                        print("lost: \(endpoint)")
                    case .didUpdate:
                        break
                    }
                }
            )
```            

You may have a look at the [sample app](Sources/CombineBonjourSampleApp) which runs on iOS and macOS.

## Installation:


```swift
.package(url: "https://github.com/teufelaudio/CombineBonjour.git", .branch("master"))
```
