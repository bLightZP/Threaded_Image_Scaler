//
// Multi-threaded background load & scale demo application
//
//   by Yaron Gur - https://www.inmatrix.com
//
//
// This demo decodes and scales images in the background as soon as you click the mouse anywhere in the form.
//
// While the images are loaded and scaled, anti-aliased text is drawn against a semi-transparent layered window
// with rounded rectangle corners.
//
// You can use the keyboard to navigate the list or press space to animate to a random list position every 1000ms.
//
//
// Flag images courtsey - https://flagpedia.net
// 



unit MainUnit;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, ThreadedImageScaler, GDIPAPI ,GDIPOBJ, ExtCtrls;


const
  resizeTargetRes : Integer = 96; // Resized image maximum resolution in Pixels
  maxThreads      : Integer = 4;  // Number of active loading and resizing work threads (not including manager)

type
  TMainForm = class(TForm)
    IndexTimer: TTimer;
    procedure FormKeyPress(Sender: TObject; var Key: Char);
    procedure FormShow(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormClick(Sender: TObject);
    procedure IndexTimerTimer(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
  private
    { Private declarations }
  public
    { Public declarations }
    fileList    : TStringList;
    iconList    : TList;
    bgBitmap    : TBitmap;
    bgBitmapSrc : TBitmap;
    iScrollOfs  : Integer;
    iTextMargin : Integer;
    iTextWidth  : Integer;
    iTextHeight : Integer;
    iLineHeight : Integer;    iLineCount  : Integer;    iCenterY    : Integer;    iItemIndex  : Integer;

    // Colors
    bgColor           : Cardinal;
    activeTextColor   : Cardinal;
    inactiveTextColor : Cardinal;

    // GDI+
    ovGDIGraphics     : TGPGraphics;
    ovFont            : TGPFont;
    ovFontFamily      : TGPFontFamily;
    ovStringFormat    : TGPStringFormat;

    procedure DrawUserInterface;
    procedure TerminateThreadManager;
    procedure SetNewIndex(newIndex : Integer);
  end;

  // Screen update animation thread
  TImageUpdateThread = Class(TThread)
    procedure Execute; override;
  public
    procedure DrawFrame;
  end;


var
  MainForm                 : TMainForm;
  uiAnimating              : Boolean = False;
  delayedDrawUserInterface : Boolean = False;
  threadManager            : TImageScalerManagerThread;
  imageUpdateThread        : TImageUpdateThread;


implementation

{$R *.dfm}


procedure TImageUpdateThread.Execute;
var
  groupTimer   : THandle;
  timerDueTime : Int64;
  timerPeriod  : Integer;
begin
  FreeOnTerminate := True;
  timerDueTime := -10000 * 10;
  timerPeriod  := 10;
  groupTimer   := CreateWaitableTimer(nil, False, nil);
  SetWaitableTimer(groupTimer, timerDueTime, timerPeriod, nil, nil, False);

  while not Terminated do
  begin
    WaitForSingleObject(groupTimer, INFINITE);
    Synchronize(DrawFrame);
  end;

  CancelWaitableTimer(groupTimer);
  CloseHandle(groupTimer);
end;


procedure TImageUpdateThread.DrawFrame;
var
  iUpdate : Integer;
begin
  If (MainForm.iScrollOfs = 0) and (delayedDrawUserInterface = False) then
    Exit;

  If (Terminated = False) then
  Begin
    If MainForm.iScrollOfs <> 0 then
    Begin
      MainForm.iScrollOfs := Trunc(MainForm.iScrollOfs*0.9);
    End;
    If delayedDrawUserInterface = True then
    Begin
      delayedDrawUserInterface := False;
    End;
    MainForm.DrawUserInterface;
  End;
end;


function BuildRoundedRectPath(iX, iY, iW, iH, iRadius: Integer): TGPGraphicsPath;
var
  diameter : Double;
  Radius   : Double;
  W,H,X,Y  : Double;

begin
  result   := TGPGraphicsPath.Create;

  Y        := iY-0.5;
  X        := iX-0.5;
  W        := iW+1;
  H        := iH+1;
  Radius   := iRadius+1;

  diameter := Radius * 2;

  try
    // Top-left corner
    result.AddArc(X, Y, diameter, diameter, 180, 90);

    // Top edge top-right corner
    result.AddArc(X + W - diameter, Y, diameter, diameter, 270, 90);

    // Right edge bottom-right corner
    result.AddArc(X + W - diameter, Y + H - diameter, diameter, diameter, 0, 90);

    // Bottom edge bottom-left corner
    result.AddArc(X, Y + H - diameter, diameter, diameter, 90, 90);

    result.CloseFigure;
  except
    On E : Exception do
    Begin
      result.Free;
      result := nil;
    End;
  end;
end;


procedure TMainForm.FormKeyPress(Sender: TObject; var Key: Char);
begin
  If Key = #27 then
  Begin
    Key := #0;
    Close;
  End;
end;


procedure TMainForm.FormShow(Sender: TObject);
var
  I : Integer;
begin
  bgBitmap    := nil;
  bgBitmapSrc := nil;
  iconList    := TList.Create;
  iScrollOfs  := 0;
  iItemIndex  := 0;

  fileList := TStringList.Create;
  Try
    fileList.LoadFromFile(ExtractFilePath(ParamStr(0))+'flags.m3u');
  Except
    ShowMessage('Unable to load flag playlist');
  End;

  // Create empty icon list
  iconList.Capacity := fileList.Count;
  For I := 0 to fileList.Count-1 do
    iconList.Add(nil);

  // Scaling manager thread

  threadManager := TImageScalerManagerThread.Create(False);
  threadManager.maxScalers := maxThreads;

  // User interface update thread
  imageUpdateThread := TImageUpdateThread.Create(False);

  DrawUserInterface;
end;


procedure TMainForm.FormClose(Sender: TObject; var Action: TCloseAction);
var
  I : Integer;
begin
  imageUpdateThread.Terminate;

  If bgBitmap <> nil then
  Begin
    bgBitmap.Canvas.Unlock;  
    bgBitmap.Free;
  End;
  fileList.Free;

  For I := 0 to iconList.Count-1 do
    TGPBitmap(iconList[I]).Free;
  iconList.Free;

  TerminateThreadManager;

  ovStringFormat.Free;
  ovGDIGraphics.Free;
  ovFont.Free;
  ovFontFamily.Free;
end;


procedure TMainForm.FormCreate(Sender: TObject);
begin
  Randomize;

  // Set window as layered
  SetWindowLong(Handle, GWL_EXSTYLE, GetWindowLong(Handle, GWL_EXSTYLE) or WS_EX_LAYERED or WS_EX_TOPMOST);
end;


procedure TMainForm.FormClick(Sender: TObject);
var
  I : Integer;
begin
  If fileList.Count > 0 then
  Begin
    // Clear icon from list
    For I := 0 to fileList.Count-1 do
      If iconList[I] <> nil then
    Begin
      TGPBitmap(iconList[I]).Free;
      iconList[I] := nil;
    End;

    // Add icons for decoding and scaling to within the desired frame-size (96x96)
    For I := 0 to fileList.Count-1 do
      threadManager.AddEntry(I,resizeTargetRes,resizeTargetRes,ExtractFilePath(ParamStr(0))+'flags\'+fileList[I]);

    // Start processing
    threadManager.StartProcessing;

    ShowMessage('done');
  End;
end;


procedure TMainForm.TerminateThreadManager;
begin
  If threadManager <> nil then
  Begin
    threadManager.Terminate;
    If threadManager.ThreadState = 1 then
      threadManager.StartProcessing;
    While threadManager.ThreadState <> threadStateFinished do
      Sleep(1);
    threadManager.Free;
  End;
end;


procedure TMainForm.DrawUserInterface;
var
  // Layered Form
  blend                : TBLENDFUNCTION;
  pointSrc             : TPoint;
  pointForm            : TPoint;
  bmpsize              : TSize;

  // GDI+
  ovPath               : TGPGraphicsPath;
  ovBrush              : TGPSolidBrush;
  ovStringRect         : TGPRectF;
  ovStringFlags        : Integer;
  iStatus              : TStatus;

  // Misc
  I                    : Integer;
  iStart               : Integer;
  yOfs                 : Integer;
  sText                : WideString;

begin
  If bgBitmapSrc = nil then
  Begin
    // Initialization
    bgBitmapSrc                    := TBitmap.Create;
    bgBitmapSrc.PixelFormat        := pf32bit;
    bgBitmapSrc.Canvas.Brush.Color := 0;
    bgBitmapSrc.Width              := clientWidth;
    bgBitmapSrc.Height             := clientHeight;

    bgColor           := MakeColor(192,0,0,0);
    activeTextColor   := MakeColor(255,255,255,255);
    inactiveTextColor := MakeColor(255,128,128,128);

    // Form background, round-rect coreners
    ovPath := BuildRoundedRectPath(0,0,clientWidth-1,clientHeight-1,clientHeight div 32);
    If ovPath <> nil then
    Begin
      // Clear background
      ovBrush := TGPSolidBrush.Create(0);
      ovGDIGraphics := TGPGraphics.Create(bgBitmapSrc.Canvas.Handle);
      ovGDIGraphics.FillRectangle(ovBrush,0,0,clientWidth,clientHeight);

      // Draw round-rect
      ovBrush.SetColor(bgColor);
      ovGDIGraphics.SetSmoothingMode(SmoothingModeAntiAlias);
      ovGDIGraphics.SetCompositingQuality(CompositingQualityHighQuality);
      ovGDIGraphics.FillPath(ovBrush, ovPath);
      ovGDIGraphics.Free;

      ovBrush.Free;
      ovPath.Free;
    End;

    bgBitmap       := TBitmap.Create;    iTextMargin    := clientWidth  div 32;    iTextWidth     := clientWidth-(iTextMargin*2);    iLineHeight    := clientHeight div 12;    iTextHeight    := Trunc(iLineHeight * 0.5);    iCenterY       := (clientHeight div 2) - (iLineHeight div 2);    iLineCount     := clientHeight div iLineHeight;
    ovStringFormat := TGPStringFormat.Create(TGPStringFormat.GenericTypographic); // GenericTypographic is closer to standard GDI typography
    ovStringFlags  := ovStringFormat.GetFormatFlags;
    ovStringFlags  := ovStringFlags or StringFormatFlagsNoWrap or StringFormatFlagsLineLimit;
    ovStringFormat.SetFormatFlags(ovStringFlags);
    ovStringFormat.SetAlignment(StringAlignmentNear);       // H-Left
    ovStringFormat.SetLineAlignment(StringAlignmentCenter); // V-Center
    //ovStringFormat.SetTrimming(StringTrimmingEllipsisCharacter);
    ovFontFamily   := TGPFontFamily.Create('Segoe UI Emoji');
    ovFont         := TGPFont.Create(ovFontFamily, iTextHeight, FontStyleRegular, UnitPixel);
    bgBitmap.Assign(bgBitmapSrc);    bgBitmap.Canvas.Lock;
        ovGDIGraphics  := TGPGraphics.Create(bgBitmap.Canvas.Handle);  End  Else bgBitmap.Canvas.Draw(0,0,bgBitmapSrc);

  // Copy cached background bitmap  ovBrush := TGPSolidBrush.Create(inactiveTextColor);

  // Draw Text
  ovStringRect.Height := iLineHeight;

  iStart := iItemIndex-((iLineCount div 2)+2)+(iScrollOfs div iLineHeight);
  If iStart < 0 then iStart := 0;

  If fileList.Count > 0 then
  Begin
    For I := iStart to fileList.Count-1 do
    Begin
      yOfs := (I-iItemIndex)*iLineHeight+iCenterY-iScrollOfs;

      if (yOfs + iLineHeight < 0) then
        Continue;
      If (yOfs > clientHeight) then
        Break;

      ovStringRect.Width  := iTextWidth;
      ovStringRect.X      := iTextMargin;
      ovStringRect.Y      := yOfs;

      // Highlight active group item BG
      If I = iItemIndex then
        ovBrush.SetColor(activeTextColor) else
        ovBrush.SetColor(inactiveTextColor);

      // Draw Text
      sText   := '#'+IntToStr(I)+' : '+fileList[I]+' flag';
      iStatus := ovGDIGraphics.DrawString(sText, -1, ovFont, ovStringRect, ovStringFormat, ovBrush);
    End;
  End;

  ovBrush.Free;

  // Render bitmap to layered window handle
  pointSrc                  := Point(0, 0);
  pointForm                 := Point(Left, Top);

  bmpsize.cx                := clientWidth;
  bmpsize.cy                := clientHeight;

  blend.BlendOp             := AC_SRC_OVER;
  blend.BlendFlags          := 0;
  blend.SourceConstantAlpha := 255; // Opaque
  blend.AlphaFormat         := AC_SRC_ALPHA;

  if not UpdateLayeredWindow(Handle, 0, @pointForm, @bmpsize, bgBitmap.Canvas.Handle, @pointSrc, 0, @blend, ULW_ALPHA) then
  Begin
    // Should never happen
    Close;
  end;
end;


procedure TMainForm.IndexTimerTimer(Sender: TObject);
begin
  If FileList.Count > 0 then
  Begin
    SetNewIndex(Random(FileList.Count));
  End;
end;


procedure TMainForm.SetNewIndex(newIndex : Integer);
begin
  If newIndex < 0 then
    newIndex := 0;

  If newIndex >= fileList.Count then
    newIndex := fileList.Count-1;

  If iItemIndex <> newIndex then
  Begin
    iScrollOfs := (iItemIndex - newIndex) * iLineHeight; // Triggers update
    iItemIndex := newIndex;
  End;
end;


procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
   Case Key of
     VK_HOME  : SetNewIndex(0);
     VK_UP    : SetNewIndex(iItemIndex-1);
     VK_DOWN  : SetNewIndex(iItemIndex+1);
     VK_END   : SetNewIndex(fileList.Count);
     VK_SPACE : IndexTimer.Enabled := not IndexTimer.Enabled;
   End;
end;

end.
