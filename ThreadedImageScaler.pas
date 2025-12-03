unit ThreadedImageScaler;

interface


uses
  Windows, Messages, SysUtils, StdCtrls, Variants, Classes, Graphics, Controls, ActiveX, syncobjs,
  Dialogs, ExtCtrls, GDIPAPI ,GDIPOBJ, tntclasses;


const
  threadStateCreated    = 0;
  threadStateWaiting    = 1;
  threadStateProcessing = 2;
  threadStateFinished   = 255;
  threadStateSynched    = 256;

type
  // Meta-data scraping record
  TImageScalerRecord =
  Record
    scaleIconWidth  : Integer;
    scaleIconHeight : Integer;
    scaleIconID               : Integer;
    scaleIconFileName         : WideString;
  End;
  PImageScalerRecord = ^TImageScalerRecord;

  TImageScalerManagerThread = Class(TThread)
    procedure Execute; override;
  private
    FAbortSync      : Boolean;
    FEvent          : THandle;
    FSyncCS         : TCriticalSection;
    threadList      : TList;
    mdList          : TList; // Queue list, protected by a CriticalSection
    pList           : TList; // Processing list
  public
    ThreadState     : Integer;
    procedure AddEntry(iconSourceID, iconWidth, iconHeight : Integer);

    procedure ClearEntries;
    procedure StartProcessing;
    procedure SyncUpdates;
  end;

  TImageScalerThread = Class(TThread)
    procedure Execute; override;
  private
  public
    fIconData     : TGPBitmap;
    fIconWidth    : Integer;
    fIconHeight   : Integer;
    fIconID       : Integer;
    fIconFileName : WideString;
    ThreadState   : Integer;
    constructor Create(const iconID, iconWidth, iconHeight : Integer; iconFileName : WideString);
  end;


implementation

uses
  ShellAPI, tntsysutils, math;


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

constructor TImageScalerThread.Create(const iconID, iconWidth, iconHeight : Integer; iconFileName : WideString);
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
  mStream          : TTNTMemoryStream;
  sExt             : WideString;

  procedure GetFileFromCache(var sFile : WideString; var memStream : TTNTMemoryStream);
  var
    dlStatus : String;
  begin
    If WideFileExists(sFile) = True then
    Begin
      // Try using cached file
      Try memStream.LoadFromFile(sFile); Except memStream.Clear; End;
    End;
  end; // GetFileFromCacheOrDownload


  procedure DecodeAndResizeImage(var memStream : TTNTMemoryStream);
  var
    syncGDIImage     : TGPBitmap;
  begin
    // Decode & Scale the images
    syncGDIImage := GDIPLoadBitmapFromStream(memStream);
    If (syncGDIImage <> nil) then
    Begin
      // Resize GDI+ image
      If  Terminated = False then
        fIconData := GDIPScaleGPBitmapToGDBitmapMaintainAR(syncGDIImage,fIconWidth, fIconHeight);
      syncGDIImage.Free;
    End;
  end; // DecodeAndResizeImage


begin
  mStream    := TTNTMemoryStream.Create;

  GetFileFromCache(fIconFileName,mStream);

  If (mStream.Size > 0) and (Terminated = False) then
    DecodeAndResizeImage(mStream);

  mStream.Free;
  ThreadState := threadStateFinished;
end;


// Thread Manager thread

procedure TImageScalerManagerThread.Execute;
var
  maxScalers     : Integer; // Maximum active scaling threads
  I              : Integer;
  iComplete      : Integer;

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

  maxScalers         := 4; // maximum number of active scaling threads

  fSyncCS            := TCriticalSection.Create;
  CacheWriteCS       := TCriticalSection.Create;
  threadList         := TList.Create;
  pList              := TList.Create;
  mdList             := TList.Create;

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
    fSyncCS.Enter;
    Try
      For I := mdList.Count-1 downto 0 do
        pList.Insert(0,mdList[I]);
      mdList.Clear;
    Finally
      fSyncCS.Leave;
    End;

    // Start processing
    While (Terminated = False) and (fAbortSync = False) and (pList.Count > 0) and (threadList.Count < maxScalers) do
    Begin
      // Create worker threads
      With PImageScalerRecord(pList[0])^ do
      Begin
        threadList.Add(
          TImageScalerThread.Create(
            scaleIconID,
            scaleIconWidth,
            scaleIconHeight,
            scaleIconFileName);
      End;
      Dispose(PImageScalerRecord(pList[0]));
      pList.Delete(0);
    End;

    // Wait for some threads to complete
    If (FAbortSync = False) and (Terminated = False) and (threadList.Count > 0) then
    Begin
      iComplete := 0;
      For I := 0 to threadList.Count-1 do
        If TImageScalerThread(threadList[I]).ThreadState = threadStateFinished then
          Inc(iComplete);

      // At least one thread is done, sync updates
      If (iComplete > 0) and (CloseExecuted = False) and (CloseIssued = False) then
      Begin
        Synchronize(SyncUpdates);

        // Clear completed threads
        For I := threadList.Count-1 downto 0 do
          If TImageScalerThread(threadList[I]).ThreadState = threadStateSynched then
        Begin
          // Release thread
          TImageScalerThread(threadList[I]).Free;
          threadList.Delete(I);
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

      // Clear active list
      For I := 0 to pList.Count-1 do
        Dispose(PImageScalerRecord(pList[I]));
      pList.Clear;


      // Clear queue
      fSyncCS.Enter;
      Try
        For I := mdList.Count-1 downto 0 do
          Dispose(PImageScalerRecord(mdList[I]));
        mdList.Clear;
      Finally
        fSyncCS.Leave;
      End;

      FAbortSync := False;
    End;

    // Wait for next event
    If Terminated = False then
    Begin
      If (threadList.Count = 0) and (pList.Count = 0) then
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

  CloseHandle(fEvent);
  threadList.Free;

  For I := 0 to pList.Count-1 do
    Dispose(PImageScalerRecord(pList[I]));
  pList.Free;

  For I := 0 to mdList.Count-1 do
    Dispose(PImageScalerRecord(mdList[I]));
  mdList.Free;

  CacheWriteCS.Free;
  fSyncCS.Free;

  FAbortSync  := False; // Safety measure

  ThreadState := threadStateFinished;
end;


procedure TImageScalerManagerThread.StartProcessing;
begin
  SetEvent(FEvent);
end;


procedure TImageScalerManagerThread.AddEntry(iconSourceID, iconWidth, iconHeight : Integer; iconFileName : WideString);
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

      fSyncCS.Enter;
      Try
        mdList.Add(nEntry);
      Finally
        fSyncCS.Leave;
      End;
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



procedure TImageScalerManagerThread.SyncUpdates;
var
  I             : Integer;
  iCount        : Integer;
begin
  If Terminated = False then
  Begin
    If fAbortSync = False then
    Begin
      iCount := 0;
      For I := threadList.Count-1 downto 0 do
      Begin
        If TImageScalerThread(threadList[I]).ThreadState = threadStateFinished then
        Begin
          TImageScalerThread(threadList[I]).ThreadState := threadStateSynched;

          // Sync TGDBitmaps with main thread based on IconID
          If TImageScalerThread(threadList[I]).fIconData <> nil then
          Begin
            // MyIconList is a list of TGDBitmap;
            MyIconList[TImageScalerThread(threadList[I]).fIconID] := TImageScalerThread(threadList[I]).fIconData;
            Inc(iCount);
          End;
        End;
      End;

      If iCount > 0 then
      Begin
        // Update the UI as-needed
        If uiAnimating = False then
          DrawUserInterface else
          DelayedDrawUserInterface := True;
      End;
    End
      else
    Begin
      // Release queued entries
      For I := 0 to pList.Count-1 do
        Dispose(PImageScalerRecord(pList[I]));
      pList.Clear;

      For I := 0 to mdList.Count-1 do
        Dispose(PImageScalerRecord(mdList[I]));
      mdList.Clear;

      fAbortSync := False;
    End;
  End;
end;



end.
