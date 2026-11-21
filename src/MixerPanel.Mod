MODULE MixerPanel;  (** a panel with the controls of the mixer, made from the mixer channels of Sound *)

(* MixerPanel.Open shows a panel with a row for each mixer channel of Sound (a control of the mixer of the
   card): its name, a slider for each value of a volume or a choice, a check box for each value of a
   switch. A stereo volume has a check box "both" at the end of its row: while it is set, either slider
   moves the other one too. The sliders and boxes call MixerPanel.SetVolume and MixerPanel.SetBox, the
   commands of the mixer panels of Native Oberon. *)

IMPORT Modules, Objects, Display, Texts, Oberon, Gadgets, Attributes, Panels, Documents, PanelDocs, Desktops,
  DocWindows, Windows, Sound;

CONST
  Row = 26;  (* the height of a row *)
  NameW = 250;  (* the width of the names *)
  SliderW = 130;

PROCEDURE Add(P: Panels.Panel; gen, name: ARRAY OF CHAR; x, y, w, h: INTEGER): Display.Frame;
VAR obj: Objects.Object; F: Display.Frame;
BEGIN
  obj := Gadgets.CreateObject(gen); F := obj(Display.Frame);
  F.W := w; F.H := h;
  Panels.InsertChild(P, F, x, y - h);
  IF name # "" THEN Gadgets.NameObj(F, name) END;
  RETURN F
END Add;

PROCEDURE Caption(P: Panels.Panel; text: ARRAY OF CHAR; x, y: INTEGER);
VAR F: Display.Frame;
BEGIN
  F := Add(P, "TextFields.NewCaption", "", x, y, NameW, 20); Attributes.SetString(F, "Value", text)
END Caption;

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
  i := 0; REPEAT d[i] := CHR(x MOD 10 + 30H); x := x DIV 10; INC(i) UNTIL x = 0;
  t[1] := 0X; WHILE i > 0 DO DEC(i); t[0] := d[i]; Append(s, t) END
END AppendInt;

(* the name of the gadget of subchannel sc of channel c ("C3S1"), or of its box "both" (sc = -1: "B3") *)
PROCEDURE Name(c, sc: LONGINT; VAR s: ARRAY OF CHAR);
BEGIN
  IF sc < 0 THEN COPY("B", s); AppendInt(s, c) ELSE COPY("C", s); AppendInt(s, c); Append(s, "S"); AppendInt(s, sc) END
END Name;

(* the command of a gadget: cmd c sc and the rest *)
PROCEDURE Cmd(cmd: ARRAY OF CHAR; c, sc: LONGINT; rest: ARRAY OF CHAR; VAR s: ARRAY OF CHAR);
BEGIN
  COPY(cmd, s); Append(s, " "); AppendInt(s, c); Append(s, " "); AppendInt(s, sc); Append(s, " "); Append(s, rest)
END Cmd;

(** MixerPanel.NewDoc  the generator of the document (in Objects.NewObj): the panel *)
PROCEDURE NewDoc*;
VAR D: Documents.Document; P: Panels.Panel; F: Display.Frame; n, c, sc, val, l, r: LONGINT;
  ch: Sound.Channel; sub: Sound.SubChannel; name, cmd, both: ARRAY 64 OF CHAR; y: INTEGER; stereo: BOOLEAN;
BEGIN
  n := Sound.GetNofChannels();
  PanelDocs.NewDoc; D := Objects.NewObj(Documents.Document);
  D.name := "Mixer"; D.W := NameW + 2 * SliderW + 90; D.H := SHORT(n * Row + 50);
  P := D.dsc(Panels.Panel); P.W := D.W; P.H := D.H;
  IF n = 0 THEN Caption(P, "no mixer (see System.Log)", 10, -10) ELSE Caption(P, "Mixer", 10, -10) END;
  c := 0; y := -40;
  WHILE c < n DO
    ch.Ch := c; Sound.GetChCapas(ch); Caption(P, ch.name, 10, y);
    stereo := FALSE; sc := 0;
    WHILE sc < ch.nofSubCh DO
      sub.Ch := c; sub.SubCh := sc; Sound.GetSubChCapas(sub); Sound.GetValue(c, sc, val); Name(c, sc, name);
      IF sub.maxval = 0 THEN
        F := Add(P, "BasicGadgets.NewCheckBox", name, SHORT(NameW + 20 + sc * 30), y, 20, 20);
        Attributes.SetBool(F, "Value", val # 0);
        Cmd("MixerPanel.SetBox", c, sc, "#Value", cmd); Attributes.SetString(F, "Cmd", cmd)
      ELSE
        F := Add(P, "BasicGadgets.NewSlider", name, SHORT(NameW + 20 + sc * (SliderW + 10)), y, SliderW, 20);
        Attributes.SetInt(F, "Min", 0); Attributes.SetInt(F, "Max", sub.maxval); Attributes.SetInt(F, "Value", val);
        IF ch.nofSubCh = 2 THEN stereo := TRUE; Name(c, -1, cmd); both := "#Value &"; Append(both, cmd); Append(both, ".Value")
        ELSE both := "#Value"
        END;
        Cmd("MixerPanel.SetVolume", c, sc, both, cmd); Attributes.SetString(F, "Cmd", cmd)
      END;
      INC(sc)
    END;
    IF stereo THEN
      Sound.GetValue(c, 0, l); Sound.GetValue(c, 1, r); Name(c, -1, name);
      F := Add(P, "BasicGadgets.NewCheckBox", name, NameW + 20 + 2 * (SliderW + 10), y, 20, 20);
      Attributes.SetBool(F, "Value", l = r)
    END;
    INC(c); DEC(y, Row)
  END;
  Attributes.SetBool(P, "Locked", TRUE);
  Objects.NewObj := D
END NewDoc;

(** MixerPanel.Open  the panel: in a viewer of the desktop, or in a window of its own from the shell *)
PROCEDURE Open*;
VAR D: Documents.Document; V: Windows.Window;
BEGIN
  NewDoc; D := Objects.NewObj(Documents.Document);
  IF Modules.FindMod("System") # NIL THEN Desktops.ShowDoc(D)
  ELSE V := DocWindows.Open(D); Windows.Run(V)
  END
END Open;

(* the value of a slider of the panel of the command *)
PROCEDURE Show(c, sc, val: LONGINT);
VAR obj: Objects.Object; name: ARRAY 16 OF CHAR;
BEGIN
  Name(c, sc, name); obj := Gadgets.FindObj(Gadgets.context, name);
  IF obj # NIL THEN Attributes.SetInt(obj, "Value", val); Gadgets.Update(obj) END
END Show;

(** MixerPanel.SetVolume c sc val [Yes]  sets subchannel sc of channel c to val; with Yes the other
  subchannel of a stereo channel too *)
PROCEDURE SetVolume*;
VAR S: Texts.Scanner; c, sc, val: LONGINT;
BEGIN
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
  IF S.class # Texts.Int THEN RETURN END;
  c := S.i; Texts.Scan(S); IF S.class # Texts.Int THEN RETURN END;
  sc := S.i; Texts.Scan(S); IF S.class # Texts.Int THEN RETURN END;
  val := S.i; Sound.SetValue(c, sc, val); Texts.Scan(S);
  IF (S.class = Texts.Name) & (S.s = "Yes") & ((sc = 0) OR (sc = 1)) THEN Sound.SetValue(c, 1 - sc, val); Show(c, 1 - sc, val) END
END SetVolume;

(** MixerPanel.SetBox c sc Yes|No  switches subchannel sc of channel c on or off *)
PROCEDURE SetBox*;
VAR S: Texts.Scanner; c, sc: LONGINT;
BEGIN
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
  IF S.class # Texts.Int THEN RETURN END;
  c := S.i; Texts.Scan(S); IF S.class # Texts.Int THEN RETURN END;
  sc := S.i; Texts.Scan(S);
  IF (S.class = Texts.Name) & (S.s = "Yes") THEN Sound.SetValue(c, sc, 1) ELSE Sound.SetValue(c, sc, 0) END
END SetBox;

END MixerPanel.
