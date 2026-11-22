MODULE Player;  (** WAV and MP3 files played while the desktop goes on *)

(* Player.Play file plays the file in the background: an Oberon task decodes it and gives the device what
   it takes. Player.Pause pauses or goes on, Player.Stop stops, Player.Show writes into System.Log what
   plays and where. The device is Sound.Device of Oberon.Text, else the default of Sound0. *)

IMPORT Files, Input, Texts, Oberon, Sound0, Wave0, MPEGAudio0;

CONST
  Chunk = 16384;

VAR
  dev: Sound0.Device;
  task: Oberon.Task;
  mp3: MPEGAudio0.Decoder;
  wave: Wave0.Reader;
  name: ARRAY 256 OF CHAR;
  buf: ARRAY Chunk OF CHAR;
  bufPos, bufLen, rate, channels, frames: LONGINT;
  eof: BOOLEAN;
  W: Texts.Writer;

PROCEDURE Time(n: LONGINT);
BEGIN
  n := n DIV rate; Texts.WriteInt(W, n DIV 60, 0); Texts.Write(W, ":");
  IF n MOD 60 < 10 THEN Texts.Write(W, "0") END; Texts.WriteInt(W, n MOD 60, 0)
END Time;

PROCEDURE Log(s: ARRAY OF CHAR);
BEGIN
  Texts.WriteString(W, "Player: "); Texts.WriteString(W, s); Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
END Log;

PROCEDURE Close;
BEGIN
  IF task # NIL THEN Oberon.Remove(task); task := NIL END;
  IF dev # NIL THEN Sound0.Close(dev); dev := NIL END;
  mp3 := NIL
END Close;

PROCEDURE Fill;
BEGIN
  IF mp3 # NIL THEN bufLen := MPEGAudio0.Read(mp3, buf, 0, Chunk) ELSE bufLen := Wave0.Read(wave, buf, 0, Chunk) END;
  bufPos := 0;
  IF bufLen <= 0 THEN bufLen := 0; eof := TRUE END
END Fill;

PROCEDURE Step(me: Oberon.Task);
VAR n: LONGINT;
BEGIN
  IF (dev # NIL) & ~dev.paused THEN
    LOOP
      IF bufPos >= bufLen THEN
        IF ~eof THEN Fill END;
        IF eof THEN EXIT END
      END;
      n := Sound0.WriteSome(dev, buf, bufPos, bufLen - bufPos);
      IF n < 0 THEN Log(Sound0.lastError); Close; RETURN END;
      INC(bufPos, n);
      IF bufPos < bufLen THEN EXIT END
    END;
    IF eof THEN
      IF Sound0.WriteSome(dev, buf, 0, 0) < 0 THEN Close; RETURN END;
      IF Sound0.Delay(dev) <= 0 THEN Close; RETURN END
    END
  END;
  IF task # NIL THEN task.time := Oberon.Time() + Input.TimeUnit DIV 50 END
END Step;

(** Player.Play file  plays a WAV or an MP3 file; what plays already stops *)
PROCEDURE Play*;
VAR R: Texts.Reader; S: Texts.Scanner; f: Files.File; fmt: Wave0.Format; bits: LONGINT; device: ARRAY 64 OF CHAR;
BEGIN
  Texts.OpenArgs(R);
  IF ~Texts.Arg(R, name) THEN Log("usage: Player.Play file  (a WAV or MP3 file)"); RETURN END;
  Close;
  f := Files.Old(name);
  IF f = NIL THEN Log("no such file"); RETURN END;
  IF Wave0.ReadFormat(f, fmt) THEN
    Wave0.OpenReader(wave, f, fmt); rate := fmt.rate; channels := fmt.channels; bits := wave.outBits; frames := fmt.frames
  ELSIF (Wave0.lastError = "not a WAV file") & MPEGAudio0.Open(f, mp3) THEN
    rate := mp3.rate; channels := mp3.channels; bits := 16; frames := mp3.samples
  ELSIF Wave0.lastError # "not a WAV file" THEN Log(Wave0.lastError); RETURN
  ELSE Log("neither a WAV nor an MP3 file"); RETURN
  END;
  Oberon.OpenScanner(S, "Sound.Device");
  IF (S.class = Texts.Name) OR (S.class = Texts.String) THEN COPY(S.s, device) ELSE device := "" END;
  IF ~Sound0.Open(device, FALSE, rate, channels, bits, dev) THEN Log(Sound0.lastError); dev := NIL; mp3 := NIL; RETURN END;
  bufPos := 0; bufLen := 0; eof := FALSE;
  NEW(task); task.safe := FALSE; task.handle := Step; task.time := Oberon.Time(); Oberon.Install(task);
  Texts.WriteString(W, "Player: "); Texts.WriteString(W, name); Texts.WriteString(W, ", "); Time(frames);
  Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
END Play;

(** Player.Stop  stops at once *)
PROCEDURE Stop*;
BEGIN
  IF dev # NIL THEN Sound0.Drop(dev) END;
  Close
END Stop;

(** Player.Pause  pauses, or goes on after a pause *)
PROCEDURE Pause*;
BEGIN
  IF dev # NIL THEN Sound0.Pause(dev, ~dev.paused) END
END Pause;

(** Player.Show  what plays and where *)
PROCEDURE Show*;
BEGIN
  IF dev = NIL THEN Log("nothing plays")
  ELSE
    Texts.WriteString(W, "Player: "); Texts.WriteString(W, name); Texts.WriteString(W, " ");
    Time(Sound0.Played(dev)); Texts.WriteString(W, " of "); Time(frames);
    IF dev.paused THEN Texts.WriteString(W, ", paused") END;
    Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
  END
END Show;

BEGIN
  Texts.OpenWriter(W); dev := NIL; task := NIL; mp3 := NIL
END Player.
