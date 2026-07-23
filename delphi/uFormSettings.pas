unit uFormSettings;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IniFiles,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Samples.Spin;

const
  DefaultHttpPort = 2580;
  DefaultFrPort = 1;
  DefaultFrBaud = 6;
  DefaultFrPassword = 30;
  DefaultCashierName = 'Кассир';
  DefaultUiMaxLines = 2000;
  DefaultMaxBodyLen = 4096;

type
  TFormSettings = class(TForm)
    ScrollBox: TScrollBox;
    gbHttpServer: TGroupBox;
    lblHttpPort: TLabel;
    seHttpPort: TSpinEdit;
    gbFRCash: TGroupBox;
    lblFrPort: TLabel;
    seFrPort: TSpinEdit;
    lblFrBaud: TLabel;
    cbFrBaud: TComboBox;
    lblFrPassword: TLabel;
    seFrPassword: TSpinEdit;
    gbKKT: TGroupBox;
    chkEmulation: TCheckBox;
    chkTestReceiptMode: TCheckBox;
    pnlEmulation: TPanel;
    lblEmulatedSerial: TLabel;
    edEmulatedSerial: TEdit;
    lblEmulatedInn: TLabel;
    edEmulatedInn: TEdit;
    lblEmulatedFnNumber: TLabel;
    edEmulatedFnNumber: TEdit;
    lblEmulatedCheckNumber: TLabel;
    seEmulatedCheckNumber: TSpinEdit;
    lblEmulatedSessionNumber: TLabel;
    seEmulatedSessionNumber: TSpinEdit;
    gbLog: TGroupBox;
    chkLogEnabled: TCheckBox;
    chkLogUiEnabled: TCheckBox;
    lblLogUiMaxLines: TLabel;
    seLogUiMaxLines: TSpinEdit;
    lblLogPath: TLabel;
    edLogPath: TEdit;
    btnBrowseLogPath: TButton;
    lblLogLevel: TLabel;
    cbLogLevel: TComboBox;
    lblLogMaxBodyLen: TLabel;
    seLogMaxBodyLen: TSpinEdit;
    lblRestartHint: TLabel;
    pnlButtons: TPanel;
    btnOk: TButton;
    btnCancel: TButton;
    dlgSaveLog: TSaveDialog;
    procedure FormCreate(Sender: TObject);
    procedure chkEmulationClick(Sender: TObject);
    procedure btnBrowseLogPathClick(Sender: TObject);
    procedure btnOkClick(Sender: TObject);
  private
    FSettings: TCustomIniFile;
    FServerRunning: Boolean;
    procedure LoadFromIni;
    procedure SaveToIni;
    procedure UpdateEmulationPanel;
    procedure ApplyRunningRestrictions;
    function ValidateInput: Boolean;
    function BaudToComboIndex(Baud: Integer): Integer;
    function ComboIndexToBaud(Index: Integer): Integer;
  public
    /// <summary>%ProgramData%\CTO_KSM\kktserver — без прав админа.</summary>
    class function GetDataDirectory: string;
    class function GetSettingsFileName: string;
    class function GetDefaultLogFileName: string;
    class function Execute(ASettings: TCustomIniFile; ServerRunning: Boolean): Boolean;
    /// <summary>Записывает полный набор настроек по умолчанию (первый запуск).</summary>
    class procedure WriteDefaultSettings(ASettings: TCustomIniFile;
      FrPort: Integer = DefaultFrPort; FrBaud: Integer = DefaultFrBaud);
  end;

implementation

{$R *.dfm}

procedure TFormSettings.FormCreate(Sender: TObject);
begin
  cbFrBaud.Items.Clear;
  cbFrBaud.Items.Add('2400');
  cbFrBaud.Items.Add('4800');
  cbFrBaud.Items.Add('9600');
  cbFrBaud.Items.Add('19200');
  cbFrBaud.Items.Add('38400');
  cbFrBaud.Items.Add('57600');
  cbFrBaud.Items.Add('115200');
  cbFrBaud.Items.Add('230400');
  cbFrBaud.Items.Add('460800');
  cbFrBaud.Items.Add('921600');

  cbLogLevel.Items.Clear;
  cbLogLevel.Items.Add('off');
  cbLogLevel.Items.Add('error');
  cbLogLevel.Items.Add('info');
  cbLogLevel.Items.Add('debug');

  seHttpPort.MinValue := 1;
  seHttpPort.MaxValue := 65535;
  seFrPort.MinValue := 1;
  seFrPort.MaxValue := 256;
  seFrPassword.MinValue := 0;
  seFrPassword.MaxValue := 999999;
  seLogUiMaxLines.MinValue := 100;
  seLogUiMaxLines.MaxValue := 100000;
  seLogMaxBodyLen.MinValue := 256;
  seLogMaxBodyLen.MaxValue := 1048576;
  seEmulatedCheckNumber.MinValue := 0;
  seEmulatedCheckNumber.MaxValue := 999999999;
  seEmulatedSessionNumber.MinValue := 0;
  seEmulatedSessionNumber.MaxValue := 999999999;
end;

function TFormSettings.BaudToComboIndex(Baud: Integer): Integer;
begin
  if (Baud >= 0) and (Baud <= 9) then
    Result := Baud - 1
  else
    Result := DefaultFrBaud;
end;

function TFormSettings.ComboIndexToBaud(Index: Integer): Integer;
begin
  if (Index >= 0) and (Index <= 9) then
    Result := Index
  else
    Result := DefaultFrBaud;
end;

procedure TFormSettings.LoadFromIni;
var
  LevelStr: string;
  LevelIndex: Integer;
begin
  seHttpPort.Value := FSettings.ReadInteger('HttpServer', 'Port', DefaultHttpPort);

  seFrPort.Value := FSettings.ReadInteger('FRCash', 'Port', DefaultFrPort);
  cbFrBaud.ItemIndex := BaudToComboIndex(FSettings.ReadInteger('FRCash', 'Baud', DefaultFrBaud));
  seFrPassword.Value := FSettings.ReadInteger('FRCash', 'Password', DefaultFrPassword);

  chkEmulation.Checked := FSettings.ReadBool('KKT', 'Emulation', False);
  chkTestReceiptMode.Checked := FSettings.ReadBool('KKT', 'TestReceiptMode', False);
  edEmulatedSerial.Text := FSettings.ReadString('KKT', 'EmulatedSerial', '0000000000000001');
  edEmulatedInn.Text := FSettings.ReadString('KKT', 'EmulatedInn', '1234567890');
  edEmulatedFnNumber.Text := FSettings.ReadString('KKT', 'EmulatedFnNumber', '9999078900000001');
  seEmulatedCheckNumber.Value := FSettings.ReadInteger('KKT', 'EmulatedCheckNumber', 0);
  seEmulatedSessionNumber.Value := FSettings.ReadInteger('KKT', 'EmulatedSessionNumber', 0);

  chkLogEnabled.Checked := FSettings.ReadBool('Log', 'Enabled', True);
  chkLogUiEnabled.Checked := FSettings.ReadBool('Log', 'UiEnabled', True);
  seLogUiMaxLines.Value := FSettings.ReadInteger('Log', 'UiMaxLines', DefaultUiMaxLines);
  edLogPath.Text := FSettings.ReadString('Log', 'Path', GetDefaultLogFileName);
  seLogMaxBodyLen.Value := FSettings.ReadInteger('Log', 'MaxBodyLen', DefaultMaxBodyLen);

  LevelStr := LowerCase(Trim(FSettings.ReadString('Log', 'Level', 'info')));
  LevelIndex := cbLogLevel.Items.IndexOf(LevelStr);
  if LevelIndex < 0 then
    LevelIndex := cbLogLevel.Items.IndexOf('info');
  cbLogLevel.ItemIndex := LevelIndex;

  UpdateEmulationPanel;
  ApplyRunningRestrictions;
end;

procedure TFormSettings.SaveToIni;
begin
  FSettings.WriteInteger('HttpServer', 'Port', seHttpPort.Value);

  FSettings.WriteInteger('FRCash', 'Port', seFrPort.Value);
  FSettings.WriteInteger('FRCash', 'Baud', ComboIndexToBaud(cbFrBaud.ItemIndex));
  FSettings.WriteInteger('FRCash', 'Password', seFrPassword.Value);

  FSettings.WriteBool('KKT', 'Emulation', chkEmulation.Checked);
  FSettings.WriteBool('KKT', 'TestReceiptMode', chkTestReceiptMode.Checked);
  FSettings.WriteString('KKT', 'EmulatedSerial', Trim(edEmulatedSerial.Text));
  FSettings.WriteString('KKT', 'EmulatedInn', Trim(edEmulatedInn.Text));
  FSettings.WriteString('KKT', 'EmulatedFnNumber', Trim(edEmulatedFnNumber.Text));
  FSettings.WriteInteger('KKT', 'EmulatedCheckNumber', seEmulatedCheckNumber.Value);
  FSettings.WriteInteger('KKT', 'EmulatedSessionNumber', seEmulatedSessionNumber.Value);

  FSettings.WriteBool('Log', 'Enabled', chkLogEnabled.Checked);
  FSettings.WriteBool('Log', 'UiEnabled', chkLogUiEnabled.Checked);
  FSettings.WriteInteger('Log', 'UiMaxLines', seLogUiMaxLines.Value);
  FSettings.WriteString('Log', 'Path', Trim(edLogPath.Text));
  if cbLogLevel.ItemIndex >= 0 then
    FSettings.WriteString('Log', 'Level', cbLogLevel.Items[cbLogLevel.ItemIndex])
  else
    FSettings.WriteString('Log', 'Level', 'info');
  FSettings.WriteInteger('Log', 'MaxBodyLen', seLogMaxBodyLen.Value);

  FSettings.UpdateFile;
end;

procedure TFormSettings.UpdateEmulationPanel;
begin
  pnlEmulation.Enabled := chkEmulation.Checked;
end;

procedure TFormSettings.ApplyRunningRestrictions;
begin
  gbHttpServer.Enabled := not FServerRunning;
  gbFRCash.Enabled := not FServerRunning;
  gbKKT.Enabled := not FServerRunning;

  if FServerRunning then
    lblRestartHint.Caption :=
      'Сервер запущен: HTTP, ККТ и эмуляция недоступны для изменения. ' +
      'Остановите сервер и запустите снова, чтобы применить эти параметры.'
  else
    lblRestartHint.Caption :=
      'Изменения HTTP-порта, параметров COM и режима эмуляции вступят в силу после перезапуска сервера.';
end;

function TFormSettings.ValidateInput: Boolean;
begin
  Result := False;

  if Trim(edLogPath.Text) = '' then
  begin
    ShowMessage('Укажите путь к файлу лога.');
    ActiveControl := edLogPath;
    Exit;
  end;

  if cbLogLevel.ItemIndex < 0 then
  begin
    ShowMessage('Выберите уровень логирования.');
    ActiveControl := cbLogLevel;
    Exit;
  end;

  Result := True;
end;

procedure TFormSettings.chkEmulationClick(Sender: TObject);
begin
  UpdateEmulationPanel;
end;

procedure TFormSettings.btnBrowseLogPathClick(Sender: TObject);
var
  Dir, FileName: string;
begin
  FileName := Trim(edLogPath.Text);
  if FileName = '' then
    FileName := GetDefaultLogFileName;

  dlgSaveLog.FileName := ExtractFileName(FileName);
  Dir := ExtractFilePath(FileName);
  if (Dir <> '') and DirectoryExists(Dir) then
    dlgSaveLog.InitialDir := Dir
  else
    dlgSaveLog.InitialDir := GetDataDirectory;

  if dlgSaveLog.Execute then
    edLogPath.Text := dlgSaveLog.FileName;
end;

procedure TFormSettings.btnOkClick(Sender: TObject);
begin
  if not ValidateInput then
    ModalResult := mrNone
  else
    ModalResult := mrOk;
end;

class function TFormSettings.GetDataDirectory: string;
var
  ProgramData: string;
begin
  ProgramData := GetEnvironmentVariable('PROGRAMDATA');
  if ProgramData = '' then
    ProgramData := 'C:\ProgramData';
  Result := IncludeTrailingPathDelimiter(ProgramData) + 'CTO_KSM\kktserver';
  ForceDirectories(Result);
end;

class function TFormSettings.GetSettingsFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(GetDataDirectory) + 'kktserverindy.ini';
end;

class function TFormSettings.GetDefaultLogFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(GetDataDirectory) + 'kktserver.log';
end;

class function TFormSettings.Execute(ASettings: TCustomIniFile; ServerRunning: Boolean): Boolean;
var
  Form: TFormSettings;
begin
  Form := TFormSettings.Create(nil);
  try
    Form.FSettings := ASettings;
    Form.FServerRunning := ServerRunning;
    Form.LoadFromIni;
    Result := Form.ShowModal = mrOk;
    if Result then
      Form.SaveToIni;
  finally
    Form.Free;
  end;
end;

class procedure TFormSettings.WriteDefaultSettings(ASettings: TCustomIniFile;
  FrPort, FrBaud: Integer);
begin
  if ASettings = nil then
    Exit;

  if FrPort < 1 then
    FrPort := DefaultFrPort;
  if (FrBaud < 0) or (FrBaud > 9) then
    FrBaud := DefaultFrBaud;

  ASettings.WriteInteger('HttpServer', 'Port', DefaultHttpPort);

  ASettings.WriteInteger('FRCash', 'Port', FrPort);
  ASettings.WriteInteger('FRCash', 'Baud', FrBaud);
  ASettings.WriteInteger('FRCash', 'Password', DefaultFrPassword);
  ASettings.WriteString('FRCash', 'CashierName', DefaultCashierName);

  ASettings.WriteBool('KKT', 'Emulation', False);
  ASettings.WriteBool('KKT', 'TestReceiptMode', False);
  ASettings.WriteString('KKT', 'EmulatedSerial', '0000000000000001');
  ASettings.WriteString('KKT', 'EmulatedInn', '1234567890');
  ASettings.WriteString('KKT', 'EmulatedRegNumber', '1234567111890');
  ASettings.WriteString('KKT', 'EmulatedFnNumber', '9999078900000001');
  ASettings.WriteInteger('KKT', 'EmulatedCheckNumber', 0);
  ASettings.WriteInteger('KKT', 'EmulatedSessionNumber', 0);

  ASettings.WriteBool('Log', 'Enabled', True);
  ASettings.WriteBool('Log', 'UiEnabled', True);
  ASettings.WriteInteger('Log', 'UiMaxLines', DefaultUiMaxLines);
  ASettings.WriteString('Log', 'Path', GetDefaultLogFileName);
  ASettings.WriteString('Log', 'Level', 'info');
  ASettings.WriteInteger('Log', 'MaxBodyLen', DefaultMaxBodyLen);

  ASettings.UpdateFile;
end;

end.
