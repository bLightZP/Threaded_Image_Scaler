//
// Barebone image loader based on WIC, Delphi 7 compatible.
//
// Unlike GDI+, WIC decoding code is fully multi-threaded, supporting concurrent decoding of multiple media files.
//
// https://github.com/bLightZP/WIC_Barebone_Image_Loader

unit WICBitmapLoader;

interface

uses
  Windows, ActiveX, SysUtils, Classes, Graphics,
    TntSysUtils; // Used to support WideFileExists

function LoadBitmapWIC32(const AFileName: WideString; ADest: TBitmap): Boolean; overload;
function LoadBitmapWIC32(AStream: TStream; ADest: TBitmap): Boolean; overload;

implementation

{$IFDEF TRACEDEBUG}
uses dialogs, debugunit;
{$ENDIF}

type
  UINT             = LongWord;
  WICDecodeOptions = Longint;

const
  // CLSID / IID
  CLSID_WICImagingFactory       : TGUID = '{CACAF262-9370-4615-A13B-9F5539DA4C0A}';
  IID_IWICImagingFactory        : TGUID = '{EC5EC8A9-C395-4314-9C77-54D7A935FF70}';

  GUID_WICPixelFormat32bppBGRA  : TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC90F}'; // 32bpp BGRA (non premultiplied)
  GUID_WICPixelFormat32bppPBGRA : TGUID = '{6FDDC324-4E03-4BFE-B185-3D77768DC910}'; // 32bpp PBGRA (premultiplied)


  // Decode options
  WICDecodeMetadataCacheOnDemand = $00000000;

  // Dither / palette types (only what's used)
  WICBitmapDitherTypeNone    = 0;
  WICBitmapPaletteTypeCustom = 0;

type
  IWICBitmapSource = interface(IUnknown)
    ['{00000120-A8F2-4877-BA0A-FD2B6645FB94}']
    function GetSize(out uiWidth, uiHeight: UINT): HResult; stdcall;
    function GetPixelFormat(out pPixelFormat: TGUID): HResult; stdcall;
    function GetResolution(out pDpiX, pDpiY: Double): HResult; stdcall;
    function CopyPalette(pIPalette: IUnknown): HResult; stdcall;
    function CopyPixels(prc: Pointer; cbStride, cbBufferSize: UINT; pbBuffer: Pointer): HResult; stdcall;
  end;

  IWICBitmapFrameDecode = interface(IWICBitmapSource)
    ['{3B16811B-6A43-4EC9-A813-3D930C13B940}']
    function GetMetadataQueryReader(out ppIMetadataQueryReader: IUnknown): HResult; stdcall;
    function GetColorContexts(cCount: UINT; colorContexts: Pointer; out pcActualCount: UINT): HResult; stdcall;
    function GetThumbnail(out ppIThumbnail: IWICBitmapSource): HResult; stdcall;
  end;

  IWICBitmapDecoder = interface(IUnknown)
    ['{9EDDE9E7-8DEE-47EA-99DF-E6FAF2ED44BF}']
    function QueryCapability(pIStream: IUnknown; out pdwCapability: DWORD): HResult; stdcall;
    function Initialize(pIStream: IUnknown; metadataOptions: WICDecodeOptions): HResult; stdcall;
    function GetContainerFormat(out pguidContainerFormat: TGUID): HResult; stdcall;
    function GetDecoderInfo(out ppIDecoderInfo: IUnknown): HResult; stdcall;
    function CopyPalette(pIPalette: IUnknown): HResult; stdcall;
    function GetMetadataQueryReader(out ppIMetadataQueryReader: IUnknown): HResult; stdcall;
    function GetPreview(out ppIBitmapSource: IWICBitmapSource): HResult; stdcall;
    function GetColorContexts(cCount: UINT; colorContexts: Pointer; out pcActualCount: UINT): HResult; stdcall;
    function GetThumbnail(out ppIThumbnail: IWICBitmapSource): HResult; stdcall;
    function GetFrameCount(out pCount: UINT): HResult; stdcall;
    function GetFrame(index: UINT; out ppIBitmapFrame: IWICBitmapFrameDecode): HResult; stdcall;
  end;

  IWICFormatConverter = interface(IWICBitmapSource)
    ['{00000301-A8F2-4877-BA0A-FD2B6645FB94}']
    function Initialize(pISource: IWICBitmapSource; const dstFormat: TGUID; dither: Integer; pIPalette: IUnknown; alphaThresholdPercent: Double; paletteTranslate: Integer): HResult; stdcall;
    function CanConvert(const srcPixelFormat, dstPixelFormat: TGUID; out pfCanConvert: LongBool): HResult; stdcall;
  end;

 
  IWICImagingFactory = interface(IUnknown)
    ['{EC5EC8A9-C395-4314-9C77-54D7A935FF70}']
    function CreateDecoderFromFilename(
      wzFilename: PWideChar;
      const pguidVendor: PGUID;
      dwDesiredAccess: DWORD;
      metadataOptions: WICDecodeOptions;
      out ppIDecoder: IWICBitmapDecoder
    ): HResult; stdcall;

    function CreateDecoderFromStream(
      pIStream: IStream;
      const pguidVendor: PGUID;
      metadataOptions: WICDecodeOptions;
      out ppIDecoder: IWICBitmapDecoder
    ): HResult; stdcall;

    function CreateDecoderFromFileHandle(
      hFile: THandle;
      const pguidVendor: PGUID;
      metadataOptions: WICDecodeOptions;
      out ppIDecoder: IWICBitmapDecoder
    ): HResult; stdcall;

    function CreateComponentInfo(
      const clsidComponent: TGUID;
      out ppIInfo: IUnknown
    ): HResult; stdcall;

    function CreateDecoder(
      const guidContainerFormat: TGUID;
      const pguidVendor: PGUID;
      out ppIDecoder: IWICBitmapDecoder
    ): HResult; stdcall;

    function CreateEncoder(
      const guidContainerFormat: TGUID;
      const pguidVendor: PGUID;
      out ppIEncoder: IUnknown
    ): HResult; stdcall;

    function CreatePalette(
      out ppIPalette: IUnknown
    ): HResult; stdcall;

    function CreateFormatConverter(
      out ppIFormatConverter: IWICFormatConverter
    ): HResult; stdcall;

    function CreateBitmapScaler(
      out ppIBitmapScaler: IUnknown
    ): HResult; stdcall;

    function CreateBitmapClipper(
      out ppIBitmapClipper: IUnknown
    ): HResult; stdcall;

    function CreateBitmapFlipRotator(
      out ppIBitmapFlipRotator: IUnknown
    ): HResult; stdcall;

    function CreateStream(
      out ppIWICStream: IStream  // really IWICStream, IStream is fine if you only need IStream
    ): HResult; stdcall;

    function CreateColorContext(
      out ppIWICColorContext: IUnknown
    ): HResult; stdcall;

    function CreateColorTransformer(
      out ppIWICColorTransform: IUnknown
    ): HResult; stdcall;

    function CreateBitmap(
      uiWidth, uiHeight: UINT;
      const pixelFormat: TGUID;
      option: Integer;              // WICBitmapCreateCacheOption, we do not use it here
      out ppIBitmap: IUnknown
    ): HResult; stdcall;

    function CreateBitmapFromSource(
      pIBitmapSource: IWICBitmapSource;
      option: Integer;
      out ppIBitmap: IUnknown
    ): HResult; stdcall;

    function CreateBitmapFromSourceRect(
      pIBitmapSource: IWICBitmapSource;
      x, y: UINT;
      width, height: UINT;
      out ppIBitmap: IUnknown
    ): HResult; stdcall;

    function CreateBitmapFromMemory(
      uiWidth, uiHeight: UINT;
      const pixelFormat: TGUID;
      cbStride: UINT;
      cbBufferSize: UINT;
      pbBuffer: Pointer;
      out ppIBitmap: IUnknown
    ): HResult; stdcall;

    function CreateBitmapFromHBITMAP(
      hBitmap: HBITMAP;
      hPalette: HPALETTE;
      option: Integer;
      out ppIBitmap: IUnknown
    ): HResult; stdcall;

    function CreateBitmapFromHICON(
      hIcon: HICON;
      out ppIBitmap: IUnknown
    ): HResult; stdcall;

    function CreateComponentEnumerator(
      componentTypes: DWORD;
      options: DWORD;
      out ppIEnumUnknown: IUnknown
    ): HResult; stdcall;

    function CreateFastMetadataEncoderFromDecoder(
      pIDecoder: IWICBitmapDecoder;
      out ppIFastEncoder: IUnknown
    ): HResult; stdcall;

    function CreateFastMetadataEncoderFromFrameDecode(
      pIFrameDecoder: IWICBitmapFrameDecode;
      out ppIFastEncoder: IUnknown
    ): HResult; stdcall;

    function CreateQueryWriter(
      const guidMetadataFormat: TGUID;
      const pguidVendor: PGUID;
      out ppIQueryWriter: IUnknown
    ): HResult; stdcall;

    function CreateQueryWriterFromReader(
      pIQueryReader: IUnknown;
      const pguidVendor: PGUID;
      out ppIQueryWriter: IUnknown
    ): HResult; stdcall;

    function CreateMetadataQueryWriterFromReader(
      pIQueryReader: IUnknown;
      const pguidVendor: PGUID;
      out ppIQueryWriter: IUnknown
    ): HResult; stdcall;
  end;


procedure DecodeToBitmap32(const Factory: IWICImagingFactory; const Decoder: IWICBitmapDecoder; ADest: TBitmap; out Success: Boolean);
var
  Frame      : IWICBitmapFrameDecode;
  Converter  : IWICFormatConverter;
  W, H       : UINT;
  strideWIC  : UINT;
  strideBMP  : UINT;
  bufferSize : UINT;
  tempBuffer : Pointer;
  hr         : HResult;
  y          : Integer;
  srcPtr     : PByte;
  dstPtr     : PByte;
begin
  {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','DecodeToBitmap32 (before)');{$ENDIF}
  Success := False;

  hr := Decoder.GetFrame(0,Frame);
  if Failed(hr) or (Frame = nil) then
  begin
    {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on Decoder.GetFrame, error '+IntToHex(hr,8));{$ENDIF}
    Exit;
  end;

  hr := Frame.GetSize(W,H);
  if Failed(hr) or (W = 0) or (H = 0) then
  begin
    {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on Decoder.GetSize, error '+IntToHex(hr,8));{$ENDIF}
    Exit;
  end;

  hr := Factory.CreateFormatConverter(Converter);
  if Failed(hr) or (Converter = nil) then
  begin
    {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on Create Converter, error '+IntToHex(hr,8));{$ENDIF}
    Exit;
  end;

  hr := Converter.Initialize(
    Frame,
    //GUID_WICPixelFormat32bppBGRA,
    GUID_WICPixelFormat32bppPBGRA, // Premultiplied
    WICBitmapDitherTypeNone,
    nil,
    0.0,
    WICBitmapPaletteTypeCustom
  );
  if Failed(hr) then
  begin
    {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on Converter init, error '+IntToHex(hr,8));{$ENDIF}
    Exit;
  end;

  // Prepare destination bitmap
  ADest.PixelFormat := pf32bit;
  ADest.Width       := W;
  ADest.Height      := H;

  // WIC: top-down, positive stride
  strideWIC  := W*4; // 4 bytes per pixel (BGRA)
  bufferSize := strideWIC*H;

  GetMem(tempBuffer,bufferSize);
  try
    hr := Converter.CopyPixels(
      nil,        // full image
      strideWIC,
      bufferSize,
      tempBuffer
    );
    if Failed(hr) then
    begin
      {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on CopyPixels, error '+IntToHex(hr,8));{$ENDIF}
      Exit;
    end;

    // Copy rows from tempBuffer into TBitmap
    srcPtr := tempBuffer;
    dstPtr := ADest.Scanline[0];

    If H > 1 then
      strideBMP := Integer(ADest.Scanline[1])-Integer(ADest.Scanline[0]) else
      strideBMP := 0;

    for Y := 0 to H-1 do
    begin
      Move(srcPtr^,dstPtr^,strideWIC);
      Inc(srcPtr,strideWIC);
      Inc(dstPtr,strideBMP);
    end;

    Success := True;
  finally
    FreeMem(tempBuffer);
  end;
  {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','DecodeToBitmap32 (after)');{$ENDIF}
end;


function LoadBitmapWIC32(const AFileName: WideString; ADest: TBitmap): Boolean; overload;
var
  hr         : HResult;
  needUninit : Boolean;
  Factory    : IWICImagingFactory;
  Decoder    : IWICBitmapDecoder;
begin
  {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','LoadBitmapWIC32 "'+aFileName+'" (before)');{$ENDIF}
  Result := False;

  if (AFileName = '') then
  Begin
    {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on invalid params');{$ENDIF}
    Exit;
  End;

  if WideFileExists(AFileName) = False then
  begin
    {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on file not found');{$ENDIF}
    Exit;
  end;

  hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  needUninit := (hr = S_OK) or (hr = S_FALSE);

  try
    hr := CoCreateInstance(
      CLSID_WICImagingFactory,
      nil,
      CLSCTX_INPROC_SERVER,
      IID_IWICImagingFactory,
      Factory
    );
    if Failed(hr) or (Factory = nil) then
    begin
      {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on Create factory, error '+IntToHex(hr,8));{$ENDIF}
      Exit;
    end;

    hr := Factory.CreateDecoderFromFilename(
      PWideChar(AFileName),
      nil,
      GENERIC_READ,
      WICDecodeMetadataCacheOnDemand,
      Decoder
    );
    if Failed(hr) or (Decoder = nil) then
    begin
      {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on Create decoder, error '+IntToHex(hr,8));{$ENDIF}
      Exit;
    end;  

    DecodeToBitmap32(Factory, Decoder, ADest, Result);
  finally
    if needUninit then
      CoUninitialize;
  end;
  {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','LoadBitmapWIC32 (after)');{$ENDIF}
end;


function LoadBitmapWIC32(AStream: TStream; ADest: TBitmap): Boolean; overload;
var
  hr         : HResult;
  needUninit : Boolean;
  Factory    : IWICImagingFactory;
  Decoder    : IWICBitmapDecoder;
  StreamIntf : IStream;
begin
  {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','LoadBitmapWIC32 (before)');{$ENDIF}
  Result := False;

  if (AStream = nil) or (AStream.Size = 0) then
  Begin
    {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on invalid params');{$ENDIF}
    Exit;
  End;

  // Reset to start by default. Remove this if you want to use "from current position"
  try
    AStream.Position := 0;
  except
    // ignore if not supported
  end;

  hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  needUninit := (hr = S_OK) or (hr = S_FALSE);

  try
    hr := CoCreateInstance(
      CLSID_WICImagingFactory,
      nil,
      CLSCTX_INPROC_SERVER,
      IID_IWICImagingFactory,
      Factory
    );
    if Failed(hr) or (Factory = nil) then
    Begin
      {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on Create factory, error '+IntToHex(hr,8));{$ENDIF}
      Exit;
    End;

    // Wrap TStream as IStream without changing ownership
    StreamIntf := TStreamAdapter.Create(AStream, soReference);

    hr := Factory.CreateDecoderFromStream(
      StreamIntf,
      nil,
      WICDecodeMetadataCacheOnDemand,
      Decoder
    );
    if Failed(hr) or (Decoder = nil) then
    Begin
      {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','Exit on Create decoder, error '+IntToHex(hr,8));{$ENDIF}
      Exit;
    End;

    DecodeToBitmap32(Factory, Decoder, ADest, Result);
  finally
    if needUninit then
      CoUninitialize;
  end;
  {$IFDEF TRACEDEBUG}DebugMSGFT('c:\log\.LoadImage.txt','LoadBitmapWIC32 (after)');{$ENDIF}
end;

end.

