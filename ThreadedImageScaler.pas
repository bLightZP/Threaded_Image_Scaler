unit ThreadedImageScaler;

interface


uses
  Windows, Messages, SysUtils, StdCtrls, Variants, Classes, Graphics, Controls, ActiveX, syncobjs,
  Dialogs, ExtCtrls, GDIPAPI ,GDIPOBJ;


const
  threadStateCreated    = 0;
  threadStateWaiting    = 1;
  threadStateProcessing = 2;
  threadStateCleanup    = 254;
  threadStateFinished   = 255;
  //threadStateSynched    = 256;

type
  // Meta-data scraping record
  TImageScalerRecord =
  Record
    scaleIconWidth    : Integer;
    scaleIconHeight   : Integer;
    scaleIconID       : Integer;
    scaleIconFileName : String;
  End;
  PImageScalerRecord = ^TImageScalerRecord;

  TSyncRecord =
  Record
    syncIconID               : Integer;
    syncIconData             : TGPBitmap;
  End;
  PSyncRecord = ^TSyncRecord;

  TImageScalerManagerThread = Class(TThread)
    procedure Execute; override;
  private
    FAbortSync      : Boolean;
    FEvent          : THandle;
    FSyncAddCS      : TCriticalSection;
    FSyncGetCS      : TCriticalSection;
    threadList      : TList;
    queueList       : TList; // Queue list, protected by a CriticalSection
    procList        : TList; // Processing list
    syncList        : TList; // Sync list, protected by a CriticalSection
  public
    ThreadState     : Integer;
    maxScalers      : Integer; // Maximum active scaling threads
    procedure AddEntry(iconSourceID, iconWidth, iconHeight : Integer; iconFileName : String);

    procedure ClearEntries;
    procedure StartProcessing;
    function  GetUpdates : Boolean;
  end;

  TImageScalerThread = Class(TThread)
    procedure Execute; override;
  private
  public
    fIconData     : TGPBitmap;
    fIconWidth    : Integer;
    fIconHeight   : Integer;
    fIconID       : Integer;
    fIconFileName : String;
    ThreadState   : Integer;
    constructor Create(const iconID, iconWidth, iconHeight : Integer; iconFileName : String);
  end;


implementation

uses
  ShellAPI, math, mainunit;


// GDI+ helper functions

function GDIPLoadBitmapFromStream(AStream: TStream) : TGPBitmap;
var
  LImg: TGPBitmap;
begin
  Result := nil;
  if (AStream = nil) then Exit;
  Result := TGPBitmap.Create(TStreamAdapter.Create(AStream) as IStream);
end;


function GDIPScaleGPBitmapToGDBitmapMaintainAR(AImg: TGPBitmap; AMaxWidth, AMaxHeight: Integer): TGPBitmap;
var
  LGraphics: TGPGraphics;
  LOrgWidth, LOrgHeight: Integer;
  LNewWidth, LNewHeight: Integer;
  LScale, LScaleX, LScaleY: Double;
  LDestBitmap: TGPBitmap;
begin
  Result := nil;

  If (AImg = nil) or (AMaxWidth <= 0) or (AMaxHeight <= 0) then
    Exit;

  // Get original image dimensions
  LOrgWidth  := AImg.GetWidth;
  LOrgHeight := AImg.GetHeight;

  If (LOrgWidth <= 0) or (LOrgHeight <= 0) then
    Exit;

  // Calculate new dimensions maintaining Aspect Ratio (AR)
  LScaleX    := AMaxWidth  / LOrgWidth;
  LScaleY    := AMaxHeight / LOrgHeight;

  // Choose the smallest scale factor to ensure the image fits within the bounds
  LScale     := Min(LScaleX, LScaleY);

  LNewWidth  := Round(LOrgWidth * LScale);
  LNewHeight := Round(LOrgHeight * LScale);

  // Guard against zero dimensions from rounding errors
  if LNewWidth  = 0 then LNewWidth  := 1;
  If LNewHeight = 0 then LNewHeight := 1;

  // Create the destination GDI+ TGPBitmap with full alpha channel support
  LDestBitmap := TGPBitmap.Create(LNewWidth, LNewHeight, PixelFormat32bppARGB);
  
  if LDestBitmap = nil then
    Exit;

  // Create a GDI+ Graphics object from the new GDI+ Bitmap
  LGraphics := TGPGraphics.Create(LDestBitmap);
  
  if LGraphics = nil then
  begin
    LDestBitmap.Free;
    Exit;
  end;

  try
    // Set high-quality scaling properties
    LGraphics.SetInterpolationMode(InterpolationModeHighQualityBicubic);
    LGraphics.SetCompositingQuality(CompositingQualityHighQuality);
    LGraphics.SetPixelOffsetMode(PixelOffsetModeHalf);
    LGraphics.SetCompositingMode(CompositingModeSourceCopy);

    // Draw the scaled image onto the destination bitmap
    LGraphics.DrawImage(
      AImg,
      MakeRect(0.0, 0.0, LNewWidth, LNewHeight), // Destination rectangle
      0, 0, LOrgWidth, LOrgHeight,               // Source rectangle
      UnitPixel                                  // Unit of measure
    );

    Result := LDestBitmap;
  finally
    LGraphics.Free;
  end;
end;


// Worker thread

constructor TImageScalerThread.Create(const iconID, iconWidth, iconHeight : Integer; iconFileName : String);
begin
  inherited Create(True);

  Priority        := tpIdle;
  FreeOnTerminate := False;
  ThreadState     := threadStateCreated;
  fIconData       := nil;
  fIconWidth      := iconWidth;
  fIconHeight     := iconHeight;
  fIconFileName   := iconFileName;
  fIconID         := iconID;

  Resume;
end;


procedure TImageScalerThread.Execute;
var
  I                : Integer;
  mStream          : TMemoryStream;
  sExt             : String;

  procedure GetFileFromCache(var sFile : String; var memStream : TMemoryStream);
  var
    dlStatus : String;
  begin
    If FileExists(sFile) = True then
    Begin
      // Try using cached file
      Try memStream.LoadFromFile(sFile); Except memStream.Clear; End;
    End;
  end; // GetFileFromCacheOrDownload


  procedure DecodeAndResizeImage(var memStream : TMemoryStream);
  var
    syncGDIImage     : TGPBitmap;
  begin
    // Decode & Scale the images
    syncGDIImage := GDIPLoadBitmapFromStream(memStream);
    If (syncGDIImage <> nil) then
    Begin
      // Resize GDI+ image
      If Terminated = False then
        fIconData := GDIPScaleGPBitmapToGDBitmapMaintainAR(syncGDIImage,fIconWidth, fIconHeight);
      syncGDIImage.Free;
    End;
  end; // DecodeAndResizeImage


begin
  mStream    := TMemoryStream.Create;

  GetFileFromCache(fIconFileName,mStream);

  If (mStream.Size > 0) and (Terminated = False) then
    DecodeAndResizeImage(mStream);

  mStream.Free;
  ThreadState := threadStateFinished;
end;


// Thread Manager thread

procedure TImageScalerManagerThread.Execute;
var
  I              : Integer;
  iComplete      : Integer;
  syncEntry      : PSyncRecord;

  procedure WaitForScalingThreads;
  var
    I         : Integer;
    iComplete : Integer;
  begin
    Repeat
      iComplete := 0;
      For I := 0 to threadList.Count-1 do
        If TImageScalerThread(threadList[I]).ThreadState = threadStateFinished then
           Inc(iComplete);
       If iComplete <> threadList.Count then Sleep(1);
    Until (iComplete = threadList.Count);
  End;

  procedure ClearScalingThreads;
  var
    I : Integer;
  begin
    For I := 0 to threadList.Count-1 do
    Begin
      If TImageScalerThread(threadList[I]).fIconData <> nil then
        TImageScalerThread(threadList[I]).fIconData.Free;

      TImageScalerThread(threadList[I]).Free;
    End;
    threadList.Clear;
  End;

begin
  FreeOnTerminate    := False;
  FAbortSync         := False;
  Priority           := tpIdle;
  ThreadState        := threadStateCreated;

  maxScalers         := 2; // maximum number of active scaling threads

  fSyncAddCS         := TCriticalSection.Create;
  fSyncGetCS         := TCriticalSection.Create;
  threadList         := TList.Create;
  procList           := TList.Create;
  queueList          := TList.Create;
  syncList           := TList.Create;

  FEvent             := CreateEvent(nil,
                          False,    // auto reset
                          False,    // initial state = not signaled
                          nil);

  // Waiting on initial use
  ThreadState := threadStateWaiting;
  WaitForSingleObject(FEvent, INFINITE);
  ThreadState := threadStateProcessing;

  Repeat
    // Add items to processing list queue, new items first (for better update responsiveness)
    fSyncAddCS.Enter;
    Try
      For I := queueList.Count-1 downto 0 do
        procList.Insert(0,queueList[I]);
      queueList.Clear;
    Finally
      fSyncAddCS.Leave;
    End;

    // Start processing
    While (Terminated = False) and (fAbortSync = False) and (procList.Count > 0) and (threadList.Count < maxScalers) do
    Begin
      // Create worker threads
      With PImageScalerRecord(procList[0])^ do
      Begin
        threadList.Add(
          TImageScalerThread.Create(
            scaleIconID,
            scaleIconWidth,
            scaleIconHeight,
            scaleIconFileName));
      End;
      Dispose(PImageScalerRecord(procList[0]));
      procList.Delete(0);
    End;

    // Wait for some threads to complete
    If (FAbortSync = False) and (Terminated = False) and (threadList.Count > 0) then
    Begin
      iComplete := 0;
      For I := 0 to threadList.Count-1 do
        If TImageScalerThread(threadList[I]).ThreadState = threadStateFinished then
          Inc(iComplete);

      // At least one thread is done, sync updates
      If (iComplete > 0) then
      Begin
        fSyncGetCS.Enter;
        Try
          // Process and Clear completed threads
          For I := threadList.Count-1 downto 0 do
            If TImageScalerThread(threadList[I]).ThreadState = threadStateFinished then
          Begin
            // Add sync entry
            If TImageScalerThread(threadList[I]).fIconData <> nil then
            Begin
              New(syncEntry);
              syncEntry^.syncIconID   := TImageScalerThread(threadList[I]).fIconID;
              syncEntry^.syncIconData := TImageScalerThread(threadList[I]).fIconData;
              syncList.Insert(0,syncEntry);
            End;

            // Release thread
            TImageScalerThread(threadList[I]).Free;
            threadList.Delete(I);
          End;
        Finally
          fSyncGetCS.Leave;
        End;
      End;
    End;

    If (FAbortSync = True) and (Terminated = False) then
    Begin
      // Aborting, clear everything
      If threadList.Count > 0 then
      Begin
        WaitForScalingThreads;
        ClearScalingThreads;
      End;

      // Clear processing list
      For I := 0 to procList.Count-1 do
        Dispose(PImageScalerRecord(procList[I]));
      procList.Clear;


      // Clear queue list
      fSyncAddCS.Enter;
      Try
        For I := queueList.Count-1 downto 0 do
          Dispose(PImageScalerRecord(queueList[I]));
        queueList.Clear;
      Finally
        fSyncAddCS.Leave;
      End;

      // Clear sync list
      fSyncGetCS.Enter;
      Try
        For I := 0 to syncList.Count-1 do
          Dispose(PSyncRecord(syncList[I]));
        syncList.Clear;
      Finally
        fSyncGetCS.Leave;
      End;

      FAbortSync := False;
    End;

    // Wait for next event
    If Terminated = False then
    Begin
      If (threadList.Count = 0) and (procList.Count = 0) then
      Begin
        ThreadState := threadStateWaiting;
        WaitForSingleObject(FEvent, INFINITE);
        ThreadState := threadStateProcessing;
      End
        else
      Begin
        // Threads still working, wait a bit to let them process more and check again
        ThreadState := threadStateWaiting;
        WaitForSingleObject(FEvent, 25);
        ThreadState := threadStateProcessing;
      End;
    End;
  Until (Terminated = True);


  // Wait and clear any remaining threads (due to early termination)
  If threadList.Count > 0 then
  Begin
    // Terminate scraping threads
    For I := 0 to threadList.Count-1 do
      TImageScalerThread(threadList[I]).Terminate;

    WaitForScalingThreads;
    ClearScalingThreads;
  End;
  ThreadState := threadStateCleanup;

  CloseHandle(fEvent);
  threadList.Free;

  For I := 0 to procList.Count-1 do
    Dispose(PImageScalerRecord(procList[I]));
  procList.Free;

  For I := 0 to queueList.Count-1 do
    Dispose(PImageScalerRecord(queueList[I]));
  queueList.Free;

  For I := 0 to syncList.Count-1 do
    Dispose(PSyncRecord(syncList[I]));
  syncList.Free;

  fSyncGetCS.Free;
  fSyncAddCS.Free;

  FAbortSync  := False; // Safety measure

  ThreadState := threadStateFinished;
end;


procedure TImageScalerManagerThread.StartProcessing;
begin
  SetEvent(FEvent);
end;


procedure TImageScalerManagerThread.AddEntry(iconSourceID, iconWidth, iconHeight : Integer; iconFileName : String);
var
  nEntry : PImageScalerRecord;
begin
  If Terminated = False then
  Begin
    New(nEntry);
    nEntry^.scaleIconWidth    := iconWidth;
    nEntry^.scaleIconHeight   := iconHeight;
    nEntry^.scaleIconID       := iconSourceID;
    nEntry^.scaleIconFileName := iconFileName;

    fSyncAddCS.Enter;
    Try
      queueList.Add(nEntry);
    Finally
      fSyncAddCS.Leave;
    End;
  End;
end;


procedure TImageScalerManagerThread.ClearEntries;
var
  I : Integer;
begin
  // Make sure we're not paused
  If ThreadState = 1 then
    StartProcessing;

  // Signal Abort
  fAbortSync := True;

  // Wait for thread to clear queue or exit
  While (Terminated = False) and (FAbortSync = True) do
    Sleep(1);
End;


function TImageScalerManagerThread.GetUpdates : Boolean;
var
  I          : Integer;
  updateList : TList;
  iID        : Integer;
begin
  updateList := nil;
  Result     := False;

  fSyncGetCS.Enter;
  Try
    If syncList.Count > 0 then
    Begin
      UpdateList := TList.Create;
      UpdateList.Assign(syncList);
      syncList.Clear;
    End;
  Finally
    fSyncGetCS.Leave;
  End;

  If updateList <> nil then
  Begin
    For I := 0 to updateList.Count-1 do
    Begin
      iID := PSyncRecord(updateList[I])^.syncIconID;
      If (iID > -1) and (iID < MainForm.iconList.Count) then
      Begin
        If MainForm.iconList[iID] <> nil then
          TGPBitmap(MainForm.iconList[iID]).Free;

        MainForm.iconList[iID] := PSyncRecord(updateList[I])^.syncIconData;
        Result := True;
      End;
      Dispose(PSyncRecord(updateList[I]));
    End;
    updateList.Free;
  End;
end;


end.
