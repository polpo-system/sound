MODULE sound;  (** console commands for sound: WAV and MP3 files and tones played, recording, the mixer *)

IMPORT Files, Texts, Texts0, Oberon0, Out, Math, Sound0, Wave0, MPEGAudio0;

CONST
  Chunk = 16384;
  ToneRate = 48000;

TYPE
  Source = RECORD  (* a WAV or an MP3 file being read *)
    mp3: MPEGAudio0.Decoder;
    wave: Wave0.Reader;
    rate, channels, bits, frames: LONGINT
  END;

VAR
  dev: Sound0.Device;  (* the device of the running command, for Stop *)
  device: ARRAY 64 OF CHAR;  (* the device named with /d, else Sound.Device of Oberon.Text *)
  buf: ARRAY Chunk OF CHAR;

(* Oberon0.OnStop: a stopped command leaves no device open *)
PROCEDURE Stop;
BEGIN
  IF dev # NIL THEN Sound0.Drop(dev); Sound0.Close(dev); dev := NIL END
END Stop;

PROCEDURE Error(s: ARRAY OF CHAR);
BEGIN Out.String("sound: "); Out.String(s); Out.Ln
END Error;

PROCEDURE Default;
VAR S: Texts0.Scanner;
BEGIN
  Oberon0.OpenScanner(S, "Sound.Device");
  IF (S.class = Texts0.Name) OR (S.class = Texts0.String) THEN COPY(S.s, device) ELSE device := "" END
END Default;

PROCEDURE Number(s: ARRAY OF CHAR; VAR x: LONGINT): BOOLEAN;
VAR i: LONGINT; neg: BOOLEAN;
BEGIN
  x := 0; i := 0; neg := s[0] = "-"; IF neg THEN i := 1 END;
  IF (s[i] < "0") OR (s[i] > "9") THEN RETURN FALSE END;
  WHILE (s[i] >= "0") & (s[i] <= "9") DO x := x * 10 + ORD(s[i]) - 30H; INC(i) END;
  IF neg THEN x := -x END;
  RETURN (s[i] = 0X) OR (s[i] = "%") & (s[i + 1] = 0X)
END Number;

(* the next argument after the options /d and those in opts ("rcbv": each takes a number into val) *)
PROCEDURE Args(VAR R: Texts.Reader; opts: ARRAY OF CHAR; VAR val: ARRAY OF LONGINT; VAR a: ARRAY OF CHAR): BOOLEAN;
VAR i: LONGINT; s: ARRAY 64 OF CHAR;
BEGIN
  Default;
  LOOP
    IF ~Texts.Arg(R, a) THEN RETURN FALSE END;
    IF (a[0] # "/") OR (a[1] = 0X) OR (a[2] # 0X) THEN RETURN TRUE END;
    IF a[1] = "d" THEN IF ~Texts.Arg(R, device) THEN RETURN FALSE END
    ELSE
      i := 0; WHILE (opts[i] # 0X) & (opts[i] # a[1]) DO INC(i) END;
      IF (opts[i] = 0X) OR ~Texts.Arg(R, s) OR ~Number(s, val[i]) THEN Error("unknown option or no number after it"); RETURN FALSE END
    END
  END
END Args;

PROCEDURE Time(frames, rate: LONGINT);
VAR s: LONGINT;
BEGIN
  s := frames DIV rate; Out.Int(s DIV 60, 0); Out.Char(":");
  IF s MOD 60 < 10 THEN Out.Char("0") END; Out.Int(s MOD 60, 0)
END Time;

PROCEDURE NameError(name, s: ARRAY OF CHAR);
BEGIN Out.String(name); Out.String(": "); Out.String(s); Out.Ln
END NameError;

(* opens the WAV or MP3 file name and says what it is *)
PROCEDURE OpenSource(name: ARRAY OF CHAR; VAR s: Source): BOOLEAN;
VAR f: Files.File; fmt: Wave0.Format;
BEGIN
  f := Files.Old(name); s.mp3 := NIL;
  IF f = NIL THEN NameError(name, "no such file"); RETURN FALSE END;
  IF Wave0.ReadFormat(f, fmt) THEN
    Wave0.OpenReader(s.wave, f, fmt);
    s.rate := fmt.rate; s.channels := fmt.channels; s.bits := s.wave.outBits; s.frames := fmt.frames
  ELSIF Wave0.lastError # "not a WAV file" THEN NameError(name, Wave0.lastError); RETURN FALSE
  ELSIF MPEGAudio0.Open(f, s.mp3) THEN
    s.rate := s.mp3.rate; s.channels := s.mp3.channels; s.bits := 16; s.frames := s.mp3.samples
  ELSE NameError(name, "neither a WAV nor an MP3 file"); RETURN FALSE
  END;
  Out.String(name); Out.String(": "); Out.Int(s.rate, 0); Out.String(" Hz, ");
  IF s.channels = 1 THEN Out.String("mono, ") ELSE Out.String("stereo, ") END;
  IF s.mp3 # NIL THEN
    Out.String("MP3 (MPEG-");
    IF s.mp3.version = 3 THEN Out.String("2.5") ELSE Out.Int(s.mp3.version, 0) END; Out.String("), ");
    IF s.mp3.bitrate = 0 THEN Out.String("variable bit rate, ") ELSE Out.Int(s.mp3.bitrate, 0); Out.String(" kbit/s, ") END
  ELSE
    Out.Int(fmt.bits, 0); IF fmt.float THEN Out.String(" bits float, ") ELSE Out.String(" bits, ") END
  END;
  Time(s.frames, s.rate); Out.Ln;
  RETURN TRUE
END OpenSource;

PROCEDURE ReadSource(VAR s: Source; VAR data: ARRAY OF CHAR; len: LONGINT): LONGINT;
BEGIN
  IF s.mp3 # NIL THEN RETURN MPEGAudio0.Read(s.mp3, data, 0, len) ELSE RETURN Wave0.Read(s.wave, data, 0, len) END
END ReadSource;

PROCEDURE PlayFile(name: ARRAY OF CHAR): BOOLEAN;
VAR s: Source; n: LONGINT;
BEGIN
  IF ~OpenSource(name, s) THEN RETURN FALSE END;
  IF ~Sound0.Open(device, FALSE, s.rate, s.channels, s.bits, dev) THEN Error(Sound0.lastError); RETURN FALSE END;
  Oberon0.OnStop(Stop);
  LOOP
    n := ReadSource(s, buf, Chunk);
    IF n <= 0 THEN EXIT END;
    IF ~Sound0.Write(dev, buf, 0, n) THEN Error(Sound0.lastError); Stop; RETURN FALSE END
  END;
  Sound0.Drain(dev); Sound0.Close(dev); dev := NIL;
  RETURN TRUE
END PlayFile;

(** sound.Play [/d device] file ...  plays WAV and MP3 files *)
PROCEDURE Play*;
VAR R: Texts.Reader; a: ARRAY 256 OF CHAR; v: ARRAY 1 OF LONGINT;
BEGIN
  Texts.OpenArgs(R);
  IF ~Args(R, "", v, a) THEN Out.String("usage: sound.Play [/d device] file ...  (plays WAV and MP3 files)"); Out.Ln; RETURN END;
  REPEAT IF ~PlayFile(a) THEN RETURN END UNTIL ~Texts.Arg(R, a)
END Play;

(** sound.Convert from to.wav  writes a WAV or MP3 file as a WAV file (16 bits, 8 for one of 8) *)
PROCEDURE Convert*;
VAR R: Texts.Reader; a, b: ARRAY 256 OF CHAR; v: ARRAY 1 OF LONGINT; s: Source; f: Files.File; r: Files.Rider;
  n, total: LONGINT;
BEGIN
  Texts.OpenArgs(R);
  IF ~Args(R, "", v, a) OR ~Texts.Arg(R, b) THEN
    Out.String("usage: sound.Convert from to.wav  (a WAV or MP3 file as a WAV file)"); Out.Ln; RETURN
  END;
  IF ~OpenSource(a, s) THEN RETURN END;
  f := Files.New(b); Files.Set(r, f, 0); Wave0.WriteHeader(r, s.rate, s.channels, s.bits); total := 0;
  LOOP n := ReadSource(s, buf, Chunk); IF n <= 0 THEN EXIT END; Files.WriteBytes(r, buf, n); INC(total, n) END;
  Wave0.Finish(f, total); Files.Register(f);
  Out.String(b); Out.String(": "); Time(total DIV (s.channels * s.bits DIV 8), s.rate); Out.Ln
END Convert;

(* n samples of a tone of freq Hz (0: silence) at amplitude amp into buf, 16 bits mono, from sample
  at of a tone of len samples; fades of 5 ms at both ends *)
PROCEDURE ToneSamples(freq, amp, at, n, len: LONGINT);
VAR i, v, fade, k: LONGINT; w: REAL;
BEGIN
  fade := ToneRate DIV 200; w := 2.0 * 3.14159265 * freq / ToneRate;
  i := 0;
  WHILE i < n DO
    k := at + i;
    IF freq = 0 THEN v := 0
    ELSE
      v := ENTIER(amp * Math.sin(w * (k MOD ToneRate)));
      IF k < fade THEN v := v * k DIV fade ELSIF len - k < fade THEN v := v * (len - k) DIV fade END
    END;
    buf[i * 2] := CHR(v MOD 256); buf[i * 2 + 1] := CHR(v DIV 256 MOD 256);
    INC(i)
  END
END ToneSamples;

(** sound.Tone [/d device] [/v volume] freq ms ...  plays tones (freq 0: a rest), volume in per cent (30) *)
PROCEDURE Tone*;
VAR R: Texts.Reader; a: ARRAY 64 OF CHAR; v: ARRAY 1 OF LONGINT; freq, ms, len, at, n, amp: LONGINT;
BEGIN
  Texts.OpenArgs(R); v[0] := 30;
  IF ~Args(R, "v", v, a) OR ~Number(a, freq) THEN
    Out.String("usage: sound.Tone [/d device] [/v volume] freq ms ...  (Hz, milliseconds; volume in per cent)"); Out.Ln; RETURN
  END;
  IF ~Sound0.Open(device, FALSE, ToneRate, 1, 16, dev) THEN Error(Sound0.lastError); RETURN END;
  Oberon0.OnStop(Stop);
  amp := 32767 * v[0] DIV 100; IF amp > 32767 THEN amp := 32767 ELSIF amp < 0 THEN amp := 0 END;
  LOOP
    IF ~Texts.Arg(R, a) OR ~Number(a, ms) OR (freq < 0) OR (freq >= ToneRate DIV 2) OR (ms < 0) THEN
      IF a # "" THEN Error("a pair of numbers: freq (below 24000) and ms") END;
      EXIT
    END;
    len := ToneRate DIV 1000 * ms; at := 0;
    WHILE at < len DO
      n := len - at; IF n > Chunk DIV 2 THEN n := Chunk DIV 2 END;
      ToneSamples(freq, amp, at, n, len);
      IF ~Sound0.Write(dev, buf, 0, n * 2) THEN Error(Sound0.lastError); Stop; RETURN END;
      INC(at, n)
    END;
    IF ~Texts.Arg(R, a) THEN EXIT END;
    IF ~Number(a, freq) THEN Error("not a number"); EXIT END
  END;
  Sound0.Drain(dev); Sound0.Close(dev); dev := NIL
END Tone;

(** sound.Record [/d device] [/r rate] [/c channels] [/b bits] seconds file.wav  records into a WAV file
  (44100 Hz, 2 channels, 16 bits) *)
PROCEDURE Record*;
VAR R: Texts.Reader; a, name: ARRAY 256 OF CHAR; v: ARRAY 3 OF LONGINT; secs, want, got, n: LONGINT;
  f: Files.File; r: Files.Rider;
BEGIN
  Texts.OpenArgs(R); v[0] := 44100; v[1] := 2; v[2] := 16;
  IF ~Args(R, "rcb", v, a) OR ~Number(a, secs) OR ~Texts.Arg(R, name) THEN
    Out.String("usage: sound.Record [/d device] [/r rate] [/c channels] [/b bits] seconds file.wav"); Out.Ln; RETURN
  END;
  IF ~Sound0.Open(device, TRUE, v[0], v[1], v[2], dev) THEN Error(Sound0.lastError); RETURN END;
  Oberon0.OnStop(Stop);
  f := Files.New(name); Files.Set(r, f, 0); Wave0.WriteHeader(r, v[0], v[1], v[2]);
  want := secs * v[0] * v[1] * (v[2] DIV 8); got := 0;
  WHILE got < want DO
    n := Sound0.Read(dev, buf, 0, Chunk);
    IF n < 0 THEN Error(Sound0.lastError); want := got
    ELSE
      IF n > want - got THEN n := want - got END;
      Files.WriteBytes(r, buf, n); INC(got, n)
    END
  END;
  Sound0.Close(dev); dev := NIL;
  Wave0.Finish(f, got); Files.Register(f);
  Out.String(name); Out.String(": "); Time(got DIV (v[1] * (v[2] DIV 8)), v[0]); Out.Ln
END Record;

PROCEDURE ShowControl(m: Sound0.Mixer; i: LONGINT);
VAR k, x: LONGINT; s: ARRAY 64 OF CHAR;
BEGIN
  Out.String("  "); Out.String(m.c[i].name); Out.String(":");
  k := 0;
  WHILE k < m.c[i].count DO
    x := Sound0.GetValue(m, i, k); Out.Char(" ");
    IF m.c[i].kind = Sound0.Switch THEN IF x # 0 THEN Out.String("on") ELSE Out.String("off") END
    ELSIF m.c[i].kind = Sound0.Choice THEN Sound0.ItemName(m, i, x, s); IF s = "" THEN Out.Int(x, 0) ELSE Out.String(s) END
    ELSE Out.Int(x, 0)
    END;
    INC(k)
  END;
  IF m.c[i].kind = Sound0.Volume THEN Out.String("  ("); Out.Int(m.c[i].min, 0); Out.String(".."); Out.Int(m.c[i].max, 0); Out.String(")") END;
  IF ~m.c[i].writable THEN Out.String("  (read only)") END;
  IF ~m.c[i].active THEN Out.String("  (inactive)") END;
  Out.Ln
END ShowControl;

PROCEDURE Lower(ch: CHAR): CHAR;
BEGIN
  IF (ch >= "A") & (ch <= "Z") THEN RETURN CHR(ORD(ch) + 32) END;
  RETURN ch
END Lower;

(* the control named name, else the first whose name begins with it (case ignored); -1 *)
PROCEDURE Find(m: Sound0.Mixer; name: ARRAY OF CHAR): LONGINT;
VAR i, k: LONGINT;
BEGIN
  i := Sound0.This(m, name);
  IF i >= 0 THEN RETURN i END;
  i := 0;
  WHILE i < m.n DO
    k := 0; WHILE (name[k] # 0X) & (Lower(name[k]) = Lower(m.c[i].name[k])) DO INC(k) END;
    IF name[k] = 0X THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END Find;

(* the value a for control i: a number (a per cent of the range with %), on/off, or a Choice's item *)
PROCEDURE Value(m: Sound0.Mixer; i: LONGINT; a: ARRAY OF CHAR; VAR x: LONGINT): BOOLEAN;
VAR k, j: LONGINT; s: ARRAY 64 OF CHAR;
BEGIN
  IF Number(a, x) THEN
    k := 0; WHILE a[k] # 0X DO INC(k) END;
    IF (k > 0) & (a[k - 1] = "%") THEN x := m.c[i].min + (m.c[i].max - m.c[i].min) * x DIV 100 END;
    RETURN TRUE
  ELSIF (a = "on") OR (a = "off") THEN
    IF a = "on" THEN x := 1 ELSE x := 0 END; RETURN m.c[i].kind = Sound0.Switch
  ELSIF m.c[i].kind = Sound0.Choice THEN
    j := 0;
    WHILE j < m.c[i].items DO Sound0.ItemName(m, i, j, s); IF s = a THEN x := j; RETURN TRUE END; INC(j) END
  END;
  RETURN FALSE
END Value;

(** sound.Mixer [/d card]  lists the controls of the mixer; sound.Mixer [/d card] name value [value]
  sets one (a name or the start of one; values: numbers, n% of the range, on/off, items) *)
PROCEDURE Mixer*;
VAR R: Texts.Reader; a, b: ARRAY 64 OF CHAR; v: ARRAY 1 OF LONGINT; m: Sound0.Mixer; i, x: LONGINT; set: BOOLEAN;
BEGIN
  Texts.OpenArgs(R); set := Args(R, "", v, a);
  IF ~Sound0.OpenMixer(device, m) THEN Error(Sound0.lastError); RETURN END;
  IF ~set THEN
    Out.String(m.path); Out.String(": "); Out.Int(m.n, 0); Out.String(" controls"); Out.Ln;
    i := 0; WHILE i < m.n DO ShowControl(m, i); INC(i) END
  ELSE
    i := Find(m, a);
    IF i < 0 THEN Error("no such control (sound.Mixer lists them)")
    ELSIF ~Texts.Arg(R, b) THEN ShowControl(m, i)
    ELSIF ~Value(m, i, b, x) THEN Error("not a value of this control")
    ELSE
      IF Texts.Arg(R, a) THEN
        IF Sound0.SetValue(m, i, 0, x) & Value(m, i, a, x) & Sound0.SetValue(m, i, 1, x) THEN END
      ELSIF Sound0.SetValue(m, i, -1, x) THEN
      END;
      IF Sound0.lastError # "" THEN Error(Sound0.lastError) ELSE ShowControl(m, i) END
    END
  END;
  Sound0.CloseMixer(m)
END Mixer;

PROCEDURE ShowDevice(capture: BOOLEAN);
VAR d: Sound0.Device;
BEGIN
  IF capture THEN Out.String("capture: ") ELSE Out.String("playback: ") END;
  IF Sound0.Open(device, capture, 48000, 2, 16, d) THEN
    Out.String(d.path); IF d.alsa THEN Out.String(" (ALSA), ") ELSE Out.String(" (OSS), ") END;
    Out.Int(d.hwRate, 0); Out.String(" Hz, "); Out.Int(d.hwChannels, 0); Out.String(" channels, buffer ");
    Out.Int(d.bufferFrames * 1000 DIV d.hwRate, 0); Out.String(" ms");
    IF d.canPause THEN Out.String(", pauses") END;
    Sound0.Close(d)
  ELSE Out.String(Sound0.lastError)
  END;
  Out.Ln
END ShowDevice;

(** sound.Info [/d device]  the devices for playback and capture and the mixer *)
PROCEDURE Info*;
VAR R: Texts.Reader; a: ARRAY 64 OF CHAR; v: ARRAY 1 OF LONGINT; m: Sound0.Mixer;
BEGIN
  Texts.OpenArgs(R); IF Args(R, "", v, a) THEN END;
  ShowDevice(FALSE); ShowDevice(TRUE);
  Out.String("mixer: ");
  IF Sound0.OpenMixer(device, m) THEN
    Out.String(m.path); Out.String(", "); Out.Int(m.n, 0); Out.String(" controls"); Sound0.CloseMixer(m)
  ELSE Out.String(Sound0.lastError)
  END;
  Out.Ln
END Info;

PROCEDURE Help*;
BEGIN
  Out.String("sound: WAV and MP3 files and tones played, recording, the mixer"); Out.Ln; Out.Ln;
  Out.String("  sound.Play [/d device] file ...          plays WAV files (8 to 32 bits) and MP3 files"); Out.Ln;
  Out.String("  sound.Convert from to.wav                a WAV or MP3 file as a WAV file of 16 bits"); Out.Ln;
  Out.String("  sound.Tone [/d device] [/v volume] freq ms ...   tones in Hz for ms milliseconds;"); Out.Ln;
  Out.String("      freq 0 is a rest, volume in per cent (30)"); Out.Ln;
  Out.String("  sound.Record [/d device] [/r rate] [/c channels] [/b bits] seconds file.wav"); Out.Ln;
  Out.String("      records into a WAV file (44100 Hz, 2 channels, 16 bits)"); Out.Ln;
  Out.String("  sound.Mixer [/d card]                    lists the controls of the mixer"); Out.Ln;
  Out.String("  sound.Mixer [/d card] name value [value]  sets a control: a number, n% of its range,"); Out.Ln;
  Out.String("      on/off, or an item; the name or the start of it, in quotes if it has blanks"); Out.Ln;
  Out.String("  sound.Info [/d device]                   the devices used"); Out.Ln; Out.Ln;
  Out.String("Devices: hw:c,d (ALSA card c, device d), oss (/dev/dsp), or a path; without /d,"); Out.Ln;
  Out.String("Sound.Device of Oberon.Text, else ALSA hw:0,0, else /dev/dsp."); Out.Ln;
  Out.String("Examples:"); Out.Ln;
  Out.String("  sound.Tone 440 300 0 100 660 300"); Out.Ln;
  Out.String("  sound.Mixer Master 70%"); Out.Ln;
  Out.String("  sound.Record 5 zq.wav"); Out.Ln;
  Out.String("  sound.Play zq.wav"); Out.Ln
END Help;

BEGIN
  dev := NIL; device := ""
END sound.
