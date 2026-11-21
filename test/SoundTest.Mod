MODULE SoundTest;  (** SoundTest.Run: conversions and WAV files; silence on the sound device if there is one *)

IMPORT SYSTEM, Files, Out, Sound0, Wave0;

VAR
  fails, checks: LONGINT;
  in, out, ref: ARRAY 4096 OF CHAR;

PROCEDURE Check(what: ARRAY OF CHAR; ok: BOOLEAN);
BEGIN
  INC(checks);
  IF ~ok THEN INC(fails); Out.String("FAIL "); Out.String(what); Out.String(" (case "); Out.Int(checks, 0); Out.String(")"); Out.Ln END
END Check;

PROCEDURE Put16(VAR a: ARRAY OF CHAR; i, v: LONGINT);
BEGIN a[i] := CHR(v MOD 256); a[i + 1] := CHR(v DIV 256 MOD 256)
END Put16;

PROCEDURE Get16(VAR a: ARRAY OF CHAR; i: LONGINT): LONGINT;
VAR v, h: LONGINT;
BEGIN
  h := ORD(a[i + 1]); v := h * 256 + ORD(a[i]);
  IF v >= 32768 THEN DEC(v, 65536) END;
  RETURN v
END Get16;

PROCEDURE Same(VAR a, b: ARRAY OF CHAR; n: LONGINT): BOOLEAN;
VAR i: LONGINT;
BEGIN
  i := 0; WHILE (i < n) & (a[i] = b[i]) DO INC(i) END;
  RETURN i = n
END Same;

PROCEDURE Near(a, b, d: LONGINT): BOOLEAN;
BEGIN RETURN ABS(a - b) <= d
END Near;

PROCEDURE Conversions;
VAR c: Sound0.Converter; used, made, i, k, total, n: LONGINT; ok: BOOLEAN;
BEGIN
  (* the same format: a copy *)
  i := 0; WHILE i < 32 DO in[i] := CHR(i * 7 + 3); INC(i) END;
  Sound0.InitConverter(c, 48000, 2, 16, 48000, 2, 16);
  Sound0.Convert(c, in, 0, 32, out, 0, LEN(out), used, made);
  Check("copy", (used = 32) & (made = 32) & Same(in, out, 32));
  (* 8 bits mono to 16 bits stereo *)
  in[0] := 80X; in[1] := 0FFX; in[2] := 0X;
  Sound0.InitConverter(c, 8000, 1, 8, 8000, 2, 16);
  Sound0.Convert(c, in, 0, 3, out, 0, LEN(out), used, made);
  Check("8 to 16 bits", (made = 12) & (Get16(out, 0) = 0) & (Get16(out, 2) = 0) & (Get16(out, 4) = 32512)
    & (Get16(out, 6) = 32512) & (Get16(out, 8) = -32768) & (Get16(out, 10) = -32768));
  (* stereo to mono, 16 to 8 bits *)
  Put16(in, 0, 1000); Put16(in, 2, 3000); Put16(in, 4, -32768); Put16(in, 6, -32768);
  Sound0.InitConverter(c, 8000, 2, 16, 8000, 1, 16);
  Sound0.Convert(c, in, 0, 8, out, 0, LEN(out), used, made);
  Check("stereo to mono", (made = 4) & (Get16(out, 0) = 2000) & (Get16(out, 2) = -32768));
  Sound0.InitConverter(c, 8000, 1, 16, 8000, 1, 8);
  Sound0.Convert(c, in, 0, 2, out, 0, LEN(out), used, made);
  Check("16 to 8 bits", (made = 1) & (out[0] = CHR(1000 DIV 256 + 128)));
  (* a frame in pieces *)
  i := 0; WHILE i < 40 DO in[i] := CHR(i * 5 + 1); INC(i) END;
  Sound0.InitConverter(c, 44100, 2, 16, 44100, 2, 16);
  total := 0; i := 0;
  WHILE i < 40 DO
    Sound0.Convert(c, in, i, 1, out, total, LEN(out) - total, used, made); INC(total, made); INC(i, used)
  END;
  Check("byte by byte", (total = 40) & Same(in, out, 40));
  (* 8000 to 48000 Hz: a ramp stays a ramp, six frames for each *)
  i := 0; WHILE i < 100 DO Put16(in, i * 2, i * 300); INC(i) END;
  Sound0.InitConverter(c, 8000, 1, 16, 48000, 1, 16);
  Sound0.Convert(c, in, 0, 200, out, 0, LEN(out), used, made);
  Sound0.Finish(c, out, made, LEN(out) - made, n); total := (made + n) DIV 2;
  Check("8000 to 48000: frames", total = 600);
  ok := TRUE; k := 0; WHILE k < 595 DO IF ~Near(Get16(out, k * 2), k * 50, 4) THEN ok := FALSE END; INC(k) END;
  Check("8000 to 48000: values", ok);
  (* 48000 to 8000 Hz *)
  i := 0; WHILE i < 600 DO Put16(in, i * 2, i * 50); INC(i) END;
  Sound0.InitConverter(c, 48000, 1, 16, 8000, 1, 16);
  Sound0.Convert(c, in, 0, 1200, out, 0, LEN(out), used, made);
  Sound0.Finish(c, out, made, LEN(out) - made, n); total := (made + n) DIV 2;
  Check("48000 to 8000: frames", Near(total, 100, 1));
  ok := TRUE; k := 0; WHILE k < 99 DO IF ~Near(Get16(out, k * 2), k * 300, 4) THEN ok := FALSE END; INC(k) END;
  Check("48000 to 8000: values", ok);
  (* 44100 to 48000 Hz, in parts *)
  Sound0.InitConverter(c, 44100, 2, 16, 48000, 2, 16);
  i := 0; WHILE i < 4000 DO in[i] := 0X; INC(i) END;
  total := 0; k := 0;
  WHILE k < 44100 DO
    Sound0.Convert(c, in, 0, 400, out, 0, LEN(out), used, made);
    INC(total, made DIV 4); INC(k, used DIV 4)
  END;
  Sound0.Finish(c, out, 0, LEN(out), n); INC(total, n DIV 4);
  Check("44100 to 48000: one second", Near(total, 48000, 1))
END Conversions;

(* a WAV file of the header h (n bytes) and data d (m bytes) *)
PROCEDURE MakeFile(name: ARRAY OF CHAR; VAR h: ARRAY OF CHAR; n: LONGINT; VAR d: ARRAY OF CHAR; m: LONGINT);
VAR f: Files.File; r: Files.Rider;
BEGIN
  f := Files.New(name); Files.Set(r, f, 0); Files.WriteBytes(r, h, n); Files.WriteBytes(r, d, m); Files.Register(f)
END MakeFile;

PROCEDURE Head(VAR h: ARRAY OF CHAR; kind, channels, rate, bits, dataLen: LONGINT);
VAR f: Files.File; r: Files.Rider;
BEGIN
  f := Files.New(""); Files.Set(r, f, 0); Wave0.WriteHeader(r, rate, channels, 16);
  IF kind >= 32768 THEN DEC(kind, 65536) END;
  Files.Set(r, f, 20); Files.WriteInt(r, SHORT(kind));
  Files.Set(r, f, 34); Files.WriteInt(r, SHORT(bits));
  Files.Set(r, f, 40); Files.WriteLInt(r, dataLen);
  Files.Set(r, f, 0); Files.ReadBytes(r, h, 44)
END Head;

PROCEDURE Waves;
VAR f: Files.File; r: Files.Rider; fmt: Wave0.Format; rd: Wave0.Reader; i, n: LONGINT; h: ARRAY 128 OF CHAR;
BEGIN
  (* written and read back *)
  i := 0; WHILE i < 400 DO ref[i] := CHR(i * 3 + 1); INC(i) END;
  f := Files.New("zq_snd1.wav"); Files.Set(r, f, 0); Wave0.WriteHeader(r, 22050, 2, 16);
  Files.WriteBytes(r, ref, 400); Wave0.Finish(f, 400); Files.Register(f);
  f := Files.Old("zq_snd1.wav");
  Check("written: format", (f # NIL) & Wave0.ReadFormat(f, fmt) & (fmt.rate = 22050) & (fmt.channels = 2)
    & (fmt.bits = 16) & ~fmt.float & (fmt.frames = 100) & (fmt.dataPos = 44));
  IF f # NIL THEN
    Wave0.OpenReader(rd, f, fmt); n := Wave0.Read(rd, out, 10, 1000);
    i := 0; WHILE (i < 400) & (out[10 + i] = ref[i]) DO INC(i) END;
    Check("written: samples", (n = 400) & (i = 400) & (Wave0.Read(rd, out, 0, 100) = 0));
    Wave0.SetFrame(rd, 50); n := Wave0.Read(rd, out, 0, 1000);
    Check("SetFrame", (n = 200) & (out[0] = ref[200]))
  END;
  (* 24 bits: the upper two bytes *)
  Head(h, 1, 1, 8000, 24, 6);
  in[0] := 56X; in[1] := 34X; in[2] := 12X; in[3] := 0X; in[4] := 0X; in[5] := 80X;
  MakeFile("zq_snd2.wav", h, 44, in, 6); f := Files.Old("zq_snd2.wav");
  Check("24 bits: format", Wave0.ReadFormat(f, fmt) & (fmt.bits = 24) & (fmt.frames = 2));
  Wave0.OpenReader(rd, f, fmt); n := Wave0.Read(rd, out, 0, 100);
  Check("24 bits: samples", (rd.outBits = 16) & (n = 4) & (Get16(out, 0) = 1234H) & (Get16(out, 2) = -32768));
  (* floating point *)
  Head(h, 3, 1, 8000, 32, 12);
  in[0] := 0X; in[1] := 0X; in[2] := 0X; in[3] := 3FX;  (* 0.5 *)
  in[4] := 0X; in[5] := 0X; in[6] := 80X; in[7] := 0BFX;  (* -1.0 *)
  in[8] := 0X; in[9] := 0X; in[10] := 0X; in[11] := 40X;  (* 2.0 *)
  MakeFile("zq_snd3.wav", h, 44, in, 12); f := Files.Old("zq_snd3.wav");
  Check("float: format", Wave0.ReadFormat(f, fmt) & fmt.float & (fmt.frames = 3));
  Wave0.OpenReader(rd, f, fmt); n := Wave0.Read(rd, out, 0, 100);
  Check("float: samples", (n = 6) & (Get16(out, 0) = 16383) & (Get16(out, 2) = -32768) & (Get16(out, 4) = 32767));
  (* a LIST chunk before the data, an odd length padded *)
  Head(h, 1, 1, 8000, 8, 2);
  i := 0; WHILE i < 36 DO ref[i] := h[i]; INC(i) END;
  ref[36] := "L"; ref[37] := "I"; ref[38] := "S"; ref[39] := "T"; ref[40] := 3X; ref[41] := 0X; ref[42] := 0X; ref[43] := 0X;
  ref[44] := "a"; ref[45] := "b"; ref[46] := "c"; ref[47] := 0X;
  i := 0; WHILE i < 8 DO ref[48 + i] := h[36 + i]; INC(i) END;
  in[0] := 10X; in[1] := 0F0X;
  MakeFile("zq_snd4.wav", ref, 56, in, 2); f := Files.Old("zq_snd4.wav");
  Check("chunks skipped", Wave0.ReadFormat(f, fmt) & (fmt.dataPos = 56) & (fmt.frames = 2) & (fmt.bits = 8));
  (* WAVE_FORMAT_EXTENSIBLE *)
  Head(h, 0FFFEH, 2, 44100, 16, 4);
  i := 0; WHILE i < 36 DO ref[i] := h[i]; INC(i) END;
  ref[16] := CHR(40); ref[36] := CHR(22); ref[37] := 0X; ref[38] := CHR(16); ref[39] := 0X;
  ref[40] := 3X; ref[41] := 0X; ref[42] := 0X; ref[43] := 0X; ref[44] := 1X; ref[45] := 0X;
  i := 46; WHILE i < 60 DO ref[i] := 0X; INC(i) END;
  i := 0; WHILE i < 8 DO ref[60 + i] := h[36 + i]; INC(i) END;
  MakeFile("zq_snd5.wav", ref, 68, in, 4); f := Files.Old("zq_snd5.wav");
  Check("extensible", Wave0.ReadFormat(f, fmt) & (fmt.channels = 2) & (fmt.rate = 44100) & (fmt.frames = 1));
  (* not a WAV file *)
  MakeFile("zq_snd6.wav", in, 40, in, 0); f := Files.Old("zq_snd6.wav");
  Check("not a WAV file", ~Wave0.ReadFormat(f, fmt) & (Wave0.lastError # ""));
  Head(h, 2, 1, 8000, 4, 2); MakeFile("zq_snd7.wav", h, 44, in, 2); f := Files.Old("zq_snd7.wav");
  Check("compressed refused", ~Wave0.ReadFormat(f, fmt))
END Waves;

(* silence played and some frames recorded, if a device is there *)
PROCEDURE Device;
VAR d: Sound0.Device; m: Sound0.Mixer; i, n, x: LONGINT;
BEGIN
  IF Sound0.Open("", FALSE, 22050, 1, 16, d) THEN
    Out.String("  playback: "); Out.String(d.path); Out.Ln;
    i := 0; WHILE i < LEN(out) DO out[i] := 0X; INC(i) END;
    i := 0; WHILE i < 2 DO Check("silence played", Sound0.Write(d, out, 0, 2205)); INC(i) END;
    Check("frames given", d.frames = 2205);
    Sound0.Drain(d); Check("all played", Sound0.Played(d) = 2205);
    Sound0.Close(d)
  ELSE Out.String("  no playback: "); Out.String(Sound0.lastError); Out.Ln
  END;
  IF Sound0.Open("", TRUE, 8000, 1, 8, d) THEN
    Out.String("  capture: "); Out.String(d.path); Out.Ln;
    n := Sound0.Read(d, out, 0, 400);
    Check("recorded", (n > 0) & (n <= 400)); Sound0.Close(d)
  ELSE Out.String("  no capture: "); Out.String(Sound0.lastError); Out.Ln
  END;
  IF Sound0.OpenMixer("", m) THEN
    Out.String("  mixer: "); Out.String(m.path); Out.Int(m.n, 4); Out.String(" controls"); Out.Ln;
    i := 0; WHILE (i < m.n) & ((m.c[i].kind # Sound0.Volume) OR ~m.c[i].writable) DO INC(i) END;
    IF i < m.n THEN
      x := Sound0.GetValue(m, i, 0);
      Check("mixer value set to itself", Sound0.SetValue(m, i, 0, x) & (Sound0.GetValue(m, i, 0) = x))
    END;
    Sound0.CloseMixer(m)
  ELSE Out.String("  no mixer: "); Out.String(Sound0.lastError); Out.Ln
  END
END Device;

PROCEDURE Run*;
BEGIN
  fails := 0; checks := 0;
  Conversions; Waves; Device;
  Out.String("SoundTest: "); Out.Int(checks, 0); Out.String(" checks, "); Out.Int(fails, 0); Out.String(" failed"); Out.Ln
END Run;

(** the offline checks only, for the recipe: a test machine may have no free sound device *)
PROCEDURE Offline*;
BEGIN
  fails := 0; checks := 0;
  Conversions; Waves;
  Out.String("SoundTest: "); Out.Int(checks, 0); Out.String(" checks, "); Out.Int(fails, 0); Out.String(" failed"); Out.Ln
END Offline;

END SoundTest.
