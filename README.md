# Hertzwise

Automatic sample-rate switching for Mac music players, so your DAC follows every track and lossless plays bit-perfect.

Hertzwise is a fork of [SyncHz](https://github.com/jcongaku/SyncHz) by Gary Kong. It keeps SyncHz's Apple Music support and headphone EQ, and adds other players.

## Status

| Player | Rate switching | Status |
|---|---|---|
| Apple Music | Yes | From SyncHz |
| Tidal (exclusive mode off) | Planned | In progress |
| YouTube Music | Planned | Later |

For how rate detection and the EQ work, see the [SyncHz README](https://github.com/jcongaku/SyncHz#readme). Everything there applies here.

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/zeetabit/Hertzwise/releases/latest) and drag **Hertzwise** into Applications.
2. It is not notarized, so clear the quarantine flag once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Hertzwise.app
   ```

Requires macOS 15 or later. Hertzwise can be installed next to SyncHz: settings, EQ profiles and permissions are separate.

## Build from source

```bash
git clone https://github.com/zeetabit/Hertzwise.git
cd Hertzwise
open SampleRateSwitcher.xcodeproj
```

Needs Xcode 26 or later.

## Acknowledgements

- **[SyncHz](https://github.com/jcongaku/SyncHz)** by Gary Kong, which Hertzwise is built on.
- **[LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher)** by Vincent Neo, which SyncHz credits as its inspiration.

## License

[MIT](LICENSE). The original copyright notice is kept as the license requires.
