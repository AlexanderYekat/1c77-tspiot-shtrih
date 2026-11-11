object kktServerIndyForm: TkktServerIndyForm
  Left = 0
  Top = 0
  Caption = 'kktServerIndyForm'
  ClientHeight = 599
  ClientWidth = 1031
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  WindowState = wsMinimized
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object HeaderLabel: TLabel
    Left = 448
    Top = 16
    Width = 160
    Height = 15
    Caption = #1050#1050#1058' '#1089#1077#1088#1074#1077#1088' '#1076#1083#1103' '#1087#1077#1095#1072#1090#1080' '#1095#1077#1082#1086#1074
  end
  object VersionLabel: TLabel
    Left = 448
    Top = 36
    Width = 42
    Height = 15
    Caption = #1042#1077#1088#1089#1080#1103':'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
  end
  object ButtonStartServer: TButton
    Left = 88
    Top = 40
    Width = 153
    Height = 25
    Caption = #1057#1090#1072#1088#1090
    TabOrder = 0
    OnClick = ButtonStartServerClick
  end
  object ButtonStopServer: TButton
    Left = 88
    Top = 120
    Width = 153
    Height = 25
    Caption = #1057#1090#1086#1087
    TabOrder = 1
    OnClick = ButtonStopServerClick
  end
  object LogsMemo: TMemo
    Left = 88
    Top = 240
    Width = 873
    Height = 320
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -11
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 2
    WordWrap = False
  end
  object OptionsButton: TButton
    Left = 886
    Top = 192
    Width = 75
    Height = 25
    Caption = #1053#1072#1089#1090#1088#1086#1081#1082#1080
    TabOrder = 3
    OnClick = OptionsButtonClick
  end
end
