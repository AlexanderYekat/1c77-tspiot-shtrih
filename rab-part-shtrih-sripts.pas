
	//создать объект драйвера
    ovObject := CreateOleObject('AddIn.DrvFR');
  
  //подлкючение
     try
       ovObject.ComNumber := ifMain.ReadInteger('FRCash', 'Port', 1);
       ovObject.BaudRate  := ifMain.ReadInteger('FRCash', 'Baud', 5);
       ovObject.Password  := ifMain.ReadInteger('FRCash', 'Password', 30);
       ovObject.Connect;
     finally
       sleep(100);
       if CheckFRResult(sOption) then
          Setup := True;
     end;
	 
	 
	 //отмена чека
	 ovObject.CancelCheck;
	 
	 //продолжить печать
	 ovObject.ContinuePrint;
	 
	 
	 //отрытие смены
     try
       ovObject.TableNumber := 2;
       ovObject.FieldNumber := 2;
       ovObject.RowNumber := 30;
       ovObject.ValueOfFieldString := sSysOpNm;
       ovObject.WriteTable;
     finally
       sfMF.AddSingleResultEvent(54, 56, 'Задано имя оператора.', '');
     end;

     try
       ovObject.TableNumber := 1;
       ovObject.FieldNumber := 6;
       ovObject.RowNumber := 1;
       ovObject.ValueOfFieldInteger := 0; //не открываем денежный ящик
       ovObject.WriteTable;
     finally
       sfMF.AddSingleResultEvent(54, 56, 'Не октрываем денежный ящик автоматически.', '');
     end;

     try
       ovObject.OpenSession;
     finally
       sfMF.AddSingleResultEvent(54, 56, 'Смена открыта.', '');
     end;
	 
	 
	 
	 //регистрация позии
       if not(returnCheck) then
        ovObject.CheckType := 0 //ошибка было 1, должно быть 0 исправлено 20220813 // ffd 1.05
       else
        ovObject.CheckType := 2;
		
       ovObject.StringForPrinting := sLine;
       ovObject.Quantity   := cQty;
       ovObject.Price      := cPrice;
       ovObject.Department := iDepartment;
       iLastDepartment := iDepartment;
       ovObject.Tax1 := iTaxIx;
       ovObject.Tax2 := 0;
       ovObject.Tax3 := 0;
       ovObject.Tax4 := 0;
       ovObject.PaymentTypeSign := 4;                                          // ffd 1.05 (полный расчёт)

       PredmRasch:=1;
       if not(excise) then begin
        if (datamatrix <> '') and (VersFFD12) then
         PredmRasch := 33;                                          // ffd 1.05 (товар)
       end
       else begin
        if (datamatrix <> '') and (VersFFD12) then
         PredmRasch := 31
        else
         PredmRasch := 2;                                          // ffd 1.05 (акцизный товар)
       end;
       ovObject.PaymentItemSign := PredmRasch;

       try
        ovObject.MeasureUnit:=0;
       except
       end;
       ovObject.FNOperation;

       if (datamatrix <> '') then begin
        MarkParsed:='01'+gtin+'21'+serial+tail;
        WriteAdvancedLogFile('Out', 'VersFFD12: '+BoolToStr(VersFFD12));
        if (rrRes.ReqId<>'') and VersFFD12 then begin
          strUUIDandTime:='UUID='+rrRes.ReqId+'&Time='+rrRes.ReqTimestamp;
          WriteLogFile('Тег 1265 (' + strUUIDandTime + ').');
          WriteAdvancedLogFile('Out', 'UUIDandTime: '+strUUIDandTime);
					//ovObject.TagNumber := 1260;
					//ovObject.TagType := 8; //STLV
					//tagID := ovObject.FNBeginSTLVTag();
						//ovObject.TagID := tagID;
						ovObject.TagNumber := 1262;
						ovObject.TagType := 7;
						ovObject.TagValueStr := '030';
            ovObject.FNSendTagOperation;
            WriteAdvancedLogFile('Out', '1262: 030');
            WriteAdvancedLogFile('Out', '1262: '+ovObject.ResultCodeDescription);
						//ovObject.FNAddTag();

						//ovObject.TagID := tagID;
						ovObject.TagNumber := 1263;
						ovObject.TagType := 7;
						ovObject.TagValueStr := '21.11.2023';
            ovObject.FNSendTagOperation;
            WriteAdvancedLogFile('Out', '1263: 21.11.2023');
            WriteAdvancedLogFile('Out', '1263: '+ovObject.ResultCodeDescription);
						//ovObject.FNAddTag();

						//ovObject.TagID := tagID;
						ovObject.TagNumber := 1264;
						ovObject.TagType := 7;
						ovObject.TagValueStr := '1944';
            ovObject.FNSendTagOperation;
            WriteAdvancedLogFile('Out', '1264: 1944');
            WriteAdvancedLogFile('Out', '1264: '+ovObject.ResultCodeDescription);
						//ovObject.FNAddTag();

						//ovObject.TagID := tagID;
						ovObject.TagNumber := 1265;
						ovObject.TagType := 7;
						ovObject.TagValueStr := strUUIDandTime;
            ovObject.FNSendTagOperation;
            WriteAdvancedLogFile('Out', '1265'+strUUIDandTime);
            WriteAdvancedLogFile('Out', '1265: '+ovObject.ResultCodeDescription);
						//ovObject.FNAddTag();
					//ovObject.FNSendSTLVTagOperation(); //FNSendSTLVTag
        end;
         WriteAdvancedLogFile('Out', 'FNSendItemBarcode: begin');
         ovObject.BarCode:=MarkParsed;
         ovObject.FNSendItemBarcode;
         WriteAdvancedLogFile('Out', 'FNSendItemBarcode: '+ovObject.ResultCodeDescription);
         WriteAdvancedLogFile('Out', 'FNSendItemBarcode: end');
		 
		 
		 //закрытие чека
     try                                                                       // Подытог
       ovObject.CheckSubTotal;
     finally
     end;

     if not CheckFRResult(':: CheckSubTotals inside CloseCheck ::') then
        Exit;

     try
       ovObject.StringForPrinting := '';
       ovObject.Summ1 := 0; ovObject.Summ2 := 0; ovObject.Summ3 := 0; ovObject.Summ4 := 0;
       ovObject.Summ5 := 0; ovObject.Summ6 := 0; ovObject.Summ7 := 0; ovObject.Summ8 := 0;
       ovObject.Summ9 := 0; ovObject.Summ10 := 0; ovObject.Summ11 := 0; ovObject.Summ12 := 0;
       ovObject.Summ13 := 0; ovObject.Summ14 := 0; ovObject.Summ15 := 0; ovObject.Summ16 := 0;
       case TPayment of
          0,1: ovObject.Summ1 := cSum;
          2: ovObject.Summ2 := cSum;
          3: ovObject.Summ3 := cSum;
          4: ovObject.Summ4 := cSum;
       end;
       ovObject.DiscountOnCheck := 0;
       ovObject.TaxValue1 := 0;
       ovObject.TaxValue2 := 0;
       ovObject.TaxValue3 := 0;
       ovObject.TaxValue4 := 0;
       ovObject.TaxValue5 := 0;
       ovObject.TaxValue6 := 0;

//       if (slDepart2Tax.IndexOf(IntToStr(iLastDepartment)) > 0) then begin
       ovObject.TaxType := ifSetup.ReadInteger('TaxType', IntToStr(iLastDepartment), 1);
//       slDepart2Tax
//       end else begin
//            := 1;
//       end;
       //ovObject.CloseCheck;
       ovObject.FNCloseCheckEx;                                                // ffd 1.05
       if openDrawerB then
         OpenDrawer;
     finally
       if CheckFRAdvancedMode(100, sOption) then begin                         // проверка обрыв бумаги ?????
          iLastNDoc := ovObject.OpenDocumentNumber;
          CloseCheck := True;
       end;
     end;
		 
		 
		 
		 
function TVariantPrint.FNSendCashFam(sLine: string): Bool;
const sOption: string = ':: Cashir ::';
begin
  FNSendCashFam := False;

     try
       ovObject.TagNumber := 1021;
       ovObject.TagType := 7;
       ovObject.TagValueStr := sLine;
       ovObject.FNSendTag;
     finally
     end;

     if not CheckFRResult(sOption) then
        Exit;

     FNSendCashFam := True;
end;
		 
		 
		 
		 
		 //x-отчёты
		 ovObject.PrintReportWithoutCleaning;
		 
		 /z-отчёты
		 ovObject.PrintReportWithCleaning;
		 
		 
		 //печать строки
	   ovObject.StringForPrinting := sLine;
       ovObject.PrintString;

//отключиться
ovObject.Disconnect;