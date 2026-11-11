unit uKktLog;

interface

uses
  Classes, System.SysUtils, System.SyncObjs, System.IniFiles, System.DateUtils;

type
  TKktLogLevel = (llOff, llError, llInfo, llDebug);
  TKktLogLineEvent = procedure(Sender: TObject; const Line: string) of object;

  TKktLogger = class
  private
    FLock: TCriticalSection;
    FEnabled: Boolean;
    FUiEnabled: Boolean;
    FLevel: TKktLogLevel;
    FPath: string;
    FMaxBodyLen: Integer;
    FLastHealthLog: TDateTime;
    FOnLogLine: TKktLogLineEvent;
    procedure WriteLine(const Prefix, Msg: string);
    function LevelEnabled(ALevel: TKktLogLevel): Boolean;
    function ShouldLogHealthRequest: Boolean;
  public
    constructor Create(ASettings: TCustomIniFile; const DefaultPath: string);
    destructor Destroy; override;

    procedure LogError(const Msg: string);
    procedure LogInfo(const Msg: string);
    procedure LogDebug(const Msg: string);
    procedure LogHttp(const Method, Path, Body, Response: string);

    property Enabled: Boolean read FEnabled;
    property UiEnabled: Boolean read FUiEnabled;
    property Path: string read FPath;
    property OnLogLine: TKktLogLineEvent read FOnLogLine write FOnLogLine;
  end;

implementation

var LogFileLock: TCriticalSection;

{ TKktLogger }

constructor TKktLogger.Create(ASettings: TCustomIniFile; const DefaultPath: string);
var
  LevelStr: string;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEnabled := ASettings.ReadBool('Log', 'Enabled', True);
  FUiEnabled := ASettings.ReadBool('Log', 'UiEnabled', True);
  FPath := ASettings.ReadString('Log', 'Path', DefaultPath);
  FMaxBodyLen := ASettings.ReadInteger('Log', 'MaxBodyLen', 4096);
  FLastHealthLog := 0;

  LevelStr := LowerCase(Trim(ASettings.ReadString('Log', 'Level', 'info')));
  if LevelStr = 'off' then
    FLevel := llOff
  else if LevelStr = 'error' then
    FLevel := llError
  else if LevelStr = 'debug' then
    FLevel := llDebug
  else
    FLevel := llInfo;
end;

destructor TKktLogger.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TKktLogger.LevelEnabled(ALevel: TKktLogLevel): Boolean;
begin
  Result := FEnabled and (FLevel <> llOff) and (Ord(ALevel) <= Ord(FLevel));
end;

procedure TKktLogger.WriteLine(const Prefix, Msg: string);
var
  Line: string;
  Stream: TFileStream; Bytes: TBytes;
  Handler: TKktLogLineEvent;
begin
  Line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' [' + Prefix + '] ' + Msg;

  if FUiEnabled then
  begin
    Handler := FOnLogLine;
    if Assigned(Handler) then
      Handler(Self, Line);
  end;

  if not FEnabled or (FLevel = llOff) then
    Exit;

  // Printer and HTTP server use separate logger instances for the same file.
  // Log I/O must never turn an accepted fiscal command into a failed operation.
  LogFileLock.Enter;
  try
    try
      if FileExists(FPath) then Stream := TFileStream.Create(FPath, fmOpenReadWrite or fmShareDenyWrite)
      else Stream := TFileStream.Create(FPath, fmCreate or fmShareDenyWrite);
      try
        Stream.Seek(0, soEnd);
        Bytes := TEncoding.UTF8.GetBytes(Line + sLineBreak);
        Stream.WriteBuffer(Bytes[0], Length(Bytes));
      finally Stream.Free; end;
    except
      on E: EInOutError do ;
      on E: EStreamError do ;
    end;
  finally LogFileLock.Leave; end;
end;

procedure TKktLogger.LogError(const Msg: string);
begin
  if LevelEnabled(llError) then
    WriteLine('ERROR', Msg);
end;

procedure TKktLogger.LogInfo(const Msg: string);
begin
  if LevelEnabled(llInfo) then
    WriteLine('INFO', Msg);
end;

procedure TKktLogger.LogDebug(const Msg: string);
begin
  if LevelEnabled(llDebug) then
    WriteLine('DEBUG', Msg);
end;

function TKktLogger.ShouldLogHealthRequest: Boolean;
const
  // Proxy опрашивает /health ~каждые 15 с — на info не чаще раза в 5 мин
  HealthLogIntervalSec = 300;
begin
  // debug: каждый запрос; info: с троттлингом
  if LevelEnabled(llDebug) then
    Exit(True);

  FLock.Enter;
  try
    Result := (FLastHealthLog = 0) or
      (SecondsBetween(Now, FLastHealthLog) >= HealthLogIntervalSec);
    if Result then
      FLastHealthLog := Now;
  finally
    FLock.Leave;
  end;
end;

procedure TKktLogger.LogHttp(const Method, Path, Body, Response: string);
var
  BodyPart, RespPart: string;
begin
  if not LevelEnabled(llInfo) then
    Exit;

  // GET /health от proxy не засоряет UI/файл на уровне info
  if SameText(Method, 'GET') and SameText(Path, '/health') and
     not ShouldLogHealthRequest then
    Exit;

  BodyPart := Body;
  if Length(BodyPart) > FMaxBodyLen then
    BodyPart := Copy(BodyPart, 1, FMaxBodyLen) + '...';

  RespPart := Response;
  if Length(RespPart) > FMaxBodyLen then
    RespPart := Copy(RespPart, 1, FMaxBodyLen) + '...';

  WriteLine('HTTP', Format('%s %s | body=%s | resp=%s',
    [Method, Path, BodyPart, RespPart]));
end;

initialization
  LogFileLock := TCriticalSection.Create;
finalization
  LogFileLock.Free;
end.
