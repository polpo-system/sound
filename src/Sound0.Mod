MODULE Sound0;  (** sound through the interfaces of the kernel: ALSA PCM devices, else OSS *)

(* Playback and capture of PCM data of 8 bits (unsigned) or 16 bits (signed, little-endian, as in WAV
   files), mono or stereo, at any rate. The device runs with 16 bits and with a rate and channels it
   takes; the data is converted on the way (channels mixed or doubled, the rate by linear
   interpolation). The device is an ALSA PCM device (/dev/snd/pcmC0D0p, its ioctls), or with OSS
   /dev/dsp; the mixer reads and sets the controls of an ALSA card, or those of /dev/mixer.
   Everything goes through system calls (Linux0): open, ioctl, read, write, select. *)

IMPORT SYSTEM, Linux0;

CONST
  BufSize = 16384;  (* bytes converted for the device, or read from it *)
  MaxControls* = 256;

  (** kinds of mixer controls *)
  Other* = 0; Switch* = 1; Volume* = 2; Choice* = 3;

  EINTR = 4; ENOENT = 2; EAGAIN = 11; EACCES = 13; EBUSY = 16; ENODEV = 19; EINVAL = 22;
  ENOTTY = 25; EPIPE = 32;

  (* struct snd_pcm_hw_params as 151 words: masks from word 1, intervals from word 65, 3 words each *)
  ParamWords = 151; ParamSize = 604; Ivl = 65; PInfo = 130;
  IChannels = 2; IRate = 3; IPeriodTime = 4; IBufferTime = 8; IBufferSize = 9;

  OSSNames = "vol bass treble synth pcm speaker line mic cd mix pcm2 rec igain ogain line1 line2 line3 dig1 dig2 dig3 phin phout video radio monitor";

TYPE
  Params = ARRAY ParamWords OF LONGINT;

  (** a conversion of PCM data from one format to another *)
  Converter* = RECORD
    srcRate*, srcChannels*, srcBits*: LONGINT;
    dstRate*, dstChannels*, dstBits*: LONGINT;
    srcFrame, dstFrame, maxOut, frac, a0, b0, partLen: LONGINT;
    primed: BOOLEAN;
    part: ARRAY 4 OF CHAR
  END;

  Device* = POINTER TO DeviceDesc;
  DeviceDesc* = RECORD
    alsa*: BOOLEAN;  (** an ALSA PCM device, else OSS *)
    capture*: BOOLEAN;
    canPause*: BOOLEAN;  (** the device pauses itself (ALSA) *)
    paused*: BOOLEAN;
    rate*, channels*, bits*: LONGINT;  (** the format of the data of the caller *)
    hwRate*, hwChannels*: LONGINT;  (** the format of the device, always 16 bits *)
    bufferFrames*: LONGINT;  (** the size of the buffer of the device *)
    frames*: LONGINT;  (** frames given (playback) or taken (capture) so far, in the caller's format *)
    res*: LONGINT;  (** 0, or the error of the last operation (negative errno) *)
    path*: ARRAY 64 OF CHAR;
    fd, hwFrame, bufPos, bufLen, given: LONGINT;
    started: BOOLEAN;  (* START was sent since the last PREPARE *)
    drained: BOOLEAN;  (* everything given was played *)
    conv: Converter;
    buf: ARRAY BufSize OF CHAR
  END;

  Control* = RECORD
    name*: ARRAY 48 OF CHAR;
    kind*: LONGINT;  (** Switch, Volume, Choice or Other *)
    count*: LONGINT;  (** the number of values (2 for left and right) *)
    min*, max*: LONGINT;  (** the range of a Volume *)
    items*: LONGINT;  (** the number of items of a Choice *)
    writable*, active*: BOOLEAN;
    id: LONGINT  (* ALSA numid, OSS channel *)
  END;

  Mixer* = POINTER TO MixerDesc;
  MixerDesc* = RECORD
    alsa*: BOOLEAN;
    n*: LONGINT;  (** the number of controls *)
    c*: ARRAY MaxControls OF Control;
    path*: ARRAY 64 OF CHAR;
    fd: LONGINT
  END;

VAR
  lastError*: ARRAY 128 OF CHAR;
  mipsIoctl, bigEndian: BOOLEAN;
  nonblock, integerBit, valueOfs, valueSize, listSize: LONGINT;

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  j := 0; WHILE (t[j] # 0X) & (i < LEN(s) - 1) DO s[i] := t[j]; INC(i); INC(j) END;
  s[i] := 0X
END Append;

PROCEDURE AppendInt(VAR s: ARRAY OF CHAR; x: LONGINT);
VAR d: ARRAY 12 OF CHAR; t: ARRAY 2 OF CHAR; i: LONGINT;
BEGIN
  IF x < 0 THEN Append(s, "-"); x := -x END;
  i := 0; REPEAT d[i] := CHR(x MOD 10 + 30H); x := x DIV 10; INC(i) UNTIL x = 0;
  t[1] := 0X; WHILE i > 0 DO DEC(i); t[0] := d[i]; Append(s, t) END
END AppendInt;

(* lastError for the system call error e on path *)
PROCEDURE Error(e: LONGINT; path: ARRAY OF CHAR);
BEGIN
  IF e = -EBUSY THEN COPY("busy: ", lastError)
  ELSIF (e = -ENOENT) OR (e = -ENODEV) THEN COPY("no such device: ", lastError)
  ELSIF e = -EACCES THEN COPY("no permission (group audio?): ", lastError)
  ELSIF e = -ENOTTY THEN COPY("not a sound device: ", lastError)
  ELSIF e = -EINVAL THEN COPY("the device takes none of the formats: ", lastError)
  ELSE COPY("error ", lastError); AppendInt(lastError, -e); Append(lastError, ": ")
  END;
  Append(lastError, path)
END Error;

(* the number of an ioctl; dir 0 none, 1 write, 2 read, 3 both, as the _IOC of the kernel *)
PROCEDURE IOC(dir: LONGINT; type: CHAR; nr, size: LONGINT): LONGINT;
VAR v: LONGINT;
BEGIN
  v := size * 10000H + LONG(ORD(type)) * 100H + nr;
  IF mipsIoctl THEN
    IF dir = 0 THEN INC(v, 20000000H) ELSIF dir = 1 THEN v := v + MIN(LONGINT)
    ELSIF dir = 2 THEN INC(v, 40000000H) ELSE v := v - 40000000H
    END
  ELSE
    IF dir = 1 THEN INC(v, 40000000H) ELSIF dir = 2 THEN v := v + MIN(LONGINT)
    ELSIF dir = 3 THEN v := v - 40000000H
    END
  END;
  RETURN v
END IOC;

PROCEDURE Open0(path: ARRAY OF CHAR; flags: LONGINT): LONGINT;
VAR name: ARRAY 64 OF CHAR;
BEGIN
  COPY(path, name); RETURN Linux0.Openat0(Linux0.ATFDCWD, SYSTEM.ADR(name[0]), flags, 0)
END Open0;

(** Conversion *)

PROCEDURE InitConverter*(VAR c: Converter; srcRate, srcChannels, srcBits, dstRate, dstChannels, dstBits: LONGINT);
BEGIN
  c.srcRate := srcRate; c.srcChannels := srcChannels; c.srcBits := srcBits;
  c.dstRate := dstRate; c.dstChannels := dstChannels; c.dstBits := dstBits;
  c.srcFrame := srcChannels * (srcBits DIV 8); c.dstFrame := dstChannels * (dstBits DIV 8);
  c.maxOut := dstRate DIV srcRate + 2;
  c.frac := 0; c.a0 := 0; c.b0 := 0; c.partLen := 0; c.primed := FALSE
END InitConverter;

PROCEDURE Sample(adr, bits: LONGINT): LONGINT;
VAR lo, hi: CHAR; v, h: LONGINT;
BEGIN
  IF bits = 8 THEN SYSTEM.GET(adr, lo); v := ORD(lo); RETURN (v - 128) * 256
  ELSE
    SYSTEM.GET(adr, lo); SYSTEM.GET(adr + 1, hi); h := ORD(hi); v := h * 256 + ORD(lo);
    IF v >= 32768 THEN DEC(v, 65536) END;
    RETURN v
  END
END Sample;

PROCEDURE PutSample(adr, bits, v: LONGINT);
BEGIN
  IF bits = 8 THEN SYSTEM.PUT(adr, CHR(v DIV 256 + 128))
  ELSE SYSTEM.PUT(adr, CHR(v MOD 256)); SYSTEM.PUT(adr + 1, CHR(v DIV 256 MOD 256))
  END
END PutSample;

PROCEDURE Emit(VAR c: Converter; adr, l, r: LONGINT);
BEGIN
  IF c.dstChannels = 1 THEN PutSample(adr, c.dstBits, (l + r) DIV 2)
  ELSE PutSample(adr, c.dstBits, l); PutSample(adr + c.dstBits DIV 8, c.dstBits, r)
  END
END Emit;

(* converts from in (inLen bytes) to out (room for outLen bytes): used bytes taken, made bytes written;
   an incomplete frame at the end of in is kept for the next call *)
PROCEDURE ConvertAdr(VAR c: Converter; in, inLen, out, outLen: LONGINT; VAR used, made: LONGINT);
VAR fa, l, r, w: LONGINT;
BEGIN
  used := 0; made := 0;
  LOOP
    IF outLen - made < c.maxOut * c.dstFrame THEN EXIT END;
    IF (c.partLen > 0) OR (inLen - used < c.srcFrame) THEN
      WHILE (c.partLen < c.srcFrame) & (used < inLen) DO SYSTEM.GET(in + used, c.part[c.partLen]); INC(c.partLen); INC(used) END;
      IF c.partLen < c.srcFrame THEN EXIT END;
      fa := SYSTEM.ADR(c.part[0]); c.partLen := 0
    ELSE fa := in + used; INC(used, c.srcFrame)
    END;
    l := Sample(fa, c.srcBits);
    IF c.srcChannels = 2 THEN r := Sample(fa + c.srcBits DIV 8, c.srcBits) ELSE r := l END;
    IF c.srcRate = c.dstRate THEN Emit(c, out + made, l, r); INC(made, c.dstFrame)
    ELSIF ~c.primed THEN c.a0 := l; c.b0 := r; c.primed := TRUE
    ELSE
      WHILE c.frac < c.dstRate DO
        w := c.frac * 256 DIV c.dstRate;
        Emit(c, out + made, c.a0 + (l - c.a0) * w DIV 256, c.b0 + (r - c.b0) * w DIV 256);
        INC(made, c.dstFrame); INC(c.frac, c.srcRate)
      END;
      DEC(c.frac, c.dstRate); c.a0 := l; c.b0 := r
    END
  END
END ConvertAdr;

(* the rest of a conversion between different rates: the last frame *)
PROCEDURE FinishAdr(VAR c: Converter; out, outLen: LONGINT; VAR made: LONGINT);
BEGIN
  made := 0;
  IF c.primed & (c.srcRate # c.dstRate) THEN
    WHILE (c.frac < c.dstRate) & (outLen - made >= c.dstFrame) DO
      Emit(c, out + made, c.a0, c.b0); INC(made, c.dstFrame); INC(c.frac, c.srcRate)
    END
  END;
  c.primed := FALSE; c.frac := 0; c.partLen := 0
END FinishAdr;

(** converts data[inPos..inPos+inLen) into out[outPos..outPos+outLen): used bytes taken, made bytes
  written; an incomplete frame at the end is kept for the next call. out takes a frame only when it
  has room for all that one input frame gives (dstRate DIV srcRate + 2 frames). *)
PROCEDURE Convert*(VAR c: Converter; VAR in: ARRAY OF SYSTEM.BYTE; inPos, inLen: LONGINT;
  VAR out: ARRAY OF SYSTEM.BYTE; outPos, outLen: LONGINT; VAR used, made: LONGINT);
BEGIN
  ASSERT((inPos >= 0) & (inLen >= 0) & (inPos + inLen <= LEN(in)));
  ASSERT((outPos >= 0) & (outLen >= 0) & (outPos + outLen <= LEN(out)));
  ConvertAdr(c, SYSTEM.ADR(in[0]) + inPos, inLen, SYSTEM.ADR(out[0]) + outPos, outLen, used, made)
END Convert;

(** the end of a conversion between different rates: the last frame given (made bytes) *)
PROCEDURE Finish*(VAR c: Converter; VAR out: ARRAY OF SYSTEM.BYTE; outPos, outLen: LONGINT; VAR made: LONGINT);
BEGIN
  ASSERT((outPos >= 0) & (outLen >= 0) & (outPos + outLen <= LEN(out)));
  FinishAdr(c, SYSTEM.ADR(out[0]) + outPos, outLen, made)
END Finish;

(* ALSA hardware parameters *)

PROCEDURE InitParams(VAR p: Params);
VAR i: LONGINT;
BEGIN
  i := 0; WHILE i < ParamWords DO p[i] := 0; INC(i) END;
  i := 1; WHILE i < 25 DO p[i] := -1; INC(i) END;
  i := 0; WHILE i < 12 DO p[Ivl + i * 3 + 1] := -1; INC(i) END;
  p[128] := -1; p[PInfo] := -1
END InitParams;

PROCEDURE SetMask(VAR p: Params; m, bit: LONGINT);
VAR i: LONGINT;
BEGIN
  i := 0; WHILE i < 8 DO p[1 + m * 8 + i] := 0; INC(i) END;
  p[1 + m * 8 + bit DIV 32] := SYSTEM.VAL(LONGINT, {bit MOD 32})
END SetMask;

PROCEDURE SetExact(VAR p: Params; i, v: LONGINT);
BEGIN p[Ivl + i * 3] := v; p[Ivl + i * 3 + 1] := v; p[Ivl + i * 3 + 2] := integerBit
END SetExact;

PROCEDURE Refine(fd: LONGINT; VAR p: Params): LONGINT;
BEGIN
  p[128] := -1;  (* rmask: all parameters; the kernel clears it *)
  RETURN Linux0.IOCtl0(fd, IOC(3, "A", 10H, ParamSize), SYSTEM.ADR(p[0]))
END Refine;

(* the first of the values in try (n of them) the device takes for interval i, else 0 *)
PROCEDURE Choose(fd: LONGINT; VAR p: Params; i: LONGINT; VAR try: ARRAY OF LONGINT; n: LONGINT): LONGINT;
VAR q: Params; k: LONGINT;
BEGIN
  k := 0;
  WHILE k < n DO
    IF try[k] > 0 THEN
      q := p; SetExact(q, i, try[k]);
      IF Refine(fd, q) >= 0 THEN p := q; RETURN try[k] END
    END;
    INC(k)
  END;
  RETURN 0
END Choose;

PROCEDURE Close0(d: Device);
VAR r: LONGINT;
BEGIN
  IF d.fd >= 0 THEN r := Linux0.Close0(d.fd); d.fd := -1 END
END Close0;

PROCEDURE OpenALSA(d: Device; path: ARRAY OF CHAR): LONGINT;
VAR p, q: Params; r: LONGINT; try: ARRAY 4 OF LONGINT;
BEGIN
  d.alsa := TRUE; COPY(path, d.path);
  d.fd := Open0(path, Linux0.ORDWR + nonblock);
  IF d.fd < 0 THEN RETURN d.fd END;
  InitParams(p); SetMask(p, 0, 3); SetMask(p, 1, 2); SetMask(p, 2, 0);  (* interleaved, S16_LE, standard *)
  r := Refine(d.fd, p);
  IF r < 0 THEN Close0(d); RETURN r END;
  try[0] := d.channels; try[1] := 2; try[2] := 1; try[3] := p[Ivl + IChannels * 3];
  d.hwChannels := Choose(d.fd, p, IChannels, try, 4);
  try[0] := d.rate; try[1] := 48000; try[2] := 44100; try[3] := p[Ivl + IRate * 3];
  d.hwRate := Choose(d.fd, p, IRate, try, 4);
  IF (d.hwChannels < 1) OR (d.hwChannels > 2) OR (d.hwRate = 0) THEN Close0(d); RETURN -EINVAL END;
  q := p; q[Ivl + IPeriodTime * 3] := 10000; q[Ivl + IBufferTime * 3 + 1] := 250000;  (* 10 ms periods, at most 250 ms *)
  IF Refine(d.fd, q) >= 0 THEN p := q END;
  r := Linux0.IOCtl0(d.fd, IOC(3, "A", 11H, ParamSize), SYSTEM.ADR(p[0]));
  IF r < 0 THEN Close0(d); RETURN r END;
  d.hwChannels := p[Ivl + IChannels * 3]; d.hwRate := p[Ivl + IRate * 3];
  d.bufferFrames := p[Ivl + IBufferSize * 3];
  d.canPause := 19 IN SYSTEM.VAL(SET, p[PInfo]);
  r := Linux0.IOCtl0(d.fd, IOC(0, "A", 40H, 0), 0);  (* PREPARE *)
  IF r < 0 THEN Close0(d); RETURN r END;
  RETURN 0
END OpenALSA;

PROCEDURE OSSInt(fd, nr, v: LONGINT; VAR res: LONGINT): LONGINT;
BEGIN
  res := Linux0.IOCtl0(fd, IOC(3, "P", nr, 4), SYSTEM.ADR(v)); RETURN v
END OSSInt;

PROCEDURE OpenOSS(d: Device; path: ARRAY OF CHAR): LONGINT;
VAR r, v, flags: LONGINT; info: ARRAY 4 OF LONGINT;
BEGIN
  d.alsa := FALSE; d.canPause := FALSE; COPY(path, d.path);
  IF d.capture THEN flags := Linux0.ORDonly ELSE flags := Linux0.OWRonly END;
  d.fd := Open0(path, flags + nonblock);
  IF d.fd < 0 THEN RETURN d.fd END;
  v := OSSInt(d.fd, 10, 0008000CH, r);  (* 8 fragments of 4 KB *)
  v := OSSInt(d.fd, 5, 10H, r);  (* AFMT_S16_LE *)
  IF (r < 0) OR (v # 10H) THEN Close0(d); IF r < 0 THEN RETURN r ELSE RETURN -EINVAL END END;
  d.hwChannels := OSSInt(d.fd, 6, d.channels, r);
  IF (r < 0) OR (d.hwChannels < 1) OR (d.hwChannels > 2) THEN Close0(d); IF r < 0 THEN RETURN r ELSE RETURN -EINVAL END END;
  d.hwRate := OSSInt(d.fd, 2, d.rate, r);
  IF (r < 0) OR (d.hwRate <= 0) THEN Close0(d); IF r < 0 THEN RETURN r ELSE RETURN -EINVAL END END;
  IF d.capture THEN v := 13 ELSE v := 12 END;  (* GETISPACE, GETOSPACE: fragments, fragstotal, fragsize, bytes *)
  r := Linux0.IOCtl0(d.fd, IOC(2, "P", v, 16), SYSTEM.ADR(info[0]));
  IF r >= 0 THEN d.bufferFrames := info[1] * info[2] DIV (d.hwChannels * 2) ELSE d.bufferFrames := 0 END;
  RETURN 0
END OpenOSS;

(* path for the name of a device: "hw:c,d" (an ALSA card c and device d), "oss", or a path *)
PROCEDURE PathOf(name: ARRAY OF CHAR; capture: BOOLEAN; VAR path: ARRAY OF CHAR; VAR alsa: BOOLEAN);
VAR i, card, dev: LONGINT;
BEGIN
  IF name = "oss" THEN COPY("/dev/dsp", path); alsa := FALSE
  ELSIF (name[0] = "h") & (name[1] = "w") & (name[2] = ":") THEN
    i := 3; card := 0; WHILE (name[i] >= "0") & (name[i] <= "9") DO card := card * 10 + ORD(name[i]) - 30H; INC(i) END;
    dev := 0;
    IF name[i] = "," THEN INC(i); WHILE (name[i] >= "0") & (name[i] <= "9") DO dev := dev * 10 + ORD(name[i]) - 30H; INC(i) END END;
    COPY("/dev/snd/pcmC", path); AppendInt(path, card); Append(path, "D"); AppendInt(path, dev);
    IF capture THEN Append(path, "c") ELSE Append(path, "p") END;
    alsa := TRUE
  ELSE
    COPY(name, path); alsa := FALSE;
    i := 0; WHILE (path[i] # 0X) & ~((path[i] = "p") & (path[i + 1] = "c") & (path[i + 2] = "m")) DO INC(i) END;
    alsa := path[i] # 0X
  END
END PathOf;

(** opens a device for playback or capture (capture) of data with rate, channels (1, 2) and bits (8, 16);
  name "" is ALSA hw:0,0, else OSS /dev/dsp; else "hw:c,d", "oss" or the path of a device. FALSE: lastError
  says why. *)
PROCEDURE Open*(name: ARRAY OF CHAR; capture: BOOLEAN; rate, channels, bits: LONGINT; VAR d: Device): BOOLEAN;
VAR path: ARRAY 64 OF CHAR; alsa: BOOLEAN; r: LONGINT;
BEGIN
  d := NIL; lastError := "";
  IF (rate < 1000) OR (rate > 384000) OR (channels < 1) OR (channels > 2) OR (bits # 8) & (bits # 16) THEN
    lastError := "rate from 1000 to 384000, 1 or 2 channels, 8 or 16 bits"; RETURN FALSE
  END;
  NEW(d); d.capture := capture; d.rate := rate; d.channels := channels; d.bits := bits; d.fd := -1;
  d.started := FALSE; d.drained := TRUE;
  d.paused := FALSE; d.frames := 0; d.given := 0; d.res := 0; d.bufPos := 0; d.bufLen := 0;
  IF name = "" THEN
    PathOf("hw:0,0", capture, path, alsa); r := OpenALSA(d, path);
    IF r < 0 THEN
      IF r # -EBUSY THEN r := OpenOSS(d, "/dev/dsp") END;
      IF r < 0 THEN COPY("/dev/dsp", path) END
    END
  ELSE
    PathOf(name, capture, path, alsa);
    IF alsa THEN r := OpenALSA(d, path) ELSE r := OpenOSS(d, path) END
  END;
  IF r < 0 THEN Error(r, path); d := NIL; RETURN FALSE END;
  d.hwFrame := d.hwChannels * 2;
  IF capture THEN InitConverter(d.conv, d.hwRate, d.hwChannels, 16, rate, channels, bits)
  ELSE InitConverter(d.conv, rate, channels, bits, d.hwRate, d.hwChannels, 16)
  END;
  RETURN TRUE
END Open;

(* ALSA writei (nr 50H) or readi (51H): frames moved or -errno *)
PROCEDURE Xfer(d: Device; nr, adr, frames: LONGINT): LONGINT;
VAR x: ARRAY 3 OF LONGINT; r, dir: LONGINT;
BEGIN
  x[0] := 0; x[1] := adr; x[2] := frames;
  IF nr = 50H THEN dir := 1 ELSE dir := 2 END;
  r := Linux0.IOCtl0(d.fd, IOC(dir, "A", nr, 12), SYSTEM.ADR(x[0]));
  IF r = 0 THEN RETURN x[0] ELSE RETURN r END
END Xfer;

PROCEDURE Prepare(d: Device);
VAR r: LONGINT;
BEGIN
  IF d.alsa THEN r := Linux0.IOCtl0(d.fd, IOC(0, "A", 40H, 0), 0); d.started := FALSE END
END Prepare;

(* writes d.buf to the device; TRUE when it is empty; waits for room if wait *)
PROCEDURE Flush(d: Device; wait: BOOLEAN): BOOLEAN;
VAR r: LONGINT;
BEGIN
  WHILE d.bufPos < d.bufLen DO
    IF d.alsa THEN
      r := Xfer(d, 50H, SYSTEM.ADR(d.buf[d.bufPos]), (d.bufLen - d.bufPos) DIV d.hwFrame);
      IF r > 0 THEN INC(d.bufPos, r * d.hwFrame) END
    ELSE
      r := Linux0.Write0(d.fd, SYSTEM.ADR(d.buf[d.bufPos]), d.bufLen - d.bufPos);
      IF r > 0 THEN INC(d.bufPos, r) END
    END;
    IF (r = 0) OR (r = -EAGAIN) THEN
      IF d.alsa & ~d.started THEN r := Linux0.IOCtl0(d.fd, IOC(0, "A", 42H, 0), 0); d.started := TRUE END;  (* START, if it waits for more *)
      IF ~wait THEN RETURN FALSE END;
      r := Linux0.Poll0(d.fd, TRUE, 100)
    ELSIF r = -EPIPE THEN Prepare(d)  (* underrun: the device waited for data *)
    ELSIF (r < 0) & (r # -EINTR) THEN d.res := r; Error(r, d.path); RETURN FALSE
    END
  END;
  d.bufPos := 0; d.bufLen := 0;
  RETURN TRUE
END Flush;

PROCEDURE Put(d: Device; adr, len: LONGINT; wait: BOOLEAN): LONGINT;
VAR taken, used, made: LONGINT;
BEGIN
  d.res := 0; taken := 0;
  ASSERT(~d.capture);
  LOOP
    IF ~Flush(d, wait) OR (taken >= len) THEN EXIT END;
    ConvertAdr(d.conv, adr + taken, len - taken, SYSTEM.ADR(d.buf[0]), BufSize, used, made);
    d.bufPos := 0; d.bufLen := made; INC(taken, used);
    IF used > 0 THEN d.drained := FALSE END;
    IF (used = 0) & (made = 0) THEN EXIT END
  END;
  IF wait & (d.res = 0) & Flush(d, TRUE) THEN END;
  INC(d.given, taken); d.frames := d.given DIV d.conv.srcFrame;
  RETURN taken
END Put;

(** plays data[pos..pos+len); returns when the device has taken it all. FALSE: lastError says why. *)
PROCEDURE Write*(d: Device; VAR data: ARRAY OF SYSTEM.BYTE; pos, len: LONGINT): BOOLEAN;
BEGIN
  ASSERT((pos >= 0) & (len >= 0) & (pos + len <= LEN(data)));
  RETURN (Put(d, SYSTEM.ADR(data[0]) + pos, len, TRUE) = len) & (d.res = 0)
END Write;

(** gives the device as much of data[pos..pos+len) as it takes without waiting: the number of bytes
  taken, -1 on an error; with len 0 it only passes on what it holds from before *)
PROCEDURE WriteSome*(d: Device; VAR data: ARRAY OF SYSTEM.BYTE; pos, len: LONGINT): LONGINT;
VAR n: LONGINT;
BEGIN
  ASSERT((pos >= 0) & (len >= 0) & (pos + len <= LEN(data)));
  n := Put(d, SYSTEM.ADR(data[0]) + pos, len, FALSE);
  IF d.res # 0 THEN RETURN -1 END;
  RETURN n
END WriteSome;

(** frames given that the device has not played yet (playback), or holds for reading (capture), in
  the device's rate *)
PROCEDURE Delay*(d: Device): LONGINT;
VAR v, r: LONGINT; info: ARRAY 4 OF LONGINT;
BEGIN
  v := 0;
  IF ~d.capture & d.drained THEN RETURN 0 END;
  IF d.alsa THEN
    r := Linux0.IOCtl0(d.fd, IOC(2, "A", 21H, 4), SYSTEM.ADR(v));
    IF (r < 0) OR (v < 0) THEN v := 0 END
  ELSIF ~d.capture THEN
    r := Linux0.IOCtl0(d.fd, IOC(2, "P", 23, 4), SYSTEM.ADR(v));  (* GETODELAY, in bytes *)
    IF r < 0 THEN  (* GETOSPACE: the buffer less its free bytes *)
      r := Linux0.IOCtl0(d.fd, IOC(2, "P", 12, 16), SYSTEM.ADR(info[0])); v := info[1] * info[2] - info[3]
    END;
    IF (r < 0) OR (v < 0) THEN v := 0 ELSE v := v DIV d.hwFrame END
  END;
  IF ~d.capture THEN INC(v, (d.bufLen - d.bufPos) DIV d.hwFrame) END;
  RETURN v
END Delay;

(** the frames played so far, in the caller's rate *)
PROCEDURE Played*(d: Device): LONGINT;
VAR n: LONGINT;
BEGIN
  n := d.frames - ENTIER(Delay(d) * (d.rate / d.hwRate));
  IF n < 0 THEN n := 0 END;
  RETURN n
END Played;

(** waits until the device has played all that it was given *)
PROCEDURE Drain*(d: Device);
VAR made, r: LONGINT;
BEGIN
  IF d.capture OR (d.fd < 0) THEN RETURN END;
  IF Flush(d, TRUE) THEN
    FinishAdr(d.conv, SYSTEM.ADR(d.buf[0]), BufSize, made); d.bufPos := 0; d.bufLen := made;
    IF Flush(d, TRUE) THEN
      r := Linux0.SetBlocking0(d.fd, TRUE);
      IF d.alsa THEN r := Linux0.IOCtl0(d.fd, IOC(0, "A", 44H, 0), 0); Prepare(d)
      ELSE r := Linux0.IOCtl0(d.fd, IOC(0, "P", 1, 0), 0)  (* SYNC *)
      END;
      r := Linux0.SetBlocking0(d.fd, FALSE);
      d.drained := TRUE
    END
  END
END Drain;

(** stops at once: what the device holds is dropped *)
PROCEDURE Drop*(d: Device);
VAR r, made: LONGINT;
BEGIN
  IF d.fd < 0 THEN RETURN END;
  IF d.alsa THEN r := Linux0.IOCtl0(d.fd, IOC(0, "A", 43H, 0), 0); Prepare(d)
  ELSE r := Linux0.IOCtl0(d.fd, IOC(0, "P", 0, 0), 0)  (* RESET *)
  END;
  d.bufPos := 0; d.bufLen := 0; FinishAdr(d.conv, 0, 0, made); d.paused := FALSE; d.drained := TRUE
END Drop;

(** pauses (on) or resumes the device; without canPause the caller just stops giving data *)
PROCEDURE Pause*(d: Device; on: BOOLEAN);
VAR r, v: LONGINT;
BEGIN
  IF d.canPause & (d.fd >= 0) THEN
    IF on THEN v := 1 ELSE v := 0 END;
    r := Linux0.IOCtl0(d.fd, IOC(1, "A", 45H, 4), v);
    IF r < 0 THEN d.canPause := FALSE END
  END;
  d.paused := on
END Pause;

PROCEDURE Get(d: Device; adr, len: LONGINT; wait: BOOLEAN): LONGINT;
VAR got, used, made, r: LONGINT;
BEGIN
  d.res := 0; got := 0;
  ASSERT(d.capture);
  LOOP
    IF len - got < d.conv.maxOut * d.conv.dstFrame THEN EXIT END;
    IF d.bufPos < d.bufLen THEN
      ConvertAdr(d.conv, SYSTEM.ADR(d.buf[d.bufPos]), d.bufLen - d.bufPos, adr + got, len - got, used, made);
      INC(d.bufPos, used); INC(got, made);
      IF (used = 0) & (made = 0) THEN EXIT END
    ELSE
      d.bufPos := 0; d.bufLen := 0;
      IF d.alsa THEN r := Xfer(d, 51H, SYSTEM.ADR(d.buf[0]), BufSize DIV d.hwFrame); IF r > 0 THEN d.bufLen := r * d.hwFrame END
      ELSE r := Linux0.Read0(d.fd, SYSTEM.ADR(d.buf[0]), BufSize); IF r > 0 THEN d.bufLen := r END
      END;
      IF (r = 0) OR (r = -EAGAIN) THEN
        IF ~wait OR (got > 0) THEN EXIT END;
        r := Linux0.Poll0(d.fd, FALSE, 100)
      ELSIF r = -EPIPE THEN Prepare(d)  (* overrun: data was lost *)
      ELSIF (r < 0) & (r # -EINTR) THEN d.res := r; Error(r, d.path); EXIT
      END
    END
  END;
  INC(d.given, got); d.frames := d.given DIV d.conv.dstFrame;
  RETURN got
END Get;

(** records into data[pos..pos+len): waits until there is data, then returns the bytes read (whole
  frames; len must hold a few of them); -1 on an error *)
PROCEDURE Read*(d: Device; VAR data: ARRAY OF SYSTEM.BYTE; pos, len: LONGINT): LONGINT;
VAR n: LONGINT;
BEGIN
  ASSERT((pos >= 0) & (len >= 0) & (pos + len <= LEN(data)));
  n := Get(d, SYSTEM.ADR(data[0]) + pos, len, TRUE);
  IF d.res # 0 THEN RETURN -1 END;
  RETURN n
END Read;

(** as Read, without waiting: 0 when there is nothing yet *)
PROCEDURE ReadSome*(d: Device; VAR data: ARRAY OF SYSTEM.BYTE; pos, len: LONGINT): LONGINT;
VAR n: LONGINT;
BEGIN
  ASSERT((pos >= 0) & (len >= 0) & (pos + len <= LEN(data)));
  n := Get(d, SYSTEM.ADR(data[0]) + pos, len, FALSE);
  IF d.res # 0 THEN RETURN -1 END;
  RETURN n
END ReadSome;

(** closes the device; what it has not played yet is dropped (Drain first to hear it) *)
PROCEDURE Close*(d: Device);
BEGIN
  IF d # NIL THEN Close0(d) END
END Close;

(** Mixer *)

PROCEDURE CtlInfo(m: Mixer; VAR info: ARRAY OF LONGINT): LONGINT;
BEGIN RETURN Linux0.IOCtl0(m.fd, IOC(3, "U", 11H, 272), SYSTEM.ADR(info[0]))
END CtlInfo;

PROCEDURE OpenALSAMixer(m: Mixer; card: LONGINT): LONGINT;
VAR list: ARRAY 18 OF LONGINT; ids: ARRAY MaxControls * 16 OF LONGINT; info: ARRAY 68 OF LONGINT;
  r, i, k, n: LONGINT; s: SET; ch: CHAR;
BEGIN
  m.alsa := TRUE; COPY("/dev/snd/controlC", m.path); AppendInt(m.path, card);
  m.fd := Open0(m.path, Linux0.ORDWR);
  IF m.fd < 0 THEN RETURN m.fd END;
  i := 0; WHILE i < 18 DO list[i] := 0; INC(i) END;
  r := Linux0.IOCtl0(m.fd, IOC(3, "U", 10H, listSize), SYSTEM.ADR(list[0]));
  IF r < 0 THEN RETURN r END;
  n := list[3]; IF n > MaxControls THEN n := MaxControls END;
  list[0] := 0; list[1] := n; list[4] := SYSTEM.ADR(ids[0]);
  r := Linux0.IOCtl0(m.fd, IOC(3, "U", 10H, listSize), SYSTEM.ADR(list[0]));
  IF r < 0 THEN RETURN r END;
  n := list[2]; m.n := 0; i := 0;
  WHILE i < n DO
    IF ids[i * 16 + 1] = 2 THEN  (* SNDRV_CTL_ELEM_IFACE_MIXER *)
      k := 0; WHILE k < 68 DO info[k] := 0; INC(k) END;
      k := 0; WHILE k < 16 DO info[k] := ids[i * 16 + k]; INC(k) END;
      IF CtlInfo(m, info) >= 0 THEN
        s := SYSTEM.VAL(SET, info[17]);
        IF (0 IN s) & (info[16] >= 1) & (info[16] <= 3) THEN
          k := 0;
          REPEAT SYSTEM.GET(SYSTEM.ADR(ids[i * 16 + 4]) + k, ch); m.c[m.n].name[k] := ch; INC(k) UNTIL (ch = 0X) OR (k = 44);
          m.c[m.n].name[k] := 0X;
          IF info[16] = 1 THEN m.c[m.n].kind := Switch; m.c[m.n].min := 0; m.c[m.n].max := 1
          ELSIF info[16] = 2 THEN m.c[m.n].kind := Volume; m.c[m.n].min := info[20]; m.c[m.n].max := info[21]
          ELSE m.c[m.n].kind := Choice; m.c[m.n].items := info[20]; m.c[m.n].min := 0; m.c[m.n].max := info[20] - 1
          END;
          m.c[m.n].count := info[18]; m.c[m.n].writable := 1 IN s; m.c[m.n].active := ~(8 IN s);
          m.c[m.n].id := ids[i * 16];
          INC(m.n)
        END
      END
    END;
    INC(i)
  END;
  RETURN 0
END OpenALSAMixer;

PROCEDURE OpenOSSMixer(m: Mixer; path: ARRAY OF CHAR): LONGINT;
VAR r, devs, stereo, ch, i, k: LONGINT; names: ARRAY 160 OF CHAR;
BEGIN
  m.alsa := FALSE; COPY(path, m.path);
  m.fd := Open0(path, Linux0.ORDWR);
  IF m.fd < 0 THEN RETURN m.fd END;
  r := Linux0.IOCtl0(m.fd, IOC(2, "M", 0FEH, 4), SYSTEM.ADR(devs));
  IF r < 0 THEN RETURN r END;
  r := Linux0.IOCtl0(m.fd, IOC(2, "M", 0FBH, 4), SYSTEM.ADR(stereo));
  IF r < 0 THEN stereo := 0 END;
  names := OSSNames; m.n := 0; ch := 0; i := 0;
  WHILE ch < 25 DO
    IF ch IN SYSTEM.VAL(SET, devs) THEN
      k := 0; WHILE (names[i + k] # " ") & (names[i + k] # 0X) DO m.c[m.n].name[k] := names[i + k]; INC(k) END;
      m.c[m.n].name[k] := 0X;
      m.c[m.n].kind := Volume; m.c[m.n].min := 0; m.c[m.n].max := 100; m.c[m.n].items := 0;
      IF ch IN SYSTEM.VAL(SET, stereo) THEN m.c[m.n].count := 2 ELSE m.c[m.n].count := 1 END;
      m.c[m.n].writable := TRUE; m.c[m.n].active := TRUE; m.c[m.n].id := ch;
      INC(m.n)
    END;
    WHILE (names[i] # " ") & (names[i] # 0X) DO INC(i) END;
    IF names[i] = " " THEN INC(i) END;
    INC(ch)
  END;
  RETURN 0
END OpenOSSMixer;

(** opens the mixer of a card: name "" is the controls of ALSA card 0, else /dev/mixer; else "hw:c",
  "oss" or the path of a device *)
PROCEDURE OpenMixer*(name: ARRAY OF CHAR; VAR m: Mixer): BOOLEAN;
VAR r, i, card: LONGINT;
BEGIN
  lastError := ""; NEW(m); m.fd := -1; m.n := 0;
  IF (name = "") OR (name[0] = "h") & (name[1] = "w") & (name[2] = ":") THEN
    card := 0; i := 3;
    IF name # "" THEN WHILE (name[i] >= "0") & (name[i] <= "9") DO card := card * 10 + ORD(name[i]) - 30H; INC(i) END END;
    r := OpenALSAMixer(m, card);
    IF (r < 0) & (name = "") THEN
      IF m.fd >= 0 THEN i := Linux0.Close0(m.fd) END;
      r := OpenOSSMixer(m, "/dev/mixer")
    END
  ELSIF name = "oss" THEN r := OpenOSSMixer(m, "/dev/mixer")
  ELSE
    i := 0; WHILE (name[i] # 0X) & ~((name[i] = "C") & (name[i + 1] >= "0") & (name[i + 1] <= "9")) DO INC(i) END;
    IF name[i] # 0X THEN
      card := 0; INC(i); WHILE (name[i] >= "0") & (name[i] <= "9") DO card := card * 10 + ORD(name[i]) - 30H; INC(i) END;
      r := OpenALSAMixer(m, card)
    ELSE r := OpenOSSMixer(m, name)
    END
  END;
  IF r < 0 THEN
    Error(r, m.path); IF m.fd >= 0 THEN i := Linux0.Close0(m.fd) END; m := NIL; RETURN FALSE
  END;
  RETURN TRUE
END OpenMixer;

(** the index of the control named name, -1 if there is none *)
PROCEDURE This*(m: Mixer; name: ARRAY OF CHAR): LONGINT;
VAR i: LONGINT;
BEGIN
  i := 0; WHILE (i < m.n) & (m.c[i].name # name) DO INC(i) END;
  IF i = m.n THEN i := -1 END;
  RETURN i
END This;

PROCEDURE ReadValues(m: Mixer; i: LONGINT; VAR v: ARRAY OF LONGINT): BOOLEAN;
VAR k, r: LONGINT;
BEGIN
  k := 0; WHILE k < LEN(v) DO v[k] := 0; INC(k) END;
  v[0] := m.c[i].id;
  r := Linux0.IOCtl0(m.fd, IOC(3, "U", 12H, valueSize), SYSTEM.ADR(v[0]));
  IF r < 0 THEN Error(r, m.path); RETURN FALSE END;
  RETURN TRUE
END ReadValues;

(** value k of control i (0 left, 1 right); MIN(LONGINT) on an error *)
PROCEDURE GetValue*(m: Mixer; i, k: LONGINT): LONGINT;
VAR v: ARRAY 178 OF LONGINT; x, r: LONGINT;
BEGIN
  IF (i < 0) OR (i >= m.n) OR (k < 0) OR (k >= m.c[i].count) THEN RETURN MIN(LONGINT) END;
  IF m.alsa THEN
    IF ~ReadValues(m, i, v) THEN RETURN MIN(LONGINT) END;
    RETURN v[valueOfs + k]
  ELSE
    r := Linux0.IOCtl0(m.fd, IOC(2, "M", m.c[i].id, 4), SYSTEM.ADR(x));
    IF r < 0 THEN Error(r, m.path); RETURN MIN(LONGINT) END;
    IF k = 0 THEN RETURN x MOD 256 ELSE RETURN x DIV 256 MOD 256 END
  END
END GetValue;

(** sets value k of control i to x; k = -1: all its values *)
PROCEDURE SetValue*(m: Mixer; i, k, x: LONGINT): BOOLEAN;
VAR v: ARRAY 178 OF LONGINT; j, y, r: LONGINT;
BEGIN
  lastError := "";
  IF (i < 0) OR (i >= m.n) OR (k >= m.c[i].count) OR ~m.c[i].writable THEN lastError := "no such value"; RETURN FALSE END;
  IF x < m.c[i].min THEN x := m.c[i].min ELSIF x > m.c[i].max THEN x := m.c[i].max END;
  IF m.alsa THEN
    IF ~ReadValues(m, i, v) THEN RETURN FALSE END;
    j := 0;
    WHILE j < m.c[i].count DO IF (k < 0) OR (k = j) THEN v[valueOfs + j] := x END; INC(j) END;
    r := Linux0.IOCtl0(m.fd, IOC(3, "U", 13H, valueSize), SYSTEM.ADR(v[0]))
  ELSE
    r := Linux0.IOCtl0(m.fd, IOC(2, "M", m.c[i].id, 4), SYSTEM.ADR(y));
    IF r >= 0 THEN
      IF k <= 0 THEN y := y DIV 256 * 256 + x END;
      IF (k < 0) OR (k = 1) THEN y := y MOD 256 + x * 256 END;
      r := Linux0.IOCtl0(m.fd, IOC(3, "M", m.c[i].id, 4), SYSTEM.ADR(y))
    END
  END;
  IF r < 0 THEN Error(r, m.path); RETURN FALSE END;
  RETURN TRUE
END SetValue;

(** the name of item of the Choice control i *)
PROCEDURE ItemName*(m: Mixer; i, item: LONGINT; VAR name: ARRAY OF CHAR);
VAR info: ARRAY 68 OF LONGINT; k: LONGINT; ch: CHAR;
BEGIN
  name[0] := 0X;
  IF m.alsa & (i >= 0) & (i < m.n) & (m.c[i].kind = Choice) & (item >= 0) & (item < m.c[i].items) THEN
    k := 0; WHILE k < 68 DO info[k] := 0; INC(k) END;
    info[0] := m.c[i].id; info[21] := item;
    IF CtlInfo(m, info) >= 0 THEN
      k := 0;
      LOOP
        SYSTEM.GET(SYSTEM.ADR(info[22]) + k, ch);
        IF (ch = 0X) OR (k = 63) OR (k = LEN(name) - 1) THEN EXIT END;
        name[k] := ch; INC(k)
      END;
      name[k] := 0X
    END
  END
END ItemName;

PROCEDURE CloseMixer*(m: Mixer);
VAR r: LONGINT;
BEGIN
  IF (m # NIL) & (m.fd >= 0) THEN r := Linux0.Close0(m.fd); m.fd := -1 END
END CloseMixer;

PROCEDURE Init;
VAR x: LONGINT; c: CHAR;
BEGIN
  x := 1; SYSTEM.GET(SYSTEM.ADR(x), c); bigEndian := c = 0X;
  mipsIoctl := (Linux0.ARCH = "MIPS") OR (Linux0.ARCH = "MIPSBE") OR (Linux0.ARCH = "PPC");
  IF (Linux0.ARCH = "MIPS") OR (Linux0.ARCH = "MIPSBE") THEN nonblock := 80H ELSE nonblock := 800H END;
  IF bigEndian THEN integerBit := 20000000H ELSE integerBit := 4 END;
  (* struct snd_ctl_elem_value: its union is 4-aligned on i386 and m68k (long long), else 8 *)
  IF (Linux0.ARCH = "X86") OR (Linux0.ARCH = "M68K") THEN valueOfs := 17; valueSize := 708
  ELSE valueOfs := 18; valueSize := 712
  END;
  IF Linux0.ARCH = "M68K" THEN listSize := 70 ELSE listSize := 72 END;
  lastError := ""
END Init;

BEGIN
  Init
END Sound0.
