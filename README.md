# sound

Sound for [polpo](https://github.com/polpo-system/polpo): WAV files played and recorded, tones,
and the mixer of the sound card, in the console and in the desktop, on all of polpo's machines.
Everything goes to the kernel through system calls: the PCM devices and the controls of ALSA, or
the older OSS devices.

```
portia.Install sound            the console commands
portia.Install sound-desktop    the panels of the desktop
```

## In the console

```
sound.Play [/d device] file.wav ...                plays WAV files
sound.Tone [/d device] [/v volume] freq ms ...     tones of freq Hz for ms milliseconds (0 Hz: a rest)
sound.Record [/d device] [/r rate] [/c channels] [/b bits] seconds file.wav
sound.Mixer [/d card]                              lists the controls of the mixer
sound.Mixer [/d card] name value [value]           sets one
sound.Info [/d device]                             the devices for playback and capture, the mixer
sound.Help
```

A control is named in full (`'"Master Playback Volume"'` from a Linux shell) or by the start of its
name (`Master`); a value is a number, a per cent of the range (`70%`), `on` or `off`, or an item of
a choice. Two values set the left and the right channel.

## In the desktop

`Desktops.OpenDoc Wave.Panel` opens the recorder and player of WAV files of Native Oberon, and
`MixerPanel.Open` a panel with the controls of the mixer: a slider for each volume, a check box for
each switch. `tools/Sound.Tool` lists the commands.

The module `Sound` has the interface of `Sound` of Native Oberon, which drove SoundBlaster cards:
blocks of data queued with `AddBlock`, a trigger procedure called for more blocks and at the end,
the mixer as channels and subchannels. `Wave`, its panel and other programs written for it run on it
unchanged. There is no CD audio: those procedures answer `NotOpened`.

## Devices

A device is named `hw:c,d` (ALSA card c, device d), `oss` (`/dev/dsp`), or by its path; without a
name, `Sound.Device` of Oberon.Text is taken, else ALSA `hw:0,0`, else `/dev/dsp`. The mixer is that
of ALSA card 0, else `/dev/mixer`.

The device plays 16-bit samples at a rate and with channels it takes; data of 8 or 16 bits, mono or
stereo, at any rate from 1000 to 384000 Hz is converted on the way (channels doubled or mixed, the
rate by linear interpolation). WAV files may also have 24 or 32-bit samples or samples in floating
point; they are played as 16 bits. Recordings are written with 8 or 16 bits.

A card that a sound server (PulseAudio, PipeWire) holds open is busy for polpo. ALSA devices that
pause themselves are paused; with OSS a pause only stops the data, and what the device holds still
plays.

## What is here

    src/Sound0.Mod          the devices: ALSA PCM and controls, OSS; the conversions
    src/Wave0.Mod           WAV files: their format, the samples read as 8 or 16 bits, written
    src/sound.Mod           the console commands
    src/Sound.Mod           the interface of Sound of Native Oberon (package sound-desktop)
    src/MixerPanel.Mod      the mixer panel
    src/Wave.Mod            the WAV recorder and player of Native Oberon
    share/Wave.Panel        its panel
    tools/Sound.Tool
    test/SoundTest.Mod
    test/SoundDesktopTest.Mod

Programs use Sound0 directly: `Sound0.Open` with the format of their data, `Write` (or `WriteSome`,
which does not wait), `Drain` and `Close`; `Read` for recording; `OpenMixer`, `GetValue` and
`SetValue` for the mixer. Wave0 reads WAV files for them.

`Wave.Mod` and `Wave.Panel` come from Native Oberon 2.3.7, by Thomas Burri; the first commit has them
unchanged, the next one has `Wave.Mod` as plain text, and in the panel the list shows `*.wav` files
(it showed `*.Wav`). They compile unchanged with all of polpo's compilers.

## Tests

    SoundTest.Run          21 checks: the conversions (formats, channels, rates, data in pieces),
                           WAV files of 8, 16, 24 and 32 bits, floating point, other chunks; and 6
                           on the device if there is a free one: silence played, a little recorded,
                           a mixer value set to itself
    SoundTest.Offline      the 21 checks without the device
    SoundDesktopTest.Run   11 checks: Sound, Wave and the mixer panel; it needs the desktop's display

qemu-user passes the ioctls of OSS but not those of ALSA: run under qemu, the tests use `/dev/dsp`,
which the OSS emulation of the kernel (the module snd-pcm-oss) provides.

The license is GPL-3 (`LICENSE`); `Wave` and the interface of `Sound` come from ETH Oberon, whose
license (`LICENSE.ETH`) asks to keep its copyright notice and conditions, which `LICENSE.ETH` does.
