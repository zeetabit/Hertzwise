# The audio path

How Hertzwise applies volume and EQ without a driver, and the Core Audio
behaviour behind each design choice. Code: `Audio/ProcessTapEngine.swift`
(one device's path) and `Audio/OutputPaths.swift` (which devices get one).

## One path per device

A device gets a path while "Control volume" is on for it, or while the EQ is
on and its "Equalizer" switch is. The path is a **muted process tap** of
everything playing to that device except Hertzwise, in a private aggregate
device with the device as output. The IOProc copies tap → EQ (when on) →
device volume → device.

- **Bit-exact when idle.** With the EQ off (and its fade to dry finished) and
  the volume at 0 dB the path copies samples untouched. Verified by playing a
  24-bit file and checking every captured sample sits on the 1/2²³ grid —
  only meaningful when nothing else is playing.
- **Hertzwise excludes itself** or its own output would loop back.
- **The tap is bound to the device's stream**, so it shares the device's clock:
  no drift compensation, which would resample.

## Core Audio behaviour learned the hard way

- **A tap still receives a process another tap mutes.** Two taps on one
  process both get its audio; muting is applied after. So the EQ and the
  volume stage share one path — two paths on the same device would play the
  music twice.
- **Two running copies of Hertzwise silence the DAC.** Each taps everything
  but itself, so each mutes the other's output. Only one copy may run
  (`LSMultipleInstancesProhibited`, plus a check in `Launcher` before any
  path starts).
- **Tap-autostart aggregates idle until a tapped process plays.** A path with
  nothing to pass through renders nothing; that is normal, not a stall.
- **Rate changes need a fresh path, built before the old one goes**
  (make-before-break). A path kept through a rate change can fall out of step
  and render ~1% short (dropouts); tearing down first unmutes the players for
  seconds, at full level on a DAC that ignores the Mac's volume.
- **A fresh path can still come out short** when built during a rate change:
  its tap at the old rate, or rendering ~2% slow. Each path measures itself —
  frames rendered against the device's rate, early in its life and every 2 s
  after — and replaces itself when short.
- **Concurrent rebuilds can deadlock coreaudiod.** Building and destroying
  several engines' taps and aggregates at once during rapid rate changes hung
  the audio server (only `kill -9` recovered it). All engines share one
  control queue.
- **A coreaudiod restart destroys every tap**, so players would reach the DAC
  unmuted. Engines listen for `kAudioHardwarePropertyServiceRestarted` and
  rebuild, retrying while devices come back. A restart can also reset the
  device volume to full: a path that starts fresh lowers it back to the volume
  Hertzwise last applied (never raises it).
- **Reading Core Audio strings:** read `CFString` properties into
  `Unmanaged<CFString>?` and take the retained value.

## Devices

- **Lotoo PAW S1** ignores the Mac's volume in its normal USB Audio 2.0 mode
  (product ID `0x201D`), so "Control volume" is on for it by default. In
  console mode (plugged in holding both volume buttons; USB Audio 1.0,
  product ID `0x2015`) it follows the Mac's volume but is limited to
  48 kHz/16-bit; Hertzwise says so when a track needs more.
- A device that can't play a track's rate plays it at the nearest one it
  supports, and Hertzwise shows a notice instead of claiming the switch.
- Some players choose their own output device (Tidal's device setting), so a
  path follows each device, not the system output.
