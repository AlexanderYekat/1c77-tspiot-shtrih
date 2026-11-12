unit uPermissionErrors;

interface

// HTTP status is separate from the application code: HTTP 400 must never
// turn into a successful permission, even if its body contains Code=0.
procedure ReadPermissionFailure(const Body: string; out Code, Detail: string);
function PermissionFailureText(HttpStatus: Integer; const Code, Detail: string): string;

implementation

uses System.SysUtils, System.JSON;

function ShortText(const S: string): string;
var C: Char;
begin
  Result := '';
  for C in S do
  begin
    if Ord(C) < 32 then Result := Result + ' '
    else Result := Result + C;
    if Length(Result) >= 600 then Break;
  end;
  Result := Trim(Result);
end;

procedure ReadPermissionFailure(const Body: string; out Code, Detail: string);
var V: TJSONValue;

  procedure Visit(Value: TJSONValue; Depth: Integer);
  var Pair: TJSONPair; Item: TJSONValue; Key, S: string;
  begin
    if (Value = nil) or (Depth > 4) or (Length(Detail) >= 1200) then Exit;
    if Value is TJSONObject then
      for Pair in TJSONObject(Value) do
      begin
        Key := LowerCase(Pair.JsonString.Value);
        if ((Key = 'code') or (Key = 'errorcode')) and
           ((Pair.JsonValue is TJSONString) or (Pair.JsonValue is TJSONNumber)) then
        begin
          S := Pair.JsonValue.Value;
          if (Code = '') or (Code = '-1') or (Code = '0') then Code := S;
        end
        else if (Key = 'error') or (Key = 'message') or (Key = 'description') or
                (Key = 'detail') or (Key = 'details') or (Key = 'errors') or
                (Key = 'truemark_response') then
          Visit(Pair.JsonValue, Depth + 1);
      end
    else if Value is TJSONArray then
      for Item in TJSONArray(Value) do Visit(Item, Depth + 1)
    else if Value is TJSONString then
    begin
      S := ShortText(Value.Value);
      if (S <> '') and not SameText(S, 'OK') then
      begin
        if Detail <> '' then Detail := Detail + '; ';
        Detail := Detail + S;
      end;
    end;
  end;

begin
  Code := ''; Detail := '';
  // Do not display HTML error pages or entire JSON objects (tokens, codes, etc.).
  if Length(Body) > 1024 * 1024 then Exit;
  V := TJSONObject.ParseJSONValue(Body);
  try
    if V <> nil then Visit(V, 0)
    else if (Pos('<', Body) = 0) and (Pos('{', Body) = 0) and
            (Pos('[', Body) = 0) then Detail := ShortText(Body);
  finally V.Free; end;
end;

function PermissionFailureText(HttpStatus: Integer; const Code, Detail: string): string;
var S, Technical, LocalIssue: string; NoAnswer, DriverIssue: Boolean;
begin
  S := AnsiLowerCase(Detail);
  NoAnswer := (Code = '514') or (HttpStatus = 514) or
    (Pos('http: 514', S) > 0) or (Pos('"code":514', S) > 0) or
    (Pos('не удалось получить ответ от гис', S) > 0);
  DriverIssue := (Pos('kkt not connected', S) > 0) or
    (Pos('127.0.0.1:4042', S) > 0) or (Pos('нет связи с дккт', S) > 0) or
    (Pos('ошибка чтения данных из дккт', S) > 0);
  LocalIssue := '';
  if (Pos('локальный модуль отключен', S) > 0) or
     (Pos('локальный модуль отключён', S) > 0) then
    LocalIssue := 'Резервная проверка недоступна: локальный модуль отключён в FMU-API.'
  else if (Code = '4045') or (Pos('lmchz not configured', S) > 0) or
          (Pos('lmcz_not_configured', S) > 0) then
    LocalIssue := 'Локальный модуль ЧЗ не настроен. Обратитесь к специалисту для настройки.';

  if (HttpStatus = 0) and ((Code = '10061') or
    (Pos('10061', S) > 0) or (Pos('connection refused', S) > 0)) then
    Result := 'Нет связи с FMU-API. Проверьте, запущена ли служба FMU-API на компьютере кассового сервера. После восстановления связи нажмите «Повторить проверку марок».'
  else if DriverIssue then
    Result := 'Нет связи ТС ПИоТ с драйвером кассы. Дождитесь подключения кассы и повторите проверку марки. Если ошибка повторяется, проверьте агент ДККТ.'
  else if NoAnswer then
    Result := 'ТС ПИоТ не получил ответ от ЧЗ или локального модуля. Подождите 10–15 секунд и нажмите «Повторить проверку марок».'
  else if LocalIssue <> '' then Result := ''
  else if HttpStatus = 0 then
  begin
    if (Pos('timeout', S) > 0) or (Pos('timed out', S) > 0) or
       (Pos('время ожидания', S) > 0) then
      Result := 'Истекло время ожидания FMU-API. Повторите проверку марки. Если ошибка повторяется, проверьте работу FMU-API и ТС ПИоТ.'
    else
      Result := 'Нет связи с сервисом проверки FMU-API. Проверьте, что служба FMU-API запущена, затем повторите проверку марки.';
  end
  else if HttpStatus = 503 then
    Result := 'Сервис проверки FMU-API временно недоступен. Подождите и повторите проверку марки.'
  else if (HttpStatus = 401) or (HttpStatus = 403) then
    Result := 'FMU-API отказал в доступе к проверке марки. Обратитесь к специалисту для проверки настроек доступа.'
  else if Trim(Detail) <> '' then
    Result := 'Проверка марки не пройдена. Ответ сервиса: ' + ShortText(Detail)
  else
    Result := 'FMU-API не выполнил проверку марки и не передал причину. Повторите проверку; если ошибка повторяется, обратитесь к специалисту.';

  if LocalIssue <> '' then
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + LocalIssue;
  end;
  Technical := '';
  if HttpStatus >= 400 then Technical := 'FMU HTTP ' + IntToStr(HttpStatus);
  if (Code <> '') and (Code <> '0') and (Code <> '0.0') then
  begin
    if Technical <> '' then Technical := Technical + '; ';
    Technical := Technical + 'код ' + ShortText(Code);
  end;
  if Technical <> '' then Result := Result + ' (' + Technical + ')';
end;

end.
