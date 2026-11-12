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
    FOwner: THandle;
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
    function Resolve(Request: TJSONObject; const DeviceSerial: string): string;
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
  FOwner := INVALID_HANDLE_VALUE;
  if not ForceDirectories(FDirectory) then raise Exception.Create('Не создан журнал чеков');
  // A second service process must not execute receipts from the same journal.
  FOwner := CreateFile(PChar(FDirectory + 'owner.lock'), GENERIC_READ or GENERIC_WRITE,
    0, nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FOwner = INVALID_HANDLE_VALUE then
    raise Exception.Create('Журнал чеков уже используется другим процессом или недоступен');
end;

destructor TReceiptJournal.Destroy;
begin
  TInterlocked.Exchange(FStopping, 1);
  if Assigned(FWorker) then begin FWorker.WaitFor; FWorker.Free; end;
  if FOwner <> INVALID_HANDLE_VALUE then CloseHandle(FOwner);
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
var J, Previous, R: TJSONObject; History: TJSONArray; G: TGUID;
  Bytes: TBytes; Stream: TFileStream; Target, Temp: string;
begin
  if not ForceDirectories(FDirectory) then
    raise Exception.Create('Не удалось создать журнал кассовых операций');
  Target := FDirectory + FId + '.json';
  Temp := Target + '.tmp';
  J := TJSONObject.Create;
  try
    History := TJSONArray.Create;
    J.AddPair('history', History);
    if FileExists(Target) then begin
      Previous := TJSONObject.ParseJSONValue(TFile.ReadAllText(Target, TEncoding.UTF8)) as TJSONObject;
      try
        if Previous = nil then raise Exception.Create('Повреждена история операции');
        if Previous.GetValue('history') is TJSONArray then begin
          J.RemovePair('history').Free;
          History := TJSONObject.ParseJSONValue(Previous.GetValue('history').ToJSON) as TJSONArray;
          J.AddPair('history', History);
        end;
        if Previous.GetValue('response') <> nil then
          History.AddElement(TJSONObject.ParseJSONValue(Previous.GetValue('response').ToJSON));
      finally Previous.Free; end;
    end;
    R := TJSONObject.ParseJSONValue(FResponse) as TJSONObject;
    if R = nil then raise Exception.Create('Некорректный результат для журнала');
    J.AddPair('response', R);
    R.RemovePair('revision').Free;
    R.RemovePair('savedAt').Free;
    CreateGUID(G);
    R.AddPair('revision', GUIDToString(G));
    R.AddPair('savedAt', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now));
    J.AddPair('hash', FHash);
    FResponse := R.ToJSON;
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
var J, R, Converted: TJSONObject; State, Target, Raw: string;
begin
  Result := ''; Hash := '';
  Target := FDirectory + Id + '.json';
  if not FileExists(Target) then begin
    // A torn initial write is also not permission to repeat an operation.
    if FileExists(Target + '.tmp') then
      Result := Response(Id, 'uncertain', 'Журнал операции повреждён; сверьте чек на ККТ.', False);
    Exit;
  end;
  Raw := TFile.ReadAllText(Target, TEncoding.UTF8);
  J := TJSONObject.ParseJSONValue(Raw) as TJSONObject;
  try
    if J = nil then raise Exception.Create('Повреждён журнал операции');
    Hash := J.GetValue<string>('hash');
    R := J.GetValue<TJSONObject>('response');
    State := R.GetValue<string>('state');
    if (State = 'running') or (State = 'waiting_for_paper') or (State = 'printing') then
      Result := Response(Id, 'uncertain', 'Служба перезапущена до сохранения результата. Повторной продажи не будет; сверьте чек на ККТ.', False)
    else Result := R.ToJSON;
    Converted := TJSONObject.ParseJSONValue(Result) as TJSONObject;
    try
      if Converted.GetValue('revision') = nil then
        Converted.AddPair('revision', R.GetValue<string>('revision', THashSHA2.GetHashString(Raw)));
      if Converted.GetValue('savedAt') = nil then
        Converted.AddPair('savedAt', R.GetValue<string>('savedAt',
          FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', TFile.GetLastWriteTime(Target))));
      // A known closed receipt must never be authorized for another sale.
      if (Converted.GetValue('fiscalClosed') = nil) and (R.GetValue('fiscalClosed') <> nil) then
        Converted.AddPair('fiscalClosed', TJSONObject.ParseJSONValue(R.GetValue('fiscalClosed').ToJSON));
      Result := Converted.ToJSON;
    finally Converted.Free; end;
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
var Next: string; Current: TJSONObject;
begin
  FLock.Enter;
  try
    Next := Response(FId, State, Description, True);
    Current := TJSONObject.ParseJSONValue(FResponse) as TJSONObject;
    try
      if (Current <> nil) and (Current.GetValue<string>('state', '') = State) and
        (Current.GetValue<string>('description', '') = Description) then Exit;
    finally Current.Free; end;
    FResponse := Next;
    Save;
  finally FLock.Leave; end;
end;

function TReceiptJournal.Resolve(Request: TJSONObject; const DeviceSerial: string): string;
var Id, Hash, Saved, Action, Evidence, OperatorName, Expected: string;
  OldResponse, NextResponse, Audit: TJSONObject; Number: Integer;
begin
  Id := LowerCase(Request.GetValue<string>('operationId', ''));
  if not ValidId(Id) then Exit(Response(Id, 'invalid', 'Некорректный operationId', False));
  FLock.Enter;
  try
    if FBusy or Stopping then Exit(Response(Id, 'busy', 'Продолжается прежний чек', False));
    if FId = Id then begin Saved := FResponse; Hash := FHash; end
    else Saved := ReadSaved(Id, Hash);
    if (Saved = '') or (Hash = '') then
      Exit(Response(Id, 'invalid', 'Нет целой записи операции; автоматическое восстановление запрещено', False));
    OldResponse := TJSONObject.ParseJSONValue(Saved) as TJSONObject;
    try
      if OldResponse.GetValue<string>('state', '') <> 'uncertain' then Exit(Saved);
      Expected := Request.GetValue<string>('revision', '');
      if (Expected = '') or (Expected <> OldResponse.GetValue<string>('revision', '')) then
        Exit(Response(Id, 'conflict', 'Результат изменился. Заново получите состояние и выполните сверку', False));
      Action := Request.GetValue<string>('action', '');
      Evidence := Trim(Request.GetValue<string>('evidence', ''));
      OperatorName := Trim(Request.GetValue<string>('operator', ''));
      if not Request.GetValue<Boolean>('confirmed', False) or (Length(Evidence) < 20) or
        (Length(Evidence) > 2000) or (OperatorName = '') or (Length(OperatorName) > 200) then
        Exit(Response(Id, 'invalid', 'Нужны подтверждение сверки ФН/ОФД, основание и имя специалиста', False));
      if (Action <> 'retry') and (Action <> 'completed') then
        Exit(Response(Id, 'invalid', 'Неизвестный результат сверки', False));
      if (Action = 'retry') and OldResponse.GetValue<Boolean>('fiscalClosed', False) then
        Exit(Response(Id, 'blocked', 'ККТ уже подтвердила закрытие чека. Разрешено только восстановить результат', False));
      if not SameText(Request.GetValue<string>('serialNumber', ''), DeviceSerial) then
        Exit(Response(Id, 'conflict', 'Заводской номер сверенной ККТ не совпадает с подключённой', False));
      Number := Request.GetValue<Integer>('checkNumber', 0);
      if (Action = 'completed') and ((Number <= 0) or
        (Trim(Request.GetValue<string>('fiscalDocument', '')) = '') or
        (Trim(Request.GetValue<string>('fiscalSign', '')) = '')) then
        Exit(Response(Id, 'invalid', 'Укажите номер чека, номер ФД и ФП из подтверждённого документа ФН/ОФД', False));
      if Action = 'retry' then
        NextResponse := TJSONObject.ParseJSONValue(Response(Id, 'retry_authorized',
          'Отсутствие чека подтверждено специалистом. Повторите проверку марок и пробейте тот же документ. Оплату картой повторять не нужно.', True)) as TJSONObject
      else begin
        NextResponse := TJSONObject.ParseJSONValue(Response(Id, 'completed',
          'Результат восстановлен по фискальному документу. Повторной фискализации и оплаты не было.', True)) as TJSONObject;
        NextResponse.AddPair('checkNumber', TJSONNumber.Create(Number));
        NextResponse.AddPair('serialNumber', DeviceSerial);
        NextResponse.AddPair('fiscalClosed', TJSONBool.Create(True));
      end;
      try
        Audit := TJSONObject.Create;
        NextResponse.AddPair('reconciliation', Audit);
        Audit.AddPair('action', Action);
        Audit.AddPair('operator', OperatorName);
        Audit.AddPair('evidence', Evidence);
        Audit.AddPair('serialNumber', DeviceSerial);
        Audit.AddPair('fiscalDocument', Request.GetValue<string>('fiscalDocument', ''));
        Audit.AddPair('fiscalSign', Request.GetValue<string>('fiscalSign', ''));
        Audit.AddPair('previousRevision', Expected);
        Audit.AddPair('previousSavedAt', OldResponse.GetValue<string>('savedAt', ''));
        FId := Id; FHash := Hash; FResponse := NextResponse.ToJSON;
        try Save;
        except
          // No device command was issued. Preserve the original reservation in memory.
          FResponse := Saved;
          raise;
        end;
        Result := FResponse;
      finally NextResponse.Free; end;
    finally OldResponse.Free; end;
  finally FLock.Leave; end;
end;

function TReceiptJournal.Submit(const Id, Body: string; const Execute: TReceiptExecute): string;
var Saved, Hash, NewHash, Key, FileName, OtherId: string; R, Req: TJSONObject;
begin
  if not ValidId(Id) then Exit(Response(Id, 'invalid', 'Некорректный operationId', False));
  Key := LowerCase(Id);
  Req := TJSONObject.ParseJSONValue(Body) as TJSONObject;
  try
    if (Req <> nil) and (Req.GetValue('documentId') <> nil) and
      not SameText(Req.GetValue<string>('documentId'), Key) then
      Exit(Response(Key, 'conflict', 'Идентификатор документа не совпадает с операцией. Используйте исходный документ.', False));
  finally Req.Free; end;
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
          if R.GetValue<string>('state') <> 'retry_authorized' then Exit(Saved);
        end;
      finally R.Free; end;
    end;
    if FBusy then Exit(Response(Key, 'busy', 'На ККТ продолжается предыдущий чек.', False));
    if Stopping then Exit(Response(Key, 'unavailable', 'Служба останавливается', False));
    // Changing operationId cannot escape an unresolved receipt on this KKT.
    for FileName in TDirectory.GetFiles(FDirectory, '*.json') do begin
      OtherId := TPath.GetFileNameWithoutExtension(FileName);
      if SameText(OtherId, Key) then Continue;
      Saved := ReadSaved(OtherId, Hash);
      R := TJSONObject.ParseJSONValue(Saved) as TJSONObject;
      try
        if (R = nil) or ((R.GetValue<string>('state') <> 'completed') and
          (R.GetValue<string>('state') <> 'rejected')) then
          Exit(Response(Key, 'blocked', 'Сначала восстановите предыдущий чек: ' + OtherId, False));
      finally R.Free; end;
    end;
    for FileName in TDirectory.GetFiles(FDirectory, '*.json.tmp') do
      Exit(Response(Key, 'blocked', 'Найдена незавершённая запись журнала. Нужна сверка предыдущего чека.', False));
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
