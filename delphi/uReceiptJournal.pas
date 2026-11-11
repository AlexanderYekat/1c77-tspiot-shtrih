unit uReceiptJournal;

interface

uses System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  System.Hash, System.IOUtils, Winapi.Windows;

type
  TReceiptExecute = function(const Body: string): string of object;
  // One worker owns the live receipt stack. A lost HTTP response never restarts it.
  TReceiptJournal = class
  private
    FLock: TCriticalSection;
    FDirectory, FId, FHash, FResponse: string;
    FWorker: TThread;
    FBusy: Boolean;
    FStopping: Integer;
    procedure Save;
    function ReadSaved(const Id: string; out Hash: string): string;
  public
    constructor Create(const Directory: string);
    destructor Destroy; override;
    function Submit(const Id, Body: string; const Execute: TReceiptExecute): string;
    function Status(const Id: string): string;
    procedure Progress(const State, Description: string);
    function Busy: Boolean;
    function Stopping: Boolean;
    class function Response(const Id, State, Description: string; Ok: Boolean): string; static;
  end;

implementation

function ValidId(const Id: string): Boolean;
var G: TGUID;
begin
  Result := False;
  if Length(Id) <> 36 then Exit;
  try
    G := StringToGUID('{' + Id + '}');
    Result := SameText(GUIDToString(G), '{' + Id + '}');
  except
    on E: EConvertError do Result := False;
  end;
end;

class function TReceiptJournal.Response(const Id, State, Description: string; Ok: Boolean): string;
var J: TJSONObject;
begin
  J := TJSONObject.Create;
  try
    J.AddPair('result', TJSONNumber.Create(Ord(Ok)));
    J.AddPair('operationId', Id);
    J.AddPair('state', State);
    J.AddPair('description', Description);
    Result := J.ToJSON;
  finally J.Free; end;
end;

constructor TReceiptJournal.Create(const Directory: string);
begin
  inherited Create;
  FDirectory := IncludeTrailingPathDelimiter(Directory);
  FLock := TCriticalSection.Create;
end;

destructor TReceiptJournal.Destroy;
begin
  TInterlocked.Exchange(FStopping, 1);
  if Assigned(FWorker) then begin FWorker.WaitFor; FWorker.Free; end;
  FLock.Free;
  inherited;
end;

function TReceiptJournal.Stopping: Boolean;
begin
  Result := TInterlocked.CompareExchange(FStopping, 0, 0) <> 0;
end;

function TReceiptJournal.Busy: Boolean;
begin
  FLock.Enter;
  try Result := FBusy; finally FLock.Leave; end;
end;

procedure TReceiptJournal.Save;
var J: TJSONObject; Bytes: TBytes; Stream: TFileStream; Target, Temp: string;
begin
  if not ForceDirectories(FDirectory) then
    raise Exception.Create('Не удалось создать журнал кассовых операций');
  Target := FDirectory + FId + '.json';
  Temp := Target + '.tmp';
  J := TJSONObject.Create;
  try
    J.AddPair('hash', FHash);
    J.AddPair('response', TJSONObject.ParseJSONValue(FResponse));
    Bytes := TEncoding.UTF8.GetBytes(J.ToJSON);
  finally J.Free; end;
  Stream := TFileStream.Create(Temp, fmCreate or fmShareExclusive);
  try
    if Length(Bytes) > 0 then Stream.WriteBuffer(Bytes[0], Length(Bytes));
    if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError;
  finally Stream.Free; end;
  if not MoveFileEx(PChar(Temp), PChar(Target), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

function TReceiptJournal.ReadSaved(const Id: string; out Hash: string): string;
var J, R: TJSONObject; State, Target: string;
begin
  Result := ''; Hash := '';
  Target := FDirectory + Id + '.json';
  if not FileExists(Target) then begin
    // A torn initial write is also not permission to repeat an operation.
    if FileExists(Target + '.tmp') then
      Result := Response(Id, 'uncertain', 'Журнал операции повреждён; сверьте чек на ККТ.', False);
    Exit;
  end;
  J := TJSONObject.ParseJSONValue(TFile.ReadAllText(Target, TEncoding.UTF8)) as TJSONObject;
  try
    if J = nil then raise Exception.Create('Повреждён журнал операции');
    Hash := J.GetValue<string>('hash');
    R := J.GetValue<TJSONObject>('response');
    State := R.GetValue<string>('state');
    if (State = 'running') or (State = 'waiting_for_paper') or (State = 'printing') then
      Result := Response(Id, 'uncertain', 'Служба перезапущена до сохранения результата. Повторной продажи не будет; сверьте чек на ККТ.', False)
    else Result := R.ToJSON;
  finally J.Free; end;
end;

function TReceiptJournal.Status(const Id: string): string;
var Hash: string;
begin
  if not ValidId(Id) then Exit(Response(Id, 'invalid', 'Некорректный operationId', False));
  FLock.Enter;
  try
    if SameText(FId, Id) then Result := FResponse
    else Result := ReadSaved(LowerCase(Id), Hash);
    if Result = '' then Result := Response(Id, 'not_found', 'Операция не найдена', False);
  finally FLock.Leave; end;
end;

procedure TReceiptJournal.Progress(const State, Description: string);
var Next: string;
begin
  FLock.Enter;
  try
    Next := Response(FId, State, Description, True);
    if Next = FResponse then Exit;
    FResponse := Next;
    Save;
  finally FLock.Leave; end;
end;

function TReceiptJournal.Submit(const Id, Body: string; const Execute: TReceiptExecute): string;
var Saved, Hash, NewHash, Key: string; R: TJSONObject;
begin
  if not ValidId(Id) then Exit(Response(Id, 'invalid', 'Некорректный operationId', False));
  Key := LowerCase(Id);
  NewHash := THashSHA2.GetHashString(Body);
  FLock.Enter;
  try
    Saved := '';
    if FId = Key then begin Saved := FResponse; Hash := FHash; end
    else Saved := ReadSaved(Key, Hash);
    if Saved <> '' then begin
      R := TJSONObject.ParseJSONValue(Saved) as TJSONObject;
      try
        // A pre-flight refusal has not started a receipt and can be corrected.
        if R.GetValue<string>('state') <> 'rejected' then begin
          if Hash <> NewHash then Exit(Response(Key, 'conflict', 'Состав ранее отправленного чека изменён. Восстановите исходный чек; новая продажа не выполнялась.', False));
          Exit(Saved);
        end;
      finally R.Free; end;
    end;
    if FBusy then Exit(Response(Key, 'busy', 'На ККТ продолжается предыдущий чек.', False));
    if Stopping then Exit(Response(Key, 'unavailable', 'Служба останавливается', False));
    if Assigned(FWorker) then begin FWorker.WaitFor; FreeAndNil(FWorker); end;
    FId := Key; FHash := NewHash;
    FResponse := Response(Key, 'running', 'Чек передан на ККТ', True);
    try
      Save; // Durable reservation precedes the first device command.
    except
      on E: Exception do begin
        FResponse := Response(Key, 'rejected', 'Не записан журнал; печать не начиналась: ' + E.Message, False);
        Exit(FResponse);
      end;
    end;
    FBusy := True;
    try
      FWorker := TThread.CreateAnonymousThread(procedure
      var FinalResponse: string; J: TJSONObject;
      begin
        try
          FinalResponse := Execute(Body);
          J := TJSONObject.ParseJSONValue(FinalResponse) as TJSONObject;
          try
            if J = nil then raise Exception.Create('Некорректный результат печати');
            J.RemovePair('operationId').Free;
            J.AddPair('operationId', Key);
            FinalResponse := J.ToJSON;
          finally J.Free; end;
        except
          on E: Exception do FinalResponse := Response(Key, 'uncertain', E.Message, False);
        end;
        FLock.Enter;
        try
          FResponse := FinalResponse;
          try Save;
          except on E: Exception do
            FResponse := Response(Key, 'uncertain', 'Не сохранён результат: ' + E.Message, False);
          end;
          FBusy := False;
        finally FLock.Leave; end;
      end);
      FWorker.FreeOnTerminate := False;
      FWorker.Start;
    except
      FBusy := False;
      raise;
    end;
    Result := FResponse;
  finally FLock.Leave; end;
end;

end.
