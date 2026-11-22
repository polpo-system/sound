MODULE MPEGAudio0;  (** MP3 files: MPEG-1, MPEG-2 and MPEG-2.5 audio, layer III, decoded to 16-bit PCM *)

(* The decoding follows the standards ISO 11172-3 and 13818-3: frames and their side information, the bit
   reservoir, scale factors, Huffman decoding, requantization, middle/side and intensity stereo, the
   reordering of short blocks, alias reduction, the IMDCT with its windows and overlap, and the polyphase
   synthesis filter bank. The Huffman code trees are those of the reference decoder of the standard, read
   from share/MP3Huffman.Bin, and the synthesis window has the values of the standard; both come from the
   MP3 decoder of A2 (ETH Zurich). ID3 tags are skipped. A Xing, Info or VBRI frame gives the length of the
   file and is not played; with a LAME tag in it, the delay and the padding of the encoder are left out
   (gapless playback, as mpg123 does it). *)

IMPORT SYSTEM, Files, MathL;

CONST
  MaxNodes = 10240;  (* nodes of the Huffman trees *)
  ResSize = 4096;  (* the bit reservoir *)
  FrameSize = 2048;
  Samples = 1152;  (* samples of a frame of MPEG-1 for each channel *)
  GaplessDelay = 529;  (* samples the decoder delays: left out with the encoder delay *)

TYPE
  Table = RECORD start, len, linbits: LONGINT END;

  Granule = RECORD  (* the side information of a granule of a channel *)
    part23, bigValues, globalGain, sfCompress, blockType, region0, region1, preflag, sfScale: LONGINT;
    switching, mixed, count1: BOOLEAN;
    table, subblockGain: ARRAY 3 OF LONGINT
  END;

  Decoder* = POINTER TO DecoderDesc;
  DecoderDesc* = RECORD
    rate*, channels*: LONGINT;  (** of the first frame; later frames have the same rate *)
    version*: LONGINT;  (** 1 MPEG-1, 2 MPEG-2, 3 MPEG-2.5 *)
    bitrate*: LONGINT;  (** kbit/s of the first frame; 0 with a Xing header (variable bit rate) *)
    samples*: LONGINT;  (** samples of each channel in the file, estimated without a Xing header *)
    frames*: LONGINT;  (** frames decoded so far *)
    f: Files.File;
    r: Files.Rider;
    pos, dataEnd, first, skip, left, frameLen: LONGINT;
    eof: BOOLEAN;
    (* the frame *)
    lsf, mpeg1: BOOLEAN;
    vIdx, srIdx, band, mode, modeExt, nch, ngr: LONGINT;
    fbuf: ARRAY FrameSize OF CHAR;
    g: ARRAY 2, 2 OF Granule;
    scfsi: ARRAY 2 OF LONGINT;
    res: ARRAY ResSize OF CHAR;
    resLen, bitPos: LONGINT;
    (* a granule of each channel *)
    width: ARRAY 2, 40 OF LONGINT;  (* the bands: long ones, then short ones three times (windows) *)
    nBands, nLong: ARRAY 2 OF LONGINT;
    scf: ARRAY 2, 40 OF LONGINT;
    isMax: ARRAY 40 OF LONGINT;  (* the illegal intensity positions (MPEG-2) *)
    ix: ARRAY 2, 580 OF LONGINT;
    nz: ARRAY 2 OF LONGINT;
    xr: ARRAY 2, 576 OF REAL;
    over: ARRAY 2, 576 OF REAL;
    v: ARRAY 2, 1024 OF REAL;
    voff: ARRAY 2 OF LONGINT;
    pcm: ARRAY 2, Samples OF LONGINT;
    out: ARRAY Samples * 4 OF CHAR;
    outPos, outLen: LONGINT
  END;

VAR
  lastError*: ARRAY 128 OF CHAR;
  loaded: BOOLEAN;
  tab: ARRAY 34 OF Table;
  n0, n1: ARRAY MaxNodes OF CHAR;
  pow43: ARRAY 8207 OF REAL;
  pow2q: ARRAY 600 OF REAL;  (* 2^((i - 500) / 4) *)
  D: ARRAY 512 OF REAL;
  cosL: ARRAY 648 OF REAL;
  cosS: ARRAY 72 OF REAL;
  win: ARRAY 4, 36 OF REAL;
  nm: ARRAY 2048 OF REAL;
  cs, ca: ARRAY 8 OF REAL;
  isL, isR: ARRAY 7 OF REAL;
  pow2: ARRAY 25 OF LONGINT;
  longW: ARRAY 8 * 22 OF LONGINT;
  shortW: ARRAY 8 * 13 OF LONGINT;
  pretab: ARRAY 22 OF LONGINT;
  rateTab: ARRAY 9 OF LONGINT;
  brTab: ARRAY 32 OF LONGINT;
  slen1, slen2: ARRAY 16 OF LONGINT;
  nrSfb: ARRAY 72 OF LONGINT;
  bandOf: ARRAY 9 OF LONGINT;

PROCEDURE Ints(s: ARRAY OF CHAR; VAR a: ARRAY OF LONGINT; VAR n: LONGINT);
VAR i, x: LONGINT; neg: BOOLEAN;
BEGIN
  i := 0;
  LOOP
    WHILE s[i] = " " DO INC(i) END;
    IF s[i] = 0X THEN EXIT END;
    neg := s[i] = "-"; IF neg THEN INC(i) END;
    x := 0; WHILE (s[i] >= "0") & (s[i] <= "9") DO x := x * 10 + ORD(s[i]) - 30H; INC(i) END;
    IF neg THEN x := -x END;
    a[n] := x; INC(n)
  END
END Ints;

(* the Huffman code trees from MP3Huffman.Bin: for each of the 34 tables its number of nodes (mod 256),
   two bytes not used here, its linbits, then the nodes, two bytes each *)
PROCEDURE LoadTables(): BOOLEAN;
VAR f: Files.File; r: Files.Rider; t, i, n, len: LONGINT; c: CHAR;
BEGIN
  f := Files.Old("MP3Huffman.Bin");
  IF f = NIL THEN lastError := "MP3Huffman.Bin is missing (share/)"; RETURN FALSE END;
  Files.Set(r, f, 0); n := 0; t := 0;
  WHILE t < 34 DO
    Files.Read(r, c); len := ORD(c);
    IF (t >= 13) & (t < 24) & (len # 0) THEN INC(len, 256) ELSIF (t >= 24) & (t < 32) THEN INC(len, 512) END;
    Files.Read(r, c); Files.Read(r, c); Files.Read(r, c);
    tab[t].start := n; tab[t].len := len; tab[t].linbits := ORD(c);
    IF n + len > MaxNodes THEN lastError := "MP3Huffman.Bin is damaged"; RETURN FALSE END;
    i := 0; WHILE i < len DO Files.Read(r, n0[n]); Files.Read(r, n1[n]); INC(n); INC(i) END;
    INC(t)
  END;
  IF r.eof THEN lastError := "MP3Huffman.Bin is damaged"; RETURN FALSE END;
  loaded := TRUE;
  RETURN TRUE
END LoadTables;

(* n bits of a from bit pos *)
PROCEDURE Get(VAR a: ARRAY OF CHAR; VAR pos: LONGINT; n: LONGINT): LONGINT;
VAR v, k, r, b: LONGINT;
BEGIN
  v := 0;
  WHILE n > 0 DO
    r := 8 - pos MOD 8; k := n; IF k > r THEN k := r END;
    IF pos DIV 8 < LEN(a) THEN b := ORD(a[pos DIV 8]) DIV pow2[r - k] MOD pow2[k] ELSE b := 0 END;
    v := v * pow2[k] + b; INC(pos, k); DEC(n, k)
  END;
  RETURN v
END Get;

PROCEDURE Bit(d: Decoder): LONGINT;
VAR p: LONGINT;
BEGIN
  p := d.bitPos; INC(d.bitPos);
  IF p DIV 8 >= ResSize THEN RETURN 0 END;
  RETURN ORD(d.res[p DIV 8]) DIV pow2[7 - p MOD 8] MOD 2
END Bit;

(* Frames *)

PROCEDURE ValidHeader(b0, b1, b2: LONGINT): BOOLEAN;
BEGIN
  RETURN (b0 = 0FFH) & (b1 DIV 32 = 7) & ((b1 DIV 8) MOD 4 # 1) & ((b1 DIV 2) MOD 4 = 1)
    & (b2 DIV 16 > 0) & (b2 DIV 16 < 15) & ((b2 DIV 4) MOD 4 # 3)
END ValidHeader;

(* the index of the sample rate of a header in rateTab (0..8) *)
PROCEDURE RateIndex(b1, b2: LONGINT): LONGINT;
VAR v: LONGINT;
BEGIN
  v := (b1 DIV 8) MOD 4;
  IF v = 3 THEN v := 0 ELSIF v = 2 THEN v := 1 ELSE v := 2 END;
  RETURN v * 3 + (b2 DIV 4) MOD 4
END RateIndex;

PROCEDURE FrameLength(b1, b2: LONGINT): LONGINT;
VAR rate, br, pad: LONGINT;
BEGIN
  rate := rateTab[RateIndex(b1, b2)]; pad := (b2 DIV 2) MOD 2;
  IF (b1 DIV 8) MOD 4 = 3 THEN br := brTab[b2 DIV 16]; RETURN 144000 * br DIV rate + pad
  ELSE br := brTab[16 + b2 DIV 16]; RETURN 72000 * br DIV rate + pad
  END
END FrameLength;

PROCEDURE ReadByte(VAR r: Files.Rider): LONGINT;
VAR c: CHAR;
BEGIN Files.Read(r, c); RETURN ORD(c)
END ReadByte;

PROCEDURE Big32(VAR a: ARRAY OF CHAR; i: LONGINT): LONGINT;
VAR v, k: LONGINT;
BEGIN
  v := 0; k := 0; WHILE k < 4 DO v := v * 256 + ORD(a[i + k]); INC(k) END;
  RETURN v
END Big32;

(* the header at pos is valid and the frame after it (if there is one) has the same kind *)
PROCEDURE FrameAt(d: Decoder; pos: LONGINT; VAR len: LONGINT): BOOLEAN;
VAR b0, b1, b2, c0, c1, c2: LONGINT;
BEGIN
  IF pos + 4 > d.dataEnd THEN RETURN FALSE END;
  Files.Set(d.r, d.f, pos); b0 := ReadByte(d.r); b1 := ReadByte(d.r); b2 := ReadByte(d.r);
  IF ~ValidHeader(b0, b1, b2) THEN RETURN FALSE END;
  len := FrameLength(b1, b2);
  IF pos + len + 4 > d.dataEnd THEN RETURN pos + len <= d.dataEnd END;
  Files.Set(d.r, d.f, pos + len); c0 := ReadByte(d.r); c1 := ReadByte(d.r); c2 := ReadByte(d.r);
  RETURN ValidHeader(c0, c1, c2) & (c1 DIV 2 = b1 DIV 2) & ((c2 DIV 4) MOD 4 = (b2 DIV 4) MOD 4)
END FrameAt;

(* the next frame into d.fbuf; frames of another kind than the first are passed over *)
PROCEDURE NextFrame(d: Decoder): BOOLEAN;
VAR b0, b1, b2, len: LONGINT;
BEGIN
  LOOP
    IF d.pos + 4 > d.dataEnd THEN RETURN FALSE END;
    Files.Set(d.r, d.f, d.pos); b0 := ReadByte(d.r); b1 := ReadByte(d.r); b2 := ReadByte(d.r);
    IF ValidHeader(b0, b1, b2) & (RateIndex(b1, b2) = d.vIdx * 3 + d.srIdx) THEN
      len := FrameLength(b1, b2);
      IF d.pos + len > d.dataEnd THEN RETURN FALSE END;
      Files.Set(d.r, d.f, d.pos); Files.ReadBytes(d.r, d.fbuf, len);
      d.frameLen := len; INC(d.pos, len);
      RETURN TRUE
    END;
    INC(d.pos)
  END
END NextFrame;

PROCEDURE Side(d: Decoder): LONGINT;  (* the size of the side information *)
BEGIN
  IF d.mpeg1 THEN IF d.nch = 1 THEN RETURN 17 ELSE RETURN 32 END
  ELSIF d.nch = 1 THEN RETURN 9 ELSE RETURN 17
  END
END Side;

PROCEDURE ParseHeader(d: Decoder);
VAR b1, b2, b3, v: LONGINT;
BEGIN
  b1 := ORD(d.fbuf[1]); b2 := ORD(d.fbuf[2]); b3 := ORD(d.fbuf[3]);
  v := (b1 DIV 8) MOD 4; d.mpeg1 := v = 3; d.lsf := ~d.mpeg1;
  IF v = 3 THEN d.vIdx := 0 ELSIF v = 2 THEN d.vIdx := 1 ELSE d.vIdx := 2 END;
  d.srIdx := (b2 DIV 4) MOD 4; d.band := bandOf[d.vIdx * 3 + d.srIdx];
  d.mode := b3 DIV 64; d.modeExt := (b3 DIV 16) MOD 4;
  IF d.mode = 3 THEN d.nch := 1 ELSE d.nch := 2 END;
  IF d.mpeg1 THEN d.ngr := 2 ELSE d.ngr := 1 END
END ParseHeader;

(** opens the MP3 file f; FALSE: lastError says why *)
PROCEDURE Open*(f: Files.File; VAR d: Decoder): BOOLEAN;
VAR h: ARRAY 10 OF CHAR; pos, len, p, k, off, flags, nframes, delay, padding, spf, b1, b2: LONGINT; lame: BOOLEAN;
BEGIN
  lastError := ""; d := NIL;
  IF ~loaded & ~LoadTables() THEN RETURN FALSE END;
  NEW(d); d.f := f; len := Files.Length(f); pos := 0;
  LOOP  (* ID3v2 tags *)
    IF pos + 10 > len THEN EXIT END;
    Files.Set(d.r, f, pos); Files.ReadBytes(d.r, h, 10);
    IF (h[0] # "I") OR (h[1] # "D") OR (h[2] # "3") THEN EXIT END;
    p := 0; k := 6; WHILE k < 10 DO p := p * 128 + ORD(h[k]) MOD 128; INC(k) END;
    pos := pos + 10 + p; IF ODD(ORD(h[5]) DIV 16) THEN INC(pos, 10) END
  END;
  d.dataEnd := len;
  IF len >= 128 THEN
    Files.Set(d.r, f, len - 128); Files.ReadBytes(d.r, h, 3);
    IF (h[0] = "T") & (h[1] = "A") & (h[2] = "G") THEN d.dataEnd := len - 128 END
  END;
  p := pos; WHILE (p < pos + 65536) & ~FrameAt(d, p, k) DO INC(p) END;
  IF ~FrameAt(d, p, k) THEN lastError := "no MPEG audio layer III frames"; d := NIL; RETURN FALSE END;
  Files.Set(d.r, f, p); Files.ReadBytes(d.r, d.fbuf, k); d.frameLen := k;
  ParseHeader(d); b1 := ORD(d.fbuf[1]); b2 := ORD(d.fbuf[2]);
  d.rate := rateTab[d.vIdx * 3 + d.srIdx]; d.channels := d.nch; d.version := d.vIdx + 1;
  IF d.mpeg1 THEN d.bitrate := brTab[b2 DIV 16] ELSE d.bitrate := brTab[16 + b2 DIV 16] END;
  IF d.mpeg1 THEN spf := Samples ELSE spf := Samples DIV 2 END;
  d.first := p; d.pos := p; d.skip := 0; d.left := -1;
  d.samples := (d.dataEnd - p) DIV k * spf;
  off := 4 + Side(d);
  IF ~ODD(b1) & (d.fbuf[off] # "X") & (d.fbuf[off] # "I") THEN INC(off, 2) END;  (* LAME leaves out the CRC *)
  IF (off + 12 <= k) & ((d.fbuf[off] = "X") & (d.fbuf[off + 1] = "i") & (d.fbuf[off + 2] = "n") & (d.fbuf[off + 3] = "g")
    OR (d.fbuf[off] = "I") & (d.fbuf[off + 1] = "n") & (d.fbuf[off + 2] = "f") & (d.fbuf[off + 3] = "o")) THEN
    IF d.fbuf[off] = "X" THEN d.bitrate := 0 END;
    flags := Big32(d.fbuf, off + 4); off := off + 8; nframes := 0;
    IF ODD(flags) THEN nframes := Big32(d.fbuf, off); INC(off, 4) END;
    IF ODD(flags DIV 2) THEN INC(off, 4) END;
    IF ODD(flags DIV 4) THEN INC(off, 100) END;
    IF ODD(flags DIV 8) THEN INC(off, 4) END;
    lame := (off + 24 <= k) & ((d.fbuf[off] = "L") & (d.fbuf[off + 1] = "A") & (d.fbuf[off + 2] = "M") & (d.fbuf[off + 3] = "E")
      OR (d.fbuf[off] = "L") & (d.fbuf[off + 1] = "a") & (d.fbuf[off + 2] = "v"));
    d.pos := p + k;  (* the frame of the header is not played *)
    IF nframes > 0 THEN
      d.samples := nframes * spf;
      IF lame THEN
        delay := ORD(d.fbuf[off + 21]) * 16 + ORD(d.fbuf[off + 22]) DIV 16;
        padding := ORD(d.fbuf[off + 22]) MOD 16 * 256 + ORD(d.fbuf[off + 23]);
        IF delay + padding < d.samples THEN
          d.samples := d.samples - delay - padding; d.skip := delay + GaplessDelay; d.left := d.samples
        END
      END
    END
  ELSIF (36 + 18 <= k) & (d.fbuf[36] = "V") & (d.fbuf[37] = "B") & (d.fbuf[38] = "R") & (d.fbuf[39] = "I") THEN
    d.bitrate := 0; d.pos := p + k; nframes := Big32(d.fbuf, 36 + 14);
    IF nframes > 0 THEN d.samples := nframes * spf END
  END;
  d.resLen := 0; d.outPos := 0; d.outLen := 0; d.frames := 0; d.eof := FALSE;
  d.voff[0] := 0; d.voff[1] := 0;
  RETURN TRUE
END Open;

(* Side information and scale factors *)

PROCEDURE ReadGranule(d: Decoder; VAR g: Granule; VAR pos: LONGINT);
VAR i: LONGINT;
BEGIN
  g.part23 := Get(d.fbuf, pos, 12); g.bigValues := Get(d.fbuf, pos, 9);
  IF g.bigValues > 288 THEN g.bigValues := 288 END;
  g.globalGain := Get(d.fbuf, pos, 8);
  IF d.lsf THEN g.sfCompress := Get(d.fbuf, pos, 9) ELSE g.sfCompress := Get(d.fbuf, pos, 4) END;
  g.switching := Get(d.fbuf, pos, 1) = 1;
  IF g.switching THEN
    g.blockType := Get(d.fbuf, pos, 2); g.mixed := Get(d.fbuf, pos, 1) = 1;
    g.table[0] := Get(d.fbuf, pos, 5); g.table[1] := Get(d.fbuf, pos, 5); g.table[2] := 0;
    i := 0; WHILE i < 3 DO g.subblockGain[i] := Get(d.fbuf, pos, 3); INC(i) END;
    IF (g.blockType = 2) & ~g.mixed THEN g.region0 := 8 ELSE g.region0 := 7 END;
    g.region1 := 36
  ELSE
    g.blockType := 0; g.mixed := FALSE;
    i := 0; WHILE i < 3 DO g.table[i] := Get(d.fbuf, pos, 5); g.subblockGain[i] := 0; INC(i) END;
    g.region0 := Get(d.fbuf, pos, 4); g.region1 := Get(d.fbuf, pos, 3)
  END;
  IF d.mpeg1 THEN g.preflag := Get(d.fbuf, pos, 1) ELSE g.preflag := 0 END;
  g.sfScale := Get(d.fbuf, pos, 1); g.count1 := Get(d.fbuf, pos, 1) = 1
END ReadGranule;

(* the side information; FALSE if the frame cannot be decoded *)
PROCEDURE ReadSide(d: Decoder; VAR mdb: LONGINT): BOOLEAN;
VAR pos, gr, ch: LONGINT;
BEGIN
  pos := 32; IF ~ODD(ORD(d.fbuf[1])) THEN INC(pos, 16) END;
  IF d.mpeg1 THEN
    mdb := Get(d.fbuf, pos, 9);
    IF d.nch = 1 THEN INC(pos, 5) ELSE INC(pos, 3) END;
    ch := 0; WHILE ch < d.nch DO d.scfsi[ch] := Get(d.fbuf, pos, 4); INC(ch) END
  ELSE
    mdb := Get(d.fbuf, pos, 8);
    IF d.nch = 1 THEN INC(pos, 1) ELSE INC(pos, 2) END;
    d.scfsi[0] := 0; d.scfsi[1] := 0
  END;
  gr := 0;
  WHILE gr < d.ngr DO
    ch := 0; WHILE ch < d.nch DO ReadGranule(d, d.g[gr, ch], pos); INC(ch) END;
    INC(gr)
  END;
  RETURN TRUE
END ReadSide;

(* the bands of a granule of channel ch: long bands, then short ones, each three times *)
PROCEDURE Bands(d: Decoder; VAR g: Granule; ch: LONGINT);
VAR i, n, sum, b, start, w: LONGINT;
BEGIN
  n := 0;
  IF g.switching & (g.blockType = 2) THEN
    b := 0; start := 0;
    IF g.mixed THEN
      sum := 0; i := 0;
      WHILE sum < 36 DO d.width[ch, n] := longW[d.band * 22 + i]; INC(sum, longW[d.band * 22 + i]); INC(n); INC(i) END;
      WHILE start + shortW[d.band * 13 + b] <= 12 DO INC(start, shortW[d.band * 13 + b]); INC(b) END
    ELSE start := 12  (* no band is cut *)
    END;
    d.nLong[ch] := n;
    WHILE b < 13 DO
      w := shortW[d.band * 13 + b];
      IF start < 12 THEN w := start + w - 12; start := 12 END;
      i := 0; WHILE i < 3 DO d.width[ch, n] := w; INC(n); INC(i) END;
      INC(b)
    END
  ELSE
    i := 0; WHILE i < 22 DO d.width[ch, n] := longW[d.band * 22 + i]; INC(n); INC(i) END;
    d.nLong[ch] := n
  END;
  d.nBands[ch] := n
END Bands;

PROCEDURE Scalefactors1(d: Decoder; gr, ch: LONGINT);
VAR g: Granule; s1, s2, e, i, k: LONGINT; bound: ARRAY 5 OF LONGINT;
BEGIN
  g := d.g[gr, ch]; s1 := slen1[g.sfCompress]; s2 := slen2[g.sfCompress];
  IF g.switching & (g.blockType = 2) THEN
    e := 0;
    IF g.mixed THEN
      WHILE e < 8 DO d.scf[ch, e] := Get(d.res, d.bitPos, s1); INC(e) END;
      k := 9
    ELSE k := 18
    END;
    i := 0; WHILE i < k DO d.scf[ch, e] := Get(d.res, d.bitPos, s1); INC(e); INC(i) END;
    i := 0; WHILE i < 18 DO d.scf[ch, e] := Get(d.res, d.bitPos, s2); INC(e); INC(i) END;
    WHILE e < 40 DO d.scf[ch, e] := 0; INC(e) END
  ELSE
    bound[0] := 0; bound[1] := 6; bound[2] := 11; bound[3] := 16; bound[4] := 21;
    i := 0;
    WHILE i < 4 DO
      IF (gr = 0) OR ~ODD(d.scfsi[ch] DIV pow2[3 - i]) THEN
        e := bound[i];
        WHILE e < bound[i + 1] DO
          IF i < 2 THEN d.scf[ch, e] := Get(d.res, d.bitPos, s1) ELSE d.scf[ch, e] := Get(d.res, d.bitPos, s2) END;
          INC(e)
        END
      END;
      INC(i)
    END;
    d.scf[ch, 21] := 0
  END
END Scalefactors1;

PROCEDURE Scalefactors2(d: Decoder; gr, ch: LONGINT);
VAR sfc, t, bi, part, i, e, n: LONGINT; slen: ARRAY 4 OF LONGINT;
BEGIN
  sfc := d.g[gr, ch].sfCompress;
  IF ~d.g[gr, ch].switching OR (d.g[gr, ch].blockType # 2) THEN bi := 0
  ELSIF d.g[gr, ch].mixed THEN bi := 2
  ELSE bi := 1
  END;
  slen[3] := 0;
  IF (ch = 1) & (d.mode = 1) & ODD(d.modeExt) THEN
    sfc := sfc DIV 2;
    IF sfc < 180 THEN slen[0] := sfc DIV 36; slen[1] := sfc MOD 36 DIV 6; slen[2] := sfc MOD 6; t := 3
    ELSIF sfc < 244 THEN sfc := sfc - 180; slen[0] := sfc MOD 64 DIV 16; slen[1] := sfc MOD 16 DIV 4; slen[2] := sfc MOD 4; t := 4
    ELSE sfc := sfc - 244; slen[0] := sfc DIV 3; slen[1] := sfc MOD 3; slen[2] := 0; t := 5
    END;
    d.g[gr, ch].preflag := 0
  ELSE
    IF sfc < 400 THEN slen[0] := sfc DIV 16 DIV 5; slen[1] := sfc DIV 16 MOD 5; slen[2] := sfc MOD 16 DIV 4; slen[3] := sfc MOD 4;
      t := 0; d.g[gr, ch].preflag := 0
    ELSIF sfc < 500 THEN sfc := sfc - 400; slen[0] := sfc DIV 4 DIV 5; slen[1] := sfc DIV 4 MOD 5; slen[2] := sfc MOD 4;
      t := 1; d.g[gr, ch].preflag := 0
    ELSE sfc := sfc - 500; slen[0] := sfc DIV 3; slen[1] := sfc MOD 3; slen[2] := 0; t := 2; d.g[gr, ch].preflag := 1
    END
  END;
  e := 0; part := 0;
  WHILE part < 4 DO
    n := nrSfb[(t * 3 + bi) * 4 + part]; i := 0;
    WHILE (i < n) & (e < 40) DO
      d.scf[ch, e] := Get(d.res, d.bitPos, slen[part]); d.isMax[e] := pow2[slen[part]] - 1; INC(e); INC(i)
    END;
    INC(part)
  END;
  WHILE e < 40 DO d.scf[ch, e] := 0; d.isMax[e] := 0; INC(e) END
END Scalefactors2;

(* Huffman decoding *)

PROCEDURE Walk(d: Decoder; t: LONGINT): LONGINT;  (* the value at the leaf of table t, -1 on an error *)
VAR p, e, steps: LONGINT;
BEGIN
  p := tab[t].start; e := p + tab[t].len; steps := 0;
  LOOP
    IF n0[p] = 0X THEN RETURN ORD(n1[p]) END;
    IF Bit(d) = 1 THEN
      WHILE (ORD(n1[p]) >= 250) & (p < e) DO p := p + ORD(n1[p]) END;
      IF p < e THEN p := p + ORD(n1[p]) END
    ELSE
      WHILE (ORD(n0[p]) >= 250) & (p < e) DO p := p + ORD(n0[p]) END;
      IF p < e THEN p := p + ORD(n0[p]) END
    END;
    INC(steps);
    IF (steps > 32) OR (p >= e) THEN RETURN -1 END
  END
END Walk;

PROCEDURE Pair(d: Decoder; t: LONGINT; VAR x, y: LONGINT);
VAR v: LONGINT;
BEGIN
  x := 0; y := 0;
  IF tab[t].len = 0 THEN RETURN END;
  v := Walk(d, t);
  IF v < 0 THEN RETURN END;
  x := v DIV 16; y := v MOD 16;
  IF (tab[t].linbits > 0) & (x = 15) THEN x := x + Get(d.res, d.bitPos, tab[t].linbits) END;
  IF (x # 0) & (Bit(d) = 1) THEN x := -x END;
  IF (tab[t].linbits > 0) & (y = 15) THEN y := y + Get(d.res, d.bitPos, tab[t].linbits) END;
  IF (y # 0) & (Bit(d) = 1) THEN y := -y END
END Pair;

PROCEDURE Quad(d: Decoder; t, ch, i: LONGINT);
VAR v, k, x: LONGINT;
BEGIN
  v := Walk(d, t); IF v < 0 THEN v := 0 END;
  k := 0;
  WHILE k < 4 DO
    x := v DIV pow2[3 - k] MOD 2;
    IF (x # 0) & (Bit(d) = 1) THEN x := -x END;
    d.ix[ch, i + k] := x; INC(k)
  END
END Quad;

(* the start of band b of channel ch (576 past the last) *)
PROCEDURE BandStart(d: Decoder; ch, b: LONGINT): LONGINT;
VAR i, s: LONGINT;
BEGIN
  IF b >= d.nBands[ch] THEN RETURN 576 END;
  s := 0; i := 0; WHILE i < b DO INC(s, d.width[ch, i]); INC(i) END;
  RETURN s
END BandStart;

PROCEDURE Huffman(d: Decoder; gr, ch, end: LONGINT);
VAR g: Granule; i, r1, r2, big, t, x, y: LONGINT;
BEGIN
  g := d.g[gr, ch];
  r1 := BandStart(d, ch, g.region0 + 1); r2 := BandStart(d, ch, g.region0 + g.region1 + 2);
  big := g.bigValues * 2; i := 0;
  WHILE i < big DO
    IF i < r1 THEN t := g.table[0] ELSIF i < r2 THEN t := g.table[1] ELSE t := g.table[2] END;
    Pair(d, t, x, y); d.ix[ch, i] := x; d.ix[ch, i + 1] := y; INC(i, 2)
  END;
  IF g.count1 THEN t := 33 ELSE t := 32 END;
  WHILE (i <= 572) & (d.bitPos < end) DO Quad(d, t, ch, i); INC(i, 4) END;
  IF (d.bitPos > end) & (i > big) THEN DEC(i, 4) END;  (* the last quadruple went past the part *)
  d.nz[ch] := i;
  WHILE i < 576 DO d.ix[ch, i] := 0; INC(i) END
END Huffman;

(* Requantization *)

PROCEDURE Requantize(d: Decoder; gr, ch: LONGINT);
VAR g: Granule; e, j, k, w, q, m, x, win, nz: LONGINT; f: REAL;
BEGIN
  g := d.g[gr, ch]; IF g.sfScale = 1 THEN m := 4 ELSE m := 2 END;
  j := 0; e := 0; nz := d.nz[ch];
  WHILE (e < d.nBands[ch]) & (j < nz) DO
    w := d.width[ch, e];
    IF e < d.nLong[ch] THEN q := g.globalGain - 210 - m * (d.scf[ch, e] + g.preflag * pretab[e])
    ELSE win := (e - d.nLong[ch]) MOD 3; q := g.globalGain - 210 - 8 * g.subblockGain[win] - m * d.scf[ch, e]
    END;
    IF q < -500 THEN f := 0.0 ELSIF q > 99 THEN f := pow2q[599] ELSE f := pow2q[q + 500] END;
    k := 0;
    WHILE (k < w) & (j < 576) DO
      x := d.ix[ch, j];
      IF x = 0 THEN d.xr[ch, j] := 0.0
      ELSIF x > 0 THEN IF x > 8206 THEN x := 8206 END; d.xr[ch, j] := pow43[x] * f
      ELSE IF x < -8206 THEN x := -8206 END; d.xr[ch, j] := -pow43[-x] * f
      END;
      INC(j); INC(k)
    END;
    INC(e)
  END;
  WHILE j < 576 DO d.xr[ch, j] := 0.0; INC(j) END
END Requantize;

(* Stereo *)

PROCEDURE MS(d: Decoder; a, b: LONGINT);
VAR i: LONGINT; m, s: REAL;
BEGIN
  i := a;
  WHILE i < b DO
    m := d.xr[0, i]; s := d.xr[1, i];
    d.xr[0, i] := (m + s) * 0.70710678; d.xr[1, i] := (m - s) * 0.70710678; INC(i)
  END
END MS;

(* intensity stereo for the lines [a, b) at position p of band e *)
PROCEDURE Intensity(d: Decoder; gr, e, p, a, b: LONGINT; ms: BOOLEAN);
VAR kl, kr, io: REAL; i, n: LONGINT; legal: BOOLEAN;
BEGIN
  IF d.mpeg1 THEN legal := p < 7 ELSE legal := p # d.isMax[e] END;
  IF ~legal THEN IF ms THEN MS(d, a, b) END; RETURN END;
  IF d.mpeg1 THEN kl := isL[p]; kr := isR[p]
  ELSE
    IF ODD(d.g[gr, 1].sfCompress) THEN io := 0.70710678 ELSE io := 0.84089642 END;
    kl := 1.0; kr := 1.0;
    IF ODD(p) THEN n := (p + 1) DIV 2; WHILE n > 0 DO kl := kl * io; DEC(n) END
    ELSE n := p DIV 2; WHILE n > 0 DO kr := kr * io; DEC(n) END
    END
  END;
  i := a;
  WHILE i < b DO d.xr[1, i] := d.xr[0, i] * kr; d.xr[0, i] := d.xr[0, i] * kl; INC(i) END
END Intensity;

PROCEDURE Stereo(d: Decoder; gr: LONGINT);
VAR ms: BOOLEAN; e, s, last, w, win, nb, nl, p, k: LONGINT; is: ARRAY 40 OF BOOLEAN; start: ARRAY 41 OF LONGINT;
  zero: BOOLEAN; lastWin: ARRAY 3 OF LONGINT;
BEGIN
  IF (d.nch # 2) OR (d.mode # 1) THEN RETURN END;
  ms := ODD(d.modeExt DIV 2);
  IF ~ODD(d.modeExt) THEN IF ms THEN MS(d, 0, 576) END
  ELSE
    nb := d.nBands[1]; nl := d.nLong[1];
    start[0] := 0; e := 0; WHILE e < nb DO start[e + 1] := start[e] + d.width[1, e]; is[e] := FALSE; INC(e) END;
    last := -1;  (* the last long band with lines not zero in the right channel *)
    lastWin[0] := -1; lastWin[1] := -1; lastWin[2] := -1;
    e := 0;
    WHILE e < nb DO
      zero := TRUE; s := start[e];
      WHILE (s < start[e + 1]) & (s < 576) DO IF d.xr[1, s] # 0.0 THEN zero := FALSE END; INC(s) END;
      IF ~zero THEN IF e < nl THEN last := e ELSE lastWin[(e - nl) MOD 3] := e END END;
      INC(e)
    END;
    IF nl = nb THEN e := last + 1; WHILE e < nb DO is[e] := TRUE; INC(e) END
    ELSE
      e := nl;
      WHILE e < nb DO win := (e - nl) MOD 3; IF e > lastWin[win] THEN is[e] := TRUE END; INC(e) END;
      IF (nl > 0) & (lastWin[0] < 0) & (lastWin[1] < 0) & (lastWin[2] < 0) THEN
        e := last + 1; WHILE e < nl DO is[e] := TRUE; INC(e) END
      END
    END;
    e := 0;
    WHILE e < nb DO
      w := start[e + 1]; IF w > 576 THEN w := 576 END;
      IF is[e] THEN
        k := e;
        IF (nl = nb) & (e = nb - 1) THEN k := e - 1  (* the last long band takes the position of the one before *)
        ELSIF (e >= nl) & (e >= nb - 3) THEN k := e - 3  (* the last short band too *)
        END;
        p := d.scf[1, k];
        Intensity(d, gr, k, p, start[e], w, ms)
      ELSIF ms THEN MS(d, start[e], w)
      END;
      INC(e)
    END
  END;
  d.nz[0] := 576; d.nz[1] := 576
END Stereo;

(* Reordering, alias reduction, IMDCT *)

PROCEDURE Reorder(d: Decoder; gr, ch: LONGINT);
VAR tmp: ARRAY 576 OF REAL; e, j, w, win, k, s: LONGINT;
BEGIN
  IF ~d.g[gr, ch].switching OR (d.g[gr, ch].blockType # 2) THEN RETURN END;
  s := 0; e := 0; WHILE e < d.nLong[ch] DO INC(s, d.width[ch, e]); INC(e) END;
  j := s;
  WHILE e < d.nBands[ch] DO
    w := d.width[ch, e]; win := 0;
    WHILE win < 3 DO
      k := 0; WHILE k < w DO tmp[j + k * 3 + win] := d.xr[ch, j + win * w + k]; INC(k) END;
      INC(win)
    END;
    INC(j, 3 * w); INC(e, 3)
  END;
  WHILE s < j DO d.xr[ch, s] := tmp[s]; INC(s) END
END Reorder;

PROCEDURE Antialias(d: Decoder; gr, ch: LONGINT);
VAR sb, n, i, a, b: LONGINT; bu, bd: REAL;
BEGIN
  IF d.g[gr, ch].switching & (d.g[gr, ch].blockType = 2) THEN
    IF ~d.g[gr, ch].mixed THEN RETURN END;
    n := 2
  ELSE n := 32
  END;
  sb := 1;
  WHILE sb < n DO
    i := 0;
    WHILE i < 8 DO
      a := sb * 18 - 1 - i; b := sb * 18 + i; bu := d.xr[ch, a]; bd := d.xr[ch, b];
      d.xr[ch, a] := bu * cs[i] - bd * ca[i]; d.xr[ch, b] := bd * cs[i] + bu * ca[i]; INC(i)
    END;
    INC(sb)
  END
END Antialias;

PROCEDURE Hybrid(d: Decoder; gr, ch: LONGINT);
VAR sb, bt, i, k, w, b: LONGINT; s: REAL; in: ARRAY 18 OF REAL; o: ARRAY 36 OF REAL; zero: BOOLEAN; g: Granule;
BEGIN
  g := d.g[gr, ch]; sb := 0;
  WHILE sb < 32 DO
    b := sb * 18;
    IF ~g.switching THEN bt := 0
    ELSIF (g.blockType = 2) & g.mixed & (sb < 2) THEN bt := 0
    ELSE bt := g.blockType
    END;
    zero := TRUE; i := 0;
    WHILE i < 18 DO in[i] := d.xr[ch, b + i]; IF in[i] # 0.0 THEN zero := FALSE END; INC(i) END;
    i := 0; WHILE i < 36 DO o[i] := 0.0; INC(i) END;
    IF zero THEN
    ELSIF bt # 2 THEN
      i := 0;
      WHILE i < 36 DO
        s := 0.0; k := 0; WHILE k < 18 DO s := s + in[k] * cosL[i * 18 + k]; INC(k) END;
        o[i] := s * win[bt, i]; INC(i)
      END
    ELSE
      w := 0;
      WHILE w < 3 DO
        i := 0;
        WHILE i < 12 DO
          s := 0.0; k := 0; WHILE k < 6 DO s := s + in[w + 3 * k] * cosS[i * 6 + k]; INC(k) END;
          o[6 + 6 * w + i] := o[6 + 6 * w + i] + s * win[2, i]; INC(i)
        END;
        INC(w)
      END
    END;
    i := 0;
    WHILE i < 18 DO
      d.xr[ch, b + i] := o[i] + d.over[ch, b + i]; d.over[ch, b + i] := o[18 + i];
      IF ODD(sb) & ODD(i) THEN d.xr[ch, b + i] := -d.xr[ch, b + i] END;
      INC(i)
    END;
    INC(sb)
  END
END Hybrid;

(* the polyphase synthesis of the 576 samples of granule gr of channel ch *)
PROCEDURE Synth(d: Decoder; gr, ch: LONGINT);
VAR ss, i, k, j, t, off, x, at: LONGINT; sum: REAL; s: ARRAY 32 OF REAL; zero: BOOLEAN;
BEGIN
  at := gr * 576; ss := 0;
  WHILE ss < 18 DO
    zero := TRUE; k := 0;
    WHILE k < 32 DO s[k] := d.xr[ch, k * 18 + ss]; IF s[k] # 0.0 THEN zero := FALSE END; INC(k) END;
    off := (d.voff[ch] + 960) MOD 1024; d.voff[ch] := off;
    i := 0;
    WHILE i < 64 DO
      sum := 0.0;
      IF ~zero THEN k := 0; WHILE k < 32 DO sum := sum + nm[i * 32 + k] * s[k]; INC(k) END END;
      d.v[ch, off + i] := sum; INC(i)
    END;
    j := 0;
    WHILE j < 32 DO
      sum := 0.0; t := 0;
      WHILE t < 8 DO
        sum := sum + d.v[ch, (off + t * 128 + j) MOD 1024] * D[t * 64 + j]
          + d.v[ch, (off + t * 128 + 96 + j) MOD 1024] * D[t * 64 + 32 + j];
        INC(t)
      END;
      x := ENTIER(sum * 32768.0 + 0.5);
      IF x > 32767 THEN x := 32767 ELSIF x < -32768 THEN x := -32768 END;
      d.pcm[ch, at + ss * 32 + j] := x; INC(j)
    END;
    INC(ss)
  END
END Synth;

(* the samples of the frame into d.out, in the channels of the file *)
PROCEDURE Interleave(d: Decoder; n: LONGINT);
VAR t, a, l, r: LONGINT;
BEGIN
  t := 0; a := 0;
  WHILE t < n DO
    l := d.pcm[0, t]; IF d.nch = 2 THEN r := d.pcm[1, t] ELSE r := l END;
    IF d.channels = 1 THEN l := (l + r) DIV 2 END;
    d.out[a] := CHR(l MOD 256); d.out[a + 1] := CHR(l DIV 256 MOD 256); INC(a, 2);
    IF d.channels = 2 THEN d.out[a] := CHR(r MOD 256); d.out[a + 1] := CHR(r DIV 256 MOD 256); INC(a, 2) END;
    INC(t)
  END;
  d.outPos := 0; d.outLen := a
END Interleave;

(* decodes the next frame into d.out; FALSE at the end *)
PROCEDURE Decode(d: Decoder): BOOLEAN;
VAR mdb, side, mainLen, start, keep, gr, ch, part2, t: LONGINT;
BEGIN
  IF ~NextFrame(d) THEN RETURN FALSE END;
  ParseHeader(d);
  IF ~ReadSide(d, mdb) THEN RETURN FALSE END;
  side := 4 + Side(d); IF ~ODD(ORD(d.fbuf[1])) THEN INC(side, 2) END;
  mainLen := d.frameLen - side; IF mainLen < 0 THEN mainLen := 0 END;
  IF d.resLen + mainLen > ResSize THEN
    keep := 1024; IF keep > d.resLen THEN keep := d.resLen END;
    SYSTEM.MOVE(SYSTEM.ADR(d.res[d.resLen - keep]), SYSTEM.ADR(d.res[0]), keep); d.resLen := keep
  END;
  start := d.resLen - mdb;
  IF mainLen > 0 THEN SYSTEM.MOVE(SYSTEM.ADR(d.fbuf[side]), SYSTEM.ADR(d.res[d.resLen]), mainLen) END;
  INC(d.resLen, mainLen);
  IF start < 0 THEN  (* the bits it takes from frames before are missing: silence *)
    t := 0; WHILE t < d.ngr * 576 DO d.pcm[0, t] := 0; d.pcm[1, t] := 0; INC(t) END
  ELSE
    d.bitPos := start * 8; gr := 0;
    WHILE gr < d.ngr DO
      ch := 0;
      WHILE ch < d.nch DO
        part2 := d.bitPos; Bands(d, d.g[gr, ch], ch);
        IF d.mpeg1 THEN Scalefactors1(d, gr, ch) ELSE Scalefactors2(d, gr, ch) END;
        Huffman(d, gr, ch, part2 + d.g[gr, ch].part23);
        d.bitPos := part2 + d.g[gr, ch].part23;
        Requantize(d, gr, ch);
        INC(ch)
      END;
      Stereo(d, gr);
      ch := 0;
      WHILE ch < d.nch DO Reorder(d, gr, ch); Antialias(d, gr, ch); Hybrid(d, gr, ch); Synth(d, gr, ch); INC(ch) END;
      INC(gr)
    END
  END;
  Interleave(d, d.ngr * 576); INC(d.frames);
  RETURN TRUE
END Decode;

(** reads decoded samples into data[pos..pos+len): 16 bits, little-endian, the channels interleaved;
  whole frames of samples; the number of bytes, 0 at the end *)
PROCEDURE Read*(d: Decoder; VAR data: ARRAY OF SYSTEM.BYTE; pos, len: LONGINT): LONGINT;
VAR fb, got, n, k, adr: LONGINT;
BEGIN
  ASSERT((pos >= 0) & (len >= 0) & (pos + len <= LEN(data)));
  fb := d.channels * 2; len := len DIV fb * fb; got := 0; adr := SYSTEM.ADR(data[0]) + pos;
  WHILE got < len DO
    IF d.outPos >= d.outLen THEN
      IF d.eof OR ~Decode(d) THEN d.eof := TRUE; RETURN got END
    END;
    n := d.outLen - d.outPos;
    IF d.skip > 0 THEN
      k := d.skip * fb; IF k > n THEN k := n END;
      INC(d.outPos, k); DEC(d.skip, k DIV fb)
    ELSE
      IF n > len - got THEN n := len - got END;
      IF d.left >= 0 THEN
        IF n > d.left * fb THEN n := d.left * fb END;
        IF n = 0 THEN d.eof := TRUE; RETURN got END;
        DEC(d.left, n DIV fb)
      END;
      SYSTEM.MOVE(SYSTEM.ADR(d.out[d.outPos]), adr + got, n); INC(d.outPos, n); INC(got, n)
    END
  END;
  RETURN got
END Read;

PROCEDURE Init;
VAR i, k, n, m: LONGINT; D0: ARRAY 512 OF LONGINT; ci: ARRAY 8 OF LONGREAL; t, pi: LONGREAL;
BEGIN
  pi := 3.14159265358979323846D0;
  pow2[0] := 1; i := 1; WHILE i < 25 DO pow2[i] := pow2[i - 1] * 2; INC(i) END;
  n := 0;
  Ints("44100 48000 32000 22050 24000 16000 11025 12000 8000", rateTab, n);
  n := 0;
  Ints("0 32 40 48 56 64 80 96 112 128 160 192 224 256 320 0", brTab, n);
  Ints("0 8 16 24 32 40 48 56 64 80 96 112 128 144 160 0", brTab, n);
  n := 0; Ints("5 6 7 2 3 4 0 0 1", bandOf, n);
  n := 0;
  Ints("6 6 6 6 6 6 8 10 12 14 16 20 24 28 32 38 46 52 60 68 58 54", longW, n);
  Ints("12 12 12 12 12 12 16 20 24 28 32 40 48 56 64 76 90 2 2 2 2 2", longW, n);
  Ints("6 6 6 6 6 6 8 10 12 14 16 20 24 28 32 38 46 52 60 68 58 54", longW, n);
  Ints("6 6 6 6 6 6 8 10 12 14 16 18 22 26 32 38 46 54 62 70 76 36", longW, n);
  Ints("6 6 6 6 6 6 8 10 12 14 16 20 24 28 32 38 46 52 60 68 58 54", longW, n);
  Ints("4 4 4 4 4 4 6 6 8 8 10 12 16 20 24 28 34 42 50 54 76 158", longW, n);
  Ints("4 4 4 4 4 4 6 6 6 8 10 12 16 18 22 28 34 40 46 54 54 192", longW, n);
  Ints("4 4 4 4 4 4 6 6 8 10 12 16 20 24 30 38 46 56 68 84 102 26", longW, n);
  n := 0;
  Ints("4 4 4 6 8 10 12 14 18 24 30 40 18", shortW, n);
  Ints("8 8 8 12 16 20 24 28 36 2 2 2 26", shortW, n);
  Ints("4 4 4 6 6 8 10 14 18 26 32 42 18", shortW, n);
  Ints("4 4 4 6 8 10 12 14 18 24 32 44 12", shortW, n);
  Ints("4 4 4 6 8 10 12 14 18 24 30 40 18", shortW, n);
  Ints("4 4 4 4 6 8 10 12 14 18 22 30 56", shortW, n);
  Ints("4 4 4 4 6 6 10 12 14 16 20 26 66", shortW, n);
  Ints("4 4 4 4 6 8 12 16 20 26 34 42 12", shortW, n);
  n := 0; Ints("0 0 0 0 0 0 0 0 0 0 0 1 1 1 1 2 2 3 3 3 2 0", pretab, n);
  n := 0; Ints("0 0 0 0 3 1 1 1 2 2 2 3 3 3 4 4", slen1, n);
  n := 0; Ints("0 1 2 3 0 1 2 3 1 2 3 1 2 3 2 3", slen2, n);
  n := 0;
  Ints("6 5 5 5 9 9 9 9 6 9 9 9", nrSfb, n);
  Ints("6 5 7 3 9 9 12 6 6 9 12 6", nrSfb, n);
  Ints("11 10 0 0 18 18 0 0 15 18 0 0", nrSfb, n);
  Ints("7 7 7 0 12 12 12 0 6 15 12 0", nrSfb, n);
  Ints("6 6 6 3 12 9 9 6 6 12 9 6", nrSfb, n);
  Ints("8 8 5 0 15 12 9 0 6 18 9 0", nrSfb, n);
  n := 0;
  Ints("0 -15259 -15259 -15259 -15259 -15259 -15259 -30518", D0, n);
  Ints("-30518 -30518 -30518 -45776 -45776 -61035 -61035 -76294", D0, n);
  Ints("-76294 -91553 -106812 -106812 -122070 -137329 -152588 -167847", D0, n);
  Ints("-198364 -213623 -244141 -259399 -289917 -320435 -366211 -396729", D0, n);
  Ints("-442505 -473022 -534058 -579834 -625610 -686646 -747681 -808716", D0, n);
  Ints("-885010 -961304 -1037598 -1113892 -1205444 -1296997 -1388550 -1480103", D0, n);
  Ints("-1586914 -1693726 -1785278 -1907349 -2014160 -2120972 -2243042 -2349854", D0, n);
  Ints("-2456665 -2578735 -2685547 -2792358 -2899170 -2990723 -3082275 -3173828", D0, n);
  Ints("3250122 3326416 3387451 3433228 3463745 3479004 3479004 3463745", D0, n);
  Ints("3417969 3372192 3280640 3173828 3051758 2883911 2700806 2487183", D0, n);
  Ints("2227783 1937866 1617432 1266479 869751 442505 -30518 -549316", D0, n);
  Ints("-1098633 -1693726 -2334595 -3005981 -3723145 -4486084 -5294800 -6118774", D0, n);
  Ints("-7003784 -7919312 -8865356 -9841919 -10848999 -11886597 -12939453 -14022827", D0, n);
  Ints("-15121460 -16235352 -17349243 -18463135 -19577026 -20690918 -21789551 -22857666", D0, n);
  Ints("-23910522 -24932861 -25909424 -26840210 -27725220 -28533936 -29281616 -29937744", D0, n);
  Ints("-30532837 -31005859 -31387329 -31661987 -31814575 -31845093 -31738281 -31478882", D0, n);
  Ints("31082153 30517578 29785156 28884888 27801514 26535034 25085449 23422241", D0, n);
  Ints("21575928 19531250 17257690 14801025 12115479 9231567 6134033 2822876", D0, n);
  Ints("-686646 -4394531 -8316040 -12420654 -16708374 -21179199 -25817871 -30609131", D0, n);
  Ints("-35552979 -40634155 -45837402 -51132202 -56533813 -61996460 -67520142 -73059082", D0, n);
  Ints("-78628540 -84182739 -89706421 -95169067 -100540161 -105819702 -110946655 -115921021", D0, n);
  Ints("-120697021 -125259399 -129562378 -133590698 -137298584 -140670776 -143676758 -146255493", D0, n);
  Ints("-148422241 -150115967 -151306152 -151962280 -152069092 -151596069 -150497437 -148773193", D0, n);
  Ints("-146362305 -143264771 -139450073 -134887695 -129577637 -123474121 -116577148 -108856201", D0, n);
  Ints("100311279 90927124 80688477 69595337 57617188 44784546 31082153 16510010", D0, n);
  Ints("1068115 -15228271 -32379150 -50354004 -69168091 -88775635 -109161377 -130310059", D0, n);
  Ints("-152206421 -174789429 -198059082 -221984863 -246505737 -271591187 -297210693 -323318481", D0, n);
  Ints("-349868774 -376800537 -404083252 -431655884 -459472656 -487472534 -515609741 -543823242", D0, n);
  Ints("-572036743 -600219727 -628295898 -656219482 -683914185 -711318970 -738372803 -765029907", D0, n);
  Ints("-791213989 -816864014 -841949463 -866363525 -890090942 -913055420 -935195923 -956481934", D0, n);
  Ints("-976852417 -996246338 -1014617920 -1031936646 -1048156738 -1063217163 -1077117920 -1089782715", D0, n);
  Ints("-1101211548 -1111373901 -1120223999 -1127746582 -1133926392 -1138763428 -1142211914 -1144287109", D0, n);
  Ints("1144989014 1144287109 1142211914 1138763428 1133926392 1127746582 1120223999 1111373901", D0, n);
  Ints("1101211548 1089782715 1077117920 1063217163 1048156738 1031936646 1014617920 996246338", D0, n);
  Ints("976852417 956481934 935195923 913055420 890090942 866363525 841949463 816864014", D0, n);
  Ints("791213989 765029907 738372803 711318970 683914185 656219482 628295898 600219727", D0, n);
  Ints("572036743 543823242 515609741 487472534 459472656 431655884 404083252 376800537", D0, n);
  Ints("349868774 323318481 297210693 271591187 246505737 221984863 198059082 174789429", D0, n);
  Ints("152206421 130310059 109161377 88775635 69168091 50354004 32379150 15228271", D0, n);
  Ints("-1068115 -16510010 -31082153 -44784546 -57617188 -69595337 -80688477 -90927124", D0, n);
  Ints("100311279 108856201 116577148 123474121 129577637 134887695 139450073 143264771", D0, n);
  Ints("146362305 148773193 150497437 151596069 152069092 151962280 151306152 150115967", D0, n);
  Ints("148422241 146255493 143676758 140670776 137298584 133590698 129562378 125259399", D0, n);
  Ints("120697021 115921021 110946655 105819702 100540161 95169067 89706421 84182739", D0, n);
  Ints("78628540 73059082 67520142 61996460 56533813 51132202 45837402 40634155", D0, n);
  Ints("35552979 30609131 25817871 21179199 16708374 12420654 8316040 4394531", D0, n);
  Ints("686646 -2822876 -6134033 -9231567 -12115479 -14801025 -17257690 -19531250", D0, n);
  Ints("-21575928 -23422241 -25085449 -26535034 -27801514 -28884888 -29785156 -30517578", D0, n);
  Ints("31082153 31478882 31738281 31845093 31814575 31661987 31387329 31005859", D0, n);
  Ints("30532837 29937744 29281616 28533936 27725220 26840210 25909424 24932861", D0, n);
  Ints("23910522 22857666 21789551 20690918 19577026 18463135 17349243 16235352", D0, n);
  Ints("15121460 14022827 12939453 11886597 10848999 9841919 8865356 7919312", D0, n);
  Ints("7003784 6118774 5294800 4486084 3723145 3005981 2334595 1693726", D0, n);
  Ints("1098633 549316 30518 -442505 -869751 -1266479 -1617432 -1937866", D0, n);
  Ints("-2227783 -2487183 -2700806 -2883911 -3051758 -3173828 -3280640 -3372192", D0, n);
  Ints("-3417969 -3463745 -3479004 -3479004 -3463745 -3433228 -3387451 -3326416", D0, n);
  Ints("3250122 3173828 3082275 2990723 2899170 2792358 2685547 2578735", D0, n);
  Ints("2456665 2349854 2243042 2120972 2014160 1907349 1785278 1693726", D0, n);
  Ints("1586914 1480103 1388550 1296997 1205444 1113892 1037598 961304", D0, n);
  Ints("885010 808716 747681 686646 625610 579834 534058 473022", D0, n);
  Ints("442505 396729 366211 320435 289917 259399 244141 213623", D0, n);
  Ints("198364 167847 152588 137329 122070 106812 106812 91553", D0, n);
  Ints("76294 76294 61035 61035 45776 45776 30518 30518", D0, n);
  Ints("30518 30518 15259 15259 15259 15259 15259 15259", D0, n);
  i := 0; WHILE i < 512 DO D[i] := SHORT(D0[i] / 1000000000.0D0); INC(i) END;
  pow43[0] := 0.0; i := 1;
  WHILE i < 8207 DO pow43[i] := SHORT(MathL.exp(MathL.ln(i) * 4.0D0 / 3.0D0)); INC(i) END;
  i := 0; WHILE i < 600 DO pow2q[i] := SHORT(MathL.exp((i - 500) / 4.0D0 * MathL.ln(2.0D0))); INC(i) END;
  i := 0;
  WHILE i < 36 DO
    k := 0;
    WHILE k < 18 DO m := (2 * i + 19) * (2 * k + 1) MOD 144; cosL[i * 18 + k] := SHORT(MathL.cos(pi * m / 72.0D0)); INC(k) END;
    INC(i)
  END;
  i := 0;
  WHILE i < 12 DO
    k := 0;
    WHILE k < 6 DO m := (2 * i + 7) * (2 * k + 1) MOD 48; cosS[i * 6 + k] := SHORT(MathL.cos(pi * m / 24.0D0)); INC(k) END;
    INC(i)
  END;
  i := 0;
  WHILE i < 64 DO
    k := 0;
    WHILE k < 32 DO m := (16 + i) * (2 * k + 1) MOD 128; nm[i * 32 + k] := SHORT(MathL.cos(pi * m / 64.0D0)); INC(k) END;
    INC(i)
  END;
  i := 0;
  WHILE i < 36 DO
    t := MathL.sin(pi / 36.0D0 * (i + 0.5D0));
    win[0, i] := SHORT(t);
    IF i < 18 THEN win[1, i] := SHORT(t) ELSIF i < 24 THEN win[1, i] := 1.0
    ELSIF i < 30 THEN win[1, i] := SHORT(MathL.sin(pi / 12.0D0 * (i - 18 + 0.5D0))) ELSE win[1, i] := 0.0
    END;
    IF i < 6 THEN win[3, i] := 0.0 ELSIF i < 12 THEN win[3, i] := SHORT(MathL.sin(pi / 12.0D0 * (i - 6 + 0.5D0)))
    ELSIF i < 18 THEN win[3, i] := 1.0 ELSE win[3, i] := SHORT(t)
    END;
    IF i < 12 THEN win[2, i] := SHORT(MathL.sin(pi / 12.0D0 * (i + 0.5D0))) ELSE win[2, i] := 0.0 END;
    INC(i)
  END;
  ci[0] := -0.6D0; ci[1] := -0.535D0; ci[2] := -0.33D0; ci[3] := -0.185D0;
  ci[4] := -0.095D0; ci[5] := -0.041D0; ci[6] := -0.0142D0; ci[7] := -0.0037D0;
  i := 0;
  WHILE i < 8 DO
    t := MathL.sqrt(1.0D0 + ci[i] * ci[i]); cs[i] := SHORT(1.0D0 / t); ca[i] := SHORT(ci[i] / t); INC(i)
  END;
  i := 0;
  WHILE i < 6 DO
    t := MathL.sin(pi * i / 12.0D0) / MathL.cos(pi * i / 12.0D0);
    isL[i] := SHORT(t / (1.0D0 + t)); isR[i] := SHORT(1.0D0 / (1.0D0 + t)); INC(i)
  END;
  isL[6] := 1.0; isR[6] := 0.0;
  loaded := FALSE; lastError := ""
END Init;

BEGIN
  Init
END MPEGAudio0.
