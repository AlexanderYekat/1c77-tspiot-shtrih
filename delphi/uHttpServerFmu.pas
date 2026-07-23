unit uHttpServerFmu;

interface

uses
  IdContext, IdCustomHTTPServer, IdHTTPServer, IdGlobal,
  SysUtils, Classes,
  uVariantPrint; // ваш модуль с KktInfoJson, PrintCheckJson и т.д.

type
  TFmuHttpServer = class
  private
    FServer: TIdHTTPServer;
    FVariantPrint: TVariantPrint;
    FServiceName: string;
    FServiceVersion: string;
    function BuildHealthJson: string;
    procedure ServerCommandGet(AContext: TIdContext;
      ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
    function ReadBody(ARequestInfo: TIdHTTPRequestInfo): string;
    procedure WriteJson(AResponseInfo: TIdHTTPResponseInfo;
      const AJson: string; AStatusCode: Integer = 200);
    procedure WriteError(AResponseInfo: TIdHTTPResponseInfo;
      const AMessage: string; AStatusCode: Integer = 500);
  protected FActive:boolean;
    function GetActive:boolean;
  public
    class function ReadExeFileVersion: string;
    constructor Create(APort: Integer; AVariantPrint: TVariantPrint);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Active:boolean read GetActive;
  end;

implementation

uses
  Winapi.Windows;

function JsonEscapeHealth(const S: string): string;
begin
  Result := S.Replace('\', '\\')
             .Replace('"', '\"')
             .Replace(#13, '\r')
             .Replace(#10, '\n')
             .Replace(#9, '\t');
end;

{ TFmuHttpServer }

class function TFmuHttpServer.ReadExeFileVersion: string;
var
  Size, Handle: DWORD;
  Buffer: Pointer;
  Value: PVSFixedFileInfo;
  Len: UINT;
begin
  Result := '0.0.0.0';
  Size := GetFileVersionInfoSize(PChar(ParamStr(0)), Handle);
  if Size = 0 then
    Exit;
  GetMem(Buffer, Size);
  try
    if not GetFileVersionInfo(PChar(ParamStr(0)), 0, Size, Buffer) then
      Exit;
    if VerQueryValue(Buffer, '\', Pointer(Value), Len) then
      Result := Format('%d.%d.%d.%d',
        [HiWord(Value^.dwFileVersionMS), LoWord(Value^.dwFileVersionMS),
         HiWord(Value^.dwFileVersionLS), LoWord(Value^.dwFileVersionLS)]);
  finally
    FreeMem(Buffer);
  end;
end;

function TFmuHttpServer.BuildHealthJson: string;
begin
  Result := Format(
    '{"result":1,"description":"OK","service":"%s","status":"up","version":"%s"}',
    [JsonEscapeHealth(FServiceName), JsonEscapeHealth(FServiceVersion)]);
end;

constructor TFmuHttpServer.Create(APort: Integer; AVariantPrint: TVariantPrint);
begin
  inherited Create;
  FVariantPrint := AVariantPrint;
  FServiceName := 'kktserverindy';
  FServiceVersion := ReadExeFileVersion;
  FServer := TIdHTTPServer.Create(nil);
  FServer.DefaultPort := APort;
  FServer.OnCommandGet := ServerCommandGet;
  // Indy по умолчанию шлёт GET/POST/PUT/DELETE в OnCommandGet,
  // если не назначен отдельный OnCommandOther — этого достаточно,
  // различаем по ARequestInfo.Command внутри одного обработчика.
end;

destructor TFmuHttpServer.Destroy;
begin
  Stop;
  FServer.Free;
  inherited;
end;

procedure TFmuHttpServer.Start;
begin
  FServer.Active := True;
end;

procedure TFmuHttpServer.Stop;
begin
  if FServer.Active then
    FServer.Active := False;
end;

function TFmuHttpServer.ReadBody(ARequestInfo: TIdHTTPRequestInfo): string;
var
  Stream: TStringStream;
begin
  Result := '';
  if Assigned(ARequestInfo.PostStream) then
  begin
    Stream := TStringStream.Create('', TEncoding.UTF8);
    try
      ARequestInfo.PostStream.Position := 0;
      Stream.CopyFrom(ARequestInfo.PostStream, 0);
      Result := Stream.DataString;
    finally
      Stream.Free;
    end;
  end
  else
    Result := ARequestInfo.FormParams; // fallback, если тело уже распарсено Indy
end;

procedure TFmuHttpServer.WriteJson(AResponseInfo: TIdHTTPResponseInfo;
  const AJson: string; AStatusCode: Integer = 200);
begin
  AResponseInfo.ResponseNo := AStatusCode;
  AResponseInfo.ContentType := 'application/json; charset=utf-8';
  AResponseInfo.ContentText := AJson;
  // Indy сам корректно посчитает ContentLength в байтах UTF-8,
  // но если наблюдаете обрезание кириллицы — раскомментируйте:
  // AResponseInfo.ContentEncoding := 'utf-8';
end;

procedure TFmuHttpServer.WriteError(AResponseInfo: TIdHTTPResponseInfo;
  const AMessage: string; AStatusCode: Integer = 500);
begin
  // тот же контракт, что JsonError в uVariantPrint: result + description
  WriteJson(AResponseInfo,
    Format('{"result":0,"description":"%s"}', [JsonEscapeHealth(AMessage)]),
    AStatusCode);
end;

procedure TFmuHttpServer.ServerCommandGet(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Path, Method, Body, ResultJson: string;
begin
  Path := ARequestInfo.Document;   // например '/print-check'
  Method := ARequestInfo.Command;  // 'GET' / 'POST' / ...
  Body := '';

  try
    if (Method = 'GET') and (Path = '/health') then
    begin
      ResultJson := BuildHealthJson;
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'GET') and (Path = '/info') then
    begin
      ResultJson := FVariantPrint.KktInfoJson;
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'GET') and (Path = '/connection-status') then
    begin
      ResultJson := FVariantPrint.KktConnectionStatusJson;
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/print-check') then
    begin
      Body := ReadBody(ARequestInfo);
      ResultJson := FVariantPrint.PrintCheckJson(Body);
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/close-shift') then
    begin
      Body := ReadBody(ARequestInfo);
      ResultJson := FVariantPrint.CloseShiftJson(Body);
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/open-shift') then
    begin
      Body := ReadBody(ARequestInfo);
      ResultJson := FVariantPrint.OpenShiftJson(Body);
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/x-report') then
    begin
      Body := ReadBody(ARequestInfo);
      ResultJson := FVariantPrint.XReportJson(Body);
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/cancel-check') then
    begin
      Body := ReadBody(ARequestInfo);
      ResultJson := FVariantPrint.CancelCheckJson(Body);
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/connect') then
    begin
      ResultJson := FVariantPrint.ConnectJson;
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/disconnect') then
    begin
      ResultJson := FVariantPrint.DisconnectJson;
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/clear-buffer-of-marks') then
    begin
      Body := ReadBody(ARequestInfo);
      ResultJson := FVariantPrint.ClearBufferOfMarksJson(Body);
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'POST') and (Path = '/check-marks') then
    begin
      Body := ReadBody(ARequestInfo);
      ResultJson := FVariantPrint.CheckMarkJson(Body);
      WriteJson(AResponseInfo, ResultJson);
    end
    else if (Method = 'GET') and (Path = '/check-marks/status') then
    begin
      ResultJson := FVariantPrint.CheckMarkStatusJson(ARequestInfo.Params.Values['taskId']);
      WriteJson(AResponseInfo, ResultJson);
    end
    else
    begin
      WriteError(AResponseInfo, 'Not found: ' + Method + ' ' + Path, 404);
      if Assigned(FVariantPrint) and Assigned(FVariantPrint.Logger) then
        FVariantPrint.Logger.LogHttp(Method, Path, Body, '404 Not found');
      Exit;
    end;

    if Assigned(FVariantPrint) and Assigned(FVariantPrint.Logger) then
      FVariantPrint.Logger.LogHttp(Method, Path, Body, ResultJson);
  except
    on E: Exception do
    begin
      if Assigned(FVariantPrint) and Assigned(FVariantPrint.Logger) then
        FVariantPrint.Logger.LogError('HTTP ' + Method + ' ' + Path + ': ' + E.Message);
      WriteError(AResponseInfo, E.Message, 500);
    end;
  end;
end;


function TFmuHttpServer.GetActive: boolean;
begin
  Result := FServer.Active;
end;
end.
