MODULE Wave0;  (** WAV files: the format of their samples, reading them as 8 or 16 bits, writing *)

(* A WAV file (RIFF WAVE) has a "fmt " chunk and a "data" chunk among others. Samples of 8 (unsigned),
   16, 24 and 32 bits (signed, little-endian) and of 32-bit floating point are read; 24 and 32 bits and
   floating point come out as 16 bits. Written files have 8 or 16 bits. *)

IMPORT SYSTEM, Files;

CONST
  HeaderSize* = 44;  (** the size of the header WriteHeader writes *)
  BufSize = 4096;

TYPE
  Format* = RECORD
    rate*, channels*, bits*: LONGINT;  (** bits of a sample in the file *)
    float*: BOOLEAN;  (** samples in floating point (32 bits) *)
    dataPos*, dataLen*: LONGINT;  (** the samples in the file, in bytes *)
    frames*: LONGINT  (** the number of frames *)
  END;

  Reader* = RECORD
    outBits*: LONGINT;  (** the bits of the samples Read gives: 8 or 16 *)
    fmt: Format;
    r: Files.Rider;
    left, inFrame, outFrame: LONGINT;
    buf: ARRAY BufSize OF CHAR
  END;

VAR
  lastError*: ARRAY 128 OF CHAR;

PROCEDURE Tag(VAR r: Files.Rider; VAR s: ARRAY OF CHAR);
VAR i: LONGINT;
BEGIN
  i := 0; WHILE i < 4 DO Files.Read(r, s[i]); INC(i) END;
  s[4] := 0X
END Tag;

PROCEDURE Int16(VAR r: Files.Rider): LONGINT;
VAR a, b: CHAR; h: LONGINT;
BEGIN
  Files.Read(r, a); Files.Read(r, b); h := ORD(b); RETURN h * 256 + ORD(a)
END Int16;

(** the format of the WAV file f; FALSE: lastError says why *)
PROCEDURE ReadFormat*(f: Files.File; VAR fmt: Format): BOOLEAN;
VAR r: Files.Rider; tag: ARRAY 8 OF CHAR; len, size, pos, kind, align, sub: LONGINT; haveFmt: BOOLEAN;
BEGIN
  lastError := ""; fmt.rate := 0; fmt.channels := 0; fmt.bits := 0; fmt.float := FALSE;
  fmt.dataPos := 0; fmt.dataLen := 0; fmt.frames := 0;
  size := Files.Length(f); Files.Set(r, f, 0);
  Tag(r, tag); Files.ReadLInt(r, len); Files.ReadBytes(r, tag, 4); tag[4] := 0X;
  IF tag # "WAVE" THEN lastError := "not a WAV file"; RETURN FALSE END;
  Files.Set(r, f, 0); Tag(r, tag);
  IF tag # "RIFF" THEN lastError := "not a WAV file"; RETURN FALSE END;
  pos := 12; haveFmt := FALSE;
  LOOP
    IF pos + 8 > size THEN EXIT END;
    Files.Set(r, f, pos); Tag(r, tag); Files.ReadLInt(r, len);
    IF len < 0 THEN EXIT END;
    IF tag = "fmt " THEN
      kind := Int16(r); fmt.channels := Int16(r); Files.ReadLInt(r, fmt.rate);
      Files.ReadLInt(r, sub); align := Int16(r); fmt.bits := Int16(r);
      IF (kind = 0FFFEH) & (len >= 40) THEN  (* WAVE_FORMAT_EXTENSIBLE: the kind is in its subformat *)
        sub := Int16(r); sub := Int16(r); Files.ReadLInt(r, sub); kind := Int16(r)
      END;
      IF kind = 3 THEN fmt.float := TRUE
      ELSIF kind # 1 THEN lastError := "not PCM data (compressed)"; RETURN FALSE
      END;
      haveFmt := TRUE
    ELSIF tag = "data" THEN
      fmt.dataPos := pos + 8; fmt.dataLen := len;
      IF fmt.dataPos + len > size THEN fmt.dataLen := size - fmt.dataPos END;
      EXIT
    END;
    pos := pos + 8 + len + len MOD 2
  END;
  IF ~haveFmt OR (fmt.dataPos = 0) THEN lastError := "no format or no data"; RETURN FALSE END;
  IF (fmt.channels < 1) OR (fmt.channels > 2) THEN lastError := "only mono and stereo"; RETURN FALSE END;
  IF fmt.float & (fmt.bits # 32) OR ~fmt.float & (fmt.bits # 8) & (fmt.bits # 16) & (fmt.bits # 24) & (fmt.bits # 32) THEN
    lastError := "samples of 8, 16, 24 or 32 bits only"; RETURN FALSE
  END;
  IF (fmt.rate < 1000) OR (fmt.rate > 384000) THEN lastError := "a rate from 1000 to 384000 only"; RETURN FALSE END;
  fmt.frames := fmt.dataLen DIV (fmt.channels * fmt.bits DIV 8);
  RETURN TRUE
END ReadFormat;

(** a reader of the samples of f (with the format fmt of ReadFormat) *)
PROCEDURE OpenReader*(VAR rd: Reader; f: Files.File; VAR fmt: Format);
BEGIN
  rd.fmt := fmt;
  IF ~fmt.float & (fmt.bits <= 16) THEN rd.outBits := fmt.bits ELSE rd.outBits := 16 END;
  rd.inFrame := fmt.channels * fmt.bits DIV 8; rd.outFrame := fmt.channels * rd.outBits DIV 8;
  rd.left := fmt.frames * rd.inFrame;
  Files.Set(rd.r, f, fmt.dataPos)
END OpenReader;

(** goes to frame n *)
PROCEDURE SetFrame*(VAR rd: Reader; n: LONGINT);
BEGIN
  IF n < 0 THEN n := 0 ELSIF n > rd.fmt.frames THEN n := rd.fmt.frames END;
  Files.Set(rd.r, Files.Base(rd.r), rd.fmt.dataPos + n * rd.inFrame);
  rd.left := (rd.fmt.frames - n) * rd.inFrame
END SetFrame;

(* sample adr of the file as 16 bits *)
PROCEDURE Wide(VAR rd: Reader; adr: LONGINT): LONGINT;
VAR a, b, c, d: CHAR; v, h: LONGINT; x: REAL;
BEGIN
  IF rd.fmt.bits = 24 THEN SYSTEM.GET(adr + 1, a); SYSTEM.GET(adr + 2, b)
  ELSIF ~rd.fmt.float THEN SYSTEM.GET(adr + 2, a); SYSTEM.GET(adr + 3, b)
  ELSE
    SYSTEM.GET(adr, a); SYSTEM.GET(adr + 1, b); SYSTEM.GET(adr + 2, c); SYSTEM.GET(adr + 3, d);
    h := ORD(d); h := h * 256 + ORD(c); h := h * 256 + ORD(b); h := h * 256 + ORD(a);
    x := SYSTEM.VAL(REAL, h);
    IF x >= 1.0 THEN RETURN 32767 ELSIF x <= -1.0 THEN RETURN -32768 END;
    RETURN ENTIER(x * 32767.0)
  END;
  h := ORD(b); v := h * 256 + ORD(a);
  IF v >= 32768 THEN DEC(v, 65536) END;
  RETURN v
END Wide;

(** reads up to len bytes of samples, whole frames of outBits bits, into data[pos..); the number
  of bytes, 0 at the end *)
PROCEDURE Read*(VAR rd: Reader; VAR data: ARRAY OF SYSTEM.BYTE; pos, len: LONGINT): LONGINT;
VAR n, k, v, got, out, adr: LONGINT;
BEGIN
  ASSERT((pos >= 0) & (len >= 0) & (pos + len <= LEN(data)));
  out := SYSTEM.ADR(data[0]) + pos; got := 0;
  WHILE (rd.left > 0) & (len - got >= rd.outFrame) DO
    n := (len - got) DIV rd.outFrame; IF n > BufSize DIV rd.inFrame THEN n := BufSize DIV rd.inFrame END;
    n := n * rd.inFrame; IF n > rd.left THEN n := rd.left END;
    Files.ReadBytes(rd.r, rd.buf, n); n := (n - rd.r.res) DIV rd.inFrame * rd.inFrame;
    IF n <= 0 THEN rd.left := 0
    ELSIF rd.inFrame = rd.outFrame THEN
      DEC(rd.left, n); SYSTEM.MOVE(SYSTEM.ADR(rd.buf[0]), out + got, n); INC(got, n)
    ELSE
      DEC(rd.left, n); adr := SYSTEM.ADR(rd.buf[0]); k := 0;
      WHILE k < n DIV (rd.fmt.bits DIV 8) DO
        v := Wide(rd, adr); SYSTEM.PUT(out + got, CHR(v MOD 256)); SYSTEM.PUT(out + got + 1, CHR(v DIV 256 MOD 256));
        INC(got, 2); INC(adr, rd.fmt.bits DIV 8); INC(k)
      END
    END
  END;
  RETURN got
END Read;

(** writes the header of a WAV file of 8 or 16 bits with sizes 0: Finish sets them *)
PROCEDURE WriteHeader*(VAR r: Files.Rider; rate, channels, bits: LONGINT);
VAR s: ARRAY 8 OF CHAR;
BEGIN
  s := "RIFF"; Files.WriteBytes(r, s, 4); Files.WriteLInt(r, 36);
  s := "WAVE"; Files.WriteBytes(r, s, 4);
  s := "fmt "; Files.WriteBytes(r, s, 4); Files.WriteLInt(r, 16);
  Files.WriteInt(r, 1); Files.WriteInt(r, SHORT(channels)); Files.WriteLInt(r, rate);
  Files.WriteLInt(r, rate * channels * (bits DIV 8)); Files.WriteInt(r, SHORT(channels * (bits DIV 8)));
  Files.WriteInt(r, SHORT(bits));
  s := "data"; Files.WriteBytes(r, s, 4); Files.WriteLInt(r, 0)
END WriteHeader;

(** sets the sizes in the header (written by WriteHeader at the start of f) for dataLen bytes of samples *)
PROCEDURE Finish*(f: Files.File; dataLen: LONGINT);
VAR r: Files.Rider;
BEGIN
  Files.Set(r, f, 4); Files.WriteLInt(r, dataLen + 36);
  Files.Set(r, f, 40); Files.WriteLInt(r, dataLen)
END Finish;

BEGIN
  lastError := ""
END Wave0.
