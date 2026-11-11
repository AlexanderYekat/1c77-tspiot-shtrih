unit kktserverindy;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  System.IniFiles, System.DateUtils, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.ExtCtrls, Vcl.Menus, uHttpServerFmu, Vcl.StdCtrls, uVariantPrint, uKktLog, uFormSettings;

type
  TkktServerIndyForm = class(TForm)
    ButtonStartServer: TButton;
    ButtonStopServer: TButton;
    LogsMemo: TMemo;
    HeaderLabel: TLabel;
    VersionLabel: TLabel;
    OptionsButton: TButton;
    procedure FormCreate(Sender: TObject);
    procedure ButtonStartServerClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure ButtonStopServerClick(Sender: TObject);
    procedure OptionsButtonClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  private
    HttpServer: TFmuHttpServer;
    FVariantPrint: TVariantPrint;
    FSettings: TIniFile;
    FListenPort: Integer;
    FUiLogMaxLines: Integer;
    FFirstRunMessage: string;
    FTrayIcon: TTrayIcon;
    FAllowClose: Boolean;
    procedure AppendLogLine(const Line: string);
    procedure HandleLogLine(Sender: TObject; const Line: string);
    procedure BindLoggerUi;
    procedure UnbindLoggerUi;
    function ServerIsRunning: Boolean;
    procedure EnsureSettings;
    procedure HideToTray;
    procedure RestoreFromTray;
    procedure TrayIconDblClick(Sender: TObject);
    procedure TrayExitClick(Sender: TObject);
    procedure HandleHttpExitRequest(Sender: TObject);
    procedure RequestRealExit;
    procedure WMQueryEndSession(var Msg: TWMQueryEndSession); message WM_QUERYENDSESSION;
  public
    { Public declarations }
  end;

var
  kktServerIndyForm: TkktServerIndyForm;

implementation

{$R *.dfm}

procedure TkktServerIndyForm.FormCreate(Sender: TObject);
var
  Ver: string;
  TrayMenu: TPopupMenu;
  MenuItem: TMenuItem;
begin
  FAllowClose := False;
  Ver := TFmuHttpServer.ReadExeFileVersion;
  FTrayIcon := TTrayIcon.Create(Self);
  FTrayIcon.Visible := False;
  FTrayIcon.Hint := 'ККТ сервер ' + Ver;
  FTrayIcon.OnDblClick := TrayIconDblClick;
  TrayMenu := TPopupMenu.Create(Self);
  MenuItem := TMenuItem.Create(TrayMenu);
  MenuItem.Caption := 'Открыть';
  MenuItem.Default := True;
  MenuItem.OnClick := TrayIconDblClick;
  TrayMenu.Items.Add(MenuItem);
  MenuItem := TMenuItem.Create(TrayMenu);
  MenuItem.Caption := 'Выход';
  MenuItem.OnClick := TrayExitClick;
  TrayMenu.Items.Add(MenuItem);
  FTrayIcon.PopupMenu := TrayMenu;
  if not Application.Icon.Empty then
    FTrayIcon.Icon.Assign(Application.Icon)
  else if not Icon.Empty then
    FTrayIcon.Icon.Assign(Icon);

  VersionLabel.Caption := 'Версия: ' + Ver;
  ButtonStartServerClick(nil);
end;

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
var
  IniPath: string;
  IsFirstRun: Boolean;
  FrPort, FrBaud: Integer;
  LdOk: Boolean;
begin
  if Assigned(FSettings) then
    Exit;

  // ProgramData — без прав админа (в Program Files писать нельзя)
  IniPath := TFormSettings.GetSettingsFileName;
  IsFirstRun := not FileExists(IniPath);
  FSettings := TIniFile.Create(IniPath);

  if not IsFirstRun then
    Exit;

  // Первый запуск: настройки по умолчанию + параметры связи из активного ЛУ драйвера
  FrPort := DefaultFrPort;
  FrBaud := DefaultFrBaud;
  LdOk := TVariantPrint.TryReadActiveLdConnection(FrPort, FrBaud);
  TFormSettings.WriteDefaultSettings(FSettings, FrPort, FrBaud);

  if LdOk then
    FFirstRunMessage := Format(
      'Первый запуск: создан %s (COM=%d, Baud=%d из активного ЛУ)',
      [IniPath, FrPort, FrBaud])
  else
    FFirstRunMessage := Format(
      'Первый запуск: создан %s (COM=%d, Baud=%d по умолчанию; активное ЛУ не прочитано)',
      [IniPath, FrPort, FrBaud]);
end;

procedure TkktServerIndyForm.HideToTray;
begin
  if Assigned(FTrayIcon) then
  begin
    if FTrayIcon.Icon.Handle = 0 then
    begin
      if not Application.Icon.Empty then
        FTrayIcon.Icon.Assign(Application.Icon)
      else if not Icon.Empty then
        FTrayIcon.Icon.Assign(Icon);
    end;
    FTrayIcon.Visible := True;
  end;
  Hide;
  if Assigned(FVariantPrint) and Assigned(FVariantPrint.Logger) then
    FVariantPrint.Logger.LogInfo(
      'Окно скрыто в трей (процесс работает; выход через меню значка или HTTP /exit)');
end;

procedure TkktServerIndyForm.RestoreFromTray;
begin
  Show;
  WindowState := wsNormal;
  Application.BringToFront;
  SetForegroundWindow(Handle);
  if Assigned(FTrayIcon) then
    FTrayIcon.Visible := False;
end;

procedure TkktServerIndyForm.TrayIconDblClick(Sender: TObject);
begin
  RestoreFromTray;
end;

procedure TkktServerIndyForm.TrayExitClick(Sender: TObject);
begin
  if Assigned(FVariantPrint) and Assigned(FVariantPrint.Logger) then
    FVariantPrint.Logger.LogInfo('Меню трея: завершение процесса');
  RequestRealExit;
end;

procedure TkktServerIndyForm.RequestRealExit;
begin
  FAllowClose := True;
  if Assigned(FTrayIcon) then
    FTrayIcon.Visible := False;
  Application.Terminate;
end;

procedure TkktServerIndyForm.HandleHttpExitRequest(Sender: TObject);
begin
  // Indy вызывает из своего потока — Terminate только в UI-потоке.
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FVariantPrint) and Assigned(FVariantPrint.Logger) then
        FVariantPrint.Logger.LogInfo('HTTP /exit: завершение процесса');
      RequestRealExit;
    end);
end;

procedure TkktServerIndyForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FAllowClose then
  begin
    CanClose := True;
    Exit;
  end;
  CanClose := False;
  HideToTray;
end;

procedure TkktServerIndyForm.WMQueryEndSession(var Msg: TWMQueryEndSession);
begin
  // Завершение сеанса Windows — разрешаем реальный выход.
  FAllowClose := True;
  inherited;
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
  begin
    HttpServer := TFmuHttpServer.Create(KktPort, FVariantPrint);
    HttpServer.OnExitRequest := HandleHttpExitRequest;
  end;
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
    if FFirstRunMessage <> '' then
    begin
      FVariantPrint.Logger.LogInfo(FFirstRunMessage);
      FFirstRunMessage := '';
    end;
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
