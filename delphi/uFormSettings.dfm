object FormSettings: TFormSettings
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = #1053#1072#1089#1090#1088#1086#1081#1082#1080
  ClientHeight = 561
  ClientWidth = 484
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  OnCreate = FormCreate
  TextHeight = 15
  object ScrollBox: TScrollBox
    Left = 8
    Top = 8
    Width = 468
    Height = 481
    HorzScrollBar.Visible = False
    TabOrder = 0
    object lblRestartHint: TLabel
      Left = 0
      Top = 548
      Width = 447
      Height = 30
      Align = alTop
      Caption = 
        #1048#1079#1084#1077#1085#1077#1085#1080#1103' HTTP-'#1087#1086#1088#1090#1072', '#1087#1072#1088#1072#1084#1077#1090#1088#1086#1074' COM '#1080' '#1088#1077#1078#1080#1084#1072' '#1101#1084#1091#1083#1103#1094#1080#1080' '#1074#1089#1090#1091#1087#1103#1090' '#1074 +
        ' '#1089#1080#1083#1091' '#1087#1086#1089#1083#1077' '#1087#1077#1088#1077#1079#1072#1087#1091#1089#1082#1072' '#1089#1077#1088#1074#1077#1088#1072'.'
      WordWrap = True
      ExplicitWidth = 435
    end
    object gbHttpServer: TGroupBox
      Left = 0
      Top = 0
      Width = 447
      Height = 57
      Align = alTop
      Caption = ' HTTP-'#1089#1077#1088#1074#1077#1088' '
      TabOrder = 0
      object lblHttpPort: TLabel
        Left = 16
        Top = 24
        Width = 31
        Height = 15
        Caption = #1055#1086#1088#1090':'
      end
      object seHttpPort: TSpinEdit
        Left = 88
        Top = 21
        Width = 81
        Height = 24
        MaxValue = 65535
        MinValue = 1
        TabOrder = 0
        Value = 2580
      end
    end
    object gbFRCash: TGroupBox
      Left = 0
      Top = 57
      Width = 447
      Height = 105
      Align = alTop
      Caption = ' '#1050#1050#1058' (FRCash) '
      TabOrder = 1
      object lblFrPort: TLabel
        Left = 16
        Top = 24
        Width = 62
        Height = 15
        Caption = 'COM-'#1087#1086#1088#1090':'
      end
      object lblFrBaud: TLabel
        Left = 16
        Top = 52
        Width = 55
        Height = 15
        Caption = #1057#1082#1086#1088#1086#1089#1090#1100':'
      end
      object lblFrPassword: TLabel
        Left = 16
        Top = 80
        Width = 45
        Height = 15
        Caption = #1055#1072#1088#1086#1083#1100':'
      end
      object seFrPort: TSpinEdit
        Left = 88
        Top = 21
        Width = 65
        Height = 24
        MaxValue = 256
        MinValue = 1
        TabOrder = 0
        Value = 1
      end
      object cbFrBaud: TComboBox
        Left = 88
        Top = 49
        Width = 145
        Height = 23
        Style = csDropDownList
        TabOrder = 1
      end
      object seFrPassword: TSpinEdit
        Left = 88
        Top = 77
        Width = 81
        Height = 24
        MaxValue = 999999
        MinValue = 0
        TabOrder = 2
        Value = 30
      end
    end
    object gbKKT: TGroupBox
      Left = 0
      Top = 162
      Width = 447
      Height = 201
      Align = alTop
      Caption = ' '#1069#1084#1091#1083#1103#1094#1080#1103' '#1050#1050#1058' '
      TabOrder = 2
      object chkEmulation: TCheckBox
        Left = 16
        Top = 20
        Width = 129
        Height = 17
        Caption = #1056#1077#1078#1080#1084' '#1101#1084#1091#1083#1103#1094#1080#1080
        TabOrder = 0
        OnClick = chkEmulationClick
      end
      object pnlEmulation: TPanel
        Left = 8
        Top = 43
        Width = 432
        Height = 150
        BevelOuter = bvNone
        TabOrder = 1
        object lblEmulatedSerial: TLabel
          Left = 8
          Top = 8
          Width = 100
          Height = 15
          Caption = #1057#1077#1088#1080#1081#1085#1099#1081' '#1085#1086#1084#1077#1088':'
        end
        object lblEmulatedInn: TLabel
          Left = 8
          Top = 36
          Width = 30
          Height = 15
          Caption = #1048#1053#1053':'
        end
        object lblEmulatedFnNumber: TLabel
          Left = 8
          Top = 64
          Width = 62
          Height = 15
          Caption = #1053#1086#1084#1077#1088' '#1060#1053':'
        end
        object lblEmulatedCheckNumber: TLabel
          Left = 8
          Top = 92
          Width = 69
          Height = 15
          Caption = #1053#1086#1084#1077#1088' '#1095#1077#1082#1072':'
        end
        object lblEmulatedSessionNumber: TLabel
          Left = 8
          Top = 120
          Width = 81
          Height = 15
          Caption = #1053#1086#1084#1077#1088' '#1089#1084#1077#1085#1099':'
        end
        object edEmulatedSerial: TEdit
          Left = 120
          Top = 5
          Width = 297
          Height = 23
          TabOrder = 0
        end
        object edEmulatedInn: TEdit
          Left = 120
          Top = 33
          Width = 177
          Height = 23
          TabOrder = 1
        end
        object edEmulatedFnNumber: TEdit
          Left = 120
          Top = 61
          Width = 297
          Height = 23
          TabOrder = 2
        end
        object seEmulatedCheckNumber: TSpinEdit
          Left = 120
          Top = 89
          Width = 121
          Height = 24
          MaxValue = 999999999
          MinValue = 0
          TabOrder = 3
          Value = 0
        end
        object seEmulatedSessionNumber: TSpinEdit
          Left = 120
          Top = 117
          Width = 121
          Height = 24
          MaxValue = 999999999
          MinValue = 0
          TabOrder = 4
          Value = 0
        end
      end
    end
    object gbLog: TGroupBox
      Left = 0
      Top = 363
      Width = 447
      Height = 185
      Align = alTop
      Caption = ' '#1051#1086#1075' '
      TabOrder = 3
      object lblLogUiMaxLines: TLabel
        Left = 16
        Top = 76
        Width = 107
        Height = 15
        Caption = #1052#1072#1082#1089'. '#1089#1090#1088#1086#1082' '#1074' '#1086#1082#1085#1077':'
      end
      object lblLogPath: TLabel
        Left = 16
        Top = 104
        Width = 60
        Height = 15
        Caption = #1060#1072#1081#1083' '#1083#1086#1075#1072':'
      end
      object lblLogLevel: TLabel
        Left = 16
        Top = 132
        Width = 49
        Height = 15
        Caption = #1059#1088#1086#1074#1077#1085#1100':'
      end
      object lblLogMaxBodyLen: TLabel
        Left = 16
        Top = 160
        Width = 131
        Height = 15
        Caption = #1052#1072#1082#1089'. '#1076#1083#1080#1085#1072' '#1090#1077#1083#1072' HTTP:'
      end
      object chkLogEnabled: TCheckBox
        Left = 16
        Top = 20
        Width = 113
        Height = 17
        Caption = #1047#1072#1087#1080#1089#1100' '#1074' '#1092#1072#1081#1083
        TabOrder = 0
      end
      object chkLogUiEnabled: TCheckBox
        Left = 16
        Top = 48
        Width = 113
        Height = 17
        Caption = #1042#1099#1074#1086#1076' '#1074' '#1086#1082#1085#1086
        TabOrder = 1
      end
      object seLogUiMaxLines: TSpinEdit
        Left = 168
        Top = 73
        Width = 97
        Height = 24
        MaxValue = 100000
        MinValue = 100
        TabOrder = 2
        Value = 2000
      end
      object edLogPath: TEdit
        Left = 168
        Top = 101
        Width = 217
        Height = 23
        TabOrder = 3
      end
      object btnBrowseLogPath: TButton
        Left = 391
        Top = 100
        Width = 41
        Height = 25
        Caption = '...'
        TabOrder = 4
        OnClick = btnBrowseLogPathClick
      end
      object cbLogLevel: TComboBox
        Left = 168
        Top = 129
        Width = 145
        Height = 23
        Style = csDropDownList
        TabOrder = 5
      end
      object seLogMaxBodyLen: TSpinEdit
        Left = 168
        Top = 157
        Width = 97
        Height = 24
        MaxValue = 1048576
        MinValue = 256
        TabOrder = 6
        Value = 4096
      end
    end
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 521
    Width = 484
    Height = 40
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 1
    object btnOk: TButton
      Left = 312
      Top = 8
      Width = 75
      Height = 25
      Caption = #1057#1086#1093#1088#1072#1085#1080#1090#1100
      Default = True
      ModalResult = 1
      TabOrder = 0
      OnClick = btnOkClick
    end
    object btnCancel: TButton
      Left = 393
      Top = 8
      Width = 75
      Height = 25
      Cancel = True
      Caption = #1054#1090#1084#1077#1085#1072
      ModalResult = 2
      TabOrder = 1
    end
  end
  object dlgSaveLog: TSaveDialog
    Filter = #1060#1072#1081#1083' '#1083#1086#1075#1072' (*.log)|*.log|'#1042#1089#1077' '#1092#1072#1081#1083#1099' (*.*)|*.*'
    Options = [ofOverwritePrompt, ofHideReadOnly, ofEnableSizing]
    Left = 40
    Top = 528
  end
end
