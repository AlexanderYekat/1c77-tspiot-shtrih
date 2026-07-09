program kktserverindyProject;

uses
  Vcl.Forms,
  kktserverindy in 'kktserverindy.pas' {kktServerIndyForm},
  uFormSettings in 'uFormSettings.pas' {FormSettings},
  uHttpServerFmu in 'uHttpServerFmu.pas',
  uVariantPrint in 'uVariantPrint.pas',
  uKktLog in 'uKktLog.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TkktServerIndyForm, kktServerIndyForm);
  Application.Run;
end.
