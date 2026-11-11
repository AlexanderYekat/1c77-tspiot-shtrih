unit uVariantPrint;

interface

uses
  System.SysUtils, System.Variants, System.JSON, System.IniFiles,
  System.SyncObjs, System.NetEncoding, System.Generics.Collections,
  System.Classes, System.DateUtils, Winapi.Windows, Winapi.ActiveX,
  ComObj, uKktLog, uFormSettings, uReceiptJournal;

type
  TCheckMarkTaskEntry = class
    Status: string;
    ResultJson: string;
    CreatedAt: TDateTime;
  end;

  /// <summary>Кэш результата проверки одной марки (ККТ + РР) в рамках текущего чека.</summary>
  TMarkCacheEntry = record
    KktAccepted: Boolean;
    KktResultCode: Integer;
    KktDescription: string;
    RrChecked: Boolean;
    RrAccepted: Boolean;
    RrCode: Integer;
    RrDescription: string;
    Uuid: string;
    TimeStr: string;
    Inst: string;
    Version: string;
    CheckedAt: TDateTime;
  end;

  TVariantPrint = class
  private
    ovObject: OleVariant;      // COM-объект драйвера ККТ (AddIn.DrvFR) — держим один на всё время
    FSettings: TCustomIniFile;
    FLog: TKktLogger;
    FLock: TCriticalSection;   // защита от параллельных обращений к ККТ
    FMarkTasksLock: TCriticalSection;
    FMarkTasks: TObjectDictionary<string, TCheckMarkTaskEntry>;
    FMarkCache: TDictionary<string, TMarkCacheEntry>; // кэш ККТ+РР в рамках текущего чека
    FReceipts: TReceiptJournal;
    FManagedReceipt, FReceiptStarted, FReceiptClosed: Boolean;
    FConnected: Boolean;       // текущее состояние соединения, как мы его понимаем
    FEmulation: Boolean;
    FTestReceiptMode: Boolean; // тестовый режим: CancelCheck вместо FNCloseCheckEx

    FEmulatedSerial: string;
    FEmulatedInn: string;
    FEmulatedRegNumber: string;
    FEmulatedFnNumber: string;
    FEmulatedCheckNumber: Integer;
    FEmulatedSessionNumber: Integer;

    // STA-поток для AddIn.DrvFR: Indy и async-задачи вызывают COM не из main thread
    FFrThread: TThread;
    FFrThreadId: TThreadID;
    FFrWorkAvail: TEvent;
    FFrWorkDone: TEvent;
    FFrReady: TEvent;
    FFrRequest: TProc;
    FFrError: string;
    FFrStop: Boolean;

    function PrintCheckCore(const Body: string): string;
    function ExecuteManagedReceipt(const Body: string): string;
    procedure WaitReceiptReady;
    procedure StartFrComThread;
    procedure StopFrComThread;
    procedure ExecOnFrThread(const Proc: TProc);
    function EnsureFRConnected: Boolean;
    procedure DoDisconnect;
    function CheckLinkAlive: Boolean;
    procedure CheckFRResult(const Place: string);
    function ReadSerialNumber: string;
    function ReadOrganizationName(const Inn: string): string;
    function ReadCheckNumberAfterClose: Integer;
    function ReadSessionNumberAfterClose: Integer;
    function FRObjectReady: Boolean;
    procedure RunFR(const Place: string; const Proc: TProc);
    procedure LogFRSkipped(const Place: string);

    procedure SendIndustryRequisite126x(const Tag1262, Tag1263, Tag1264, UUID,
      TimeStr, Inst, Version: string);
    procedure SendMarkingCodeAfterFNOperation(const MarkKkt: string);
    procedure ProcessMarkingAfterFNOperation(const MarkDecoded: string;
      MarkAccepted, ReturnCheck: Boolean);
    procedure RegisterReceiptItem(Item: TJSONObject; ReturnCheck: Boolean;
      DefaultDepartment: Integer);
    procedure PrintReceiptText(const Text: string);
    procedure ApplyReceiptHeader(Req: TJSONObject; ReturnCheck: Boolean);
    procedure CloseReceiptFromJson(Req: TJSONObject);
    /// <summary>
    /// Отрез чека с ожиданием кода 80 («Идет печать предыдущей команды»),
    /// как в ОтрезатьЧек() драйвера 1С (fr_elves).
    /// </summary>
    procedure CutCheckWithWait;

    procedure AfterCommand(Req: TJSONObject);

    function DecodeMarkBase64(const B64: string): string;
    function GetReceiptReturnCheck(Req: TJSONObject): Boolean;
    function GetCashierName(Req: TJSONObject): string;
    function ReadECRMode: Integer;
    procedure RefreshECRStatus(const Place: string);
    procedure ClearStuckOpenDocument(const Context: string);
    procedure DoOpenSession(const CashierName: string);
    procedure EnsureSessionOpen(const CashierName: string);
    procedure EnsureReadyForXReport;
    procedure EnsureReadyForZReport;
    function CheckSingleMark(const MarkDecoded: string; ReturnCheck: Boolean): TJSONObject;
    function CheckMarkInternal(const Body: string): string;
    procedure TrimOldMarkTasks;
    procedure StartAsyncCheckMark(const Body, TaskId: string);
    function NewTaskId: string;
    procedure CollectMarksFromRequest(Req: TJSONObject; out MarksB64: TArray<string>);
    procedure CollectMarksFromReceiptItems(Req: TJSONObject; out MarksB64: TArray<string>);
    function EnsureMarksReadyForPrint(Req: TJSONObject): string;

    function MarkCacheKey(const MarkDecoded: string; ReturnCheck: Boolean): string;
    function TryGetMarkFromCache(const MarkDecoded: string; ReturnCheck: Boolean;
      out Entry: TMarkCacheEntry): Boolean;
    function IsMarkAcceptedInCache(const MarkDecoded: string; ReturnCheck: Boolean): Boolean;
    function IsMarkFullyOk(const MarkDecoded: string; ReturnCheck,
      CheckPermission: Boolean): Boolean;
    procedure UpsertMarkCacheKkt(const MarkDecoded: string; ReturnCheck: Boolean;
      KktAccepted: Boolean; KktResultCode: Integer; const KktDescription: string);
    procedure UpsertMarkCacheRr(const MarkDecoded: string; ReturnCheck: Boolean;
      RrAccepted: Boolean; RrCode: Integer; const RrDescription, Uuid, TimeStr,
      Inst, Version: string);
    procedure UpdateMarkCacheFromMarkObj(const MarkDecoded: string;
      ReturnCheck: Boolean; MarkObj: TJSONObject);
    procedure AddMarkToAcceptedCache(const MarkDecoded: string; ReturnCheck: Boolean);
    procedure ClearMarkCache;
    function MarkObjFromCacheEntry(const Entry: TMarkCacheEntry): TJSONObject;
    function PermissionObjFromCacheEntry(const Entry: TMarkCacheEntry): TJSONObject;

    procedure ReadInnAndFn(out Inn, FnNumber: string);
    function ResolvePermissionInn(Req: TJSONObject): string;
    function ResolvePermissionFn(Req: TJSONObject): string;
    function BuildDocumentCheckJson(const MarkB64, Inn, Fn: string): string;
    function HttpPostJson(const Url, Body: string): string;
    function ExtractFirstTruemarkCode(Truemark: TJSONObject): TJSONObject;
    procedure AddTruemarkFields(PermObj, Truemark: TJSONObject);
    function ParsePermissionCheckResponse(const ResponseBody: string): TJSONObject;
  protected
    function CheckSingleMarkPermission(const MarkB64, Inn, Fn: string): TJSONObject; virtual;
    function ReceiptCommandCode(const Place: string; const Proc: TProc): Integer; virtual;
    function ReceiptSubmode: Integer; virtual;
    procedure ReceiptContinue; virtual;
    procedure ReceiptCommandDone(const Place: string); virtual;
  public
    function ReceiptStatusJson(const Id: string): string;
    function ReceiptBusy: Boolean;
    constructor Create(ASettings: TCustomIniFile);
    destructor Destroy; override;

    function KktInfoJson(IncludeOrganizationName: Boolean = False): string;
    function KktConnectionStatusJson: string;
    function PrintCheckJson(const Body: string): string;
    function PrintTextJson(const Body: string): string;
    function CloseShiftJson(const Body: string): string;
    function XReportJson(const Body: string = ''): string;
    function OpenShiftJson(const Body: string = ''): string;
    function CancelCheckJson(const Body: string = ''): string;
    function DisconnectJson: string;
    function ConnectJson: string;
    function ClearBufferOfMarksJson(const Body: string = ''): string;
    function CheckMarkJson(const Body: string): string;
    function CheckMarkStatusJson(const TaskId: string): string;

    /// <summary>
    /// Читает параметры связи активного ЛУ через GetActiveLD + GetParamLD
    /// (LDComNumber, LDBaudrate). Без Connect к ККТ.
    /// </summary>
    class function TryReadActiveLdConnection(out ComNumber, BaudRate: Integer): Boolean;

    property Logger: TKktLogger read FLog;
    property Emulation: Boolean read FEmulation;
  end;

implementation

uses
  IdHTTP;

const
  PERMISSION_FMU_HOST = 'localhost';
  PERMISSION_FMU_PORT = 2578;
  PERMISSION_FMU_PATH = '/document';

{-------------------------------------------------------------------------------
 Вспомогательные функции уровня модуля
-------------------------------------------------------------------------------}

function JsonEscape(const S: string): string;
begin
  Result := S.Replace('\', '\\')
             .Replace('"', '\"')
             .Replace(#13, '\r')
             .Replace(#10, '\n')
             .Replace(#9, '\t')
             .Replace(#29, '\u001D');
end;

function UnescapeJsonUnicode(const S: string): string;
var
  I, Code: Integer;
  Hex: string;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (I + 5 <= Length(S)) and (S[I] = '\') and (UpCase(S[I + 1]) = 'U') then
    begin
      Hex := Copy(S, I + 2, 4);
      if TryStrToInt('$' + Hex, Code) then
      begin
        Result := Result + WideChar(Code);
        Inc(I, 6);
        Continue;
      end;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
end;

function JsonToPlainText(const V: TJSONAncestor): string;
begin
  // ToJSON в старых Delphi экранирует кириллицу как \uXXXX; раскодируем для 1С 7.7 и логов.
  Result := UnescapeJsonUnicode(V.ToJSON);
end;

function JsonBodyPreviewPlain(const Body: string; MaxLen: Integer = 300): string;
var
  Parsed: TJSONValue;
begin
  Result := Body;
  Parsed := TJSONObject.ParseJSONValue(Body);
  if Parsed = nil then
  begin
    if Length(Result) > MaxLen then
      Result := Copy(Result, 1, MaxLen) + '...';
    Exit;
  end;
  try
    if Parsed is TJSONAncestor then
      Result := JsonToPlainText(TJSONAncestor(Parsed))
    else
      Result := UnescapeJsonUnicode(Parsed.ToJSON);
  finally
    Parsed.Free;
  end;
  if Length(Result) > MaxLen then
    Result := Copy(Result, 1, MaxLen) + '...';
end;

function JsonOk(const Extra: string = ''): string;
begin
  Result := '{"result":1,"description":"OK"';
  if Extra <> '' then
    Result := Result + ',' + Extra;
  Result := Result + '}';
end;

function JsonError(const Msg: string): string;
begin
  Result := '{"result":0,"description":"' + JsonEscape(Msg) + '"}';
end;

function JsonBodyPreview(const Body: string; MaxLen: Integer = 300): string;
begin
  Result := Body;
  if Length(Result) > MaxLen then
    Result := Copy(Result, 1, MaxLen) + '...';
end;

function ParseJsonObjectOrRaise(const Body: string; const LogPrefix: string;
  ALog: TKktLogger): TJSONObject;
var
  V: TJSONValue;
begin
  if Trim(Body) = '' then
    raise Exception.Create('Empty request body');
  V := TJSONObject.ParseJSONValue(Body);
  if not (V is TJSONObject) then
  begin
    if Assigned(ALog) then
      ALog.LogError(Format('%s: Invalid JSON, bodyLen=%d, head=%s',
        [LogPrefix, Length(Body), JsonBodyPreview(Body)]));
    if V <> nil then
      V.Free;
    raise Exception.Create(Format('Invalid JSON, bodyLen=%d', [Length(Body)]));
  end;
  Result := TJSONObject(V);
end;

function JStr(O: TJSONObject; const Name: string; const Def: string = ''): string;
var
  V: TJSONValue;
begin
  Result := Def;
  if O = nil then Exit;
  V := O.GetValue(Name);
  if V <> nil then
    Result := V.Value;
end;

function JInt(O: TJSONObject; const Name: string; const Def: Integer = 0): Integer;
begin
  Result := StrToIntDef(JStr(O, Name, IntToStr(Def)), Def);
end;

function JBool(O: TJSONObject; const Name: string; const Def: Boolean = False): Boolean;
var
  V: TJSONValue;
begin
  Result := Def;
  if O = nil then Exit;
  V := O.GetValue(Name);
  if V is TJSONBool then
    Result := TJSONBool(V).AsBoolean
  else if V is TJSONTrue then
    Result := True
  else if V is TJSONFalse then
    Result := False;
end;

function JFloat(O: TJSONObject; const Name: string; const Def: Double = 0): Double;
var
  S: string;
  FS: TFormatSettings;
begin
  FS := TFormatSettings.Create;
  FS.DecimalSeparator := '.';
  S := StringReplace(JStr(O, Name, FloatToStr(Def, FS)), ',', '.', [rfReplaceAll]);
  Result := StrToFloatDef(S, Def, FS);
end;

function MapTax1(const TaxTypeStr: string): Integer;
begin
  if SameText(TaxTypeStr, 'none') then Result := 0
  else if SameText(TaxTypeStr, 'vat20') then Result := 1
  else if SameText(TaxTypeStr, 'vat10') then Result := 2
  else if SameText(TaxTypeStr, 'vat0') then Result := 3
  else if SameText(TaxTypeStr, 'vat120') then Result := 5
  else if SameText(TaxTypeStr, 'vat110') then Result := 6
  else if SameText(TaxTypeStr, 'vat5') then Result := 7
  else if SameText(TaxTypeStr, 'vat7') then Result := 8
  else if SameText(TaxTypeStr, 'vat105') then Result := 9
  else if SameText(TaxTypeStr, 'vat107') then Result := 10
  else if SameText(TaxTypeStr, 'vat22') then Result := 11
  else if SameText(TaxTypeStr, 'vat122') then Result := 12
  else Result := 0;
end;

function MapTaxationType(const S: string): Integer;
begin
  if SameText(S, 'osn') then Result := 1
  else if SameText(S, 'usnIncome') then Result := 2
  else if SameText(S, 'usnIncomeOutcome') then Result := 4
  else if SameText(S, 'esn') then Result := 16
  else if SameText(S, 'patent') then Result := 32
  else Result := 0;
end;

function MapPaymentObject(const Obj: string; HasMark: Boolean): Integer;
begin
  if HasMark then
    Exit(33);
  if SameText(Obj, 'commodity') then Result := 1
  else if SameText(Obj, 'excise') then Result := 2
  else if SameText(Obj, 'job') then Result := 3
  else if SameText(Obj, 'service') then Result := 4
  else if SameText(Obj, 'gamblingBet') then Result := 5
  else if SameText(Obj, 'gamblingPrize') then Result := 6
  else if SameText(Obj, 'lottery') then Result := 7
  else if SameText(Obj, 'lotteryPrize') then Result := 8
  else if SameText(Obj, 'intellectualActivity') then Result := 9
  else if SameText(Obj, 'payment') then Result := 10
  else if SameText(Obj, 'agentCommission') then Result := 12
  else if SameText(Obj, 'composite') then Result := 14
  else if SameText(Obj, 'another') then Result := 14
  else if SameText(Obj, 'exciseWithoutMarking') then Result := 30
  else if SameText(Obj, 'exciseWithMarking') then Result := 31
  else if SameText(Obj, 'commodityWithoutMarking') then Result := 32
  else if SameText(Obj, 'commodityWithMarking') then Result := 33

  else Result := 1;
end;

function MapPaymentMethodSign(const Method: string): Integer;
begin
  if SameText(Method, 'fullPrepayment') then Result := 1
  else if SameText(Method, 'prepayment') then Result := 2
  else if SameText(Method, 'advance') then Result := 3
  else if SameText(Method, 'fullPayment') then Result := 4
  else if SameText(Method, 'partialPayment') then Result := 5
  else if SameText(Method, 'credit') then Result := 6
  else if SameText(Method, 'creditPayment') then Result := 7
  else Result := 4;
end;

function MapMeasureUnit(const U: string): Integer;
begin
  if SameText(U, 'piece') or SameText(U, #1096#1090) then
    Result := 0
  else if SameText(U, 'liter') then
    Result := 41
  else
    Result := 0;
end;

function FRResultText(ovObject: OleVariant): string;
begin
  try
    Result := VarToStr(ovObject.ResultCodeDescription);
  except
    Result := '';
  end;
end;

/// <summary>Человекочитаемое имя режима Штрих ECRMode.</summary>
function ECRModeCaption(Mode: Integer): string;
begin
  case Mode of
    0: Result := 'принтер в рабочем режиме';
    1: Result := 'выдача данных';
    2: Result := 'смена открыта (менее 24 часов)';
    3: Result := 'смена открыта более 24 часов';
    4: Result := 'смена закрыта';
    5: Result := 'блокировка по паролю налогового инспектора';
    6: Result := 'ожидание подтверждения даты';
    7: Result := 'разрешение изменения десятичной точки';
    8: Result := 'открыт документ (чек)';
    9: Result := 'разрешение технологического обнуления';
    10: Result := 'тестовый прогон';
    11: Result := 'печать полного фискального отчёта';
    12: Result := 'печать длинного отчёта ЭКЛЗ';
    14: Result := 'работа с фискальным подкладным документом';
    15: Result := 'переполнение принтера';
  else
    Result := 'неизвестный режим ККТ (' + IntToStr(Mode) + ')';
  end;
end;

/// <summary>Понятное сообщение, если режим ККТ не позволяет проверку марки / печать.</summary>
function MessageForBlockedECRMode(Mode: Integer): string;
begin
  case Mode of
    3:
      Result := 'Смена открыта более 24 часов. Снимите Z-отчёт (закрытие смены) и повторите.';
    4:
      Result := 'Смена закрыта. Откройте смену и повторите.';
    5:
      Result := 'ККТ заблокирована (пароль налогового инспектора). Обратитесь к администратору.';
    6:
      Result := 'ККТ ожидает подтверждения даты. Подтвердите дату на кассе и повторите.';
    8:
      Result := 'На ККТ открыт незакрытый чек. Отмените или закройте чек и повторите.';
    1:
      Result := 'ККТ занята выдачей данных. Подождите и повторите.';
    11, 12:
      Result := 'ККТ печатает отчёт. Дождитесь окончания и повторите.';
    15:
      Result := 'Переполнение буфера печати ККТ. Устраните проблему на кассе и повторите.';
  else
    Result := 'Операция недоступна: ' + ECRModeCaption(Mode) +
      '. Приведите ККТ в режим открытой смены и повторите.';
  end;
end;

function UserMessageForFRError(const Place: string; Code: Integer;
  const Desc: string; ECRMode: Integer): string;
begin
  // 115 — «Команда не поддерживается в данном режиме»
  if Code = 115 then
  begin
    if ECRMode >= 0 then
      Result := MessageForBlockedECRMode(ECRMode)
    else
      Result :=
        'ККТ отклонила команду: текущий режим кассы не позволяет выполнить операцию. ' +
        'Проверьте, что смена открыта (не более 24 часов) и нет незакрытого чека.';
    Exit;
  end;
  Result := Place + ': ' + IntToStr(Code) + ' ' + Desc;
end;

{-------------------------------------------------------------------------------
 TVariantPrint — конструктор/деструктор
-------------------------------------------------------------------------------}

constructor TVariantPrint.Create(ASettings: TCustomIniFile);
begin
  inherited Create;
  FSettings := ASettings;
  FLock := TCriticalSection.Create;
  FMarkTasksLock := TCriticalSection.Create;
  FMarkTasks := TObjectDictionary<string, TCheckMarkTaskEntry>.Create([doOwnsValues]);
  FMarkCache := TDictionary<string, TMarkCacheEntry>.Create;
  FLog := TKktLogger.Create(ASettings, TFormSettings.GetDefaultLogFileName);
  ovObject := Unassigned;
  FConnected := False;
  FFrStop := False;
  FFrThreadId := 0;
  FFrRequest := nil;
  FFrError := '';
  FFrWorkAvail := TEvent.Create(nil, False, False, '');
  FFrWorkDone := TEvent.Create(nil, False, False, '');
  FFrReady := TEvent.Create(nil, True, False, '');

  FEmulation := FSettings.ReadBool('KKT', 'Emulation', False);
  FTestReceiptMode := FSettings.ReadBool('KKT', 'TestReceiptMode', False);
  FEmulatedSerial := FSettings.ReadString('KKT', 'EmulatedSerial', '0000000000000001');
  FEmulatedInn := FSettings.ReadString('KKT', 'EmulatedInn', '1234567890');
  FEmulatedRegNumber := FSettings.ReadString('KKT', 'EmulatedRegNumber', '1234567111890');
  FEmulatedFnNumber := FSettings.ReadString('KKT', 'EmulatedFnNumber', '9999078900000001');
  FEmulatedCheckNumber := FSettings.ReadInteger('KKT', 'EmulatedCheckNumber', 0);
  FEmulatedSessionNumber := FSettings.ReadInteger('KKT', 'EmulatedSessionNumber', 0);

  FReceipts := TReceiptJournal.Create(FSettings.ReadString('KKT', 'ReceiptJournalPath',
    IncludeTrailingPathDelimiter(ExtractFilePath(FSettings.FileName)) + 'receipt-journal'));
  StartFrComThread;

  if FEmulation then
    FLog.LogInfo('Режим эмуляции ККТ включён — команды ovObject выполняются, ошибки логируются, ответ API = OK')
  else
    FLog.LogInfo('Боевой режим ККТ');
  if FTestReceiptMode then
    FLog.LogInfo('Тестовый режим чека: вместо FNCloseCheckEx будет CancelCheck');
end;

class function TVariantPrint.TryReadActiveLdConnection(out ComNumber, BaudRate: Integer): Boolean;
var
  Drv: OleVariant;
  NeedUninit: Boolean;
  Hr: HRESULT;
  LdNum, LdCom, LdBaud: Integer;
begin
  Result := False;
  ComNumber := 1;
  BaudRate := 6;

  Hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  NeedUninit := (Hr = S_OK) or (Hr = S_FALSE);
  try
    try
      Drv := CreateOleObject('AddIn.DrvFR');
    except
      on E: Exception do
        Exit;
    end;

    try
      // GetActiveLD → LDNumber / LDIndex активного логического устройства
      Drv.GetActiveLD;
      LdNum := Integer(Drv.LDNumber);
      if LdNum < 1 then
        Exit;

      // GetParamLD → параметры ЛУ с номером LDNumber
      Drv.GetParamLD;
      LdCom := Integer(Drv.LDComNumber);
      LdBaud := Integer(Drv.LDBaudrate);

      if LdCom < 1 then
        Exit;

      ComNumber := LdCom;
      if (LdBaud >= 0) and (LdBaud <= 9) then
        BaudRate := LdBaud;
      Result := True;
    finally
      Drv := Unassigned;
    end;
  finally
    if NeedUninit then
      CoUninitialize;
  end;
end;

destructor TVariantPrint.Destroy;
begin
  FReceipts.Free; // Join receipt worker before freeing COM, locks or logging.
  FLock.Enter;
  try
    DoDisconnect;
  finally
    FLock.Leave;
  end;
  StopFrComThread;
  FFrWorkAvail.Free;
  FFrWorkDone.Free;
  FFrReady.Free;
  FMarkTasksLock.Enter;
  try
    FMarkTasks.Free;
  finally
    FMarkTasksLock.Leave;
    FMarkTasksLock.Free;
  end;
  FMarkCache.Free;
  FLog.Free;
  FLock.Free;
  inherited;
end;

procedure TVariantPrint.StartFrComThread;
begin
  FFrThread := TThread.CreateAnonymousThread(
    procedure
    begin
      CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
      try
        FFrThreadId := GetCurrentThreadId;
        FFrReady.SetEvent;
        while True do
        begin
          FFrWorkAvail.WaitFor(INFINITE);
          if FFrStop then
            Break;
          FFrError := '';
          try
            if Assigned(FFrRequest) then
              FFrRequest();
          except
            on E: Exception do
              FFrError := E.Message;
          end;
          FFrRequest := nil;
          FFrWorkDone.SetEvent;
        end;
        try
          if not (VarIsEmpty(ovObject) or VarIsNull(ovObject)) then
            ovObject := Unassigned;
        except
        end;
      finally
        CoUninitialize;
      end;
    end);
  FFrThread.FreeOnTerminate := False;
  FFrThread.Start;
  if FFrReady.WaitFor(15000) <> wrSignaled then
    raise Exception.Create('Не удалось запустить STA-поток драйвера ККТ');
end;

procedure TVariantPrint.StopFrComThread;
begin
  if FFrThread = nil then
    Exit;
  FFrStop := True;
  FFrWorkAvail.SetEvent;
  FFrThread.WaitFor;
  FreeAndNil(FFrThread);
  FFrThreadId := 0;
end;

procedure TVariantPrint.ExecOnFrThread(const Proc: TProc);
begin
  if not Assigned(Proc) then
    Exit;
  if GetCurrentThreadId = FFrThreadId then
  begin
    Proc();
    Exit;
  end;
  FFrError := '';
  FFrRequest := Proc;
  FFrWorkDone.ResetEvent;
  FFrWorkAvail.SetEvent;
  if FFrWorkDone.WaitFor(120000) <> wrSignaled then
    raise Exception.Create('Таймаут ожидания STA-потока драйвера ККТ');
  if FFrError <> '' then
    raise Exception.Create(FFrError);
end;

procedure TVariantPrint.CheckFRResult(const Place: string);
var
  Code, Mode: Integer;
  Desc, UserMsg: string;
begin
  try
    Code := ovObject.ResultCode;
  except
    on E: Exception do
    begin
      FLog.LogError('[FR] ' + Place + ': не удалось прочитать ResultCode — ' + E.Message);
      if not FEmulation then
        raise;
      Exit;
    end;
  end;

  Desc := FRResultText(ovObject);
  if Code <> 0 then
  begin
    FLog.LogError('[FR] ' + Place + ': ' + IntToStr(Code) + ' ' + Desc);
    if not FEmulation then
    begin
      try
        Mode := ovObject.ECRMode;
      except
        Mode := -1;
      end;
      UserMsg := UserMessageForFRError(Place, Code, Desc, Mode);
      if (Code = 115) and (Mode >= 0) then
        FLog.LogError('[FR] ' + Place + ': ECRMode=' + IntToStr(Mode) +
          ' (' + ECRModeCaption(Mode) + ')');
      raise Exception.Create(UserMsg);
    end;
  end
  else
    FLog.LogDebug('[FR] ' + Place + ': OK');
end;

function TVariantPrint.ReadSerialNumber: string;
var
  Local: string;
begin
  Result := '';
  if FEmulation then
  begin
    Result := FEmulatedSerial;
    Exit;
  end;
  if VarIsEmpty(ovObject) or VarIsNull(ovObject) then
    Exit;

  Local := '';
  ExecOnFrThread(procedure
  begin
    try
      Local := VarToStr(ovObject.SerialNumber);
    except
      on E: Exception do
        FLog.LogError('[FR] ReadSerialNumber: ' + E.Message);
    end;
  end);
  Result := Local;
end;

function TVariantPrint.FRObjectReady: Boolean;
begin
  Result := not (VarIsEmpty(ovObject) or VarIsNull(ovObject));
end;

function TVariantPrint.ReceiptSubmode: Integer;
var Mode: Integer;
begin
  if FEmulation then Exit(0);
  Mode := -1;
  ExecOnFrThread(procedure
  begin
    if not FRObjectReady then LogFRSkipped('Receipt status');
    ovObject.GetECRStatus;
    CheckFRResult('Receipt status');
    Mode := ovObject.ECRAdvancedMode;
  end);
  Result := Mode;
end;

procedure TVariantPrint.ReceiptContinue;
begin
  ExecOnFrThread(procedure
  begin
    ovObject.ContinuePrint;
    CheckFRResult('ContinuePrint');
  end);
end;

procedure TVariantPrint.ReceiptCommandDone(const Place: string);
begin
  // Virtual seam for deterministic printer-state tests; production has no test flags.
end;

procedure TVariantPrint.WaitReceiptReady;
var Mode: Integer;
begin
  if not FManagedReceipt then Exit;
  while True do begin
    if FReceipts.Stopping then raise Exception.Create('Служба остановлена во время печати');
    Mode := ReceiptSubmode;
    case Mode of
      0: begin FReceipts.Progress('running', 'Продолжается прежний чек'); Exit; end;
      1, 2: FReceipts.Progress('waiting_for_paper', 'Замените бумагу. Печать этого чека продолжится автоматически.');
      3: begin
        FReceipts.Progress('printing', 'Продолжается печать после замены бумаги');
        ReceiptContinue;
      end;
      4, 5: FReceipts.Progress('printing', 'ККТ печатает прежнюю операцию');
    else raise Exception.Create('Неизвестный подрежим ККТ: ' + IntToStr(Mode));
    end;
    TThread.Sleep(250);
  end;
end;

function TVariantPrint.ReceiptCommandCode(const Place: string; const Proc: TProc): Integer;
var Code: Integer;
begin
  Code := 0;
  ExecOnFrThread(procedure
  begin
    if FEmulation then begin FLog.LogInfo('[FR] ' + Place + ' (emu)'); Exit; end;
    if not FRObjectReady then LogFRSkipped(Place);
    Proc();
    Code := ovObject.ResultCode;
    // Device refusal, not a lost response: the requested command was not accepted.
    if not (FManagedReceipt and ((Code = 80) or (Code = 107))) then CheckFRResult(Place);
  end);
  Result := Code;
end;

procedure TVariantPrint.RunFR(const Place: string; const Proc: TProc);
var Code: Integer;
begin
  repeat
    WaitReceiptReady;
    if FManagedReceipt and ((Place = 'FNOperation') or (Place = 'PrintString') or
      (Place = 'FNCloseCheckEx')) then FReceiptStarted := True;
    Code := ReceiptCommandCode(Place, Proc);
    if Code = 107 then FReceipts.Progress('waiting_for_paper', 'Замените бумагу. Печать этого чека продолжится автоматически.');
    if Code = 80 then FReceipts.Progress('printing', 'ККТ печатает предыдущую команду');
    if (Code = 80) or (Code = 107) then TThread.Sleep(250);
  until (Code <> 80) and (Code <> 107);
  if FManagedReceipt then begin
    if Place = 'FNCloseCheckEx' then FReceiptClosed := True;
    ReceiptCommandDone(Place);
    // Keep this exact call stack while paper is replaced; do not replay the command.
    WaitReceiptReady;
  end;
end;

procedure TVariantPrint.LogFRSkipped(const Place: string);
begin
  FLog.LogError('[FR] ' + Place + ': ovObject недоступен');
  if not FEmulation then
    raise Exception.Create(Place + ': ovObject недоступен');
end;

function TVariantPrint.ReadCheckNumberAfterClose: Integer;
var
  Local: Integer;
begin
  Result := 0;
  RunFR('GetECRStatus after close', procedure
  begin
    ovObject.GetECRStatus;
  end);
  if FEmulation then
  begin
    Inc(FEmulatedCheckNumber);
    Result := FEmulatedCheckNumber;
    Exit;
  end;
  if not FRObjectReady then
    Exit;

  Local := 0;
  ExecOnFrThread(procedure
  begin
    try
      Local := ovObject.OpenDocumentNumber;
      try
        if ovObject.ECRAdvancedMode = 5 then
          Inc(Local);
      except
      end;
    except
      on E: Exception do
      begin
        FLog.LogError('[FR] ReadCheckNumberAfterClose: ' + E.Message);
        raise;
      end;
    end;
  end);
  Result := Local;
end;

function TVariantPrint.ReadSessionNumberAfterClose: Integer;
var
  Local: Integer;
begin
  Result := 0;
  RunFR('GetECRStatus after close shift', procedure
  begin
    ovObject.GetECRStatus;
  end);
  if FEmulation then
  begin
    Inc(FEmulatedSessionNumber);
    Result := FEmulatedSessionNumber;
    Exit;
  end;
  if not FRObjectReady then
    Exit;

  Local := 0;
  ExecOnFrThread(procedure
  begin
    try
      Local := ovObject.SessionNumber;
      try
        if ovObject.ECRAdvancedMode = 5 then
          Inc(Local);
      except
      end;
    except
      on E: Exception do
      begin
        FLog.LogError('[FR] ReadSessionNumberAfterClose: ' + E.Message);
        raise;
      end;
    end;
  end);
  Result := Local;
end;

{-------------------------------------------------------------------------------
 Подключение / переиспользование соединения
-------------------------------------------------------------------------------}

function TVariantPrint.CheckLinkAlive: Boolean;
var
  Local: Boolean;
begin
  Result := False;
  if not FConnected then
    Exit;

  if FEmulation then
  begin
    Result := True;
    Exit;
  end;

  if VarIsEmpty(ovObject) or VarIsNull(ovObject) then
    Exit;

  Local := False;
  ExecOnFrThread(procedure
  begin
    try
      Local := ovObject.Connected;
    except
      on E: Exception do
      begin
        FLog.LogError('[FR] CheckLinkAlive: ' + E.Message);
        Local := False;
      end;
    end;
  end);
  Result := Local;
end;

function TVariantPrint.EnsureFRConnected: Boolean;
var
  ComPort, Baud, Password: Integer;
begin
  if FConnected and CheckLinkAlive then
  begin
    Result := True;
    Exit;
  end;

  FConnected := False;

  if VarIsEmpty(ovObject) or VarIsNull(ovObject) then
  begin
    try
      ExecOnFrThread(procedure
      begin
        ovObject := CreateOleObject('AddIn.DrvFR');
      end);
      FLog.LogInfo('[FR] CreateOleObject AddIn.DrvFR');
    except
      on E: Exception do
      begin
        FLog.LogError('[FR] CreateOleObject: ' + E.Message);
        if FEmulation then
        begin
          FConnected := True;
          Result := True;
          Exit;
        end;
        raise;
      end;
    end;
  end;

  ComPort := FSettings.ReadInteger('FRCash', 'Port', 1);
  Baud := FSettings.ReadInteger('FRCash', 'Baud', 6);
  Password := FSettings.ReadInteger('FRCash', 'Password', 30);

  FLog.LogInfo(Format('[FR] Connect ComNumber=%d BaudRate=%d', [ComPort, Baud]));

  RunFR('Connect', procedure
  begin
    ovObject.ComNumber := ComPort;
    ovObject.BaudRate := Baud;
    ovObject.Password := Password;
    ovObject.Connect;
  end);

  FConnected := True;
  Result := True;
end;

procedure TVariantPrint.DoDisconnect;
begin
  if FConnected and FRObjectReady then
    RunFR('Disconnect', procedure
    begin
      ovObject.Disconnect;
    end);
  FConnected := False;
end;

procedure TVariantPrint.AfterCommand(Req: TJSONObject);
begin
  if (Req <> nil) and JBool(Req, 'disconnect', False) then
    DoDisconnect;
end;

function TVariantPrint.DisconnectJson: string;
begin
  FLock.Enter;
  try
    try
      DoDisconnect;
      Result := JsonOk;
    except
      on E: Exception do
      begin
        FLog.LogError('DisconnectJson: ' + E.Message);
        if FEmulation then
          Result := JsonOk
        else
          Result := JsonError(E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TVariantPrint.ConnectJson: string;
begin
  FLock.Enter;
  try
    try
      EnsureFRConnected;
      Result := JsonOk('"connected":true');
      FLog.LogInfo('ConnectJson OK');
    except
      on E: Exception do
      begin
        FLog.LogError('ConnectJson: ' + E.Message);
        if FEmulation then
          Result := JsonOk('"connected":true')
        else
          Result := JsonError(E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

{-------------------------------------------------------------------------------
 /connection-status — статус связи и настройки FSettings (без принудительного Connect)
-------------------------------------------------------------------------------}

function TVariantPrint.KktConnectionStatusJson: string;
var
  ComPort, Baud, Password, HttpPort: Integer;
  Cashier: string;
  Connected: Boolean;
begin
  FLock.Enter;
  try
    ComPort := FSettings.ReadInteger('FRCash', 'Port', 1);
    Baud := FSettings.ReadInteger('FRCash', 'Baud', 6);
    Password := FSettings.ReadInteger('FRCash', 'Password', 30);
    HttpPort := FSettings.ReadInteger('HttpServer', 'Port', 2580);
    Cashier := FSettings.ReadString('FRCash', 'CashierName', 'Кассир');
    Connected := CheckLinkAlive;

    Result := JsonOk(
      '"connected":' + BoolToStr(Connected, True).ToLower + ',' +
      '"comPort":' + IntToStr(ComPort) + ',' +
      '"baudRate":' + IntToStr(Baud) + ',' +
      '"password":' + IntToStr(Password) + ',' +
      '"cashierName":"' + JsonEscape(Cashier) + '",' +
      '"httpPort":' + IntToStr(HttpPort) + ',' +
      '"emulation":' + BoolToStr(FEmulation, True).ToLower + ',' +
      '"testReceiptMode":' + BoolToStr(FTestReceiptMode, True).ToLower);
  finally
    FLock.Leave;
  end;
end;

{-------------------------------------------------------------------------------
 /info
-------------------------------------------------------------------------------}

function TVariantPrint.ReadOrganizationName(const Inn: string): string;
const
  FiscalStorageTable = 18;
  FiscalStorageRow = 1;
  TaxpayerInnField = 2;
  TaxpayerNameField = 7;
var
  TableInn: string;

  function ReadField(FieldNumber: Integer; const FieldName: string): string;
  var
    Value: string;
  begin
    Value := '';
    RunFR('ReadTable fiscal storage', procedure
    begin
      ovObject.TableNumber := FiscalStorageTable;
      ovObject.RowNumber := FiscalStorageRow;
      ovObject.FieldNumber := FieldNumber;
      ovObject.GetFieldStruct;
      CheckFRResult('GetFieldStruct fiscal storage');
      if not SameText(Trim(VarToStr(ovObject.FieldName)), FieldName) then
        Exit;
      ovObject.ReadTable;
      CheckFRResult('ReadTable fiscal storage');
      Value := Trim(VarToStr(ovObject.ValueOfFieldString));
    end);
    Result := Value;
  end;

begin
  Result := '';
  if FEmulation or (Trim(Inn) = '') then
    Exit;

  try
    // Some driver versions pad the INN from FNGetFiscalizationResult to 12 digits.
    TableInn := ReadField(TaxpayerInnField, 'Inn');
    if (TableInn <> '') and (TableInn.PadLeft(12, '0') = Trim(Inn).PadLeft(12, '0')) then
      Result := ReadField(TaxpayerNameField, 'User');
  except
    on E: Exception do
      FLog.LogInfo('KktInfoJson: название организации недоступно');
  end;
end;

function TVariantPrint.KktInfoJson(IncludeOrganizationName: Boolean): string;
var
  SerialNumber, KKTRegistrationNumber, Inn, FnNumber, OrganizationJson: string;
begin
  FLock.Enter;
  try
    try
      EnsureFRConnected;

      SerialNumber := '';
      Inn := '';
      KKTRegistrationNumber := '';
      FnNumber := '';

      RunFR('GetECRStatus', procedure
      begin
        ovObject.GetECRStatus;
      end);
      SerialNumber := ReadSerialNumber;

      RunFR('FNGetFiscalizationResult', procedure
      begin
        ovObject.FNGetFiscalizationResult;
        if not FEmulation and FRObjectReady then
        begin
          try Inn := VarToStr(ovObject.INN); except end;
          try KKTRegistrationNumber := VarToStr(ovObject.KKTRegistrationNumber); except end;
        end;
      end);

      RunFR('FNGetSerial', procedure
      begin
        ovObject.FNGetSerial;
        if not FEmulation and FRObjectReady then
        begin
          try FnNumber := VarToStr(ovObject.SerialNumber); except end;
          try if FnNumber = '' then FnNumber := VarToStr(ovObject.FiscalStorageNumber); except end;
        end;
      end);

      if FEmulation then begin
       if Inn = '' then Inn := FEmulatedInn;
       if KKTRegistrationNumber = '' then KKTRegistrationNumber := FEmulatedInn;
       if FnNumber = '' then FnNumber := FEmulatedFnNumber;
      end;

      OrganizationJson := '';
      if IncludeOrganizationName then
        OrganizationJson := '"organizationName":"' +
          JsonEscape(ReadOrganizationName(Inn)) + '",';

      Result := JsonOk(
        '"serialNumber":"' + JsonEscape(SerialNumber) + '",' +
        '"inn":"'       + JsonEscape(Inn) + '",' +
        OrganizationJson +
        '"regNumber":"' + JsonEscape(KKTRegistrationNumber) + '",' +
        '"fnNumber":"'  + JsonEscape(FnNumber) + '",' +
        '"connected":'  + BoolToStr(FConnected, True).ToLower + ',' +
        '"emulation":'  + BoolToStr(FEmulation, True).ToLower);
    except
      on E: Exception do
      begin
        FLog.LogError('KktInfoJson: ' + E.Message);
        if FEmulation then
          Result := JsonOk(
            '"serialNumber":"' + JsonEscape(FEmulatedSerial) + '",' +
            '"inn":"' + JsonEscape(FEmulatedInn) + '",' +
            '"fnNumber":"' + JsonEscape(FEmulatedFnNumber) + '",' +
            '"connected":true,' +
            '"emulation":true')
        else
          Result := JsonError(E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

{-------------------------------------------------------------------------------
 Печать позиции и маркировки
-------------------------------------------------------------------------------}

procedure TVariantPrint.SendIndustryRequisite126x(const Tag1262, Tag1263, Tag1264,
  UUID, TimeStr, Inst, Version: string);
var OtrsaslRekvizit:string;
begin
  if (UUID = '') or (TimeStr = '') then
    Exit;

  FLog.LogInfo(Format('Теги РР: 1262=%s 1263=%s 1264=%s 1265 UUID=%s Time=%s Inst=%s Version=%s',
    [Tag1262, Tag1263, Tag1264, UUID, TimeStr, Inst, Version]));

  RunFR('FNSendTagOperation 1262', procedure
  begin
    ovObject.TagNumber := 1262;
    ovObject.TagType := 7;
    ovObject.TagValueStr := Tag1262;
    ovObject.FNSendTagOperation;
    FLog.LogDebug('[FR] 1262: ' + Tag1262 + ' -> ' + FRResultText(ovObject));
  end);

  RunFR('FNSendTagOperation 1263', procedure
  begin
    ovObject.TagNumber := 1263;
    ovObject.TagType := 7;
    ovObject.TagValueStr := Tag1263;
    ovObject.FNSendTagOperation;
    FLog.LogDebug('[FR] 1263: ' + Tag1263 + ' -> ' + FRResultText(ovObject));
  end);

  RunFR('FNSendTagOperation 1264', procedure
  begin
    ovObject.TagNumber := 1264;
    ovObject.TagType := 7;
    ovObject.TagValueStr := Tag1264;
    ovObject.FNSendTagOperation;
    FLog.LogDebug('[FR] 1264: ' + Tag1264 + ' -> ' + FRResultText(ovObject));
  end);

  RunFR('FNSendTagOperation 1265', procedure
  begin
    ovObject.TagNumber := 1265;
    ovObject.TagType := 7;
    OtrsaslRekvizit:='UUID=' + UUID + '&Time=' + TimeStr;
    if Inst<>'' then OtrsaslRekvizit:=OtrsaslRekvizit+'&Inst='+Inst+'&Ver='+Version;
    ovObject.TagValueStr := OtrsaslRekvizit;
    ovObject.FNSendTagOperation;
    FLog.LogDebug('[FR] 1265: ' + OtrsaslRekvizit + ' -> ' + FRResultText(ovObject));
  end);
end;

procedure TVariantPrint.SendMarkingCodeAfterFNOperation(const MarkKkt: string);
begin
  if MarkKkt = '' then
    Exit;

  RunFR('FNSendItemBarcode', procedure
  begin
    FLog.LogDebug('[FR] FNSendItemBarcode begin: ' + MarkKkt);
    ovObject.BarCode := MarkKkt;
    ovObject.FNSendItemBarcode;
    FLog.LogDebug('[FR] FNSendItemBarcode: ' + FRResultText(ovObject));
  end);
end;

function TVariantPrint.MarkCacheKey(const MarkDecoded: string; ReturnCheck: Boolean): string;
begin
  if ReturnCheck then
    Result := 'R|' + MarkDecoded
  else
    Result := 'S|' + MarkDecoded;
end;

function TVariantPrint.TryGetMarkFromCache(const MarkDecoded: string;
  ReturnCheck: Boolean; out Entry: TMarkCacheEntry): Boolean;
begin
  Result := False;
  Entry := Default(TMarkCacheEntry);
  if MarkDecoded = '' then
    Exit;
  Result := FMarkCache.TryGetValue(MarkCacheKey(MarkDecoded, ReturnCheck), Entry);
end;

function TVariantPrint.IsMarkAcceptedInCache(const MarkDecoded: string;
  ReturnCheck: Boolean): Boolean;
var
  Entry: TMarkCacheEntry;
begin
  Result := TryGetMarkFromCache(MarkDecoded, ReturnCheck, Entry) and Entry.KktAccepted;
end;

function TVariantPrint.IsMarkFullyOk(const MarkDecoded: string; ReturnCheck,
  CheckPermission: Boolean): Boolean;
var
  Entry: TMarkCacheEntry;
begin
  Result := False;
  if not TryGetMarkFromCache(MarkDecoded, ReturnCheck, Entry) then
    Exit;
  if not Entry.KktAccepted then
    Exit;
  if CheckPermission and not ReturnCheck then
  begin
    if not Entry.RrChecked then
      Exit;
    if not Entry.RrAccepted then
      Exit;
    if (Trim(Entry.Uuid) = '') or (Trim(Entry.TimeStr) = '') then
      Exit;
  end;
  Result := True;
end;

procedure TVariantPrint.UpsertMarkCacheKkt(const MarkDecoded: string;
  ReturnCheck: Boolean; KktAccepted: Boolean; KktResultCode: Integer;
  const KktDescription: string);
var
  Key: string;
  Entry: TMarkCacheEntry;
begin
  if MarkDecoded = '' then
    Exit;
  Key := MarkCacheKey(MarkDecoded, ReturnCheck);
  if not FMarkCache.TryGetValue(Key, Entry) then
  begin
    Entry := Default(TMarkCacheEntry);
    Entry.RrAccepted := True; // РР ещё не проверялся
  end;
  Entry.KktAccepted := KktAccepted;
  Entry.KktResultCode := KktResultCode;
  Entry.KktDescription := KktDescription;
  Entry.CheckedAt := Now;
  FMarkCache.AddOrSetValue(Key, Entry);
  FLog.LogInfo(Format('Кэш марки ККТ: accepted=%s code=%d len=%d return=%s',
    [BoolToStr(KktAccepted, True), KktResultCode, Length(MarkDecoded),
     BoolToStr(ReturnCheck, True)]));
end;

procedure TVariantPrint.UpsertMarkCacheRr(const MarkDecoded: string;
  ReturnCheck: Boolean; RrAccepted: Boolean; RrCode: Integer;
  const RrDescription, Uuid, TimeStr, Inst, Version: string);
var
  Key: string;
  Entry: TMarkCacheEntry;
begin
  if MarkDecoded = '' then
    Exit;
  Key := MarkCacheKey(MarkDecoded, ReturnCheck);
  if not FMarkCache.TryGetValue(Key, Entry) then
    Entry := Default(TMarkCacheEntry);
  Entry.RrChecked := True;
  Entry.RrAccepted := RrAccepted;
  Entry.RrCode := RrCode;
  Entry.RrDescription := RrDescription;
  Entry.Uuid := Uuid;
  Entry.TimeStr := TimeStr;
  Entry.Inst := Inst;
  Entry.Version := Version;
  Entry.CheckedAt := Now;
  FMarkCache.AddOrSetValue(Key, Entry);
  FLog.LogInfo(Format('Кэш марки РР: accepted=%s code=%d uuid=%s len=%d',
    [BoolToStr(RrAccepted, True), RrCode, Uuid, Length(MarkDecoded)]));
end;

procedure TVariantPrint.UpdateMarkCacheFromMarkObj(const MarkDecoded: string;
  ReturnCheck: Boolean; MarkObj: TJSONObject);
var
  PermObj: TJSONObject;
  CodeStr, Desc: string;
begin
  if (MarkDecoded = '') or (MarkObj = nil) then
    Exit;

  Desc := JStr(MarkObj, 'description', '');
  if (Length(Desc) >= 9) and (Copy(Desc, Length(Desc) - 8, 9) = ' (cached)') then
    Desc := Copy(Desc, 1, Length(Desc) - 9);

  UpsertMarkCacheKkt(MarkDecoded, ReturnCheck,
    JBool(MarkObj, 'accepted', False),
    JInt(MarkObj, 'resultCode', 0),
    Desc);

  PermObj := MarkObj.GetValue('permission') as TJSONObject;
  if PermObj = nil then
    Exit;

  CodeStr := JStr(PermObj, 'code', '0');
  UpsertMarkCacheRr(MarkDecoded, ReturnCheck,
    JBool(PermObj, 'accepted', False),
    StrToIntDef(CodeStr, 0),
    JStr(PermObj, 'error', ''),
    JStr(PermObj, 'uuid', ''),
    JStr(PermObj, 'time', ''),
    JStr(PermObj, 'inst', ''),
    JStr(PermObj, 'version', ''));
end;

procedure TVariantPrint.AddMarkToAcceptedCache(const MarkDecoded: string;
  ReturnCheck: Boolean);
begin
  UpsertMarkCacheKkt(MarkDecoded, ReturnCheck, True, 0, 'OK');
end;

procedure TVariantPrint.ClearMarkCache;
begin
  if FMarkCache.Count > 0 then
  begin
    FLog.LogInfo('Сброс кэша марок (' + IntToStr(FMarkCache.Count) + ')');
    FMarkCache.Clear;
  end;
end;

function TVariantPrint.MarkObjFromCacheEntry(const Entry: TMarkCacheEntry): TJSONObject;
var
  Desc: string;
begin
  Result := TJSONObject.Create;
  Result.AddPair('accepted', TJSONBool.Create(Entry.KktAccepted));
  Result.AddPair('resultCode', TJSONNumber.Create(Entry.KktResultCode));
  Result.AddPair('checkItemLocalResult', TJSONNumber.Create(15));
  Result.AddPair('checkItemLocalError', TJSONNumber.Create(0));
  Result.AddPair('markingType2', TJSONNumber.Create(0));
  Result.AddPair('kmServerErrorCode', TJSONNumber.Create(0));
  Result.AddPair('kmServerCheckingStatus', TJSONNumber.Create(15));
  Desc := Entry.KktDescription;
  if Desc = '' then
    Desc := 'OK';
  if Pos('(cached)', Desc) = 0 then
    Desc := Desc + ' (cached)';
  Result.AddPair('description', Desc);
end;

function TVariantPrint.PermissionObjFromCacheEntry(const Entry: TMarkCacheEntry): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('accepted', TJSONBool.Create(Entry.RrAccepted));
  Result.AddPair('code', IntToStr(Entry.RrCode));
  Result.AddPair('error', Entry.RrDescription);
  Result.AddPair('uuid', Entry.Uuid);
  Result.AddPair('time', Entry.TimeStr);
  Result.AddPair('inst', Entry.Inst);
  Result.AddPair('version', Entry.Version);
end;

procedure TVariantPrint.ProcessMarkingAfterFNOperation(const MarkDecoded: string;
  MarkAccepted, ReturnCheck: Boolean);
var
  FromCache, EffectiveAccepted: Boolean;
begin
  if MarkDecoded = '' then
    Exit;

  FromCache := IsMarkAcceptedInCache(MarkDecoded, ReturnCheck);
  EffectiveAccepted := MarkAccepted or FromCache;

  if EffectiveAccepted then
  begin
    if FromCache and not MarkAccepted then
      FLog.LogInfo('markAccepted из pre-flight/кэша — только FNSendItemBarcode')
    else if MarkAccepted then
      FLog.LogInfo('markAccepted=true — только FNSendItemBarcode')
    else
      FLog.LogInfo('марка принята — только FNSendItemBarcode');
    SendMarkingCodeAfterFNOperation(MarkDecoded);
    AddMarkToAcceptedCache(MarkDecoded, ReturnCheck);
    Exit;
  end;

  FLog.LogInfo('Полный цикл маркировки в чеке');
  RunFR('FNCheckItemBarcode', procedure
  begin
    if ReturnCheck then
      ovObject.ItemStatus := 3
    else
      ovObject.ItemStatus := 1;
    ovObject.CheckItemMode := 0;
    ovObject.TLVDataHEX := '';
    ovObject.BarCode := MarkDecoded;
    ovObject.FNCheckItemBarcode;
  end);

  RunFR('FNSendItemBarcode (1)', procedure
  begin
    ovObject.BarCode := MarkDecoded;
    ovObject.FNSendItemBarcode;
  end);

  RunFR('FNAcceptMarkingCode', procedure
  begin
    ovObject.FNAcceptMarkingCode;
  end);

  RunFR('FNSendItemBarcode (2)', procedure
  begin
    ovObject.BarCode := MarkDecoded;
    ovObject.FNSendItemBarcode;
  end);

  AddMarkToAcceptedCache(MarkDecoded, ReturnCheck);
end;

function TVariantPrint.GetReceiptReturnCheck(Req: TJSONObject): Boolean;
var
  T: string;
begin
  T := LowerCase(Trim(JStr(Req, 'type')));
  Result := T = 'sellreturn';
end;

function TVariantPrint.GetCashierName(Req: TJSONObject): string;
var
  Op: TJSONObject;
begin
  Result := '';
  if Req = nil then
    Exit;
  Op := Req.GetValue('operator') as TJSONObject;
  if Op <> nil then
    Result := JStr(Op, 'name');
end;

procedure TVariantPrint.ApplyReceiptHeader(Req: TJSONObject; ReturnCheck: Boolean);
var
  TaxTypeVal: Integer;
begin
  TaxTypeVal := MapTaxationType(JStr(Req, 'taxationType'));

  RunFR('ApplyReceiptHeader CheckType', procedure
  begin
    if ReturnCheck then
      ovObject.CheckType := 2
    else
      ovObject.CheckType := 0;
  end);

  if TaxTypeVal > 0 then
  begin
    FLog.LogInfo('TaxType (СНО)=' + IntToStr(TaxTypeVal));
    RunFR('ApplyReceiptHeader TaxType', procedure
    begin
      ovObject.TaxType := TaxTypeVal;
    end);
  end;
end;

procedure TVariantPrint.PrintReceiptText(const Text: string);
begin
  FLog.LogInfo('PrintString: "' + Text + '"');
  RunFR('PrintString', procedure
  begin
    try
      ovObject.UseReceiptRibbon := 1;
    except
    end;
    ovObject.StringForPrinting := Text;
    ovObject.PrintString;
  end);
end;

procedure TVariantPrint.RegisterReceiptItem(Item: TJSONObject; ReturnCheck: Boolean;
  DefaultDepartment: Integer);
var
  Name, MarkB64, MarkDecoded, UUID, TimeStr, Inst, Version, ItemType: string;
  Tag1262, Tag1263, Tag1264: string;
  TaxObj, PermObj: TJSONObject;
  Qty, Price: Double;
  Department, Tax1, PayObj, PayMethod: Integer;
  MarkAccepted, HasMark: Boolean;
  Cached: TMarkCacheEntry;
begin
  ItemType := LowerCase(Trim(JStr(Item, 'type', 'position')));
  if (ItemType <> 'position') and (ItemType <> '') and (JStr(Item, 'name') = '') then
    Exit;

  Name := JStr(Item, 'name');
  Qty := JFloat(Item, 'quantity', 1);
  Price := JFloat(Item, 'price', 0);
  Department := JInt(Item, 'department', DefaultDepartment);

  MarkB64 := JStr(Item, 'mark');
  if MarkB64 <> '' then
    MarkDecoded := DecodeMarkBase64(MarkB64)
  else
    MarkDecoded := '';
  HasMark := MarkDecoded <> '';
  MarkAccepted := JBool(Item, 'markAccepted', False);

  PermObj := Item.GetValue('permission') as TJSONObject;
  UUID := '';
  TimeStr := '';
  Inst := '';
  Version := '';
  Tag1262 := '030';
  Tag1263 := '21.11.2023';
  Tag1264 := '1944';
  if PermObj <> nil then
  begin
    UUID := JStr(PermObj, 'uuid');
    TimeStr := JStr(PermObj, 'time');
    Inst := JStr(PermObj, 'inst');
    Version := JStr(PermObj, 'version');
    Tag1262 := JStr(PermObj, 'tag1262', Tag1262);
    Tag1263 := JStr(PermObj, 'tag1263', Tag1263);
    Tag1264 := JStr(PermObj, 'tag1264', Tag1264);
  end;

  // Ленивый клиент: permission не в JSON — берём из FMarkCache (после pre-flight / check-marks)
  if HasMark and (not ReturnCheck) and ((UUID = '') or (TimeStr = '')) then
  begin
    if TryGetMarkFromCache(MarkDecoded, ReturnCheck, Cached) and Cached.RrChecked and
      (Cached.Uuid <> '') and (Cached.TimeStr <> '') then
    begin
      UUID := Cached.Uuid;
      TimeStr := Cached.TimeStr;
      Inst := Cached.Inst;
      Version := Cached.Version;
      FLog.LogInfo('permission из кэша: uuid=' + UUID);
    end;
  end;

  TaxObj := Item.GetValue('tax') as TJSONObject;
  if TaxObj <> nil then
    Tax1 := MapTax1(JStr(TaxObj, 'type'))
  else
    Tax1 := 0;

  PayObj := MapPaymentObject(JStr(Item, 'paymentObject', 'commodity'), HasMark);
  PayMethod := MapPaymentMethodSign(JStr(Item, 'paymentMethod', 'fullPayment'));

  FLog.LogInfo(Format(
    'FNOperation: "%s" qty=%g price=%g dept=%d tax=%d payObj=%d payMethod=%d markLen=%d markAccepted=%s',
    [Name, Qty, Price, Department, Tax1, PayObj, PayMethod, Length(MarkDecoded),
     BoolToStr(MarkAccepted, True)]));

  RunFR('FNOperation', procedure
  begin
    ovObject.StringForPrinting := Name;
    ovObject.Quantity := Qty;
    ovObject.Price := Price;
    ovObject.Department := Department;
    ovObject.Tax1 := Tax1;
    ovObject.Tax2 := 0;
    ovObject.Tax3 := 0;
    ovObject.Tax4 := 0;
    ovObject.PaymentTypeSign := PayMethod;
    ovObject.PaymentItemSign := PayObj;
    try
      ovObject.MeasureUnit := MapMeasureUnit(JStr(Item, 'measurementUnit'));
    except
    end;
    ovObject.FNOperation;
  end);

  if HasMark and (not ReturnCheck) then
  begin
    if (UUID <> '') and (TimeStr <> '') then
      SendIndustryRequisite126x(Tag1262, Tag1263, Tag1264, UUID, TimeStr, Inst, Version)
    else
      FLog.LogInfo('WARN: маркированная позиция без permission — теги РР не отправляются');
  end;

  ProcessMarkingAfterFNOperation(MarkDecoded, MarkAccepted, ReturnCheck);
end;

{-------------------------------------------------------------------------------
 Закрытие чека
-------------------------------------------------------------------------------}

procedure TVariantPrint.CloseReceiptFromJson(Req: TJSONObject);
var
  Payments: TJSONArray;
  Pay: TJSONObject;
  I, Payment: Integer;
  PayType: string;
  Sum, Total, Received, Summ1, Summ2, Summ15: Double;
  TaxTypeVal: Integer;
begin
  Total := JFloat(Req, 'total', 0);
  Received := JFloat(Req, 'received', Total);
  Summ1 := 0;
  Summ2 := 0;
  Summ15 := 0;

  Payments := Req.GetValue('payments') as TJSONArray;
  if (Payments <> nil) and (Payments.Count > 0) then
  begin
    for I := 0 to Payments.Count - 1 do
    begin
      if not (Payments.Items[I] is TJSONObject) then
        Continue;
      Pay := TJSONObject(Payments.Items[I]);
      PayType := LowerCase(Trim(JStr(Pay, 'type')));
      Sum := JFloat(Pay, 'sum', 0);
      if PayType = 'cash' then
        Summ1 := Summ1 + Sum
      else if PayType = 'electronically' then
        Summ2 := Summ2 + Sum
      else if PayType = 'credit' then
        Summ15 := Summ15 + Sum
      else
        FLog.LogInfo('WARN: неизвестный тип оплаты "' + PayType + '"');
    end;
    FLog.LogInfo('FNCloseCheckEx: payments[] total=' + FloatToStr(Total) +
      ' Summ1=' + FloatToStr(Summ1) +
      ' Summ2=' + FloatToStr(Summ2) +
      ' Summ15=' + FloatToStr(Summ15));
  end
  else
  begin
    Payment := JInt(Req, 'payment', 0);
    FLog.LogInfo('FNCloseCheckEx: payment=' + IntToStr(Payment) +
      ' total=' + FloatToStr(Total) + ' received=' + FloatToStr(Received));
    case Payment of
      0: Summ1 := Total;
      1: Summ2 := Total;
      2: Summ15 := Received;
    else
      Summ1 := Total;
    end;
  end;

  TaxTypeVal := MapTaxationType(JStr(Req, 'taxationType'));

  if FTestReceiptMode then
  begin
    FLog.LogInfo('Тестовый режим: CancelCheck вместо FNCloseCheckEx');
    RunFR('CancelCheck', procedure
    begin
      ovObject.CancelCheck;
    end);
  end
  else
  begin
    RunFR('FNCloseCheckEx', procedure
    begin
      ovObject.StringForPrinting := '';
      ovObject.Summ1 := Summ1;
      ovObject.Summ2 := Summ2;
      ovObject.Summ3 := 0;
      ovObject.Summ4 := 0;
      ovObject.Summ5 := 0;
      ovObject.Summ6 := 0;
      ovObject.Summ7 := 0;
      ovObject.Summ8 := 0;
      ovObject.Summ9 := 0;
      ovObject.Summ10 := 0;
      ovObject.Summ11 := 0;
      ovObject.Summ12 := 0;
      ovObject.Summ13 := 0;
      ovObject.Summ14 := 0;
      ovObject.Summ15 := Summ15;
      ovObject.Summ16 := 0;
      if TaxTypeVal > 0 then
        ovObject.TaxType := TaxTypeVal;
      ovObject.RoundingSumm := 0;
      ovObject.TaxValue1 := 0;
      ovObject.TaxValue2 := 0;
      ovObject.TaxValue3 := 0;
      ovObject.TaxValue4 := 0;
      ovObject.TaxValue5 := 0;
      ovObject.TaxValue6 := 0;
      ovObject.FNCloseCheckEx;
    end);
  end;
  ClearMarkCache;
end;

procedure TVariantPrint.CutCheckWithWait;
const
  FR_BUSY_PRINTING = 80;
  MaxAttempts = 300; // ~30 с при Sleep(100)
  RetryDelayMs = 100;
var
  Attempt, Code: Integer;
  Desc: string;
begin
  if FEmulation then
  begin
    FLog.LogInfo('[FR] CutCheck (emu)');
    Exit;
  end;

  Attempt := 0;
  while True do
  begin
    Inc(Attempt);
    Code := -1;
    Desc := '';
    ExecOnFrThread(procedure
    begin
      if not FRObjectReady then
        LogFRSkipped('CutCheck');
      ovObject.CutType := 1;
      ovObject.CutCheck;
      try
        Code := ovObject.ResultCode;
      except
        on E: Exception do
        begin
          FLog.LogError('[FR] CutCheck: не удалось прочитать ResultCode — ' + E.Message);
          raise;
        end;
      end;
      Desc := FRResultText(ovObject);
    end);

    if Code = 0 then
    begin
      if Attempt > 1 then
        FLog.LogInfo(Format('[FR] CutCheck: OK после ожидания печати (попытка %d)', [Attempt]))
      else
        FLog.LogDebug('[FR] CutCheck: OK');
      Exit;
    end;

    if Code = FR_BUSY_PRINTING then
    begin
      if Attempt = 1 then
        FLog.LogInfo('[FR] CutCheck: ждём окончания печати (код 80)...');
      if Attempt >= MaxAttempts then
        raise Exception.Create(
          'CutCheck: 80 Идет печать предыдущей команды (таймаут ожидания)');
      Sleep(RetryDelayMs);
      Continue;
    end;

    FLog.LogError('[FR] CutCheck: ' + IntToStr(Code) + ' ' + Desc);
    raise Exception.Create(UserMessageForFRError('CutCheck', Code, Desc, -1));
  end;
end;

function TVariantPrint.ReceiptStatusJson(const Id: string): string;
begin Result := FReceipts.Status(Id); end;

function TVariantPrint.ReceiptBusy: Boolean;
begin Result := FReceipts.Busy; end;

function TVariantPrint.PrintCheckJson(const Body: string): string;
var Req: TJSONObject; Id: string;
begin
  Req := ParseJsonObjectOrRaise(Body, 'PrintCheckJson', FLog);
  try Id := JStr(Req, 'operationId'); finally Req.Free; end;
  if Id = '' then begin
    if ReceiptBusy then Exit(JsonError('Продолжается предыдущий чек'));
    Exit(PrintCheckCore(Body));
  end;
  Result := FReceipts.Submit(Id, Body, ExecuteManagedReceipt);
end;

function TVariantPrint.ExecuteManagedReceipt(const Body: string): string;
begin
  FLock.Enter;
  try
    FManagedReceipt := True;
    try Result := PrintCheckCore(Body);
    finally FManagedReceipt := False; end;
  finally FLock.Leave; end;
end;

function TVariantPrint.PrintCheckCore(const Body: string): string;
var
  Req, Item: TJSONObject;
  Items: TJSONArray;
  I, CheckNumber: Integer;
  ReturnCheck: Boolean;
  SerialNumber, ItemType, CashierName, PreflightErr: string;
  DefaultDept: Integer;
begin
  FLock.Enter;
  try
    Result := JsonError('Unknown error');
    Req := nil;
    FReceiptStarted := False; FReceiptClosed := False;
    try
      FLog.LogInfo('PrintCheckJson begin');
      EnsureFRConnected;

      Req := ParseJsonObjectOrRaise(Body, 'PrintCheckJson', FLog);

      ReturnCheck := GetReceiptReturnCheck(Req);
      CashierName := GetCashierName(Req);
      EnsureSessionOpen(CashierName);

      Items := Req.GetValue('items') as TJSONArray;
      if Items = nil then
        raise Exception.Create('items is empty');

      PreflightErr := EnsureMarksReadyForPrint(Req);
      if PreflightErr <> '' then
      begin
        Result := PreflightErr;
        FLog.LogError('PrintCheckJson: pre-flight — марки не прошли, чек не открываем');
        // кэш не сбрасываем — результаты проверки уже известны
      end
      else
      begin
        DefaultDept := JInt(Req, 'department', 1);
        ApplyReceiptHeader(Req, ReturnCheck);

        for I := 0 to Items.Count - 1 do
        begin
          if not (Items.Items[I] is TJSONObject) then
            Continue;
          Item := TJSONObject(Items.Items[I]);
          ItemType := LowerCase(Trim(JStr(Item, 'type', 'position')));
          if ItemType = 'text' then
            PrintReceiptText(JStr(Item, 'text'))
          else if (ItemType = 'position') or (ItemType = '') or (JStr(Item, 'name') <> '') then
            RegisterReceiptItem(Item, ReturnCheck, DefaultDept)
          else
            FLog.LogInfo('Пропуск элемента items type="' + ItemType + '"');
        end;

        CloseReceiptFromJson(Req);

        CheckNumber := ReadCheckNumberAfterClose;
        SerialNumber := ReadSerialNumber;

        // Отрез — после успешного FNCloseCheckEx. Код 80 ждём (как в 1С).
        // Ошибку отреза не поднимаем наружу: чек уже фискально закрыт,
        // иначе клиент получит result=0 и может напечатать чек повторно.
        if not FTestReceiptMode then
        begin
          try
            CutCheckWithWait;
          except
            on E: Exception do
              FLog.LogError('PrintCheckJson: отрез не выполнен — ' + E.Message);
          end;
        end
        else
          FLog.LogInfo('Тестовый режим: CutCheck пропущен');

        Result := JsonOk(
          '"state":"completed","checkNumber":' + IntToStr(CheckNumber) + ',' +
          '"serialNumber":"' + JsonEscape(SerialNumber) + '"');

        FLog.LogInfo(Format('PrintCheckJson OK checkNumber=%d serial=%s',
          [CheckNumber, SerialNumber]));
        ClearMarkCache;
        AfterCommand(Req);
      end;
    except
      on E: Exception do
      begin
        FLog.LogError('PrintCheckJson: ' + E.Message);
        // Never cancel or manufacture success after an uncertain device outcome.
        // In particular, a closed fiscal receipt must never become a new sale.
        Result := JsonError(E.Message);

      end;
    end;
    if FManagedReceipt then begin
      Item := TJSONObject.ParseJSONValue(Result) as TJSONObject;
      try
        if Item.GetValue('state') = nil then begin
          if FReceiptStarted then Item.AddPair('state', 'uncertain')
          else Item.AddPair('state', 'rejected');
        end;
        Item.AddPair('fiscalClosed', TJSONBool.Create(FReceiptClosed));
        Result := Item.ToJSON;
      finally Item.Free; end;
    end;
    Req.Free;
  finally
    FLock.Leave;
  end;
end;

{-------------------------------------------------------------------------------
 Служебные команды
-------------------------------------------------------------------------------}

function TVariantPrint.PrintTextJson(const Body: string): string;
var
  Req: TJSONObject;
  TextValue: TJSONValue;
  Lines: TStringList;
  I, Mode: Integer;
  Text: string;
begin
  FLock.Enter;
  try
    Req := nil;
    Lines := nil;
    try
      // Validate before connecting; malformed input is never emulated as success.
      Req := ParseJsonObjectOrRaise(Body, 'PrintTextJson', FLog);
      TextValue := Req.GetValue('text');
      if not (TextValue is TJSONString) then
        raise Exception.Create('print-text: text must be a string');
      Text := TJSONString(TextValue).Value;
      if Trim(Text) = '' then
        raise Exception.Create('print-text: text is empty');
      if Length(Text) > 65536 then
        raise Exception.Create('print-text: text is too long');
      EnsureFRConnected;
      if not FEmulation then
      begin
        Mode := ReadECRMode;
        if (Mode <> 0) and (Mode <> 2) and (Mode <> 3) and (Mode <> 4) then
          raise Exception.Create(MessageForBlockedECRMode(Mode));
      end;
      Lines := TStringList.Create;
      Lines.Text := Text.Replace(#13#10, #10).Replace(#13, #10);
      for I := 0 to Lines.Count - 1 do
        PrintReceiptText(Lines[I]);
      CutCheckWithWait;
      Result := JsonOk('"emulation":' + LowerCase(BoolToStr(FEmulation, True)));
      FLog.LogInfo('PrintTextJson OK lines=' + IntToStr(Lines.Count));
      AfterCommand(Req);
    except
      on E: Exception do
      begin
        FLog.LogError('PrintTextJson: ' + E.Message);
        Result := JsonError(E.Message);
      end;
    end;
    Lines.Free;
    Req.Free;
  finally
    FLock.Leave;
  end;
end;

function TVariantPrint.CloseShiftJson(const Body: string): string;
var
  V: TJSONValue;
  Req: TJSONObject;
  SessionNumber: Integer;
begin
  FLock.Enter;
  try
    V := nil;
    Req := nil;
    try
      FLog.LogInfo('CloseShiftJson begin');
      V := TJSONObject.ParseJSONValue(Body);
      if V is TJSONObject then
        Req := TJSONObject(V);

      EnsureFRConnected;
      // Режим 3 (смена > 24 ч) здесь допустим — это как раз повод снять Z
      EnsureReadyForZReport;
      RunFR('PrintReportWithCleaning', procedure
      begin
        ovObject.PrintReportWithCleaning;
      end);

      SessionNumber := ReadSessionNumberAfterClose;

      Result := JsonOk('"documentNumber":' + IntToStr(SessionNumber));
      FLog.LogInfo('CloseShiftJson OK documentNumber=' + IntToStr(SessionNumber));
      ClearMarkCache;
      AfterCommand(Req);
    except
      on E: Exception do
      begin
        FLog.LogError('CloseShiftJson: ' + E.Message);
        if FEmulation then
        begin
          Inc(FEmulatedSessionNumber);
          Result := JsonOk('"documentNumber":' + IntToStr(FEmulatedSessionNumber));
          ClearMarkCache;
          AfterCommand(Req);
        end
        else
          Result := JsonError(E.Message);
      end;
    end;
    V.Free;
  finally
    FLock.Leave;
  end;
end;

function TVariantPrint.XReportJson(const Body: string = ''): string;
var
  V: TJSONValue;
  Req: TJSONObject;
begin
  FLock.Enter;
  try
    V := nil;
    Req := nil;
    try
      FLog.LogInfo('XReportJson begin');
      V := TJSONObject.ParseJSONValue(Body);
      if V is TJSONObject then
        Req := TJSONObject(V);

      EnsureFRConnected;
      // Режим 3 допустим для X; смену не открываем автоматически
      EnsureReadyForXReport;
      RunFR('PrintReportWithoutCleaning', procedure
      begin
        ovObject.PrintReportWithoutCleaning;
      end);
      Result := JsonOk;
      FLog.LogInfo('XReportJson OK');
      AfterCommand(Req);
    except
      on E: Exception do
      begin
        FLog.LogError('XReportJson: ' + E.Message);
        if FEmulation then
        begin
          Result := JsonOk;
          AfterCommand(Req);
        end
        else
          Result := JsonError(E.Message);
      end;
    end;
    V.Free;
  finally
    FLock.Leave;
  end;
end;

function TVariantPrint.OpenShiftJson(const Body: string = ''): string;
var
  V: TJSONValue;
  Req: TJSONObject;
  CashierName: string;
  Mode, SessionNumber: Integer;
begin
  FLock.Enter;
  try
    V := nil;
    Req := nil;
    try
      FLog.LogInfo('OpenShiftJson begin');
      V := TJSONObject.ParseJSONValue(Body);
      if V is TJSONObject then
        Req := TJSONObject(V);

      EnsureFRConnected;

      if FEmulation then
      begin
        Inc(FEmulatedSessionNumber);
        Result := JsonOk('"documentNumber":' + IntToStr(FEmulatedSessionNumber));
        AfterCommand(Req);
        Exit;
      end;

      ClearStuckOpenDocument('OpenShift');
      Mode := ReadECRMode;
      FLog.LogInfo('OpenShiftJson: ECRMode=' + IntToStr(Mode) +
        ' (' + ECRModeCaption(Mode) + ')');

      if (Mode = 0) or (Mode = 2) then
      begin
        FLog.LogInfo('OpenShiftJson: смена уже открыта');
        SessionNumber := ReadSessionNumberAfterClose;
        // ReadSessionNumberAfterClose в эмуляции инкрементирует — здесь не эмуляция
        Result := JsonOk('"documentNumber":' + IntToStr(SessionNumber) +
          ',"alreadyOpen":true');
        AfterCommand(Req);
        Exit;
      end;

      if Mode = 3 then
        raise Exception.Create(MessageForBlockedECRMode(3));

      if Mode <> 4 then
        raise Exception.Create(MessageForBlockedECRMode(Mode));

      CashierName := '';
      if Req <> nil then
      begin
        CashierName := JStr(Req, 'cashierName');
        if CashierName = '' then
          CashierName := GetCashierName(Req);
      end;
      DoOpenSession(CashierName);

      Mode := ReadECRMode;
      if (Mode <> 0) and (Mode <> 2) then
        raise Exception.Create(MessageForBlockedECRMode(Mode));

      SessionNumber := ReadSessionNumberAfterClose;
      Result := JsonOk('"documentNumber":' + IntToStr(SessionNumber));
      FLog.LogInfo('OpenShiftJson OK documentNumber=' + IntToStr(SessionNumber));
      AfterCommand(Req);
    except
      on E: Exception do
      begin
        FLog.LogError('OpenShiftJson: ' + E.Message);
        if FEmulation then
        begin
          Inc(FEmulatedSessionNumber);
          Result := JsonOk('"documentNumber":' + IntToStr(FEmulatedSessionNumber));
          AfterCommand(Req);
        end
        else
          Result := JsonError(E.Message);
      end;
    end;
    V.Free;
  finally
    FLock.Leave;
  end;
end;

function TVariantPrint.CancelCheckJson(const Body: string = ''): string;
var
  V: TJSONValue;
  Req: TJSONObject;
begin
  FLock.Enter;
  try
    V := nil;
    Req := nil;
    try
      FLog.LogInfo('CancelCheckJson begin');
      V := TJSONObject.ParseJSONValue(Body);
      if V is TJSONObject then
        Req := TJSONObject(V);

      EnsureFRConnected;
      RunFR('CancelCheck', procedure
      begin
        ovObject.CancelCheck;
      end);
      ClearMarkCache;
      Result := JsonOk;
      FLog.LogInfo('CancelCheckJson OK');
      AfterCommand(Req);
    except
      on E: Exception do
      begin
        FLog.LogError('CancelCheckJson: ' + E.Message);
        if FEmulation then
        begin
          Result := JsonOk;
          ClearMarkCache;
          AfterCommand(Req);
        end
        else
          Result := JsonError(E.Message);
      end;
    end;
    V.Free;
  finally
    FLock.Leave;
  end;
end;

function TVariantPrint.ClearBufferOfMarksJson(const Body: string = ''): string;
var
  V: TJSONValue;
  Req: TJSONObject;
begin
  FLock.Enter;
  try
    V := nil;
    Req := nil;
    try
      FLog.LogInfo('ClearBufferOfMarksJson begin');
      V := TJSONObject.ParseJSONValue(Body);
      if V is TJSONObject then
        Req := TJSONObject(V);

      EnsureFRConnected;
      RunFR('FNMarkingClearBuffer', procedure
      begin
        ovObject.FNMarkingClearBuffer;
      end);
      ClearMarkCache;
      Result := JsonOk;
      FLog.LogInfo('ClearBufferOfMarksJson OK');
      AfterCommand(Req);
    except
      on E: Exception do
      begin
        FLog.LogError('ClearBufferOfMarksJson: ' + E.Message);
        if FEmulation then
        begin
          Result := JsonOk;
          ClearMarkCache;
          AfterCommand(Req);
        end
        else
          Result := JsonError(E.Message);
      end;
    end;
    V.Free;
  finally
    FLock.Leave;
  end;
end;

{-------------------------------------------------------------------------------
 Проверка маркировки (FNCheckItemBarcode)
-------------------------------------------------------------------------------}

function KmServerErrorCodeText(Code: Integer): string;
begin
  case Code of
    1: Result := 'КИЗ отсутствует в базе СКЗКМ/ИСМ';
    2: Result := 'Некорректен формат КИЗ';
    3: Result := 'Криптографическая проверка КПКИЗ отрицательная';
    4: Result := 'Статус КИЗ не совместим с запрашиваемым изменением';
    5: Result := 'В списке вложения обнаружены ошибки';
  else
    Result := 'KMServerErrorCode=' + IntToStr(Code);
  end;
end;

/// <summary>КМ для лога: GS→&lt;GS&gt;, прочие control→\xHH (чтобы видеть, что реально ушло в ФН).</summary>
function MarkForLog(const Mark: string): string;
var
  I, Code, GsCount: Integer;
  C: Char;
  View, HexTail: string;
begin
  View := '';
  GsCount := 0;
  for I := 1 to Length(Mark) do
  begin
    C := Mark[I];
    Code := Ord(C);
    if C = #$1D then
    begin
      Inc(GsCount);
      View := View + '<GS>';
    end
    else if (Code < 32) or (Code = 127) then
      View := View + Format('\x%.2X', [Code])
    else
      View := View + C;
  end;

  HexTail := '';
  for I := 1 to Length(Mark) do
    HexTail := HexTail + Format('%.2X', [Ord(Mark[I])]);

  Result := Format('len=%d gs=%d view="%s" hex=%s',
    [Length(Mark), GsCount, View, HexTail]);
end;

function TVariantPrint.DecodeMarkBase64(const B64: string): string;
var
  Bytes: TBytes;
  I, Len, RawLen: Integer;
  HasGS: Boolean;
begin
  if Trim(B64) = '' then
    raise Exception.Create('Пустая марка (base64)');

  try
    Bytes := TNetEncoding.Base64.DecodeStringToBytes(B64);
  except
    on E: Exception do
      raise Exception.Create('Некорректный base64 марки: ' + E.Message);
  end;

  RawLen := Length(Bytes);
  if RawLen = 0 then
    raise Exception.Create('Декодированная марка пуста');

  // 1С часто отдаёт КМ из фиксированного поля со пробелами/нулями справа —
  // в BarCode это ломает FNCheckItemBarcode (часто как -1 «Нет связи»).
  Len := RawLen;
  while (Len > 0) and ((Bytes[Len - 1] = Ord(' ')) or (Bytes[Len - 1] = 0)) do
    Dec(Len);
  if Len = 0 then
    raise Exception.Create('Декодированная марка пуста после обрезки хвоста');
  if Len <> RawLen then
    FLog.LogInfo(Format('DecodeMarkBase64: обрезан хвост %d→%d', [RawLen, Len]));

  SetLength(Result, Len);
  for I := 0 to Len - 1 do
    Result[I + 1] := Char(Bytes[I]);

  // В 1С GS (Chr29) часто хранят как литерал "0029" — ФН ждёт #$1D, иначе 211.
  HasGS := False;
  for I := 1 to Length(Result) do
    if Result[I] = #$1D then
    begin
      HasGS := True;
      Break;
    end;
  if (not HasGS) and (Pos('0029', Result) > 0) then
  begin
    Result := StringReplace(Result, '0029', #$1D, [rfReplaceAll]);
    FLog.LogInfo(Format('DecodeMarkBase64: "0029"→GS, len %d→%d', [Len, Length(Result)]));
  end;
end;

function TVariantPrint.NewTaskId: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := GUIDToString(G);
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
end;

procedure TVariantPrint.TrimOldMarkTasks;
var
  Keys: TArray<string>;
  Key: string;
  Entry: TCheckMarkTaskEntry;
  I, RemoveCount: Integer;
begin
  if FMarkTasks.Count <= 50 then
    Exit;

  Keys := FMarkTasks.Keys.ToArray;
  RemoveCount := FMarkTasks.Count - 50;
  for I := 0 to High(Keys) do
  begin
    if RemoveCount <= 0 then
      Break;
    Key := Keys[I];
    if FMarkTasks.TryGetValue(Key, Entry) then
    begin
      if (Entry.Status <> 'pending') or (MinutesBetween(Now, Entry.CreatedAt) > 60) then
      begin
        FMarkTasks.Remove(Key);
        Dec(RemoveCount);
      end;
    end;
  end;
end;

procedure TVariantPrint.CollectMarksFromRequest(Req: TJSONObject;
  out MarksB64: TArray<string>);
var
  Arr: TJSONArray;
  I: Integer;
  SingleMark: string;
begin
  SetLength(MarksB64, 0);
  if Req = nil then
    raise Exception.Create('Invalid request');

  Arr := Req.GetValue('marks') as TJSONArray;
  if Arr <> nil then
  begin
    if Arr.Count = 0 then
      raise Exception.Create('marks is empty');
    SetLength(MarksB64, Arr.Count);
    for I := 0 to Arr.Count - 1 do
      MarksB64[I] := Arr.Items[I].Value;
    Exit;
  end;

  SingleMark := JStr(Req, 'mark');
  if SingleMark = '' then
    raise Exception.Create('Укажите mark (base64) или marks (массив base64)');

  SetLength(MarksB64, 1);
  MarksB64[0] := SingleMark;
end;

procedure TVariantPrint.CollectMarksFromReceiptItems(Req: TJSONObject;
  out MarksB64: TArray<string>);
var
  Items: TJSONArray;
  Item: TJSONObject;
  I: Integer;
  ItemType, MarkB64: string;
begin
  SetLength(MarksB64, 0);
  if Req = nil then
    Exit;
  Items := Req.GetValue('items') as TJSONArray;
  if Items = nil then
    Exit;

  for I := 0 to Items.Count - 1 do
  begin
    if not (Items.Items[I] is TJSONObject) then
      Continue;
    Item := TJSONObject(Items.Items[I]);
    ItemType := LowerCase(Trim(JStr(Item, 'type', 'position')));
    if (ItemType <> 'position') and (ItemType <> '') then
      Continue;
    MarkB64 := Trim(JStr(Item, 'mark'));
    if MarkB64 = '' then
      Continue;
    SetLength(MarksB64, Length(MarksB64) + 1);
    MarksB64[High(MarksB64)] := MarkB64;
  end;
end;

function TVariantPrint.EnsureMarksReadyForPrint(Req: TJSONObject): string;
var
  MarksB64: TArray<string>;
  MarksOut: TJSONArray;
  Root, MarkObj, PermObj: TJSONObject;
  ReturnCheck, CheckPermission: Boolean;
  PermissionInn, PermissionFn: string;
  I: Integer;
  MarkDecoded: string;
  AllAccepted, AllPermissionAccepted, Accepted, PermAccepted: Boolean;
  Cached: TMarkCacheEntry;
  HasErrors: Boolean;
begin
  Result := '';
  if Req = nil then
    Exit;

  if JBool(Req, 'skipMarkPreflight', False) then
  begin
    FLog.LogInfo('print-check: skipMarkPreflight=true — pre-flight пропущен');
    Exit;
  end;

  CollectMarksFromReceiptItems(Req, MarksB64);
  if Length(MarksB64) = 0 then
  begin
    FLog.LogInfo('print-check: pre-flight — маркированных позиций нет');
    Exit;
  end;

  ReturnCheck := GetReceiptReturnCheck(Req);
  // РР только для sell; по умолчанию включаем (ленивый клиент без permission в JSON)
  CheckPermission := (not ReturnCheck) and JBool(Req, 'checkPermission', True);

  FLog.LogInfo(Format(
    'print-check: pre-flight begin, marks=%d return=%s checkPermission=%s',
    [Length(MarksB64), BoolToStr(ReturnCheck, True), BoolToStr(CheckPermission, True)]));

  if CheckPermission then
  begin
    PermissionInn := ResolvePermissionInn(Req);
    PermissionFn := ResolvePermissionFn(Req);
  end;

  MarksOut := TJSONArray.Create;
  try
    AllAccepted := True;
    AllPermissionAccepted := True;
    HasErrors := False;

    for I := 0 to High(MarksB64) do
    begin
      MarkDecoded := DecodeMarkBase64(MarksB64[I]);
      FLog.LogInfo(Format('pre-flight марка [%d/%d]: %s',
        [I + 1, Length(MarksB64), MarkForLog(MarkDecoded)]));

      if IsMarkFullyOk(MarkDecoded, ReturnCheck, CheckPermission) then
      begin
        TryGetMarkFromCache(MarkDecoded, ReturnCheck, Cached);
        FLog.LogInfo(Format('pre-flight [%d]: из кэша — skip', [I + 1]));
        MarkObj := MarkObjFromCacheEntry(Cached);
        try
          MarkObj.AddPair('index', TJSONNumber.Create(I));
          MarkObj.AddPair('mark', MarksB64[I]);
          if CheckPermission and Cached.RrChecked then
            MarkObj.AddPair('permission', PermissionObjFromCacheEntry(Cached));
          MarksOut.AddElement(MarkObj);
          MarkObj := nil;
        finally
          MarkObj.Free;
        end;
        Continue;
      end;

      MarkObj := CheckSingleMark(MarkDecoded, ReturnCheck);
      try
        MarkObj.AddPair('index', TJSONNumber.Create(I));
        MarkObj.AddPair('mark', MarksB64[I]);

        Accepted := JBool(MarkObj, 'accepted', False);
        if not Accepted then
        begin
          AllAccepted := False;
          HasErrors := True;
        end;

        if CheckPermission then
        begin
          // Retry a rejected permission check: subscription/network state may have changed.
          if TryGetMarkFromCache(MarkDecoded, ReturnCheck, Cached) and Cached.RrChecked and Cached.RrAccepted then
          begin
            FLog.LogInfo(Format('pre-flight РР [%d]: из кэша — skip POST /document', [I + 1]));
            PermObj := PermissionObjFromCacheEntry(Cached);
          end
          else
          begin
            FLog.LogInfo(Format('pre-flight РР [%d]: проверка', [I + 1]));
            PermObj := CheckSingleMarkPermission(MarksB64[I], PermissionInn, PermissionFn);
          end;
          try
            MarkObj.AddPair('permission', PermObj);
            PermObj := nil;
            PermAccepted := False;
            if MarkObj.GetValue('permission') is TJSONObject then
              PermAccepted := JBool(TJSONObject(MarkObj.GetValue('permission')), 'accepted', False);
            if not PermAccepted then
            begin
              AllPermissionAccepted := False;
              HasErrors := True;
            end;
          finally
            PermObj.Free;
          end;
        end;

        UpdateMarkCacheFromMarkObj(MarkDecoded, ReturnCheck, MarkObj);
        MarksOut.AddElement(MarkObj);
        MarkObj := nil;
      finally
        MarkObj.Free;
      end;
    end;

    if not HasErrors then
    begin
      FLog.LogInfo('print-check: pre-flight OK — все марки готовы');
      Exit;
    end;

    Root := TJSONObject.Create;
    try
      Root.AddPair('result', TJSONNumber.Create(0));
      Root.AddPair('description', 'Не все марки прошли проверку');
      Root.AddPair('allAccepted', TJSONBool.Create(AllAccepted));
      if CheckPermission then
        Root.AddPair('allPermissionAccepted', TJSONBool.Create(AllPermissionAccepted));
      Root.AddPair('marks', MarksOut);
      MarksOut := nil;
      Result := JsonToPlainText(Root);
    finally
      Root.Free;
    end;
    FLog.LogError('print-check: pre-flight FAIL allAccepted=' +
      BoolToStr(AllAccepted, True));
  finally
    MarksOut.Free;
  end;
end;

function TVariantPrint.ReadECRMode: Integer;
var
  Mode: Integer;
begin
  Mode := -1;
  if not FRObjectReady then
  begin
    Result := -1;
    Exit;
  end;
  ExecOnFrThread(procedure
  begin
    try
      Mode := ovObject.ECRMode;
    except
      Mode := -1;
    end;
  end);
  Result := Mode;
end;

procedure TVariantPrint.RefreshECRStatus(const Place: string);
begin
  RunFR(Place, procedure
  begin
    ovObject.GetECRStatus;
  end);
end;

procedure TVariantPrint.ClearStuckOpenDocument(const Context: string);
var
  Mode: Integer;
begin
  RefreshECRStatus('GetECRStatus ' + Context);
  if FEmulation then
    Exit;
  if not FRObjectReady then
  begin
    LogFRSkipped(Context);
    Exit;
  end;

  Mode := ReadECRMode;
  FLog.LogInfo(Context + ': ECRMode=' + IntToStr(Mode) +
    ' (' + ECRModeCaption(Mode) + ')');

  if Mode <> 8 then
    Exit;

  raise Exception.Create(Context + ': на ККТ открыт прежний чек. Завершите его; автоматическая отмена не выполняется.');
end;

procedure TVariantPrint.DoOpenSession(const CashierName: string);
var
  Cashier: string;
  Mode: Integer;
begin
  Cashier := CashierName;
  if Cashier = '' then
    Cashier := FSettings.ReadString('FRCash', 'CashierName', 'Кассир');

  FLog.LogInfo('Открываем смену (кассир: ' + Cashier + ')');

  RunFR('WriteTable cashier', procedure
  begin
    ovObject.TableNumber := 2;
    ovObject.FieldNumber := 2;
    ovObject.RowNumber := 30;
    ovObject.ValueOfFieldString := Cashier;
    ovObject.WriteTable;
  end);

  RunFR('WriteTable session flag', procedure
  begin
    ovObject.TableNumber := 1;
    ovObject.FieldNumber := 6;
    ovObject.RowNumber := 1;
    ovObject.ValueOfFieldInteger := 0;
    ovObject.WriteTable;
  end);

  RunFR('OpenSession', procedure
  begin
    ovObject.OpenSession;
  end);

  RefreshECRStatus('GetECRStatus after OpenSession');
  Mode := ReadECRMode;
  FLog.LogInfo('After OpenSession: ECRMode=' + IntToStr(Mode) +
    ' (' + ECRModeCaption(Mode) + ')');
end;

procedure TVariantPrint.EnsureSessionOpen(const CashierName: string);
var
  Mode: Integer;
begin
  // Для продажи / проверки марки: нужна открытая смена < 24 ч (режимы 0 или 2)
  ClearStuckOpenDocument('EnsureSessionOpen');

  if FEmulation then
    Exit;
  if not FRObjectReady then
    Exit;

  Mode := ReadECRMode;

  if Mode = 4 then
  begin
    DoOpenSession(CashierName);
    Mode := ReadECRMode;
  end;

  // 0 — готов; 2 — смена открыта < 24 ч
  if (Mode = 0) or (Mode = 2) then
    Exit;

  raise Exception.Create(MessageForBlockedECRMode(Mode));
end;

procedure TVariantPrint.EnsureReadyForXReport;
var
  Mode: Integer;
begin
  // X-отчёт: смена должна быть открыта; режим 3 (>24 ч) допустим; смену не открываем
  ClearStuckOpenDocument('XReport');

  if FEmulation then
    Exit;
  if not FRObjectReady then
    Exit;

  Mode := ReadECRMode;
  if (Mode = 2) or (Mode = 3) then
    Exit;
  if Mode = 4 then
    raise Exception.Create('Смена закрыта. Откройте смену и повторите X-отчёт.');
  raise Exception.Create(MessageForBlockedECRMode(Mode));
end;

procedure TVariantPrint.EnsureReadyForZReport;
var
  Mode: Integer;
begin
  // Z-отчёт: режимы 2 и 3 допустимы (3 — как раз повод закрыть смену); смену не открываем
  ClearStuckOpenDocument('ZReport');

  if FEmulation then
    Exit;
  if not FRObjectReady then
    Exit;

  Mode := ReadECRMode;
  if (Mode = 2) or (Mode = 3) then
    Exit;
  if Mode = 4 then
    raise Exception.Create('Смена уже закрыта.');
  raise Exception.Create(MessageForBlockedECRMode(Mode));
end;

function TVariantPrint.CheckSingleMark(const MarkDecoded: string;
  ReturnCheck: Boolean): TJSONObject;
var
  ResCheck: Integer;
  Accepted: Boolean;
  Desc: string;
  Warning: string;
  Cached: TMarkCacheEntry;
  CheckItemLocalResultVal: Integer;
  CheckItemLocalErrorVal: Integer;
  MarkingType2Val: Integer;
  KMServerErrorCodeVal: Integer;
  KMServerCheckingStatusVal: Integer;
  KmChecked: Boolean;
  KpPositive: Boolean;
  OismReceived: Boolean;
  Autonomous: Boolean;
begin
  if TryGetMarkFromCache(MarkDecoded, ReturnCheck, Cached) and Cached.KktAccepted then
  begin
    FLog.LogInfo('check-marks: марка из кэша — skip FNCheckItemBarcode, ' +
      MarkForLog(MarkDecoded) + ', desc=' + Cached.KktDescription);
    Result := MarkObjFromCacheEntry(Cached);
    Exit;
  end;

  Result := TJSONObject.Create;
  Warning := '';

  FLog.LogInfo('FNCheckItemBarcode begin: ' + MarkForLog(MarkDecoded));
  RunFR('FNCheckItemBarcode', procedure
  begin
    if ReturnCheck then
      ovObject.ItemStatus := 3
    else
      ovObject.ItemStatus := 1;
    ovObject.CheckItemMode := 0;
    ovObject.TLVDataHEX := '';
    ovObject.BarCode := MarkDecoded;
    ovObject.FNCheckItemBarcode;
  end);

  if FEmulation then
  begin
    // Sentinel для smoke этапа 4: марка с префиксом FAIL_MARK → accepted=false, чек не печатается
    if Pos('FAIL_MARK', MarkDecoded) = 1 then
    begin
      Result.AddPair('accepted', TJSONBool.Create(False));
      Result.AddPair('resultCode', TJSONNumber.Create(401));
      Result.AddPair('checkItemLocalResult', TJSONNumber.Create(0));
      Result.AddPair('checkItemLocalError', TJSONNumber.Create(1));
      Result.AddPair('markingType2', TJSONNumber.Create(0));
      Result.AddPair('kmServerErrorCode', TJSONNumber.Create(0));
      Result.AddPair('kmServerCheckingStatus', TJSONNumber.Create(0));
      Result.AddPair('description', 'Отказ ККТ (emulation FAIL_MARK)');
      UpsertMarkCacheKkt(MarkDecoded, ReturnCheck, False, 401, 'Отказ ККТ (emulation FAIL_MARK)');
      Exit;
    end;
    Result.AddPair('accepted', TJSONBool.Create(True));
    Result.AddPair('resultCode', TJSONNumber.Create(0));
    Result.AddPair('checkItemLocalResult', TJSONNumber.Create(15));
    Result.AddPair('checkItemLocalError', TJSONNumber.Create(0));
    Result.AddPair('markingType2', TJSONNumber.Create(0));
    Result.AddPair('kmServerErrorCode', TJSONNumber.Create(0));
    Result.AddPair('kmServerCheckingStatus', TJSONNumber.Create(15));
    Result.AddPair('description', 'OK (emulation)');
    UpsertMarkCacheKkt(MarkDecoded, ReturnCheck, True, 0, 'OK (emulation)');
    Exit;
  end;

  if not FRObjectReady then
  begin
    LogFRSkipped('FNCheckItemBarcode');
    Exit;
  end;

  CheckItemLocalResultVal := 0;
  CheckItemLocalErrorVal := 0;
  MarkingType2Val := 0;
  KMServerErrorCodeVal := 0;
  KMServerCheckingStatusVal := 0;
  ResCheck := 0;
  Desc := '';
  ExecOnFrThread(procedure
  begin
    try CheckItemLocalResultVal := ovObject.CheckItemLocalResult; except end;
    try CheckItemLocalErrorVal := ovObject.CheckItemLocalError; except end;
    try MarkingType2Val := ovObject.MarkingType2; except end;
    try KMServerErrorCodeVal := ovObject.KMServerErrorCode; except end;
    try KMServerCheckingStatusVal := ovObject.KMServerCheckingStatus; except end;
    try ResCheck := ovObject.ResultCode; except end;
    Desc := FRResultText(ovObject);
  end);

  Result.AddPair('checkItemLocalResult', TJSONNumber.Create(CheckItemLocalResultVal));
  FLog.LogInfo('CheckItemLocalResult=' + IntToStr(CheckItemLocalResultVal));
  Result.AddPair('checkItemLocalError', TJSONNumber.Create(CheckItemLocalErrorVal));
  FLog.LogInfo('CheckItemLocalError=' + IntToStr(CheckItemLocalErrorVal));
  Result.AddPair('markingType2', TJSONNumber.Create(MarkingType2Val));
  FLog.LogInfo('MarkingType2=' + IntToStr(MarkingType2Val));
  Result.AddPair('kmServerErrorCode', TJSONNumber.Create(KMServerErrorCodeVal));
  FLog.LogInfo('KMServerErrorCode=' + IntToStr(KMServerErrorCodeVal));
  Result.AddPair('kmServerCheckingStatus', TJSONNumber.Create(KMServerCheckingStatusVal));
  FLog.LogInfo('KMServerCheckingStatus=' + IntToStr(KMServerCheckingStatusVal));

  // Тег 2106 (KMServerCheckingStatus), биты:
  // 0=проверен, 1=КП КМ+, 2=статус ОИСМ получен, 4=автономный режим.
  // Нет связи / нет ответа ОИСМ: биты 2–3 = 0; продажу не блокируем (предупреждение).
  // Отказ: явная ошибка сервера КМ (1..5) или КМ проверен и КП отрицательный.
  KmChecked := (KMServerCheckingStatusVal and 1) <> 0;
  KpPositive := (KMServerCheckingStatusVal and 2) <> 0;
  OismReceived := (KMServerCheckingStatusVal and 4) <> 0;
  Autonomous := (KMServerCheckingStatusVal and 16) <> 0;

  if ResCheck <> 0 then
  begin
    Accepted := False;
    FLog.LogError(Format('Отказ марки: ResultCode=%d %s | %s',
      [ResCheck, Desc, MarkForLog(MarkDecoded)]));
    RunFR('FNDeclineMarkingCode', procedure
    begin
      ovObject.FNDeclineMarkingCode;
      FLog.LogDebug('[FR] FNDeclineMarkingCode: ' + FRResultText(ovObject));
    end);
  end
  else if (KMServerErrorCodeVal >= 1) and (KMServerErrorCodeVal <= 5) then
  begin
    Accepted := False;
    Desc := Format('%s (KMServerErrorCode=%d, KMServerCheckingStatus=%d)',
      [KmServerErrorCodeText(KMServerErrorCodeVal), KMServerErrorCodeVal,
       KMServerCheckingStatusVal]);
    FLog.LogError('Отказ марки: ' + Desc + ' | ' + MarkForLog(MarkDecoded));
    RunFR('FNDeclineMarkingCode', procedure
    begin
      ovObject.FNDeclineMarkingCode;
      FLog.LogDebug('[FR] FNDeclineMarkingCode: ' + FRResultText(ovObject));
    end);
  end
  else if KmChecked and not KpPositive then
  begin
    Accepted := False;
    Desc := Format(
      'КП КМ отрицательный (KMServerCheckingStatus=%d) — на чеке будет M-',
      [KMServerCheckingStatusVal]);
    FLog.LogError('Отказ марки: ' + Desc + ' | ' + MarkForLog(MarkDecoded));
    RunFR('FNDeclineMarkingCode', procedure
    begin
      ovObject.FNDeclineMarkingCode;
      FLog.LogDebug('[FR] FNDeclineMarkingCode: ' + FRResultText(ovObject));
    end);
  end
  else
  begin
    Accepted := True;
    RunFR('FNAcceptMarkingCode', procedure
    begin
      ovObject.FNAcceptMarkingCode;
      FLog.LogDebug('[FR] FNAcceptMarkingCode: ' + FRResultText(ovObject));
    end);
    FLog.LogInfo('Марка принята ККТ: ' + MarkForLog(MarkDecoded));

    if not KmChecked then
      Warning := Format(
        'КМ не проверен ФН/ОИСМ (KMServerCheckingStatus=%d); продажа разрешена, на чеке возможно [M]',
        [KMServerCheckingStatusVal])
    else if (not OismReceived) or Autonomous then
      Warning := Format(
        'Статус ОИСМ не получен / автономный режим (KMServerCheckingStatus=%d); продажа разрешена, на чеке возможно [M]',
        [KMServerCheckingStatusVal]);

    if Warning <> '' then
    begin
      FLog.LogInfo('предупреждение: ' + Warning + ' | ' + MarkForLog(MarkDecoded));
      if (Desc = '') or SameText(Trim(Desc), 'OK') or SameText(Trim(Desc), 'Ошибок нет') then
        Desc := Warning
      else
        Desc := Desc + '. ' + Warning;
    end;
  end;

  Result.AddPair('resultCode', TJSONNumber.Create(ResCheck));
  Result.AddPair('description', Desc);
  Result.AddPair('accepted', TJSONBool.Create(Accepted));
  if Warning <> '' then
    Result.AddPair('warning', Warning);
  UpsertMarkCacheKkt(MarkDecoded, ReturnCheck, Accepted, ResCheck, Desc);
end;

procedure TVariantPrint.ReadInnAndFn(out Inn, FnNumber: string);
var
  LocalInn, LocalFn: string;
begin
  Inn := '';
  FnNumber := '';
  if FEmulation then
  begin
    Inn := FEmulatedInn;
    FnNumber := FEmulatedFnNumber;
    Exit;
  end;
  if not FRObjectReady then
    Exit;

  LocalInn := '';
  LocalFn := '';

  RunFR('FNGetFiscalizationResult permission', procedure
  begin
    ovObject.FNGetFiscalizationResult;
    try
      LocalInn := VarToStr(ovObject.INN);
    except
    end;
  end);

  RunFR('FNGetSerial permission', procedure
  begin
    ovObject.FNGetSerial;
    try
      LocalFn := VarToStr(ovObject.SerialNumber);
    except
    end;
    try
      if LocalFn = '' then
        LocalFn := VarToStr(ovObject.FiscalStorageNumber);
    except
    end;
  end);

  Inn := LocalInn;
  FnNumber := LocalFn;
end;

function TVariantPrint.ResolvePermissionInn(Req: TJSONObject): string;
var
  Fn: string;
begin
  Result := JStr(Req, 'inn', '');
  if Result = '' then
    Result := JStr(Req, 'ИНН', '');
  if Result = '' then
    ReadInnAndFn(Result, Fn);
end;

function TVariantPrint.ResolvePermissionFn(Req: TJSONObject): string;
var
  Inn: string;
begin
  Result := JStr(Req, 'fnNumber', '');
  if Result = '' then
    Result := JStr(Req, 'fn', '');
  if Result = '' then
    Result := JStr(Req, 'ФН', '');
  if Result = '' then
    ReadInnAndFn(Inn, Result);
end;

function TVariantPrint.BuildDocumentCheckJson(const MarkB64, Inn, Fn: string): string;
var
  Root, Pos, Org: TJSONObject;
  PositionsArr, CodesArr: TJSONArray;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('action', 'check');
    Root.AddPair('type', 'receipt');
    if Trim(Fn) <> '' then
      Root.AddPair('shift', Fn);

    PositionsArr := TJSONArray.Create;
    Pos := TJSONObject.Create;
    Org := TJSONObject.Create;
    Org.AddPair('inn', Inn);
    // fmu-api читает ИНН только из "organisation" (через s). С "organization" ИНН теряется,
    // организация не определяется и проверка не уходит в ТС ПиОТ.
    Pos.AddPair('organisation', Org);

    CodesArr := TJSONArray.Create;
    CodesArr.AddElement(TJSONString.Create(MarkB64));
    Pos.AddPair('marking_codes', CodesArr);

    PositionsArr.AddElement(Pos);
    Root.AddPair('positions', PositionsArr);
    Result := JsonToPlainText(Root);
  finally
    Root.Free;
  end;
end;

function TVariantPrint.HttpPostJson(const Url, Body: string): string;
var
  Http: TIdHTTP;
  ReqStream: TStringStream;
begin
  Http := TIdHTTP.Create(nil);
  ReqStream := TStringStream.Create(Body, TEncoding.UTF8);
  try
    Http.Request.ContentType := 'application/json';
    Http.ConnectTimeout := 30000;
    Http.ReadTimeout := 180000;
    Result := Http.Post(Url, ReqStream);
  finally
    ReqStream.Free;
    Http.Free;
  end;
end;

function TVariantPrint.ExtractFirstTruemarkCode(Truemark: TJSONObject): TJSONObject;
var
  CodesV: TJSONValue;
  Arr: TJSONArray;
begin
  Result := nil;
  if Truemark = nil then
    Exit;
  CodesV := Truemark.GetValue('codes');
  if CodesV is TJSONArray then
  begin
    Arr := TJSONArray(CodesV);
    if (Arr.Count > 0) and (Arr.Items[0] is TJSONObject) then
      Result := TJSONObject(Arr.Items[0]);
  end;
end;

procedure TVariantPrint.AddTruemarkFields(PermObj, Truemark: TJSONObject);
const
  FieldNames: array[0..8] of string = (
    'valid', 'verified', 'found', 'realizable', 'utilised',
    'isBlocked', 'sold', 'isOwner', 'grayZone');
var
  TruemarkOut, CodeObj: TJSONObject;
  I: Integer;
  Val: string;
begin
  if PermObj = nil then
    Exit;

  CodeObj := ExtractFirstTruemarkCode(Truemark);
  if (CodeObj = nil) and (Truemark = nil) then
    Exit;

  TruemarkOut := TJSONObject.Create;
  try
    for I := Low(FieldNames) to High(FieldNames) do
    begin
      Val := '';
      if CodeObj <> nil then
        Val := JStr(CodeObj, FieldNames[I], '');
      if (Val = '') and (Truemark <> nil) then
        Val := JStr(Truemark, FieldNames[I], '');
      if Val <> '' then
        TruemarkOut.AddPair(FieldNames[I], Val);
    end;

    if CodeObj <> nil then
    begin
      Val := JStr(CodeObj, 'message', '');
      if Val <> '' then
        TruemarkOut.AddPair('message', Val);
      Val := JStr(CodeObj, 'errorCode', '');
      if Val <> '' then
        TruemarkOut.AddPair('errorCode', Val);
      Val := JStr(CodeObj, 'cis', '');
      if Val <> '' then
        TruemarkOut.AddPair('cis', Val);
      Val := JStr(CodeObj, 'gtin', '');
      if Val <> '' then
        TruemarkOut.AddPair('gtin', Val);
    end;

    if Truemark <> nil then
    begin
      Val := JStr(Truemark, 'description', '');
      if Val <> '' then
        TruemarkOut.AddPair('description', Val);
      Val := JStr(Truemark, 'code', '');
      if Val <> '' then
        TruemarkOut.AddPair('truemarkCode', Val);
    end;

    if TruemarkOut.Count > 0 then
      PermObj.AddPair('truemark', TruemarkOut)
    else
      TruemarkOut.Free;
  except
    TruemarkOut.Free;
    raise;
  end;
end;

function TVariantPrint.ParsePermissionCheckResponse(const ResponseBody: string): TJSONObject;
var
  V, TruemarkV: TJSONValue;
  Root, Truemark: TJSONObject;
  CodeStr, Err, Uuid, TimeStr, Inst, Version: string;
  Accepted: Boolean;
begin
  Result := TJSONObject.Create;

  V := TJSONObject.ParseJSONValue(ResponseBody);
  if not (V is TJSONObject) then
  begin
    if V <> nil then
      V.Free;
    Result.AddPair('accepted', TJSONBool.Create(False));
    Result.AddPair('code', '-1');
    Result.AddPair('error', 'Некорректный JSON ответа FMU');
    Exit;
  end;

  Root := TJSONObject(V);
  try
    CodeStr := JStr(Root, 'Code', '');
    if CodeStr = '' then
      CodeStr := JStr(Root, 'code', '');
    Accepted := (CodeStr = '0') or SameText(CodeStr, '0.0');

    Err := JStr(Root, 'Error', '');
    if Err = '' then
      Err := JStr(Root, 'error', '');

    Uuid := '';
    TimeStr := '';
    Inst:= '';
    Version:='';
    TruemarkV := Root.GetValue('Truemark_response');
    if TruemarkV = nil then
      TruemarkV := Root.GetValue('truemark_response');
    if TruemarkV is TJSONObject then
    begin
      Truemark := TJSONObject(TruemarkV);
      Uuid := JStr(Truemark, 'reqId', '');
      TimeStr := JStr(Truemark, 'reqTimestamp', '');
      Inst := JStr(Truemark, 'inst', '');
      Version := JStr(Truemark, 'version', '');
      AddTruemarkFields(Result, Truemark);
    end
    else
    begin
      Uuid := JStr(Root, 'reqId', '');
      TimeStr := JStr(Root, 'reqTimestamp', '');
      Inst := JStr(Root, 'inst', '');
      Version := JStr(Root, 'version', '');
    end;

    Result.AddPair('accepted', TJSONBool.Create(Accepted));
    Result.AddPair('code', CodeStr);
    Result.AddPair('error', Err);
    Result.AddPair('uuid', Uuid);
    Result.AddPair('time', TimeStr);
    Result.AddPair('inst', Inst);
    Result.AddPair('version', Version);
  finally
    Root.Free;
  end;
end;

function TVariantPrint.CheckSingleMarkPermission(const MarkB64, Inn, Fn: string): TJSONObject;
var
  Url, ReqJson, RespBody: string;
begin
  // Emulation влияет только на ККТ/ФР; РР всегда идёт на реальный FMU /document
  if FEmulation then
    FLog.LogInfo('РР: Emulation=true — фейковый ответ отключён, POST /document как обычно');

  if Trim(Inn) = '' then
    raise Exception.Create('ИНН не задан для проверки разрешительного режима');

  ReqJson := BuildDocumentCheckJson(MarkB64, Inn, Fn);
  Url := Format('http://%s:%d%s', [PERMISSION_FMU_HOST, PERMISSION_FMU_PORT, PERMISSION_FMU_PATH]);
  FLog.LogInfo('POST /document (РР): ' + Url);

  try
    RespBody := HttpPostJson(Url, ReqJson);
  except
    on E: Exception do
    begin
      FLog.LogError('POST /document (РР): ' + E.Message);
      Result := TJSONObject.Create;
      Result.AddPair('accepted', TJSONBool.Create(False));
      Result.AddPair('code', '-1');
      Result.AddPair('error', E.Message);
      Result.AddPair('uuid', '');
      Result.AddPair('time', '');
      Result.AddPair('inst', '');
      Result.AddPair('version', '');
      Exit;
    end;
  end;

  FLog.LogInfo('POST /document (РР) ответ: ' + JsonBodyPreviewPlain(RespBody, 500));
  Result := ParsePermissionCheckResponse(RespBody);
end;

function TVariantPrint.CheckMarkInternal(const Body: string): string;
var
  V: TJSONValue;
  Req: TJSONObject;
  MarksB64: TArray<string>;
  MarksOut: TJSONArray;
  Root: TJSONObject;
  MarkObj, PermObj: TJSONObject;
  ReturnCheck: Boolean;
  CheckPermission: Boolean;
  CashierName, PermissionInn, PermissionFn: string;
  I: Integer;
  MarkDecoded: string;
  AllAccepted, AllPermissionAccepted, PermAccepted, Accepted: Boolean;
  Cached: TMarkCacheEntry;
begin
  V := TJSONObject.ParseJSONValue(Body);
  if not (V is TJSONObject) then
  begin
    if V <> nil then
      V.Free;
    FLog.LogError(Format('CheckMarkInternal: Invalid JSON, bodyLen=%d, head=%s',
      [Length(Body), JsonBodyPreview(Body)]));
    raise Exception.Create(Format('Invalid JSON, bodyLen=%d', [Length(Body)]));
  end;
  Req := TJSONObject(V);

  try
    FLog.LogInfo('CheckMarkInternal begin');
    EnsureFRConnected;

    CollectMarksFromRequest(Req, MarksB64);
    ReturnCheck := GetReceiptReturnCheck(Req);
    CheckPermission := JBool(Req, 'checkPermission', False);
    CashierName := JStr(Req, 'cashierName');

    if CheckPermission and not ReturnCheck then
    begin
      PermissionInn := ResolvePermissionInn(Req);
      PermissionFn := ResolvePermissionFn(Req);
    end;

    EnsureSessionOpen(CashierName);

    MarksOut := TJSONArray.Create;
    Root := TJSONObject.Create;
    try
      AllAccepted := True;
      AllPermissionAccepted := True;
      for I := 0 to High(MarksB64) do
      begin
        MarkDecoded := DecodeMarkBase64(MarksB64[I]);
        FLog.LogInfo(Format('Проверка марки [%d/%d]: %s',
          [I + 1, Length(MarksB64), MarkForLog(MarkDecoded)]));

        if IsMarkFullyOk(MarkDecoded, ReturnCheck, CheckPermission) then
        begin
          TryGetMarkFromCache(MarkDecoded, ReturnCheck, Cached);
          FLog.LogInfo(Format('Марка [%d/%d] полностью из кэша (ККТ+РР) — skip',
            [I + 1, Length(MarksB64)]));
          MarkObj := MarkObjFromCacheEntry(Cached);
          try
            if CheckPermission and not ReturnCheck and Cached.RrChecked then
              MarkObj.AddPair('permission', PermissionObjFromCacheEntry(Cached));
            MarkObj.AddPair('index', TJSONNumber.Create(I));
            if not Cached.KktAccepted then
              AllAccepted := False;
            if CheckPermission and not ReturnCheck and not Cached.RrAccepted then
              AllPermissionAccepted := False;
            MarksOut.AddElement(MarkObj);
            MarkObj := nil;
          finally
            MarkObj.Free;
          end;
          Continue;
        end;

        MarkObj := CheckSingleMark(MarkDecoded, ReturnCheck);
        try
          if CheckPermission and not ReturnCheck then
          begin
            // Retry a rejected permission check: subscription/network state may have changed.
          if TryGetMarkFromCache(MarkDecoded, ReturnCheck, Cached) and Cached.RrChecked and Cached.RrAccepted then
            begin
              FLog.LogInfo(Format('РР [%d/%d] из кэша — skip POST /document',
                [I + 1, Length(MarksB64)]));
              PermObj := PermissionObjFromCacheEntry(Cached);
            end
            else
            begin
              FLog.LogInfo(Format('Проверка РР [%d/%d]', [I + 1, Length(MarksB64)]));
              PermObj := CheckSingleMarkPermission(MarksB64[I], PermissionInn, PermissionFn);
            end;
            try
              MarkObj.AddPair('permission', PermObj);
              PermObj := nil;
              PermAccepted := False;
              if MarkObj.GetValue('permission') is TJSONObject then
              begin
                if TJSONObject(MarkObj.GetValue('permission')).GetValue('accepted') is TJSONBool then
                  PermAccepted := TJSONBool(TJSONObject(MarkObj.GetValue('permission')).GetValue('accepted')).AsBoolean;
              end;
              if not PermAccepted then
                AllPermissionAccepted := False;
            finally
              PermObj.Free;
            end;
          end;

          UpdateMarkCacheFromMarkObj(MarkDecoded, ReturnCheck, MarkObj);

          MarkObj.AddPair('index', TJSONNumber.Create(I));
          Accepted := False;
          if MarkObj.GetValue('accepted') is TJSONBool then
            Accepted := TJSONBool(MarkObj.GetValue('accepted')).AsBoolean;
          if not Accepted then
            AllAccepted := False;
          MarksOut.AddElement(MarkObj);
          MarkObj := nil;
        finally
          MarkObj.Free;
        end;
      end;

      Root.AddPair('result', TJSONNumber.Create(1));
      Root.AddPair('description', 'OK');
      Root.AddPair('marks', MarksOut);
      MarksOut := nil;
      Root.AddPair('allAccepted', TJSONBool.Create(AllAccepted));
      if CheckPermission and not ReturnCheck then
        Root.AddPair('allPermissionAccepted', TJSONBool.Create(AllPermissionAccepted));
      Result := JsonToPlainText(Root);
      if CheckPermission and not ReturnCheck then
        FLog.LogInfo('CheckMarkInternal OK allAccepted=' + BoolToStr(AllAccepted, True) +
          ', allPermissionAccepted=' + BoolToStr(AllPermissionAccepted, True))
      else
        FLog.LogInfo('CheckMarkInternal OK allAccepted=' + BoolToStr(AllAccepted, True));
      AfterCommand(Req);
    finally
      MarksOut.Free;
      Root.Free;
    end;
  except
    on E: Exception do
    begin
      FLog.LogError('CheckMarkInternal: ' + E.Message);
      if FEmulation then
      begin
        Result := JsonOk('"allAccepted":true,"marks":[{"index":0,"accepted":true,' +
          '"resultCode":0,"checkItemLocalResult":15,"checkItemLocalError":0,' +
          '"markingType2":0,"kmServerErrorCode":0,"kmServerCheckingStatus":15,' +
          '"description":"OK (emulation)"}]');
        AfterCommand(Req);
      end
      else
        Result := JsonError(E.Message);
    end;
  end;

  V.Free;
end;

procedure TVariantPrint.StartAsyncCheckMark(const Body, TaskId: string);
var
  Entry: TCheckMarkTaskEntry;
begin
  Entry := TCheckMarkTaskEntry.Create;
  Entry.Status := 'pending';
  Entry.CreatedAt := Now;

  FMarkTasksLock.Enter;
  try
    TrimOldMarkTasks;
    FMarkTasks.Add(TaskId, Entry);
  finally
    FMarkTasksLock.Leave;
  end;

  FLog.LogInfo('async check-marks: задача принята taskId=' + TaskId);

  TThread.CreateAnonymousThread(
    procedure
    var
      JsonResult: string;
      TaskEntry: TCheckMarkTaskEntry;
      Ok: Boolean;
    begin
      FLock.Enter;
      try
        try
          // CheckMarkInternal уже пишет полный marks[] (в т.ч. permission) в FMarkCache
          JsonResult := CheckMarkInternal(Body);
        except
          on E: Exception do
            JsonResult := JsonError(E.Message);
        end;
      finally
        FLock.Leave;
      end;

      Ok := (Pos('"result":1', JsonResult) > 0) or (Pos('"result": 1', JsonResult) > 0);

      FMarkTasksLock.Enter;
      try
        if FMarkTasks.TryGetValue(TaskId, TaskEntry) then
        begin
          if Ok then
            TaskEntry.Status := 'completed'
          else
            TaskEntry.Status := 'error';
          TaskEntry.ResultJson := JsonResult;
        end;
      finally
        FMarkTasksLock.Leave;
      end;

      if Ok then
        FLog.LogInfo('async check-marks: completed taskId=' + TaskId +
          ' — FMarkCache обновлён (через CheckMarkInternal)')
      else
        FLog.LogError('async check-marks: error taskId=' + TaskId + ' ' +
          JsonBodyPreviewPlain(JsonResult, 200));
    end).Start;
end;

function TVariantPrint.CheckMarkJson(const Body: string): string;
var
  V: TJSONValue;
  Req: TJSONObject;
  TaskId: string;
begin
  V := TJSONObject.ParseJSONValue(Body);
  try
    if not (V is TJSONObject) then
    begin
      FLog.LogError(Format('CheckMarkJson: Invalid JSON, bodyLen=%d, head=%s',
        [Length(Body), JsonBodyPreview(Body)]));
      raise Exception.Create(Format('Invalid JSON, bodyLen=%d', [Length(Body)]));
    end;
    Req := TJSONObject(V);

    if JBool(Req, 'async', False) then
    begin
      TaskId := NewTaskId;
      StartAsyncCheckMark(Body, TaskId);
      Result := JsonOk('"async":true,"taskId":"' + JsonEscape(TaskId) +
        '","status":"pending"');
      Exit;
    end;

    FLock.Enter;
    try
      Result := CheckMarkInternal(Body);
    finally
      FLock.Leave;
    end;
  finally
    V.Free;
  end;
end;

function TVariantPrint.CheckMarkStatusJson(const TaskId: string): string;
var
  Entry: TCheckMarkTaskEntry;
  Root: TJSONObject;
  Parsed: TJSONValue;
begin
  if Trim(TaskId) = '' then
    Exit(JsonError('taskId is required'));

  FMarkTasksLock.Enter;
  try
    if not FMarkTasks.TryGetValue(TaskId, Entry) then
      Exit(JsonError('task not found'));

    if Entry.Status = 'pending' then
      Exit(JsonOk('"taskId":"' + JsonEscape(TaskId) + '","status":"pending"'));

    Parsed := TJSONObject.ParseJSONValue(Entry.ResultJson);
    if not (Parsed is TJSONObject) then
      Exit(JsonError('invalid task result'));

    Root := TJSONObject(Parsed);
    try
      Root.AddPair('taskId', TaskId);
      Root.AddPair('status', Entry.Status);
      Result := JsonToPlainText(Root);
    finally
      Root.Free;
    end;
  finally
    FMarkTasksLock.Leave;
  end;
end;

end.
