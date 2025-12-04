object MainForm: TMainForm
  Left = 1119
  Top = 247
  BorderStyle = bsNone
  Caption = 'MainForm'
  ClientHeight = 584
  ClientWidth = 408
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'MS Sans Serif'
  Font.Style = []
  KeyPreview = True
  OldCreateOrder = False
  Position = poScreenCenter
  OnClick = FormClick
  OnClose = FormClose
  OnCreate = FormCreate
  OnKeyDown = FormKeyDown
  OnKeyPress = FormKeyPress
  OnShow = FormShow
  PixelsPerInch = 96
  TextHeight = 13
  object IndexTimer: TTimer
    Enabled = False
    OnTimer = IndexTimerTimer
    Left = 336
    Top = 56
  end
end
