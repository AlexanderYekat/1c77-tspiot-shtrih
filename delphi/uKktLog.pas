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
    FOnLogLine: TKktLogLineEvent;
    procedure WriteLine(const Prefix, Msg: string);
    function LevelEnabled(ALevel: TKktLogLevel): Boolean;
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
  SL: TStringList;
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

  FLock.Enter;
  try
    SL := TStringList.Create;
    try
      if FileExists(FPath) then
        SL.LoadFromFile(FPath, TEncoding.UTF8);
      SL.Add(Line);
      SL.SaveToFile(FPath, TEncoding.UTF8);
    finally
      SL.Free;
    end;
  finally
    FLock.Leave;
  end;
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

procedure TKktLogger.LogHttp(const Method, Path, Body, Response: string);
var
  BodyPart, RespPart: string;
begin
  if not LevelEnabled(llInfo) then
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

end.
