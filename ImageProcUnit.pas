//
// Some basic image processing code
//
//
unit ImageProcUnit;

interface

uses
  Windows, Messages, SysUtils, StdCtrls, Variants, Classes, Graphics, Controls, syncobjs,
  Dialogs, ExtCtrls;


function  FitInBoundingBox(const OriginalWidth, OriginalHeight, TargetWidth, TargetHeight : Integer;  out AdjustedWidth: Integer; out AdjustedHeight: Integer): Boolean;
procedure DrawAlphaBitmap(ADestCanvas: TCanvas; X, Y: Integer; ASrcBitmap: TBitmap);
procedure ImageFactorResize(SrcBitmap,DestBitmap : TBitmap; SrcX,SrcY,sWidth,sHeight,DestX,DestY,dWidth,dHeight : Integer);


implementation


const
  MaxPixelCount  = 32768; // 12-nov-15: changed from 65536

type
  TMyScanLineRGBQuad     = Array[0..MaxPixelCount-1] of TRGBQuad;
  TMyScanLineRGBQuadGrid = Array[0..MaxPixelCount-1] of ^TMyScanLineRGBQuad;


procedure ImageFactorResize(SrcBitmap,DestBitmap : TBitmap; SrcX,SrcY,sWidth,sHeight,DestX,DestY,dWidth,dHeight : Integer);
Const
  accLevel     = 8; // Shifting Accuracy
  accIteration = 2; // Accuracy of Scaler
var
  Speed1            : Integer;
  Speed2            : Integer;
  Speed4            : Integer;
  PixCount          : Integer;
  PixB              : Integer;
  PixG              : Integer;
  PixR              : Integer;
  PixA              : Integer;
  SX,SY             : Integer;
  X,Y               : Integer;
  PixXShl           : Integer;
  PixYShl           : Integer;
  PixXRnd           : Integer;
  PixYRnd           : Integer;
  PicWidth          : Integer;
  PicHeight         : Integer;
  PixXPos           : Integer;
  PixYPos           : Integer;
  P32               : ^TMyScanLineRGBQuad;
  PL32              : ^TMyScanLineRGBQuadGrid;
  PRow32            : ^TMyScanLineRGBQuad;
  PDif              : Integer;
begin
  If (sWidth < 2) or (sHeight < 2) or (dWidth < 2) or (dHeight < 2) or
     (sWidth+SrcX  > SrcBitmap.Width)  or (sHeight+SrcY  > SrcBitmap.Height) or
     (dWidth+DestX > DestBitmap.Width) or (dHeight+DestY > DestBitmap.Height) then Exit;

  If (sWidth <> dWidth) or (sHeight <> dHeight) then
  Begin
    // Pre-Calcualte some math
    PicWidth     := sWidth  shl accIteration;
    PicHeight    := sHeight shl accIteration;
    PixXShl      := (PicWidth  shl accLevel) div dWidth;
    PixYShl      := (PicHeight shl accLevel) div dHeight;
    PixXRnd      := Round(PicWidth  / dWidth);
    PixYRnd      := Round(PicHeight / dHeight);
    PixCount     := PixXRnd*PixYRnd;

    New(PL32);
    // Calculate memory used for each line display for quick scanline seeks (dest image)
    PL32^[0] := SrcBitmap.Scanline[0];
    PL32^[1] := SrcBitmap.Scanline[1];
    PDif     := Integer(PL32^[1])-Integer(PL32^[0]);

    // Pre-Calculate scanline positions for source image
    For Y := 2 to SrcBitmap.Height-1 do Integer(PL32^[Y]) := Integer(PL32^[Y-1])+PDif;

    // Calculate memory used for each line display for quick scanline seeks (source image)
    P32          := DestBitmap.Scanline[DestY];
    PDif         := Integer(DestBitmap.Scanline[DestY+1])-Integer(P32);

    // scale the image
    For Y := 0 to dHeight-1 do
    Begin
      PixYPos := (Y*PixYShl) shr accLevel;
      For X := 0 to dWidth-1 do
      Begin
        PixR         := 0;
        PixG         := 0;
        PixB         := 0;
        PixA         := 0;
        PixXPos      := (X*PixXShl) shr accLevel;

        For SY := 0 to PixYRnd-1 do
        Begin
          pRow32 := @PL32^[((PixYPos+SY) shr accIteration)+SrcY]^;
          For SX := 0 to PixXRnd-1 do
          Begin
            Speed2 := ((PixXPos+SX) shr accIteration)+SrcX;
            Inc(PixB,PRow32^[Speed2].rgbBlue);
            Inc(PixG,PRow32^[Speed2].rgbGreen);
            Inc(PixR,PRow32^[Speed2].rgbRed);
            Inc(PixA,PRow32^[Speed2].rgbReserved);
          End;
        End;
        P32^[X+DestX].rgbBlue     := (PixB div PixCount);
        P32^[X+DestX].rgbGreen    := (PixG div PixCount);
        P32^[X+DestX].rgbRed      := (PixR div PixCount);
        P32^[X+DestX].rgbReserved := (PixA div PixCount);
        // Slower
        //Cardinal(P32^[X+DestX]) := ((PixR div PixCount) shl 16)+((PixG div PixCount) shl 8)+(PixB div PixCount);
      End;
      Inc(Integer(P32),PDif);
    End;

    Dispose(PL32);
  End
  Else BitBlt(DestBitmap.Canvas.Handle,DestX,DestY,sWidth,sHeight,SrcBitmap.Canvas.Handle,SrcX,SrcY,SRCCOPY);
end;


procedure DrawAlphaBitmap(ADestCanvas: TCanvas; X, Y: Integer; ASrcBitmap: TBitmap);
var
  BF: BLENDFUNCTION;
begin
  if (ASrcBitmap = nil) or (ADestCanvas = nil) then Exit;

  // Setup the Blend Function
  BF.BlendOp := AC_SRC_OVER;
  BF.BlendFlags := 0;
  BF.SourceConstantAlpha := 255; // 255 = Use per-pixel alpha from bitmap
  BF.AlphaFormat := AC_SRC_ALPHA; // This flag tells API to use the Alpha channel

  // Perform the Alpha Blend
  AlphaBlend(ADestCanvas.Handle, X, Y, ASrcBitmap.Width, ASrcBitmap.Height,
             ASrcBitmap.Canvas.Handle, 0, 0, ASrcBitmap.Width, ASrcBitmap.Height,
             BF);
end;


function FitInBoundingBox(const OriginalWidth, OriginalHeight, TargetWidth, TargetHeight : Integer;  out AdjustedWidth: Integer; out AdjustedHeight: Integer): Boolean;
var
  WidthRatio: Extended;
  HeightRatio: Extended;
  ScaleFactor: Extended;
begin
  // --- Input Validation ---
  if (OriginalWidth <= 0) or (OriginalHeight <= 0) or
     (TargetWidth <= 0) or (TargetHeight <= 0) then
  begin
    AdjustedWidth := 0;
    AdjustedHeight := 0;
    Result := False; // Indicate failure due to invalid input
    Exit;
  end;

  // --- Calculate Scaling Ratios ---
  // Determine how much we need to scale down to fit the target width
  WidthRatio := TargetWidth / OriginalWidth;

  // Determine how much we need to scale down to fit the target height
  HeightRatio := TargetHeight / OriginalHeight;

  // --- Determine the Limiting Factor ---
  // To ensure the image fits *within* the bounding box while maintaining
  // aspect ratio, we must use the *smaller* of the two ratios.
  if WidthRatio < HeightRatio then
    ScaleFactor := WidthRatio
  else
    ScaleFactor := HeightRatio;

  // --- Apply Scaling ---
  AdjustedWidth := Round(OriginalWidth * ScaleFactor);
  AdjustedHeight := Round(OriginalHeight * ScaleFactor);

  If AdjustedWidth  < 1 then AdjustedWidth  := 1;
  If AdjustedHeight < 1 then AdjustedHeight := 1;

  // --- Result ---
  Result := True; // Indicate success
end;





end.
