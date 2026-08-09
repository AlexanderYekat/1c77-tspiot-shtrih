; Deploy 1C 7.7 external forms (.ert) into the selected IB ExtForms folders.
; Payload source (Latin path): ../1cv77-extforms/*.ert
;
; Silent / future unified installer:
;   1cv77_extforms_setup.exe /VERYSILENT /SUPPRESSMSGBOXES
;   1cv77_extforms_setup.exe /VERYSILENT /BASEPATH=C:\dm\base
;
; PrivilegesRequired=lowest — must run as the same user as 1C (HKCU Titles).

#define MyAppName "1C77 ExtForms Deploy"
#define MyAppVersion "2026.07.26.02"
#define MyAppPublisher "CTO KSM"
#define MyAppDirName "1cv77_extforms"

[Setup]
AppId={{E7A1B2C3-4D5E-6F70-8192-A3B4C5D6E7F8}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://cto-ksm.ru
DefaultDirName={localappdata}\CTO_KSM\{#MyAppDirName}
DisableDirPage=yes
DisableProgramGroupPage=yes
CreateAppDir=yes
Uninstallable=no
OutputDir=output
OutputBaseFilename=1cv77_extforms_setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest
MinVersion=6.1sp1
CloseApplications=no
ShowLanguageDialog=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
; Staging only — real deploy is done in [Code] to the 1C IB path from registry
Source: "..\1cv77-extforms\*.ert"; DestDir: "{app}\payload"; Flags: ignoreversion

[Code]
const
  RegTitlesKey = 'Software\1C\1Cv7\7.7\Titles';

var
  BasePaths: TArrayOfString;
  BaseTitles: TArrayOfString;
  SelectedBasePath: String;
  BaseSelectPage: TInputOptionWizardPage;
  ForcedBasePath: String;
  BackupRoot: String;
  DeployLog: String;

function NormalizePath(const Path: String): String;
begin
  Result := AddBackslash(Trim(Path));
end;

function CmdLineParam(const ParamName: String): String;
var
  I: Integer;
  S, Prefix: String;
begin
  Result := '';
  Prefix := UpperCase(ParamName) + '=';
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (Length(S) > 0) and (Copy(S, 1, 1) = '/') then
      S := Copy(S, 2, Length(S) - 1);
    if (Length(S) > 0) and (Copy(S, 1, 1) = '-') then
      S := Copy(S, 2, Length(S) - 1);
    if UpperCase(Copy(S, 1, Length(Prefix))) = Prefix then
    begin
      Result := Copy(S, Length(Prefix) + 1, Length(S));
      if (Length(Result) >= 2) and (Copy(Result, 1, 1) = '"') and (Copy(Result, Length(Result), 1) = '"') then
        Result := Copy(Result, 2, Length(Result) - 2);
      Exit;
    end;
  end;
end;

function LoadBasesFromRegistry(): Boolean;
var
  Names: TArrayOfString;
  I, N: Integer;
  Title, Path: String;
begin
  Result := False;
  SetArrayLength(BasePaths, 0);
  SetArrayLength(BaseTitles, 0);

  if not RegGetValueNames(HKEY_CURRENT_USER, RegTitlesKey, Names) then
    Exit;

  N := 0;
  for I := 0 to GetArrayLength(Names) - 1 do
  begin
    Path := Trim(Names[I]);
    if Path <> '' then
    begin
      if not RegQueryStringValue(HKEY_CURRENT_USER, RegTitlesKey, Names[I], Title) then
        Title := Path;
      SetArrayLength(BasePaths, N + 1);
      SetArrayLength(BaseTitles, N + 1);
      BasePaths[N] := NormalizePath(Path);
      BaseTitles[N] := Title;
      N := N + 1;
    end;
  end;
  Result := N > 0;
end;

function CharToLowerOrd(O: Integer): Integer;
begin
  if (O >= Ord('A')) and (O <= Ord('Z')) then
    Result := O + 32
  else if (O >= $0410) and (O <= $042F) then
    Result := O + $20
  else if O = $0401 then
    Result := $0451
  else
    Result := O;
end;

{ Case-insensitive "сургут" via ordinals only — no DLL, no Chr(), no Cyrillic literals. }
function TitleContainsSurgut(const Title: String): Boolean;
var
  I, TL: Integer;
  Ok: Boolean;
begin
  Result := False;
  TL := Length(Title);
  if TL < 6 then
    Exit;
  for I := 1 to TL - 5 do
  begin
    Ok := True;
    { с у р г у т = $0441 $0443 $0440 $0433 $0443 $0442 }
    if CharToLowerOrd(Ord(Title[I]))     <> $0441 then Ok := False;
    if Ok and (CharToLowerOrd(Ord(Title[I+1])) <> $0443) then Ok := False;
    if Ok and (CharToLowerOrd(Ord(Title[I+2])) <> $0440) then Ok := False;
    if Ok and (CharToLowerOrd(Ord(Title[I+3])) <> $0433) then Ok := False;
    if Ok and (CharToLowerOrd(Ord(Title[I+4])) <> $0443) then Ok := False;
    if Ok and (CharToLowerOrd(Ord(Title[I+5])) <> $0442) then Ok := False;
    if Ok then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

{ If any IB title contains "сургут", keep only those; otherwise leave the full list.
  Copy element-by-element: dynamic array assignment is unreliable in Inno Pascal Script. }
procedure FilterSurgutBases();
var
  TmpPaths, TmpTitles: TArrayOfString;
  I, N, Total: Integer;
begin
  Total := GetArrayLength(BaseTitles);
  SetArrayLength(TmpPaths, Total);
  SetArrayLength(TmpTitles, Total);
  for I := 0 to Total - 1 do
  begin
    TmpPaths[I] := BasePaths[I];
    TmpTitles[I] := BaseTitles[I];
  end;

  N := 0;
  for I := 0 to Total - 1 do
  begin
    if TitleContainsSurgut(TmpTitles[I]) then
    begin
      TmpPaths[N] := TmpPaths[I];
      TmpTitles[N] := TmpTitles[I];
      N := N + 1;
    end;
  end;

  if N > 0 then
  begin
    SetArrayLength(BasePaths, N);
    SetArrayLength(BaseTitles, N);
    for I := 0 to N - 1 do
    begin
      BasePaths[I] := TmpPaths[I];
      BaseTitles[I] := TmpTitles[I];
    end;
    Log('Filtered to Surgut bases: ' + IntToStr(N));
  end
  else
    Log('No Surgut bases found, keeping all: ' + IntToStr(Total));
end;

function IsEquipFile(const FileName: String): Boolean;
begin
  Result := CompareText(ExtractFileName(FileName), 'fr_elves-12.ert') = 0;
end;

function DestRelativePath(const FileName: String): String;
begin
  if IsEquipFile(FileName) then
    Result := 'ExtForms\Equip\' + ExtractFileName(FileName)
  else
    Result := 'ExtForms\' + ExtractFileName(FileName);
end;

procedure AppendLog(const Line: String);
begin
  DeployLog := DeployLog + Line + #13#10;
  Log(Line);
end;

function DeployPayload(const BasePath: String): Boolean;
var
  PayloadDir, Src, Rel, DestFull, BackupFull: String;
  FileNames: TArrayOfString;
  I, Count: Integer;
  Ok: Boolean;
begin
  Result := False;
  DeployLog := '';
  PayloadDir := AddBackslash(ExpandConstant('{app}\payload'));
  // GetDateTimeString: separators must be non-empty (empty => Type Mismatch at runtime)
  BackupRoot := BasePath + 'ExtForms\_backup_cto_ksm\' +
    GetDateTimeString('yyyy/mm/dd_hh:nn:ss', '-', '-') + '\';

  AppendLog('Base: ' + BasePath);
  AppendLog('Payload: ' + PayloadDir);
  AppendLog('Backup: ' + BackupRoot);

  if not DirExists(PayloadDir) then
  begin
    AppendLog('ERROR: payload dir missing');
    MsgBox('Не найден каталог payload с .ert файлами:'#13#10 + PayloadDir, mbError, MB_OK);
    Exit;
  end;

  ForceDirectories(BasePath + 'ExtForms\Equip\');
  ForceDirectories(BackupRoot);

  SetArrayLength(FileNames, 5);
  FileNames[0] := 'fr_elves-12.ert';
  FileNames[1] := 'fr_elves_test.ert';
  FileNames[2] := 'permissive_regime_2024.ert';
  FileNames[3] := 'razresh_regim_check.ert';
  FileNames[4] := 'razresh_regim_dialog_error.ert';

  Count := 0;
  Ok := True;
  for I := 0 to GetArrayLength(FileNames) - 1 do
  begin
    Src := PayloadDir + FileNames[I];
    if not FileExists(Src) then
      AppendLog('SKIP (missing): ' + FileNames[I])
    else
    begin
      Rel := DestRelativePath(Src);
      DestFull := BasePath + Rel;
      ForceDirectories(ExtractFilePath(DestFull));

      if FileExists(DestFull) then
      begin
        BackupFull := BackupRoot + Rel;
        ForceDirectories(ExtractFilePath(BackupFull));
        if FileCopy(DestFull, BackupFull, False) then
          AppendLog('BACKUP OK: ' + Rel)
        else
        begin
          AppendLog('BACKUP FAIL: ' + Rel);
          Ok := False;
        end;
      end;

      if FileCopy(Src, DestFull, False) then
      begin
        AppendLog('COPY OK: ' + Rel);
        Count := Count + 1;
      end
      else
      begin
        AppendLog('COPY FAIL: ' + Rel);
        Ok := False;
      end;
    end;
  end;

  SaveStringToFile(BackupRoot + 'deploy.log', DeployLog, False);
  AppendLog('Done, count=' + IntToStr(Count));

  if (Count > 0) and Ok then
  begin
    if not WizardSilent then
      MsgBox(
        'Готово. Скопировано файлов: ' + IntToStr(Count) + #13#10 +
        'База: ' + BasePath + #13#10 +
        'Резервные копии: ' + BackupRoot,
        mbInformation, MB_OK);
    Result := True;
  end
  else
  begin
    if not WizardSilent then
      MsgBox(
        'Развёртывание завершилось с ошибками.'#13#10 +
        'См. лог: ' + BackupRoot + 'deploy.log',
        mbError, MB_OK);
  end;
end;

function InitializeSetup(): Boolean;
var
  RawBase: String;
begin
  Result := True;
  ForcedBasePath := '';
  SelectedBasePath := '';
  DeployLog := '';

  RawBase := Trim(CmdLineParam('BASEPATH'));
  if RawBase <> '' then
  begin
    ForcedBasePath := AddBackslash(RawBase);
    if not DirExists(ForcedBasePath) then
    begin
      MsgBox('Каталог базы из /BASEPATH не найден:'#13#10 + ForcedBasePath, mbError, MB_OK);
      Result := False;
      Exit;
    end;
    SelectedBasePath := ForcedBasePath;
    Log('Using /BASEPATH=' + SelectedBasePath);
    Exit;
  end;

  if not LoadBasesFromRegistry() then
  begin
    MsgBox(
      'В реестре не найдены базы 1С 7.7.'#13#10 +
      'Ключ: HKCU\' + RegTitlesKey + #13#10 +
      'Либо укажите путь: /BASEPATH=C:\path\to\base',
      mbError, MB_OK);
    Result := False;
    Exit;
  end;

  FilterSurgutBases();

  if GetArrayLength(BasePaths) = 1 then
    SelectedBasePath := BasePaths[0]
  else if WizardSilent then
  begin
    MsgBox(
      'Найдено баз: ' + IntToStr(GetArrayLength(BasePaths)) + #13#10 +
      'Для /VERYSILENT укажите /BASEPATH=C:\path\to\base',
      mbError, MB_OK);
    Result := False;
  end;
end;

procedure InitializeWizard();
var
  I: Integer;
begin
  if (ForcedBasePath = '') and (GetArrayLength(BasePaths) > 1) then
  begin
    BaseSelectPage := CreateInputOptionPage(
      wpWelcome,
      'База 1С 7.7',
      'Найдено несколько информационных баз',
      'Выберите базу, в ExtForms которой будут скопированы внешние обработки:',
      True, False);
    for I := 0 to GetArrayLength(BasePaths) - 1 do
      BaseSelectPage.Add(BaseTitles[I] + ' — ' + BasePaths[I]);
    BaseSelectPage.SelectedValueIndex := 0;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (BaseSelectPage <> nil) and (CurPageID = BaseSelectPage.ID) then
  begin
    SelectedBasePath := BasePaths[BaseSelectPage.SelectedValueIndex];
    if not DirExists(SelectedBasePath) then
    begin
      MsgBox('Каталог базы не существует:'#13#10 + SelectedBasePath, mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result :=
    'База 1С: ' + SelectedBasePath + NewLine +
    NewLine +
    'Будет скопировано:' + NewLine +
    '  - fr_elves-12.ert  ->  ExtForms\Equip\' + NewLine +
    '  - остальные *.ert  ->  ExtForms\' + NewLine +
    NewLine +
    'Оригиналы (если есть) сохраняются в:' + NewLine +
    '  ExtForms\_backup_cto_ksm\<дата_время>\';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if SelectedBasePath = '' then
    begin
      MsgBox('Не выбран путь базы 1С.', mbError, MB_OK);
      Exit;
    end;
    SelectedBasePath := NormalizePath(SelectedBasePath);
    if not DirExists(SelectedBasePath) then
    begin
      MsgBox('Каталог базы не существует:'#13#10 + SelectedBasePath, mbError, MB_OK);
      Exit;
    end;
    if DeployPayload(SelectedBasePath) then
      SaveStringToFile(ExpandConstant('{app}\last_deploy.log'), DeployLog + #13#10 + 'Result=OK', False)
    else
      SaveStringToFile(ExpandConstant('{app}\last_deploy.log'), DeployLog + #13#10 + 'Result=FAIL', False);
  end;
end;
