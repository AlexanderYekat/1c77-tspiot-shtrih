unit uVariantPrint;

interface

uses
  System.SysUtils, System.Variants, System.JSON, System.IniFiles,
  System.SyncObjs, System.NetEncoding, System.Generics.Collections,
  System.Classes, System.DateUtils, ComObj, uKktLog;

type
  TCheckMarkTaskEntry = class
    Status: string;
    ResultJson: string;
    CreatedAt: TDateTime;
  end;

  TVariantPrint = class
  private
    ovObject: OleVariant;      // COM-объект драйвера ККТ (AddIn.DrvFR) — держим один на всё время
    FSettings: TCustomIniFile;
    FLog: TKktLogger;
    FLock: TCriticalSection;   // защита от параллельных обращений к ККТ
    FMarkTasksLock: TCriticalSection;
    FMarkTasks: TObjectDictionary<string, TCheckMarkTaskEntry>;
    FAcceptedMarks: TDictionary<string, Byte>; // принятые марки в рамках текущего чека
    FConnected: Boolean;       // текущее состояние соединения, как мы его понимаем
    FEmulation: Boolean;

    FEmulatedSerial: string;
    FEmulatedInn: string;
    FEmulatedFnNumber: string;
    FEmulatedCheckNumber: Integer;
    FEmulatedSessionNumber: Integer;

    function EnsureFRConnected: Boolean;
    procedure DoDisconnect;
    function CheckLinkAlive: Boolean;
    procedure CheckFRResult(const Place: string);
    function ReadSerialNumber: string;
    function ReadCheckNumberAfterClose: Integer;
    function ReadSessionNumberAfterClose: Integer;
    function FRObjectReady: Boolean;
    procedure LogFRSkipped(const Place: string);

    procedure SendIndustryRequisite126x(const Tag1262, Tag1263, Tag1264, UUID,
      TimeStr: string);
    procedure SendMarkingCodeAfterFNOperation(const MarkKkt: string);
    procedure ProcessMarkingAfterFNOperation(const MarkDecoded: string;
      MarkAccepted, ReturnCheck: Boolean);
    procedure RegisterReceiptItem(Item: TJSONObject; ReturnCheck: Boolean;
      DefaultDepartment: Integer);
    procedure PrintReceiptText(const Text: string);
    procedure ApplyReceiptHeader(Req: TJSONObject; ReturnCheck: Boolean);
    procedure CloseReceiptFromJson(Req: TJSONObject);

    procedure AfterCommand(Req: TJSONObject);

    function DecodeMarkBase64(const B64: string): string;
    function GetReceiptReturnCheck(Req: TJSONObject): Boolean;
    function GetCashierName(Req: TJSONObject): string;
    procedure EnsureSessionOpen(const CashierName: string);
    function CheckSingleMark(const MarkDecoded: string; ReturnCheck: Boolean): TJSONObject;
    function CheckMarkInternal(const Body: string): string;
    procedure TrimOldMarkTasks;
    procedure StartAsyncCheckMark(const Body, TaskId: string);
    function NewTaskId: string;
    procedure CollectMarksFromRequest(Req: TJSONObject; out MarksB64: TArray<string>);

    function MarkCacheKey(const MarkDecoded: string; ReturnCheck: Boolean): string;
    function IsMarkAcceptedInCache(const MarkDecoded: string; ReturnCheck: Boolean): Boolean;
    procedure AddMarkToAcceptedCache(const MarkDecoded: string; ReturnCheck: Boolean);
    procedure ClearAcceptedMarksCache;
  public
    constructor Create(ASettings: TCustomIniFile);
    destructor Destroy; override;

    function KktInfoJson: string;
    function PrintCheckJson(const Body: string): string;
    function CloseShiftJson(const Body: string): string;
    function XReportJson(const Body: string = ''): string;
    function CancelCheckJson(const Body: string = ''): string;
    function DisconnectJson: string;
    function CheckMarkJson(const Body: string): string;
    function CheckMarkStatusJson(const TaskId: string): string;

    property Logger: TKktLogger read FLog;
    property Emulation: Boolean read FEmulation;
  end;

implementation

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
  FAcceptedMarks := TDictionary<string, Byte>.Create;
  FLog := TKktLogger.Create(ASettings, ChangeFileExt(ParamStr(0), '.log'));
  ovObject := Unassigned;
  FConnected := False;

  FEmulation := FSettings.ReadBool('KKT', 'Emulation', False);
  FEmulatedSerial := FSettings.ReadString('KKT', 'EmulatedSerial', '0000000000000001');
  FEmulatedInn := FSettings.ReadString('KKT', 'EmulatedInn', '1234567890');
  FEmulatedFnNumber := FSettings.ReadString('KKT', 'EmulatedFnNumber', '9999078900000001');
  FEmulatedCheckNumber := FSettings.ReadInteger('KKT', 'EmulatedCheckNumber', 0);
  FEmulatedSessionNumber := FSettings.ReadInteger('KKT', 'EmulatedSessionNumber', 0);

  if FEmulation then
    FLog.LogInfo('Режим эмуляции ККТ включён — команды ovObject выполняются, ошибки логируются, ответ API = OK')
  else
    FLog.LogInfo('Боевой режим ККТ');
end;

destructor TVariantPrint.Destroy;
begin
  FLock.Enter;
  try
    DoDisconnect;
  finally
    FLock.Leave;
    FLock.Free;
  end;
  FMarkTasksLock.Enter;
  try
    FMarkTasks.Free;
  finally
    FMarkTasksLock.Leave;
    FMarkTasksLock.Free;
  end;
  FAcceptedMarks.Free;
  FLog.Free;
  inherited;
end;

procedure TVariantPrint.CheckFRResult(const Place: string);
var
  Code: Integer;
  Desc: string;
begin
  Code := 0;
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
      raise Exception.Create(Place + ': ' + IntToStr(Code) + ' ' + Desc);
  end
  else
    FLog.LogDebug('[FR] ' + Place + ': OK');
end;

function TVariantPrint.ReadSerialNumber: string;
begin
  Result := FEmulatedSerial;
  if VarIsEmpty(ovObject) or VarIsNull(ovObject) then
    Exit;

  try
    Result := VarToStr(ovObject.SerialNumber);
    if Result = '' then
      Result := FEmulatedSerial;
  except
    on E: Exception do
    begin
      FLog.LogError('[FR] ReadSerialNumber: ' + E.Message);
      Result := FEmulatedSerial;
    end;
  end;
end;

function TVariantPrint.FRObjectReady: Boolean;
begin
  Result := not (VarIsEmpty(ovObject) or VarIsNull(ovObject));
end;

procedure TVariantPrint.LogFRSkipped(const Place: string);
begin
  FLog.LogError('[FR] ' + Place + ': ovObject недоступен');
  if not FEmulation then
    raise Exception.Create(Place + ': ovObject недоступен');
end;

function TVariantPrint.ReadCheckNumberAfterClose: Integer;
begin
  Result := 0;
  if VarIsEmpty(ovObject) or VarIsNull(ovObject) then
  begin
    if FEmulation then
    begin
      Inc(FEmulatedCheckNumber);
      Result := FEmulatedCheckNumber;
    end;
    Exit;
  end;

  try
    ovObject.GetECRStatus;
    CheckFRResult('GetECRStatus after close');
    Result := ovObject.OpenDocumentNumber;
    try
      if ovObject.ECRAdvancedMode = 5 then
        Inc(Result);
    except
    end;
  except
    on E: Exception do
    begin
      FLog.LogError('[FR] ReadCheckNumberAfterClose: ' + E.Message);
      if not FEmulation then
        raise;
    end;
  end;

  if FEmulation and (Result <= 0) then
  begin
    Inc(FEmulatedCheckNumber);
    Result := FEmulatedCheckNumber;
  end;
end;

function TVariantPrint.ReadSessionNumberAfterClose: Integer;
begin
  Result := 0;
  if VarIsEmpty(ovObject) or VarIsNull(ovObject) then
  begin
    if FEmulation then
    begin
      Inc(FEmulatedSessionNumber);
      Result := FEmulatedSessionNumber;
    end;
    Exit;
  end;

  try
    ovObject.GetECRStatus;
    CheckFRResult('GetECRStatus after close shift');
    Result := ovObject.SessionNumber;
    try
      if ovObject.ECRAdvancedMode = 5 then
        Inc(Result);
    except
    end;
  except
    on E: Exception do
    begin
      FLog.LogError('[FR] ReadSessionNumberAfterClose: ' + E.Message);
      if not FEmulation then
        raise;
    end;
  end;

  if FEmulation and (Result <= 0) then
  begin
    Inc(FEmulatedSessionNumber);
    Result := FEmulatedSessionNumber;
  end;
end;

{-------------------------------------------------------------------------------
 Подключение / переиспользование соединения
-------------------------------------------------------------------------------}

function TVariantPrint.CheckLinkAlive: Boolean;
begin
  Result := False;
  if not FConnected then
    Exit;

  if FEmulation and (VarIsEmpty(ovObject) or VarIsNull(ovObject)) then
  begin
    Result := True;
    Exit;
  end;

  if VarIsEmpty(ovObject) or VarIsNull(ovObject) then
    Exit;

  try
    ovObject.GetECRStatus;
    CheckFRResult('CheckLinkAlive GetECRStatus');
    Result := True;
  except
    on E: Exception do
    begin
      FLog.LogError('[FR] CheckLinkAlive: ' + E.Message);
      if FEmulation then
        Result := True
      else
        Result := False;
    end;
  end;
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
      ovObject := CreateOleObject('AddIn.DrvFR');
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
  ovObject.ComNumber := ComPort;
  ovObject.BaudRate := Baud;
  ovObject.Password := Password;

  FLog.LogInfo(Format('[FR] Connect ComNumber=%d BaudRate=%d', [ComPort, Baud]));

  try
    ovObject.Connect;
    CheckFRResult('Connect');
  except
    on E: Exception do
    begin
      FLog.LogError('[FR] Connect exception: ' + E.Message);
      if FEmulation then
      begin
        FConnected := True;
        Result := True;
        Exit;
      end;
      FConnected := False;
      raise;
    end;
  end;

  FConnected := True;
  Result := True;
end;

procedure TVariantPrint.DoDisconnect;
begin
  if FConnected and not (VarIsEmpty(ovObject) or VarIsNull(ovObject)) then
  begin
    try
      ovObject.Disconnect;
      CheckFRResult('Disconnect');
    except
      on E: Exception do
      begin
        FLog.LogError('[FR] Disconnect: ' + E.Message);
        if not FEmulation then
          raise;
      end;
    end;
  end;
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

{-------------------------------------------------------------------------------
 /info
-------------------------------------------------------------------------------}

function TVariantPrint.KktInfoJson: string;
var
  SerialNumber, Inn, FnNumber: string;
begin
  FLock.Enter;
  try
    try
      EnsureFRConnected;

      SerialNumber := FEmulatedSerial;
      Inn := FEmulatedInn;
      FnNumber := FEmulatedFnNumber;

      if not (VarIsEmpty(ovObject) or VarIsNull(ovObject)) then
      begin
        try
          ovObject.GetECRStatus;
          CheckFRResult('GetECRStatus');
          SerialNumber := ReadSerialNumber;

          try
            ovObject.GetFiscalizationParameters;
            CheckFRResult('GetFiscalizationParameters');
            try Inn := VarToStr(ovObject.INN); except end;
            try FnNumber := VarToStr(ovObject.FNNumber); except end;
            try if FnNumber = '' then FnNumber := VarToStr(ovObject.FiscalStorageNumber); except end;
          except
            on E: Exception do
            begin
              FLog.LogError('[FR] GetFiscalizationParameters: ' + E.Message);
              if not FEmulation then
                raise;
            end;
          end;
        except
          on E: Exception do
          begin
            FLog.LogError('[FR] KktInfoJson GetECRStatus: ' + E.Message);
            if not FEmulation then
              raise;
          end;
        end;
      end;

      if Inn = '' then Inn := FEmulatedInn;
      if FnNumber = '' then FnNumber := FEmulatedFnNumber;

      Result := JsonOk(
        '"serialNumber":"' + JsonEscape(SerialNumber) + '",' +
        '"inn":"' + JsonEscape(Inn) + '",' +
        '"fnNumber":"' + JsonEscape(FnNumber) + '",' +
        '"connected":' + BoolToStr(FConnected, True).ToLower + ',' +
        '"emulation":' + BoolToStr(FEmulation, True).ToLower);
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
  UUID, TimeStr: string);
begin
  if (UUID = '') or (TimeStr = '') then
    Exit;

  if not FRObjectReady then
  begin
    LogFRSkipped('SendIndustryRequisite126x');
    Exit;
  end;

  FLog.LogInfo(Format('Теги РР: 1262=%s 1263=%s 1264=%s 1265 UUID=%s Time=%s',
    [Tag1262, Tag1263, Tag1264, UUID, TimeStr]));

  ovObject.TagNumber := 1262;
  ovObject.TagType := 7;
  ovObject.TagValueStr := Tag1262;
  ovObject.FNSendTagOperation;
  FLog.LogDebug('[FR] 1262: ' + Tag1262 + ' -> ' + FRResultText(ovObject));
  CheckFRResult('FNSendTagOperation 1262');

  ovObject.TagNumber := 1263;
  ovObject.TagType := 7;
  ovObject.TagValueStr := Tag1263;
  ovObject.FNSendTagOperation;
  FLog.LogDebug('[FR] 1263: ' + Tag1263 + ' -> ' + FRResultText(ovObject));
  CheckFRResult('FNSendTagOperation 1263');

  ovObject.TagNumber := 1264;
  ovObject.TagType := 7;
  ovObject.TagValueStr := Tag1264;
  ovObject.FNSendTagOperation;
  FLog.LogDebug('[FR] 1264: ' + Tag1264 + ' -> ' + FRResultText(ovObject));
  CheckFRResult('FNSendTagOperation 1264');

  ovObject.TagNumber := 1265;
  ovObject.TagType := 7;
  ovObject.TagValueStr := 'UUID=' + UUID + '&Time=' + TimeStr;
  ovObject.FNSendTagOperation;
  FLog.LogDebug('[FR] 1265: UUID=' + UUID + '&Time=' + TimeStr + ' -> ' + FRResultText(ovObject));
  CheckFRResult('FNSendTagOperation 1265');
end;

procedure TVariantPrint.SendMarkingCodeAfterFNOperation(const MarkKkt: string);
begin
  if MarkKkt = '' then
    Exit;

  if not FRObjectReady then
  begin
    LogFRSkipped('FNSendItemBarcode');
    Exit;
  end;

  FLog.LogDebug('[FR] FNSendItemBarcode begin: ' + MarkKkt);
  ovObject.BarCode := MarkKkt;
  ovObject.FNSendItemBarcode;
  FLog.LogDebug('[FR] FNSendItemBarcode: ' + FRResultText(ovObject));
  CheckFRResult('FNSendItemBarcode');
end;

function TVariantPrint.MarkCacheKey(const MarkDecoded: string; ReturnCheck: Boolean): string;
begin
  if ReturnCheck then
    Result := 'R|' + MarkDecoded
  else
    Result := 'S|' + MarkDecoded;
end;

function TVariantPrint.IsMarkAcceptedInCache(const MarkDecoded: string;
  ReturnCheck: Boolean): Boolean;
begin
  Result := (MarkDecoded <> '') and FAcceptedMarks.ContainsKey(MarkCacheKey(MarkDecoded, ReturnCheck));
end;

procedure TVariantPrint.AddMarkToAcceptedCache(const MarkDecoded: string;
  ReturnCheck: Boolean);
var
  Key: string;
begin
  if MarkDecoded = '' then
    Exit;
  Key := MarkCacheKey(MarkDecoded, ReturnCheck);
  if not FAcceptedMarks.ContainsKey(Key) then
  begin
    FAcceptedMarks.Add(Key, 1);
    FLog.LogDebug('Кэш марки: добавлена, len=' + IntToStr(Length(MarkDecoded)) +
      ', return=' + BoolToStr(ReturnCheck, True));
  end;
end;

procedure TVariantPrint.ClearAcceptedMarksCache;
begin
  if FAcceptedMarks.Count > 0 then
  begin
    FLog.LogInfo('Сброс кэша принятых марок (' + IntToStr(FAcceptedMarks.Count) + ')');
    FAcceptedMarks.Clear;
  end;
end;

procedure TVariantPrint.ProcessMarkingAfterFNOperation(const MarkDecoded: string;
  MarkAccepted, ReturnCheck: Boolean);
var
  FromCache, EffectiveAccepted: Boolean;
begin
  if MarkDecoded = '' then
    Exit;

  if not FRObjectReady then
  begin
    LogFRSkipped('ProcessMarkingAfterFNOperation');
    Exit;
  end;

  FromCache := IsMarkAcceptedInCache(MarkDecoded, ReturnCheck);
  EffectiveAccepted := MarkAccepted or FromCache;

  if EffectiveAccepted then
  begin
    if FromCache and not MarkAccepted then
      FLog.LogInfo('markAccepted не указан, но марка уже принята в текущем чеке — только FNSendItemBarcode')
    else
      FLog.LogInfo('markAccepted=true — только FNSendItemBarcode');
    SendMarkingCodeAfterFNOperation(MarkDecoded);
    AddMarkToAcceptedCache(MarkDecoded, ReturnCheck);
    Exit;
  end;

  FLog.LogInfo('Полный цикл маркировки в чеке');
  if ReturnCheck then
    ovObject.ItemStatus := 3
  else
    ovObject.ItemStatus := 1;
  ovObject.CheckItemMode := 0;
  ovObject.TLVDataHEX := '';
  ovObject.BarCode := MarkDecoded;

  ovObject.FNCheckItemBarcode;
  CheckFRResult('FNCheckItemBarcode');

  ovObject.BarCode := MarkDecoded;
  ovObject.FNSendItemBarcode;
  CheckFRResult('FNSendItemBarcode (1)');

  ovObject.FNAcceptMarkingCode;
  CheckFRResult('FNAcceptMarkingCode');

  ovObject.BarCode := MarkDecoded;
  ovObject.FNSendItemBarcode;
  CheckFRResult('FNSendItemBarcode (2)');

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
  if not FRObjectReady then
    Exit;

  if ReturnCheck then
    ovObject.CheckType := 2
  else
    ovObject.CheckType := 0;

  TaxTypeVal := MapTaxationType(JStr(Req, 'taxationType'));
  if TaxTypeVal > 0 then
  begin
    try
      ovObject.TaxType := TaxTypeVal;
      FLog.LogInfo('TaxType (СНО)=' + IntToStr(TaxTypeVal));
    except
      on E: Exception do
        FLog.LogInfo('TaxType недоступен: ' + E.Message);
    end;
  end;
end;

procedure TVariantPrint.PrintReceiptText(const Text: string);
begin
  if not FRObjectReady then
  begin
    LogFRSkipped('PrintString');
    Exit;
  end;

  FLog.LogInfo('PrintString: "' + Text + '"');
  try
    ovObject.UseReceiptRibbon := 1;
  except
  end;
  ovObject.StringForPrinting := Text;
  ovObject.PrintString;
  CheckFRResult('PrintString');
end;

procedure TVariantPrint.RegisterReceiptItem(Item: TJSONObject; ReturnCheck: Boolean;
  DefaultDepartment: Integer);
var
  Name, MarkB64, MarkDecoded, UUID, TimeStr, ItemType: string;
  Tag1262, Tag1263, Tag1264: string;
  TaxObj, PermObj: TJSONObject;
  Qty, Price: Double;
  Department, Tax1, PayObj, PayMethod: Integer;
  MarkAccepted, HasMark: Boolean;
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
  Tag1262 := '030';
  Tag1263 := '21.11.2023';
  Tag1264 := '1944';
  if PermObj <> nil then
  begin
    UUID := JStr(PermObj, 'uuid');
    TimeStr := JStr(PermObj, 'time');
    Tag1262 := JStr(PermObj, 'tag1262', Tag1262);
    Tag1263 := JStr(PermObj, 'tag1263', Tag1263);
    Tag1264 := JStr(PermObj, 'tag1264', Tag1264);
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

  if not FRObjectReady then
  begin
    LogFRSkipped('FNOperation "' + Name + '"');
    Exit;
  end;

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
  CheckFRResult('FNOperation');

  if HasMark and (not ReturnCheck) then
  begin
    if (UUID <> '') and (TimeStr <> '') then
      SendIndustryRequisite126x(Tag1262, Tag1263, Tag1264, UUID, TimeStr)
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
  Sum, Total, Received: Double;
  TaxTypeVal: Integer;
begin
  Total := JFloat(Req, 'total', 0);
  Received := JFloat(Req, 'received', Total);

  if not FRObjectReady then
  begin
    LogFRSkipped('FNCloseCheckEx');
    Exit;
  end;

  ovObject.StringForPrinting := '';

  ovObject.Summ1 := 0;  ovObject.Summ2 := 0;  ovObject.Summ3 := 0;  ovObject.Summ4 := 0;
  ovObject.Summ5 := 0;  ovObject.Summ6 := 0;  ovObject.Summ7 := 0;  ovObject.Summ8 := 0;
  ovObject.Summ9 := 0;  ovObject.Summ10 := 0; ovObject.Summ11 := 0; ovObject.Summ12 := 0;
  ovObject.Summ13 := 0; ovObject.Summ14 := 0; ovObject.Summ15 := 0; ovObject.Summ16 := 0;

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
        ovObject.Summ1 := ovObject.Summ1 + Sum
      else if PayType = 'electronically' then
        ovObject.Summ2 := ovObject.Summ2 + Sum
      else if PayType = 'credit' then
        ovObject.Summ15 := ovObject.Summ15 + Sum
      else
        FLog.LogInfo('WARN: неизвестный тип оплаты "' + PayType + '"');
    end;
    FLog.LogInfo(Format('FNCloseCheckEx: payments[] total=%g Summ1=%g Summ2=%g Summ15=%g',
      [Total, ovObject.Summ1, ovObject.Summ2, ovObject.Summ15]));
  end
  else
  begin
    Payment := JInt(Req, 'payment', 0);
    FLog.LogInfo(Format('FNCloseCheckEx: payment=%d total=%g received=%g',
      [Payment, Total, Received]));
    case Payment of
      0: ovObject.Summ1 := Total;
      1: ovObject.Summ2 := Total;
      2: ovObject.Summ15 := Received;
    else
      ovObject.Summ1 := Total;
    end;
  end;

  TaxTypeVal := MapTaxationType(JStr(Req, 'taxationType'));
  if TaxTypeVal > 0 then
  begin
    try
      ovObject.TaxType := TaxTypeVal;
    except
      on E: Exception do
        FLog.LogInfo('TaxType при закрытии недоступен: ' + E.Message);
    end;
  end;

  ovObject.RoundingSumm := 0;
  ovObject.TaxValue1 := 0;
  ovObject.TaxValue2 := 0;
  ovObject.TaxValue3 := 0;
  ovObject.TaxValue4 := 0;
  ovObject.TaxValue5 := 0;
  ovObject.TaxValue6 := 0;

  ovObject.FNCloseCheckEx;
  CheckFRResult('FNCloseCheckEx');
  ClearAcceptedMarksCache;
end;

function TVariantPrint.PrintCheckJson(const Body: string): string;
var
  V: TJSONValue;
  Req, Item: TJSONObject;
  Items: TJSONArray;
  I, CheckNumber: Integer;
  ReturnCheck: Boolean;
  SerialNumber, ItemType, CashierName: string;
  DefaultDept: Integer;
begin
  FLock.Enter;
  try
    Result := JsonError('Unknown error');
    V := nil;
    try
      FLog.LogInfo('PrintCheckJson begin');
      EnsureFRConnected;

      V := TJSONObject.ParseJSONValue(Body);
      if not (V is TJSONObject) then
        raise Exception.Create('Invalid JSON');
      Req := TJSONObject(V);

      ReturnCheck := GetReceiptReturnCheck(Req);
      CashierName := GetCashierName(Req);
      EnsureSessionOpen(CashierName);

      Items := Req.GetValue('items') as TJSONArray;
      if Items = nil then
        raise Exception.Create('items is empty');

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

      if not (VarIsEmpty(ovObject) or VarIsNull(ovObject)) then
      begin
        try
          ovObject.CutType := 1;
          ovObject.CutCheck;
          CheckFRResult('CutCheck');
        except
          on E: Exception do
          begin
            FLog.LogError('[FR] CutCheck: ' + E.Message);
            if not FEmulation then
              raise;
          end;
        end;
      end;

      Result := JsonOk(
        '"checkNumber":' + IntToStr(CheckNumber) + ',' +
        '"serialNumber":"' + JsonEscape(SerialNumber) + '"');

      FLog.LogInfo(Format('PrintCheckJson OK checkNumber=%d serial=%s',
        [CheckNumber, SerialNumber]));
      ClearAcceptedMarksCache;
      AfterCommand(Req);
    except
      on E: Exception do
      begin
        FLog.LogError('PrintCheckJson: ' + E.Message);
        if FEmulation then
        begin
          try
            if not (VarIsEmpty(ovObject) or VarIsNull(ovObject)) then
              ovObject.CancelCheck;
          except
            on E2: Exception do
              FLog.LogError('[FR] CancelCheck after error: ' + E2.Message);
          end;
          ClearAcceptedMarksCache;
          Inc(FEmulatedCheckNumber);
          Result := JsonOk(
            '"checkNumber":' + IntToStr(FEmulatedCheckNumber) + ',' +
            '"serialNumber":"' + JsonEscape(FEmulatedSerial) + '"');
          AfterCommand(Req);
        end
        else
        begin
          try ovObject.CancelCheck; except end;
          ClearAcceptedMarksCache;
          Result := JsonError(E.Message);
        end;
      end;
    end;
    V.Free;
  finally
    FLock.Leave;
  end;
end;

{-------------------------------------------------------------------------------
 Служебные команды
-------------------------------------------------------------------------------}

function TVariantPrint.CloseShiftJson(const Body: string): string;
var
  V: TJSONValue;
  Req: TJSONObject;
  SessionNumber: Integer;
begin
  FLock.Enter;
  try
    V := nil;
    try
      FLog.LogInfo('CloseShiftJson begin');
      V := TJSONObject.ParseJSONValue(Body);
      Req := nil;
      if V is TJSONObject then
        Req := TJSONObject(V);

      EnsureFRConnected;
      if not FRObjectReady then
        LogFRSkipped('PrintReportWithCleaning')
      else
      begin
        ovObject.PrintReportWithCleaning;
        CheckFRResult('PrintReportWithCleaning');
      end;

      SessionNumber := ReadSessionNumberAfterClose;

      Result := JsonOk('"documentNumber":' + IntToStr(SessionNumber));
      FLog.LogInfo('CloseShiftJson OK documentNumber=' + IntToStr(SessionNumber));
      ClearAcceptedMarksCache;
      AfterCommand(Req);
    except
      on E: Exception do
      begin
        FLog.LogError('CloseShiftJson: ' + E.Message);
        if FEmulation then
        begin
          Inc(FEmulatedSessionNumber);
          Result := JsonOk('"documentNumber":' + IntToStr(FEmulatedSessionNumber));
          ClearAcceptedMarksCache;
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
    try
      FLog.LogInfo('XReportJson begin');
      V := TJSONObject.ParseJSONValue(Body);
      Req := nil;
      if V is TJSONObject then
        Req := TJSONObject(V);

      EnsureFRConnected;
      if not FRObjectReady then
        LogFRSkipped('PrintReportWithoutCleaning')
      else
      begin
        ovObject.PrintReportWithoutCleaning;
        CheckFRResult('PrintReportWithoutCleaning');
      end;
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

function TVariantPrint.CancelCheckJson(const Body: string = ''): string;
var
  V: TJSONValue;
  Req: TJSONObject;
begin
  FLock.Enter;
  try
    V := nil;
    try
      FLog.LogInfo('CancelCheckJson begin');
      V := TJSONObject.ParseJSONValue(Body);
      Req := nil;
      if V is TJSONObject then
        Req := TJSONObject(V);

      EnsureFRConnected;
      if not FRObjectReady then
        LogFRSkipped('CancelCheck')
      else
      begin
        ovObject.CancelCheck;
        CheckFRResult('CancelCheck');
      end;
      ClearAcceptedMarksCache;
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
          ClearAcceptedMarksCache;
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

function TVariantPrint.DecodeMarkBase64(const B64: string): string;
var
  Bytes: TBytes;
  I: Integer;
begin
  if Trim(B64) = '' then
    raise Exception.Create('Пустая марка (base64)');

  try
    Bytes := TNetEncoding.Base64.DecodeStringToBytes(B64);
  except
    on E: Exception do
      raise Exception.Create('Некорректный base64 марки: ' + E.Message);
  end;

  if Length(Bytes) = 0 then
    raise Exception.Create('Декодированная марка пуста');

  SetLength(Result, Length(Bytes));
  for I := 0 to High(Bytes) do
    Result[I + 1] := Char(Bytes[I]);
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
    raise Exception.Create('Invalid JSON');

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

procedure TVariantPrint.EnsureSessionOpen(const CashierName: string);
var
  SessionNotOpen: Boolean;
  Cashier: string;
begin
  if not FRObjectReady then
  begin
    LogFRSkipped('EnsureSessionOpen');
    Exit;
  end;

  if FEmulation then
    Exit;

  ovObject.GetECRStatus;
  CheckFRResult('GetECRStatus EnsureSessionOpen');

  SessionNotOpen := False;
  try
    SessionNotOpen := ovObject.ECRMode = 4;
  except
    SessionNotOpen := False;
  end;

  if not SessionNotOpen then
    Exit;

  Cashier := CashierName;
  if Cashier = '' then
    Cashier := FSettings.ReadString('FRCash', 'CashierName', 'Кассир');

  FLog.LogInfo('Смена не открыта — открываем (кассир: ' + Cashier + ')');

  ovObject.TableNumber := 2;
  ovObject.FieldNumber := 2;
  ovObject.RowNumber := 30;
  ovObject.ValueOfFieldString := Cashier;
  ovObject.WriteTable;
  CheckFRResult('WriteTable cashier');

  ovObject.TableNumber := 1;
  ovObject.FieldNumber := 6;
  ovObject.RowNumber := 1;
  ovObject.ValueOfFieldInteger := 0;
  ovObject.WriteTable;
  CheckFRResult('WriteTable session flag');

  ovObject.OpenSession;
  CheckFRResult('OpenSession');
end;

function TVariantPrint.CheckSingleMark(const MarkDecoded: string;
  ReturnCheck: Boolean): TJSONObject;
var
  ResCheck: Integer;
  Accepted: Boolean;
  Desc: string;
begin
  Result := TJSONObject.Create;

  if IsMarkAcceptedInCache(MarkDecoded, ReturnCheck) then
  begin
    FLog.LogInfo('Марка уже принята в текущем чеке — пропуск FNCheckItemBarcode');
    Result.AddPair('accepted', TJSONBool.Create(True));
    Result.AddPair('resultCode', TJSONNumber.Create(0));
    Result.AddPair('checkItemLocalResult', TJSONNumber.Create(15));
    Result.AddPair('checkItemLocalError', TJSONNumber.Create(0));
    Result.AddPair('markingType2', TJSONNumber.Create(0));
    Result.AddPair('kmServerErrorCode', TJSONNumber.Create(0));
    Result.AddPair('kmServerCheckingStatus', TJSONNumber.Create(15));
    Result.AddPair('description', 'OK (cached)');
    Exit;
  end;

  if FEmulation or not FRObjectReady then
  begin
    Result.AddPair('accepted', TJSONBool.Create(True));
    Result.AddPair('resultCode', TJSONNumber.Create(0));
    Result.AddPair('checkItemLocalResult', TJSONNumber.Create(15));
    Result.AddPair('checkItemLocalError', TJSONNumber.Create(0));
    Result.AddPair('markingType2', TJSONNumber.Create(0));
    Result.AddPair('kmServerErrorCode', TJSONNumber.Create(0));
    Result.AddPair('kmServerCheckingStatus', TJSONNumber.Create(15));
    Result.AddPair('description', 'OK (emulation)');
    AddMarkToAcceptedCache(MarkDecoded, ReturnCheck);
    Exit;
  end;

  if ReturnCheck then
    ovObject.ItemStatus := 3
  else
    ovObject.ItemStatus := 1;
  ovObject.CheckItemMode := 0;
  ovObject.TLVDataHEX := '';
  ovObject.BarCode := MarkDecoded;

  FLog.LogInfo('FNCheckItemBarcode begin');
  ovObject.FNCheckItemBarcode;

  ResCheck := 0;
  try
    ResCheck := ovObject.CheckItemLocalResult;
  except
  end;
  Result.AddPair('checkItemLocalResult', TJSONNumber.Create(ResCheck));
  FLog.LogInfo('CheckItemLocalResult=' + IntToStr(ResCheck));

  ResCheck := 0;
  try
    ResCheck := ovObject.CheckItemLocalError;
  except
  end;
  Result.AddPair('checkItemLocalError', TJSONNumber.Create(ResCheck));
  FLog.LogInfo('CheckItemLocalError=' + IntToStr(ResCheck));

  ResCheck := 0;
  try
    ResCheck := ovObject.MarkingType2;
  except
  end;
  Result.AddPair('markingType2', TJSONNumber.Create(ResCheck));
  FLog.LogInfo('MarkingType2=' + IntToStr(ResCheck));

  ResCheck := 0;
  try
    ResCheck := ovObject.KMServerErrorCode;
  except
  end;
  Result.AddPair('kmServerErrorCode', TJSONNumber.Create(ResCheck));
  FLog.LogInfo('KMServerErrorCode=' + IntToStr(ResCheck));

  ResCheck := 0;
  try
    ResCheck := ovObject.KMServerCheckingStatus;
  except
  end;
  Result.AddPair('kmServerCheckingStatus', TJSONNumber.Create(ResCheck));
  FLog.LogInfo('KMServerCheckingStatus=' + IntToStr(ResCheck));

  ResCheck := 0;
  try
    ResCheck := ovObject.ResultCode;
  except
  end;
  Desc := FRResultText(ovObject);
  Result.AddPair('resultCode', TJSONNumber.Create(ResCheck));
  Result.AddPair('description', Desc);

  if ResCheck <> 0 then
  begin
    Accepted := False;
    FLog.LogError('Ошибка проверки марки: ' + IntToStr(ResCheck) + ' ' + Desc);
    try
      ovObject.FNDeclineMarkingCode;
      FLog.LogDebug('[FR] FNDeclineMarkingCode: ' + FRResultText(ovObject));
    except
      on E: Exception do
        FLog.LogError('[FR] FNDeclineMarkingCode: ' + E.Message);
    end;
  end
  else
  begin
    Accepted := True;
    try
      ovObject.FNAcceptMarkingCode;
      FLog.LogDebug('[FR] FNAcceptMarkingCode: ' + FRResultText(ovObject));
    except
      on E: Exception do
      begin
        FLog.LogError('[FR] FNAcceptMarkingCode: ' + E.Message);
        if not FEmulation then
          raise;
      end;
    end;
  end;

  if Accepted then
    AddMarkToAcceptedCache(MarkDecoded, ReturnCheck);

  Result.AddPair('accepted', TJSONBool.Create(Accepted));
end;

function TVariantPrint.CheckMarkInternal(const Body: string): string;
var
  V: TJSONValue;
  Req: TJSONObject;
  MarksB64: TArray<string>;
  MarksOut: TJSONArray;
  Root: TJSONObject;
  MarkObj: TJSONObject;
  ReturnCheck: Boolean;
  CashierName: string;
  I: Integer;
  MarkDecoded: string;
  AllAccepted: Boolean;
  Accepted: Boolean;
begin
  V := TJSONObject.ParseJSONValue(Body);
  if not (V is TJSONObject) then
  begin
    V.Free;
    raise Exception.Create('Invalid JSON');
  end;
  Req := TJSONObject(V);

  try
    FLog.LogInfo('CheckMarkInternal begin');
    EnsureFRConnected;

    CollectMarksFromRequest(Req, MarksB64);
    ReturnCheck := GetReceiptReturnCheck(Req);
    CashierName := JStr(Req, 'cashierName');

    EnsureSessionOpen(CashierName);

    MarksOut := TJSONArray.Create;
    Root := TJSONObject.Create;
    try
      AllAccepted := True;
      for I := 0 to High(MarksB64) do
      begin
        MarkDecoded := DecodeMarkBase64(MarksB64[I]);
        FLog.LogInfo(Format('Проверка марки [%d/%d], длина=%d',
          [I + 1, Length(MarksB64), Length(MarkDecoded)]));

        MarkObj := CheckSingleMark(MarkDecoded, ReturnCheck);
        try
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
      Result := Root.ToJSON;
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

  TThread.CreateAnonymousThread(
    procedure
    var
      JsonResult: string;
      TaskEntry: TCheckMarkTaskEntry;
    begin
      FLock.Enter;
      try
        try
          JsonResult := CheckMarkInternal(Body);
        except
          on E: Exception do
            JsonResult := JsonError(E.Message);
        end;
      finally
        FLock.Leave;
      end;

      FMarkTasksLock.Enter;
      try
        if FMarkTasks.TryGetValue(TaskId, TaskEntry) then
        begin
          if Pos('"result":1', JsonResult) > 0 then
            TaskEntry.Status := 'completed'
          else
            TaskEntry.Status := 'error';
          TaskEntry.ResultJson := JsonResult;
        end;
      finally
        FMarkTasksLock.Leave;
      end;
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
      raise Exception.Create('Invalid JSON');
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
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  finally
    FMarkTasksLock.Leave;
  end;
end;

end.
