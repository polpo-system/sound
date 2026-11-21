MODULE Sound;  (** the interface of Sound of Native Oberon (audio and mixer), on Sound0 *)

(* Native Oberon drove a SoundBlaster: blocks of data queued with AddBlock went to the card by DMA, and
   the interrupt handler asked for more blocks through the trigger of the AudioDef. Here an Oberon task
   gives the queued blocks to the device of Sound0 (or fills them when recording) and calls the trigger
   the same way, so Wave and other programs of Native Oberon run unchanged. The mixer channels are the
   controls of the mixer of Sound0, one channel for each, a subchannel for each of its values. There is
   no CD audio: its procedures answer NotOpened. The device is Sound.Device of Oberon.Text, else the
   default of Sound0. *)

IMPORT SYSTEM, Input, Texts, Oberon, Sound0;

CONST
  DBdataSize* = 32768;

  (** result codes *)
  Done* = 0;  (** call succeeded *)
  Failed* = 1;  (** call failed *)
  NotOpened* = 2;  (** device isn't opened *)
  NotRunning* = 3;  (** device is not running (playing or recording) *)
  NSStereo* = 6;  (** stereo mode is not supported with this soundcard *)
  NS16bit* = 7;  (** 16 bit is not supported with this soundcard *)
  NSFreq* = 8;  (** frequency is not supported with this soundcard *)
  NSSignedData* = 9;  (** signed data is not supported with this soundcard *)

  (** format *)
  PCM* = 0;
  ADPCM8b2b* = 1;
  ADPCM8b3b* = 2;
  ADPCM8b4b* = 3;

  (** devState bits of Audio and CD *)
  opened* = 0;
  playing* = 1;
  recording* = 2;
  paused* = 3;
  stopped* = 4;
  mediapresent* = 5;  (** only in use with CD *)

  Full = 64;  (* a recorded block with less room is full *)

TYPE
  Trigger* = PROCEDURE (end: BOOLEAN);

  AudioDef* = RECORD  (** defines how to play or record the audio file *)
    format*: INTEGER;  (** PCM, ADPCMxbxb *)
    stereo*, signed*: BOOLEAN;
    bits*: INTEGER;  (** 8 / 16 bits *)
    freq*: LONGINT;
    blocks*: LONGINT;  (** number of transfer blocks needed for the audio file to play *)
    handle*: Trigger
  END;

  Channel* = RECORD  (** mixer channel capabilities and description *)
    name*: ARRAY 32 OF CHAR;
    Ch*, nofSubCh*: LONGINT
  END;

  SubChannel* = RECORD  (** mixer subchannel capabilities and description *)
    name*: ARRAY 32 OF CHAR;
    Ch*, SubCh*, maxval*: LONGINT  (** maxval = 0: use a checkbox, else a slider *)
  END;

  DataBlock* = POINTER TO DataBlockDesc;
  DataBlockDesc* = RECORD
    data*: ARRAY DBdataSize OF SYSTEM.BYTE;
    len*: LONGINT;
    next: DataBlock
  END;

VAR
  res*: INTEGER;
  dev: Sound0.Device;
  mixer: Sound0.Mixer;
  curAF: AudioDef;
  audioState: SET;
  first, last: DataBlock;  (* the queue *)
  pos, nofbuf, bufcnt: LONGINT;  (* offset in first, blocks queued, blocks done *)
  task: Oberon.Task;
  none: ARRAY 1 OF CHAR;
  device: ARRAY 64 OF CHAR;
  W: Texts.Writer;

PROCEDURE Log(s: ARRAY OF CHAR);
BEGIN
  Texts.WriteString(W, "Sound: "); Texts.WriteString(W, s); Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
END Log;

PROCEDURE Device;
VAR S: Texts.Scanner;
BEGIN
  Oberon.OpenScanner(S, "Sound.Device");
  IF (S.class = Texts.Name) OR (S.class = Texts.String) THEN COPY(S.s, device) ELSE device := "" END
END Device;

(** Mixer *)

PROCEDURE OpenMixer(): BOOLEAN;
BEGIN
  IF mixer = NIL THEN
    Device;
    IF ~Sound0.OpenMixer(device, mixer) THEN Log(Sound0.lastError); mixer := NIL END
  END;
  RETURN mixer # NIL
END OpenMixer;

(** GetNofChannels: returns number of usable mixer channels *)
PROCEDURE GetNofChannels*(): LONGINT;
BEGIN
  res := Done;
  IF ~OpenMixer() THEN res := Failed; RETURN 0 END;
  RETURN mixer.n
END GetNofChannels;

PROCEDURE GetChCapas*(VAR c: Channel);
BEGIN
  IF ~OpenMixer() OR (c.Ch < 0) OR (c.Ch >= mixer.n) THEN res := Failed; RETURN END;
  res := Done; COPY(mixer.c[c.Ch].name, c.name); c.nofSubCh := mixer.c[c.Ch].count
END GetChCapas;

PROCEDURE GetSubChCapas*(VAR sc: SubChannel);
VAR k: LONGINT;
BEGIN
  IF ~OpenMixer() OR (sc.Ch < 0) OR (sc.Ch >= mixer.n) OR (sc.SubCh < 0) OR (sc.SubCh >= mixer.c[sc.Ch].count) THEN
    res := Failed; RETURN
  END;
  res := Done; k := sc.Ch;
  IF mixer.c[k].count = 1 THEN sc.name := "" ELSIF sc.SubCh = 0 THEN sc.name := "left" ELSIF sc.SubCh = 1 THEN sc.name := "right"
  ELSE sc.name := "value"
  END;
  IF mixer.c[k].kind = Sound0.Switch THEN sc.maxval := 0 ELSE sc.maxval := mixer.c[k].max - mixer.c[k].min END
END GetSubChCapas;

PROCEDURE GetValue*(c, sc: LONGINT; VAR val: LONGINT);
BEGIN
  IF ~OpenMixer() OR (c < 0) OR (c >= mixer.n) THEN res := Failed; RETURN END;
  val := Sound0.GetValue(mixer, c, sc);
  IF val = MIN(LONGINT) THEN res := Failed; val := 0 ELSE res := Done; DEC(val, mixer.c[c].min) END
END GetValue;

PROCEDURE SetValue*(c, sc, val: LONGINT);
BEGIN
  IF ~OpenMixer() OR (c < 0) OR (c >= mixer.n) THEN res := Failed; RETURN END;
  IF Sound0.SetValue(mixer, c, sc, val + mixer.c[c].min) THEN res := Done ELSE res := Failed END
END SetValue;

(** Audio *)

PROCEDURE CloseDevice;
BEGIN
  IF task # NIL THEN Oberon.Remove(task); task := NIL END;
  IF dev # NIL THEN Sound0.Close(dev); dev := NIL END
END CloseDevice;

(* the end of playing or recording: the trigger is called with TRUE *)
PROCEDURE Ended;
BEGIN
  CloseDevice; audioState := {opened, stopped};
  IF curAF.handle # NIL THEN curAF.handle(TRUE) END
END Ended;

PROCEDURE Play;
VAR n: LONGINT;
BEGIN
  WHILE first # NIL DO
    n := Sound0.WriteSome(dev, first.data, pos, first.len - pos);
    IF n < 0 THEN Log(Sound0.lastError); Ended; RETURN END;
    INC(pos, n);
    IF pos < first.len THEN RETURN END;
    first := first.next; pos := 0; INC(bufcnt); DEC(nofbuf);
    IF first = NIL THEN last := NIL END;
    IF (curAF.blocks - bufcnt > nofbuf) & (nofbuf < 2) & (curAF.handle # NIL) THEN curAF.handle(FALSE) END
  END;
  IF Sound0.WriteSome(dev, none, 0, 0) < 0 THEN Log(Sound0.lastError); Ended; RETURN END;  (* what Sound0 holds *)
  IF bufcnt >= curAF.blocks THEN
    IF Sound0.Delay(dev) <= 0 THEN Ended END
  ELSIF curAF.handle # NIL THEN curAF.handle(FALSE)
  END
END Play;

PROCEDURE Record;
VAR n: LONGINT;
BEGIN
  WHILE first # NIL DO
    n := Sound0.ReadSome(dev, first.data, first.len, DBdataSize - first.len);
    IF n < 0 THEN Log(Sound0.lastError); Ended; RETURN END;
    INC(first.len, n);
    IF DBdataSize - first.len >= Full THEN RETURN END;
    first := first.next; INC(bufcnt); DEC(nofbuf);
    IF first = NIL THEN last := NIL END;
    IF (nofbuf < 2) & (curAF.handle # NIL) THEN curAF.handle(FALSE) END
  END;
  IF curAF.handle # NIL THEN curAF.handle(FALSE) END
END Record;

PROCEDURE Handler(me: Oberon.Task);
BEGIN
  IF (dev # NIL) & ~(paused IN audioState) THEN
    IF playing IN audioState THEN Play ELSIF recording IN audioState THEN Record END
  END;
  IF task # NIL THEN task.time := Oberon.Time() + Input.TimeUnit DIV 100 END
END Handler;

PROCEDURE Start(capture: BOOLEAN): BOOLEAN;
VAR ch: LONGINT;
BEGIN
  IF curAF.stereo THEN ch := 2 ELSE ch := 1 END;
  Device;
  IF ~Sound0.Open(device, capture, curAF.freq, ch, curAF.bits, dev) THEN Log(Sound0.lastError); dev := NIL; RETURN FALSE END;
  NEW(task); task.safe := FALSE; task.handle := Handler; task.time := Oberon.Time();
  Oberon.Install(task);
  RETURN TRUE
END Start;

PROCEDURE StopAudio*();
BEGIN
  res := Done;
  IF opened IN audioState THEN
    IF ~(stopped IN audioState) OR (paused IN audioState) THEN
      IF dev # NIL THEN Sound0.Drop(dev) END;
      IF (recording IN audioState) & (first # NIL) & (first.len > 0) THEN first := first.next; INC(bufcnt) END;
      Ended
    ELSE res := NotRunning
    END
  ELSE res := NotOpened
  END
END StopAudio;

PROCEDURE CloseAudio*();
BEGIN
  res := Done;
  IF opened IN audioState THEN
    IF ~(stopped IN audioState) THEN StopAudio() END;
    CloseDevice; audioState := {};
    nofbuf := 0; first := NIL; last := NIL
  END
END CloseAudio;

PROCEDURE OpenAudio*(VAR d: AudioDef);
BEGIN
  res := Done;
  IF opened IN audioState THEN res := Failed
  ELSIF d.format # PCM THEN res := Failed
  ELSIF (d.bits # 8) & (d.bits # 16) THEN res := NS16bit
  ELSIF (d.freq < 1000) OR (d.freq > 384000) THEN res := NSFreq
  ELSIF (d.bits = 16) & ~d.signed OR (d.bits = 8) & d.signed THEN res := NSSignedData
  ELSE
    curAF := d; audioState := {opened, stopped};
    bufcnt := 0; nofbuf := 0; pos := 0; first := NIL; last := NIL
  END
END OpenAudio;

PROCEDURE PlayAudio*();
BEGIN
  res := Done;
  IF ~(opened IN audioState) THEN res := NotOpened
  ELSIF ~(stopped IN audioState) THEN res := Failed
  ELSIF ~Start(FALSE) THEN res := Failed
  ELSE audioState := {opened, playing}
  END
END PlayAudio;

PROCEDURE RecordAudio*();
BEGIN
  res := Done;
  IF ~(opened IN audioState) THEN res := NotOpened
  ELSIF ~(stopped IN audioState) THEN res := Failed
  ELSIF ~Start(TRUE) THEN res := Failed
  ELSE audioState := {opened, recording}
  END
END RecordAudio;

PROCEDURE PauseAudio*();
BEGIN
  IF ~(opened IN audioState) THEN res := NotOpened
  ELSIF paused IN audioState THEN res := Failed
  ELSIF ~(stopped IN audioState) THEN
    IF dev # NIL THEN Sound0.Pause(dev, TRUE) END;
    INCL(audioState, paused); res := Done
  ELSE res := NotRunning
  END
END PauseAudio;

PROCEDURE ResumeAudio*();
BEGIN
  IF ~(opened IN audioState) THEN res := NotOpened
  ELSIF paused IN audioState THEN
    IF dev # NIL THEN Sound0.Pause(dev, FALSE) END;
    EXCL(audioState, paused); res := Done
  ELSE res := Failed
  END
END ResumeAudio;

PROCEDURE AddBlock*(buf: DataBlock);
BEGIN
  ASSERT(buf # NIL);
  buf.next := NIL;
  IF last = NIL THEN first := buf; pos := 0 ELSE last.next := buf END;
  last := buf; INC(nofbuf)
END AddBlock;

PROCEDURE GetAudioPos*(VAR msec: LONGINT);
BEGIN
  res := Done;
  IF ~(opened IN audioState) THEN res := NotOpened; msec := 0
  ELSIF dev = NIL THEN msec := 0
  ELSIF dev.capture THEN msec := ENTIER(dev.frames / curAF.freq * 1000)
  ELSE msec := ENTIER(Sound0.Played(dev) / curAF.freq * 1000)
  END
END GetAudioPos;

PROCEDURE GetAudioState*(): SET;
BEGIN
  res := Done;
  RETURN audioState
END GetAudioState;

(** CD: no CD audio *)

PROCEDURE CloseCD*();
BEGIN res := NotOpened
END CloseCD;

PROCEDURE OpenCD*();
BEGIN res := Failed
END OpenCD;

PROCEDURE NrOfCDTracks*(): INTEGER;
BEGIN res := NotOpened; RETURN 0
END NrOfCDTracks;

PROCEDURE CDTrackInfo*(track: INTEGER; VAR min, sec: INTEGER);
BEGIN res := NotOpened; min := 0; sec := 0
END CDTrackInfo;

PROCEDURE StopCD*();
BEGIN res := NotOpened
END StopCD;

PROCEDURE CloseDoor*();
BEGIN res := NotOpened
END CloseDoor;

PROCEDURE OpenDoor*();
BEGIN res := NotOpened
END OpenDoor;

PROCEDURE PlayCD*(track0, min0, sec0, track1, min1, sec1: INTEGER);
BEGIN res := NotOpened
END PlayCD;

PROCEDURE PauseCD*();
BEGIN res := NotOpened
END PauseCD;

PROCEDURE ResumeCD*();
BEGIN res := NotOpened
END ResumeCD;

PROCEDURE GetCDState*(): SET;
BEGIN res := NotOpened; RETURN {}
END GetCDState;

PROCEDURE GetCDPos*(VAR track, min, sec: INTEGER);
BEGIN res := NotOpened; track := 0; min := 0; sec := 0
END GetCDPos;

BEGIN
  Texts.OpenWriter(W); res := Done; audioState := {}; dev := NIL; mixer := NIL; task := NIL;
  first := NIL; last := NIL
END Sound.
