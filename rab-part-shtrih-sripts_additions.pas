{===============================================================================
 ДОБАВИТЬ В Delphi/Pascal программу рядом с rab-part-shtrih-sripts.pas
 Смысл: эта программа стоит на одном ПК с proxy-1c-fmuapi и ККТ.
 Она слушает локальный порт 2580, а proxy вызывает её endpoints:
   GET  /info
   POST /print-check
   POST /close-shift
   POST /x-report
   POST /cancel-check

 Пример ниже не является полной программой. Это вставляемые методы.
 Требует адаптации имён вашего класса, где доступны ovObject, CheckFRResult,
 CheckFRAdvancedMode, ifMain/ifSetup, WriteLogFile/WriteAdvancedLogFile.
===============================================================================}

uses
  System.SysUtils, System.Variants, System.JSON, ComObj;

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
var V: TJSONValue;
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

function JFloat(O: TJSONObject; const Name: string; const Def: Double = 0): Double;
var S: string;
    FS: TFormatSettings;
begin
  FS := TFormatSettings.Create;
  FS.DecimalSeparator := '.';
  S := StringReplace(JStr(O, Name, FloatToStr(Def, FS)), ',', '.', [rfReplaceAll]);
  Result := StrToFloatDef(S, Def, FS);
end;

function FRResultText(ovObject: OleVariant): string;
begin
  try
    Result := VarToStr(ovObject.ResultCodeDescription);
  except
    Result := '';
  end;
end;

procedure RaiseIfFRFail(ovObject: OleVariant; const Place: string);
var Code: Integer;
begin
  Code := 0;
  try
    Code := ovObject.ResultCode;
  except
  end;

  if Code <> 0 then
    raise Exception.Create(Place + ': ' + IntToStr(Code) + ' ' + FRResultText(ovObject));
end;

{-------------------------------------------------------------------------------
 Подключение/информация о ККТ
-------------------------------------------------------------------------------}

function TVariantPrint.EnsureFRConnected: Boolean;
begin
  Result := False;

  if VarIsEmpty(ovObject) or VarIsNull(ovObject) then
    ovObject := CreateOleObject('AddIn.DrvFR');

  ovObject.ComNumber := ifMain.ReadInteger('FRCash', 'Port', 1);
  ovObject.BaudRate  := ifMain.ReadInteger('FRCash', 'Baud', 5);
  ovObject.Password  := ifMain.ReadInteger('FRCash', 'Password', 30);
  ovObject.Connect;
  RaiseIfFRFail(ovObject, 'Connect');

  Result := True;
end;

function TVariantPrint.KktInfoJson: string;
var SerialNumber, Inn, FnNumber: string;
begin
  try
    EnsureFRConnected;

    ovObject.GetECRStatus;
    RaiseIfFRFail(ovObject, 'GetECRStatus');
    SerialNumber := VarToStr(ovObject.SerialNumber);

    // В разных версиях Штрих-драйвера имена свойств отличаются.
    // Если эти свойства у вас называются иначе — замените здесь, это единственное место.
    Inn := '';
    FnNumber := '';
    try
      ovObject.GetFiscalizationParameters;
      try Inn := VarToStr(ovObject.INN); except end;
      try FnNumber := VarToStr(ovObject.FNNumber); except end;
      try if FnNumber = '' then FnNumber := VarToStr(ovObject.FiscalStorageNumber); except end;
    except
      // Не валим /info полностью: для печати важен serialNumber,
      // а для разрешительного режима лучше всё-таки добиться FnNumber.
    end;

    Result := JsonOk(
      '"serialNumber":"' + JsonEscape(SerialNumber) + '",' +
      '"inn":"' + JsonEscape(Inn) + '",' +
      '"fnNumber":"' + JsonEscape(FnNumber) + '"');
  except
    on E: Exception do
      Result := JsonError(E.Message);
  end;
end;

{-------------------------------------------------------------------------------
 Печать позиции и маркировки
-------------------------------------------------------------------------------}

procedure TVariantPrint.SendIndustryRequisite126x(const UUID, TimeStr: string);
var S: string;
begin
  if (UUID = '') or (TimeStr = '') then
    Exit;

  S := 'UUID=' + UUID + '&Time=' + TimeStr;

  ovObject.TagNumber := 1262;
  ovObject.TagType := 7;
  ovObject.TagValueStr := '030';
  ovObject.FNSendTagOperation;
  RaiseIfFRFail(ovObject, 'FNSendTagOperation 1262');

  ovObject.TagNumber := 1263;
  ovObject.TagType := 7;
  ovObject.TagValueStr := '21.11.2023';
  ovObject.FNSendTagOperation;
  RaiseIfFRFail(ovObject, 'FNSendTagOperation 1263');

  ovObject.TagNumber := 1264;
  ovObject.TagType := 7;
  ovObject.TagValueStr := '1944';
  ovObject.FNSendTagOperation;
  RaiseIfFRFail(ovObject, 'FNSendTagOperation 1264');

  ovObject.TagNumber := 1265;
  ovObject.TagType := 7;
  ovObject.TagValueStr := S;
  ovObject.FNSendTagOperation;
  RaiseIfFRFail(ovObject, 'FNSendTagOperation 1265');
end;

procedure TVariantPrint.SendMarkingCodeAfterFNOperation(const MarkKkt: string);
begin
  if MarkKkt = '' then
    Exit;

  // Минимальный вариант из вашего pas-фрагмента:
  ovObject.BarCode := MarkKkt;
  ovObject.FNSendItemBarcode;
  RaiseIfFRFail(ovObject, 'FNSendItemBarcode');

  // Если на вашей версии Штрих-драйвера нужен старый 1С-сценарий,
  // можно заменить блок выше на:
  //
  // ovObject.MarkingType := 17485;
  // ovObject.ItemStatus := 1;
  // ovObject.CheckItemMode := 0;
  // ovObject.BarCode := MarkKkt;
  // ovObject.FNCheckItemBarcode;
  // RaiseIfFRFail(ovObject, 'FNCheckItemBarcode');
  // ovObject.FNSendItemBarcode;
  // RaiseIfFRFail(ovObject, 'FNSendItemBarcode 1');
  // ovObject.FNAcceptMarkingCode;
  // RaiseIfFRFail(ovObject, 'FNAcceptMarkingCode');
  // ovObject.FNSendItemBarcode;
  // RaiseIfFRFail(ovObject, 'FNSendItemBarcode 2');
end;

procedure TVariantPrint.RegisterReceiptItem(Item: TJSONObject; ReturnCheck: Boolean; DefaultDepartment: Integer);
var
  Name, MarkKkt, UUID, TimeStr: string;
  Qty, Price: Double;
  Department: Integer;
begin
  Name := JStr(Item, 'name');
  Qty := JFloat(Item, 'quantity', 1);
  Price := JFloat(Item, 'price', 0);
  Department := JInt(Item, 'department', DefaultDepartment);
  MarkKkt := JStr(Item, 'markKkt');
  UUID := JStr(Item, 'uuid');
  TimeStr := JStr(Item, 'time');

  if not ReturnCheck then
    ovObject.CheckType := 0
  else
    ovObject.CheckType := 2;

  ovObject.StringForPrinting := Name;
  ovObject.Quantity := Qty;
  ovObject.Price := Price;
  ovObject.Department := Department;
  ovObject.Tax1 := 0;
  ovObject.Tax2 := 0;
  ovObject.Tax3 := 0;
  ovObject.Tax4 := 0;
  ovObject.PaymentTypeSign := 4;     // полный расчёт
  ovObject.PaymentItemSign := 1;     // товар
  if MarkKkt <> '' then
    ovObject.PaymentItemSign := 33;  // маркированный товар, как в старой 1С

  try
    ovObject.MeasureUnit := 0;       // шт.
  except
  end;

  ovObject.FNOperation;
  RaiseIfFRFail(ovObject, 'FNOperation');

  if (MarkKkt <> '') and (not ReturnCheck) then
    SendIndustryRequisite126x(UUID, TimeStr);

  SendMarkingCodeAfterFNOperation(MarkKkt);
end;

{-------------------------------------------------------------------------------
 Закрытие чека
-------------------------------------------------------------------------------}

procedure TVariantPrint.CloseReceiptFromJson(Req: TJSONObject);
var
  Payment: Integer;
  Total, Received: Double;
begin
  Payment := JInt(Req, 'payment', 0);
  Total := JFloat(Req, 'total', 0);
  Received := JFloat(Req, 'received', Total);

  ovObject.StringForPrinting := '';

  ovObject.Summ1 := 0;  ovObject.Summ2 := 0;  ovObject.Summ3 := 0;  ovObject.Summ4 := 0;
  ovObject.Summ5 := 0;  ovObject.Summ6 := 0;  ovObject.Summ7 := 0;  ovObject.Summ8 := 0;
  ovObject.Summ9 := 0;  ovObject.Summ10 := 0; ovObject.Summ11 := 0; ovObject.Summ12 := 0;
  ovObject.Summ13 := 0; ovObject.Summ14 := 0; ovObject.Summ15 := 0; ovObject.Summ16 := 0;

  case Payment of
    0: ovObject.Summ1 := Total;       // наличные
    1: ovObject.Summ2 := Total;       // карта/безнал, как в 1С
    2: ovObject.Summ15 := Received;   // кредит, как в 1С
  else
    ovObject.Summ1 := Total;
  end;

  ovObject.RoundingSumm := 0;
  ovObject.TaxValue1 := 0;
  ovObject.TaxValue2 := 0;
  ovObject.TaxValue3 := 0;
  ovObject.TaxValue4 := 0;
  ovObject.TaxValue5 := 0;
  ovObject.TaxValue6 := 0;

  ovObject.FNCloseCheckEx;
  RaiseIfFRFail(ovObject, 'FNCloseCheckEx');
end;

function TVariantPrint.PrintCheckJson(const Body: string): string;
var
  V: TJSONValue;
  Req, Item: TJSONObject;
  Items: TJSONArray;
  I, CheckNumber: Integer;
  ReturnCheck: Boolean;
  SerialNumber: string;
begin
  Result := JsonError('Unknown error');
  V := nil;
  try
    EnsureFRConnected;

    V := TJSONObject.ParseJSONValue(Body);
    if not (V is TJSONObject) then
      raise Exception.Create('Invalid JSON');
    Req := TJSONObject(V);

    ReturnCheck := JInt(Req, 'returnCheck', 0) <> 0;
    Items := Req.GetValue('items') as TJSONArray;
    if Items = nil then
      raise Exception.Create('items is empty');

    for I := 0 to Items.Count - 1 do
    begin
      Item := Items.Items[I] as TJSONObject;
      RegisterReceiptItem(Item, ReturnCheck, JInt(Req, 'department', 1));
    end;

    CloseReceiptFromJson(Req);

    ovObject.GetECRStatus;
    RaiseIfFRFail(ovObject, 'GetECRStatus after close');
    CheckNumber := ovObject.OpenDocumentNumber;
    try
      if ovObject.ECRAdvancedMode = 5 then
        Inc(CheckNumber);
    except
    end;
    SerialNumber := VarToStr(ovObject.SerialNumber);

    try
      ovObject.CutType := 1;
      ovObject.CutCheck;
    except
    end;

    Result := JsonOk(
      '"checkNumber":' + IntToStr(CheckNumber) + ',' +
      '"serialNumber":"' + JsonEscape(SerialNumber) + '"');
  except
    on E: Exception do
    begin
      try ovObject.CancelCheck; except end;
      Result := JsonError(E.Message);
    end;
  end;
  V.Free;
end;

{-------------------------------------------------------------------------------
 Служебные команды
-------------------------------------------------------------------------------}

function TVariantPrint.CloseShiftJson(const Body: string): string;
var SessionNumber: Integer;
begin
  try
    EnsureFRConnected;
    ovObject.PrintReportWithCleaning;
    RaiseIfFRFail(ovObject, 'PrintReportWithCleaning');

    ovObject.GetECRStatus;
    RaiseIfFRFail(ovObject, 'GetECRStatus after close shift');
    SessionNumber := ovObject.SessionNumber;
    try
      if ovObject.ECRAdvancedMode = 5 then
        Inc(SessionNumber);
    except
    end;

    Result := JsonOk('"documentNumber":' + IntToStr(SessionNumber));
  except
    on E: Exception do
      Result := JsonError(E.Message);
  end;
end;

function TVariantPrint.XReportJson: string;
begin
  try
    EnsureFRConnected;
    ovObject.PrintReportWithoutCleaning;
    RaiseIfFRFail(ovObject, 'PrintReportWithoutCleaning');
    Result := JsonOk;
  except
    on E: Exception do Result := JsonError(E.Message);
  end;
end;

function TVariantPrint.CancelCheckJson: string;
begin
  try
    EnsureFRConnected;
    ovObject.CancelCheck;
    RaiseIfFRFail(ovObject, 'CancelCheck');
    Result := JsonOk;
  except
    on E: Exception do Result := JsonError(E.Message);
  end;
end;

{===============================================================================
 HTTP-слой.
 Ниже псевдо-вставка для Indy TIdHTTPServer.
 В OnCommandGet/OnCommandOther верните JSON из методов выше.
===============================================================================}

// GET /info              -> VariantPrint.KktInfoJson
// POST /print-check      -> VariantPrint.PrintCheckJson(Body)
// POST /close-shift      -> VariantPrint.CloseShiftJson(Body)
// POST /x-report         -> VariantPrint.XReportJson
// POST /cancel-check     -> VariantPrint.CancelCheckJson
//
// Все ответы должны идти как:
//   AResponseInfo.ContentType := 'application/json; charset=utf-8';
//   AResponseInfo.ContentText := ResultJson;
