Sound - WAV and MP3 files played, WAV files recorded, tones, the mixer

In the desktop:

  Player.Play /home/me/music/a.mp3   plays a WAV or MP3 file while the desktop goes on
  Player.Pause                      pauses, or goes on after a pause
  Player.Stop                       stops
  Player.Show                       what plays and where, in System.Log

  Desktops.OpenDoc Wave.Panel    the recorder and player of WAV files of Native Oberon
  MixerPanel.Open                the controls of the mixer of the card

In Wave.Panel, Show Waves lists the *.wav files of the current directory; a middle click on one
puts its name into the field above the buttons. The buttons play, record, pause and stop; a
recording goes to the file named in the field, and Store keeps it. Record Tuning shows the settings
of recording: 11025, 22050 or 44100 Hz, 8 or 16 bits, mono or stereo. In the mixer, a slider sets a
volume, a check box a switch; "both" at the end of a stereo row moves its two sliders together.

The console commands work here too, and wait until they are done:

  sound.Tone 440 300 0 100 660 300     tones: Hz and milliseconds (0 Hz is a rest)
  sound.Play /home/me/music/a.mp3      plays WAV and MP3 files
  sound.Convert a.mp3 a.wav            an MP3 file as a WAV file
  sound.Record 5 zq.wav                records 5 seconds
  sound.Mixer                          lists the controls of the mixer
  sound.Mixer Master 70%               sets one
  sound.Info                           the devices used
  sound.Help

The device is Sound.Device in Oberon.Text (hw:c,d for ALSA card c and device d, oss for /dev/dsp,
or the path of a device); without it, ALSA hw:0,0, else /dev/dsp.
