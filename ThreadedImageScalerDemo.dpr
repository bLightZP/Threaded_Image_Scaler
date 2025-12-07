program ThreadedImageScalerDemo;

uses
  FastMM4,
  FastMove,
  FastCode,
  Forms,
  MainUnit in 'MainUnit.pas' {MainForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
