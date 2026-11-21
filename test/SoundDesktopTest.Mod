MODULE SoundDesktopTest;  (** SoundDesktopTest.Run: Sound, Wave and MixerPanel; needs the desktop's display *)

IMPORT Modules, Objects, Documents, Panels, Out, Sound, MixerPanel;

VAR fails, checks: LONGINT;

PROCEDURE Check(what: ARRAY OF CHAR; ok: BOOLEAN);
BEGIN
  INC(checks);
  IF ~ok THEN INC(fails); Out.String("FAIL "); Out.String(what); Out.Ln END
END Check;

PROCEDURE Run*;
VAR d: Sound.AudioDef; obj: Objects.Object; track, min, sec: INTEGER;
BEGIN
  fails := 0; checks := 0;
  Check("Wave loaded", Modules.ThisMod("Wave") # NIL);
  Sound.PlayAudio(); Check("not opened", Sound.res = Sound.NotOpened);
  d.format := Sound.PCM; d.stereo := TRUE; d.signed := TRUE; d.bits := 12; d.freq := 22050; d.blocks := 1; d.handle := NIL;
  Sound.OpenAudio(d); Check("12 bits refused", Sound.res = Sound.NS16bit);
  d.bits := 16; d.format := Sound.ADPCM8b4b; Sound.OpenAudio(d); Check("ADPCM refused", Sound.res = Sound.Failed);
  d.format := Sound.PCM; Sound.OpenAudio(d);
  Check("opened", (Sound.res = Sound.Done) & (Sound.GetAudioState() = {Sound.opened, Sound.stopped}));
  Sound.OpenAudio(d); Check("opened once", Sound.res = Sound.Failed);
  Sound.StopAudio(); Check("not running", Sound.res = Sound.NotRunning);
  Sound.CloseAudio(); Check("closed", (Sound.res = Sound.Done) & (Sound.GetAudioState() = {}));
  Check("no CD", (Sound.NrOfCDTracks() = 0) & (Sound.res = Sound.NotOpened));
  Sound.GetCDPos(track, min, sec); Check("no CD position", (track = 0) & (Sound.res = Sound.NotOpened));
  MixerPanel.NewDoc; obj := Objects.NewObj;
  Check("mixer panel", (obj # NIL) & (obj IS Documents.Document) & (obj(Documents.Document).dsc IS Panels.Panel));
  Out.String("SoundDesktopTest: "); Out.Int(checks, 0); Out.String(" checks, "); Out.Int(fails, 0); Out.String(" failed"); Out.Ln
END Run;

END SoundDesktopTest.
