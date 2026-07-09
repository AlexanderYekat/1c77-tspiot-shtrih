unit kktserverindy;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  System.IniFiles, System.DateUtils, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  uHttpServerFmu, Vcl.StdCtrls, uVariantPrint, uKktLog, uFormSettings;

type
  TkktServerIndyForm = class(TForm)
    ButtonStartServer: TButton;
    ButtonStopServer: TButton;
    LogsMemo: TMemo;
    HeaderLabel: TLabel;
    OptionsButton: TButton;
    procedure ButtonStartServerClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure ButtonStopServerClick(Sender: TObject);
    procedure OptionsButtonClick(Sender: TObject);
  private
    HttpServer: TFmuHttpServer;
    FVariantPrint: TVariantPrint;
    FSettings: TIniFile;
    FListenPort: Integer;
    FUiLogMaxLines: Integer;
    procedure AppendLogLine(const Line: string);
    procedure HandleLogLine(Sender: TObject; const Line: string);
    procedure BindLoggerUi;
    procedure UnbindLoggerUi;
    function ServerIsRunning: Boolean;
    procedure EnsureSettings;
  public
    { Public declarations }
  end;

var
  kktServerIndyForm: TkktServerIndyForm;

implementation

{$R *.dfm}

procedure TkktServerIndyForm.AppendLogLine(const Line: string);
begin
  while LogsMemo.Lines.Count >= FUiLogMaxLines do
    LogsMemo.Lines.Delete(0);
  LogsMemo.Lines.Add(Line);
  SendMessage(LogsMemo.Handle, EM_LINESCROLL, 0, LogsMemo.Lines.Count);
  LogsMemo.SelStart := Length(LogsMemo.Text);
  LogsMemo.SelLength := 0;
end;

procedure TkktServerIndyForm.HandleLogLine(Sender: TObject; const Line: string);
begin
  if GetCurrentThreadId = MainThreadID then
    AppendLogLine(Line)
  else
    TThread.Queue(nil,
      procedure
      begin
        AppendLogLine(Line);
      end);
end;

procedure TkktServerIndyForm.BindLoggerUi;
begin
  if not Assigned(FVariantPrint) then
    Exit;
  FVariantPrint.Logger.OnLogLine := HandleLogLine;
end;

procedure TkktServerIndyForm.UnbindLoggerUi;
begin
  if Assigned(FVariantPrint) then
    FVariantPrint.Logger.OnLogLine := nil;
end;

function TkktServerIndyForm.ServerIsRunning: Boolean;
begin
  Result := Assigned(HttpServer) and HttpServer.Active;
end;

procedure TkktServerIndyForm.EnsureSettings;
begin
  if not Assigned(FSettings) then
    FSettings := TIniFile.Create(ChangeFileExt(Application.ExeName, '.ini'));
end;

procedure TkktServerIndyForm.OptionsButtonClick(Sender: TObject);
begin
  EnsureSettings;
  if TFormSettings.Execute(FSettings, ServerIsRunning) then
    FUiLogMaxLines := FSettings.ReadInteger('Log', 'UiMaxLines', 2000);
end;

procedure TkktServerIndyForm.ButtonStartServerClick(Sender: TObject);
const
  DefaultKktPort = 2580;
var
  KktPort: Integer;
begin
  if Assigned(HttpServer) then
  begin
    if HttpServer.Active then
    begin
      ShowMessage(Format('HTTP-сервер уже запущен на порту %d', [FListenPort]));
      Exit;
    end;
  end;

  EnsureSettings;
  KktPort := FSettings.ReadInteger('HttpServer', 'Port', DefaultKktPort);
  FListenPort := KktPort;
  FUiLogMaxLines := FSettings.ReadInteger('Log', 'UiMaxLines', 2000);

  if not Assigned(FVariantPrint) then
    FVariantPrint := TVariantPrint.Create(FSettings);
  BindLoggerUi;

  if not Assigned(HttpServer) then
    HttpServer := TFmuHttpServer.Create(KktPort, FVariantPrint);
  if not HttpServer.Active then
  begin
    LogsMemo.Lines.BeginUpdate;
    try
      LogsMemo.Clear;
      LogsMemo.Lines.Add('--- ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ---');
    finally
      LogsMemo.Lines.EndUpdate;
    end;
    HttpServer.Start;
    FVariantPrint.Logger.LogInfo(Format('HTTP-сервер запущен на порту %d', [KktPort]));
  end;
  ButtonStartServer.Caption := Format('Сервер запущен (%d)', [KktPort]);
  ButtonStartServer.Enabled := False;
end;

procedure TkktServerIndyForm.ButtonStopServerClick(Sender: TObject);
begin
  if not Assigned(HttpServer) then Exit;
  if not HttpServer.Active then Exit;
  HttpServer.Stop;
  if Assigned(FVariantPrint) then
    FVariantPrint.Logger.LogInfo(Format('HTTP-сервер остановлен (порт %d)', [FListenPort]));
  ButtonStartServer.Caption := 'Старт';
  ButtonStopServer.Caption := Format('Сервер остановлен (%d)', [FListenPort]);
  ButtonStopServer.Enabled := False;
  ButtonStartServer.Enabled := True;
end;

procedure TkktServerIndyForm.FormDestroy(Sender: TObject);
begin
  UnbindLoggerUi;
  FreeAndNil(HttpServer);
  FreeAndNil(FVariantPrint);
  FreeAndNil(FSettings);
end;

end.
