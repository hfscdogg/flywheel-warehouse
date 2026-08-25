# Formula Columns & Aggregate Formulas — by base table

Workspace: Zoho CRM Reports (769101000000007003). Extracted 2026-08-24 from each table's Add → Edit Formulas dialog (full text via DOM). Zoho renders "=", "&" normally — nothing altered.

## Total Revenue (query table)

- Formula columns: none
- Aggregate formulas: none

## Weekly Expected Revenue by Potential (query table)

Formula columns: none (all derived columns are defined inside the SQL — see qt_weekly_expected_revenue_by_potential.sql).

Aggregate formulas (15):

| Name | Formula |
|---|---|
| Weekly Sales Revenue | `SUM_IF("Weekly Expected Revenue by Potential"."Probability %" = 100,"Weekly Expected Revenue by Potential"."Yearly Accrued Revenue",0)` |
| Weekly L4B Revenue | `SUM_IF("Weekly Expected Revenue by Potential"."Probability %" = 100,"Weekly Expected Revenue by Potential"."Yearly Accrued L4B Revenue",0)` |
| Weekly AVG Sales | `sum_if("Weekly Expected Revenue by Potential"."Probability %" = 100,"Weekly Expected Revenue by Potential"."Yearly Accrued Revenue"/week("Weekly Expected Revenue by Potential"."Date"),0)` |
| Week Number | `week(max("Weekly Expected Revenue by Potential"."Date"))` |
| Sales Run-Rate Annualized | `52*"Weekly Expected Revenue by Potential"."Weekly AVG Sales"` |
| Weekly AVG L4B Sales | `sum_if("Weekly Expected Revenue by Potential"."Probability %" = 100,"Weekly Expected Revenue by Potential"."Yearly Accrued L4B Revenue"/week("Weekly Expected Revenue by Potential"."Date"),0)` |
| L4B Run-Rate Annualized | `52*"Weekly Expected Revenue by Potential"."Weekly AVG L4B Sales"` |
| Projects Completed on Time % | `100*COUNT_IF("Weekly Expected Revenue by Potential"."Completed on Time" = 'On Time')/COUNT("Weekly Expected Revenue by Potential"."Completed on Time")` |
| RMR Sales Run Rate % | `100*count_if("Weekly Expected Revenue by Potential"."RMR Deal?" = 'Yes')/COUNT("Weekly Expected Revenue by Potential"."RMR Deal?")` |
| Packaged Projects % | `round(100*(count_if("Weekly Expected Revenue by Potential"."Probability %" = 100 AND "Weekly Expected Revenue by Potential"."Expected Revenue" >= 221 AND "Weekly Expected Revenue by Potential"."Packaged Deal?" = true)/(count_if("Weekly Expected Revenue by Potential"."Probability %" = 100 AND "Weekly Expected Revenue by Potential"."Expected Revenue" >= 221 AND "Weekly Expected Revenue by Potential"."Closing Week" = "Weekly Expected Revenue by Potential"."Week"))),2)` |
| Actual vs Billed Hours % | `100*SUM("Weekly Expected Revenue by Potential"."Total Hours Spent")/SUM("Weekly Expected Revenue by Potential"."FO Hours Sold")` |
| RMR Sales Run-Rate | `100*(count_if("Weekly Expected Revenue by Potential"."RMR Deal?" = 'Yes')/MAX(week("Weekly Expected Revenue by Potential"."Date"))*52/12)/28` |
| Week Of Year | `MAX(week("Weekly Expected Revenue by Potential"."Date"))` |
| No. of RMR Deals | `count_if("Weekly Expected Revenue by Potential"."RMR Deal?" = 'Yes')` |
| No. of RMR Weekly Deals | `count_if("Weekly Expected Revenue by Potential"."Weekly RMR Deal?" = 'Yes')` |

## Written Business SQL (query table)

- Formula columns: none
- Aggregate formulas: none

## Stamped Weekly Expected Revenue by Potential Data (regular/imported table, 204 rows)

Snapshot table (columns: Date, Projects completed on time %, Actual vs. Billed Hours %) — appears to be periodically stamped output of the Weekly Expected Revenue aggregates.
- Formula columns: none
- Aggregate formulas: none
- Bucket columns: none

## Sales Trackers (regular table, Zoho CRM Modules (Data) folder)

Formula columns (6):

| Name | Formula |
|---|---|
| Written Business Commitment | `to_currency(if_null(to_decimal(replace(replace(replace(replace("Ketra Experience Center Appointment Commitment",',',''),'$',''),'USD',''),' ','')),0))` |
| Networking+Prospecting Commitment | `if_null(to_decimal("Networking + Prospecting Commitment"),0.0)+if_null(to_decimal("PROSPECTING MEETINGS COMMITMENT"),0.0)` |
| Networking+Prospecting Actual | `if_null(to_decimal("Networking + Prospecting Actual"),0.0)+if_null(to_decimal("PROSPECTING MEETINGS ACTUAL"),0.0)` |
| LightSource Referrals Number | `if_null(to_integer("LightSource Referrals"),0)` |
| LightSource Referrals Actual Number | `if_null(to_integer("LightSource Referrals Actual"),0)` |
| Pipeline Goal $ | `to_currency(if_null(to_integer( "Pipeline Goal (Expected Revenue)"),0))` |

Aggregate formulas: none. ("Consults Actual" used by the dashboard is a plain data column in this table.)

## Date Dimension (regular/imported table)

- Formula columns: none
- Aggregate formulas: none

## Subscriptions (Zoho Finance) (synced table — Zoho Subscription connector)

Formula columns (4):

| Name | Formula |
|---|---|
| Expired Date | `If("Subscription Status" in ('expired'),"Expiry Date","Cancelled Date")` |
| Period Active in Months | `dateandtimediff(MONTH,"Created Date",ifnull("Expired Date",now()))` |
| Cancelled/Expired Date | `If("Subscription Status" in ('expired'),"Expiry Date","Cancelled Date")` |
| Subscription Link | `concat('https://subscriptions.zoho.com/app/42411013#/subscriptions/',"Subscription ID")` |

Aggregate formulas (4):

| Name | Formula |
|---|---|
| Active Subscriptions | `Countif("Subscriptions (Zoho Finance)"."Subscription Status" = 'live')` |
| Churns | `countif("Subscriptions (Zoho Finance)"."Expired Date" is not null )` |
| Cancelled Subscriptions | `countif("Subscriptions (Zoho Finance)"."Subscription Status" in ('cancelled','expired'))` |
| Churn Rate | `100*countif("Subscriptions (Zoho Finance)"."Expired Date" is not null )/(countif("Subscriptions (Zoho Finance)"."Expired Date" is not null )+Countif("Subscriptions (Zoho Finance)"."Subscription Status" = 'live'))` |

## Invoices (Zoho Finance) (synced table — Zoho Books/Invoice connector; ~60,470 rows)

Formula columns (5):

| Name | Formula |
|---|---|
| Discount Amount | `("Sub Total (BCY)"*"Discount (%)")/100` |
| Age In Days | `datediff(now(),"Invoice Date")` |
| Age Tier | `if( "Age in Days" >= 0, if( "Age in Days" <= 20, '1. 0 - 30 days', if( "Age in Days" <= 60, '2. 31 - 60 days', if( "Age in Days" <= 90, '3. 61 - 90 days', if( "Age in Days" <= 180, '4. 91 - 180 days','5. Above 180 days')))), '6. Negative - Not Valid')` |
| Type | `If("Subscription ID",'Subscription','Invoice')` |
| Status | `If((Datediff("Due Date",current_date())) < 0 and "Invoice Status" in ('Open','Overdue','Partially Paid'),'Overdue',"Invoice Status")` |

Aggregate formulas (24):

| Name | Formula |
|---|---|
| Paid Invoice Value | `sumif("Invoices (Zoho Finance)"."Invoice Status" = 'Closed',"Invoices (Zoho Finance)"."Total (BCY)")` |
| Avg Sales Value | `sum("Invoices (Zoho Finance)"."Total (BCY)")/count(DISTINCT((((((("Invoices (Zoho Finance)"."Invoice ID"))))))))` |
| Pending Receivables | `sumif("Invoices (Zoho Finance)"."Invoice Status" = 'AUTHORISED',"Invoices (Zoho Finance)"."Total (BCY)")` |
| Revenue from New Subscriptions | `sumIf(month("Subscriptions (Zoho Finance)"."Start Date") = month("Invoices (Zoho Finance)"."Invoice Date") AND Year("Subscriptions (Zoho Finance)"."Start Date") = year("Invoices (Zoho Finance)"."Invoice Date") AND "Invoices (Zoho Finance)"."Invoice Status" not in ('Void','Draft'),ifnull("Invoices (Zoho Finance)"."Sub Total (BCY)",0),0)` |
| Unpaid Invoice Count | `Countif("Invoices (Zoho Finance)"."Type" = 'Subscription' AND "Invoices (Zoho Finance)"."Invoice Status" = 'Overdue')` |
| Average LTV | `Avgif(("Subscriptions (Zoho Finance)"."Expired Date" is not null  AND "Invoices (Zoho Finance)"."Type" = 'Subscription'),"Invoices (Zoho Finance)"."Sub Total (BCY)",0)` |
| Revenue from Subscriptions | `Sumif("Invoices (Zoho Finance)"."Subscription ID" is not null  AND "Invoices (Zoho Finance)"."Invoice Status" not in ('Draft','Void'),(Ifnull("Invoices (Zoho Finance)"."Sub Total (BCY)",0)),0)` |
| Revenue from Existing Subscriptions | `"Invoices (Zoho Finance)"."Revenue from Subscriptions"-"Invoices (Zoho Finance)"."Revenue from New Subscriptions"` |
| ARPU | `"Invoices (Zoho Finance)"."Revenue from Subscriptions"/distinctcount("Subscriptions (Zoho Finance)"."Customer ID")` |
| LTV | `Sumif("Subscriptions (Zoho Finance)"."Expired Date" is not null  AND "Invoices (Zoho Finance)"."Invoice Status" not in ('Void','Draft'),"Invoices (Zoho Finance)"."Sub Total (BCY)",0)` |
| YTD Revenue | `YTD(sumif("Invoices (Zoho Finance)"."Type" in ('Subscription'),Ifnull("Invoices (Zoho Finance)"."Sub Total (BCY)",0),0),"Invoices (Zoho Finance)"."Invoice Date")` |
| New Subscriptions | `countif(month("Subscriptions (Zoho Finance)"."Start Date") = month("Invoices (Zoho Finance)"."Invoice Date") AND Year("Subscriptions (Zoho Finance)"."Start Date") = year("Invoices (Zoho Finance)"."Invoice Date") AND "Invoices (Zoho Finance)"."Type" in ('Subscription'))` |
| Open Invoices Value | `sumif("Invoices (Zoho Finance)"."Invoice Status" = 'Open',"Invoices (Zoho Finance)"."Total (BCY)")` |
| Paid Invoices Count | `countif("Invoices (Zoho Finance)"."Invoice Status" = 'Closed')` |
| Open Invoices Count | `countif("Invoices (Zoho Finance)"."Invoice Status" = 'Open')` |
| YTD Invoices Count | `ytd(count("Invoices (Zoho Finance)"."Invoice ID"),"Invoices (Zoho Finance)"."Invoice Date")` |
| MTD Invoices Count | `mtd(count("Invoices (Zoho Finance)"."Invoice ID"),"Invoices (Zoho Finance)"."Invoice Date")` |
| YTD Invoice Value | `ytd(sum("Invoices (Zoho Finance)"."Total (BCY)"),"Invoices (Zoho Finance)"."Invoice Date")` |
| MTD Invoice Value | `mtd(sum("Invoices (Zoho Finance)"."Total (BCY)"),"Invoices (Zoho Finance)"."Invoice Date")` |
| MTD Sales Order Value | `mtd(Sum("Invoices (Zoho Finance)"."Total (BCY)"),"Invoices (Zoho Finance)"."Invoice Date")` |
| YTD Sales order count | `ytd(Count("Invoices (Zoho Finance)"."Invoice ID"),"Invoices (Zoho Finance)"."Invoice Date")` |
| Closed Invoices Count | `Countif("Invoices (Zoho Finance)"."Invoice Status" = 'Closed')` |
| Invoice Overdue Count | `countif("Invoices (Zoho Finance)"."Invoice Status" = 'Overdue')` |
| Invoice Overdue Amount | `Sumif("Invoices (Zoho Finance)"."Invoice Status" = 'Overdue',"Invoices (Zoho Finance)"."Total (BCY)",0)` |

## Potentials (synced table — Zoho CRM Potentials/Deals module)

Formula columns (18):

| Name | Formula |
|---|---|
| Forecast Type | `if("Stage" in ('RFP Sent','Closed Won','Closed Won - Service','Closed Won - Design Retainer','Closed Won - Not Ready','Change Order','Tentatively Scheduled','Rough-In','Rough-In Scheduled','Rough-In Complete','Trim-Out','Trim Out Scheduled','Trim-Out Complete','Finish-Out','Finish Out Scheduled','Finish-Out Complete','Punch Out','Punch Out Scheduled','Service Call Scheduled','Service Call Complete','Installation Complete'),'Won',if("Stage" in ('Closed Lost to Competition','Client decided not to do work','Client in holding pattern','Closed Lost - Unable to Contact'),'Lost','Open'))` |
| Age in Days | `datediff(ifnull("Closing Date",now()),"Created Time")` |
| Age Tier | `if( "Age in Days" >= 0, if( "Age in Days" <= 60, '1. 0 - 60 days', if( "Age in Days" <= 120, '2. 61 - 120 days', if( "Age in Days" <= 180, '3. 121 - 180 days', if( "Age in Days" <= 360, '4. 181 - 360 days','5. Above 360 days')))), '6. Negative - Not Valid')` |
| Amount Tier | `if( "Amount" >= 0, if( "Amount" <= 10000, '1. 0 - $10K', if( "Amount" <= 20000, '2. $10,001 - $20K', if( "Amount" <= 30000, '3. $20,001 - $30K', if( "Amount" <= 40000, '4. $30,001 - $40K','5. Above 40K')))), '6. Negative - Not Valid')` |
| Pipeline in labor hours | `if("Probability (%)"<100,("Expected Revenue" *0.3 / 100),0)` |
| Activities Involved | `to_decision_box(if("Tasks Involved"=1 OR "Events Involved"=1 OR "Calls Involved"=1, 'Yes', 'No'))` |
| Tasks Only | `if(("Tasks Involved"=1) & ("Events Involved"=0) & ("Calls Involved")=0,1,0)` |
| Events Only | `if(("Tasks Involved"=0) & ("Events Involved"=1) & ("Calls Involved"=0),1,0)` |
| Calls Only | `if(("Tasks Involved"=0) & ("Events Involved"=0) & ("Calls Involved"=1),1,0)` |
| Won Commercial Amount | `if("Potentials"."Forecast Type" = 'Won' and "Potentials"."Commercial?" = 'Yes',"Potentials"."Amount",0)` |
| Total Man Days | `ceil("FO Hours Sold"/find_max_value(1,if_null(to_integer(substring_before("Labor Needed",' Man')),1))/8)` |
| RMR Deal | `IF("Probability (%)" = 100 AND ("Alarm Monitoring Plan" LIKE '%$%' OR "Pick Service Plan" LIKE '%$%' OR "Pick Service Plan" LIKE '%Prepaid%' ),'Yes','No')` |
| Link | `concat('https://crm.zoho.com/crm/org2701844/tab/Potentials/',"Id")` |
| Won Amount2 | `if("Potentials"."Forecast Type" = 'Won',"Potentials"."Amount",0)` |
| D&E Effective Date | `if( "D&E Completed" is not null, "D&E Completed", "D&E Complete Date" )` |
| Last 3 years | `if("Created Time" >= adddate(now(), -1095), 'Yes', 'No')` |
| Created Year | `year("Created Time")` |
| Marketing Pipeline Amount | `IF(UPPER(IFNULL(TRIM("Marketing Channel"),'NONE')) IN ('GOOGLE ADS (PAID)','GOOGLE LSA (PAID)','GOOGLE/BING ORGANIC','GOOGLE BUSINESS PROFILE','HOUZZ','EMAIL/NEWSLETTER','WEBSITE INQUIRY','DIRECT (PHONE/WALK-IN)'), "Amount", 0)` |

Aggregate formulas (40):

| Name | Formula |
|---|---|
| Won vs Expected Revenue % | `sumif("Potentials"."Forecast Type" = 'Won',"Potentials"."Amount")*100/sum("Potentials"."Expected Revenue")` |
| Lost Deals Count | `count(if("Potentials"."Forecast Type" = 'Lost',"Potentials"."Id",NULL))` |
| Won Deals Count | `count(if("Potentials"."Forecast Type" = 'Won',"Potentials"."Id",NULL))` |
| Win Rate % | `count(if("Potentials"."Forecast Type" = 'Won',"Potentials"."Id",NULL))*100/count(if("Potentials"."Forecast Type" in ('Won','Lost'),"Potentials"."Id",NULL))` |
| Won Amount | `sumif("Potentials"."Forecast Type" = 'Won',"Potentials"."Amount")` |
| Avg Deal Size Won | `avgif("Potentials"."Forecast Type" = 'Won',"Potentials"."Amount",NULL)` |
| Avg Sales Cycle | `avgif("Potentials"."Forecast Type" IN ('Won','Lost'),"Potentials"."Age in Days")` |
| Lost Amount | `sumif("Potentials"."Forecast Type" = 'Lost',"Potentials"."Amount")` |
| Open Deals Count | `count(if("Potentials"."Forecast Type" = 'Open',"Potentials"."Id",NULL))` |
| Predicted Pipeline Revenue | `"Potentials"."Predicted New Deals Count Next 90 Days"*"Potentials"."Avg Deal Size Last 365 Days"` |
| Predicted New Business - Next 3 Months | `("Potentials"."Win Rate Percentage Last 365 Days11"/100)*("Potentials"."Avg Deal Size Last 365 Days")*(("Potentials"."Potentials Created Last 365 Days"*90)/365)` |
| Loss Rate % | `count(if("Potentials"."Forecast Type" = 'Lost',"Potentials"."Id",NULL))*100/count(if("Potentials"."Forecast Type" IN ('Won','Lost'),"Potentials"."Id",NULL))` |
| Won Deals Count Last 365 Days | `count(if("Potentials"."Forecast Type" = 'Won' AND "Potentials"."Closing Date" > subdate(now(),'365'),"Potentials"."Id",NULL))` |
| Lost Deals Count Last 365 Days | `count(if("Potentials"."Forecast Type" = 'Won' AND "Potentials"."Closing Date" > subdate(now(),'365'),"Potentials"."Id",NULL))`  ⚠ note: formula counts 'Won', not 'Lost' — as stored in Zoho |
| Open Deals Count Next 90 Days | `count(if("Potentials"."Forecast Type" = 'Open' AND "Potentials"."Closing Date" >= now() AND "Potentials"."Closing Date" < adddate(now(),90),"Potentials"."Id",NULL))` |
| Avg Deal Size Last 365 Days | `avgif("Potentials"."Forecast Type" = 'Won' AND "Potentials"."Closing Date" > subdate(now(),'365'),"Potentials"."Amount")` |
| Win Rate Percentage Last 365 Days11 | `("Potentials"."Won Deals Count Last 365 Days"*100)/("Potentials"."Won Deals Count Last 365 Days"+"Potentials"."Lost Deals Count Last 365 Days")` |
| Win Rate Percentage Last 365 Days | `("Potentials"."Won Deals Count Last 365 Days"*100)/("Potentials"."Won Deals Count Last 365 Days"+"Potentials"."Lost Deals Count Last 365 Days")` |
| Predicted New Deals Count Next 90 Days | `("Potentials"."Win Rate Percentage Last 365 Days11"/100)*"Potentials"."Open Deals Count Next 90 Days"` |
| Potentials Created Last 365 Days | `count(if("Potentials"."Created Time" > subdate(now(),365),"Potentials"."Id",NULL))` |
| Activities count | `countif(("Potentials"."Activities Involved" = 1))` |
| Activities done % for Potentials | `(countif(("Potentials"."Activities Involved" = 1))/count("Potentials"."Id"))*100` |
| Potentials without Activities | `countif(("Potentials"."Activities Involved" = 0))` |
| Tasks Only % | `(countif(("Potentials"."Tasks Only" = 1) AND ("Potentials"."Forecast Type" = 'Won'))/countif("Potentials"."Tasks Only" = 1))*100` |
| Events Only % | `(countif(("Potentials"."Events Only" = 1) AND ("Potentials"."Forecast Type" = 'Won'))/countif(("Potentials"."Events Only" = 1)))*100` |
| Calls Only % | `(countif(("Potentials"."Calls Only" = 1) AND ("Potentials"."Forecast Type" = 'Won'))/countif(("Potentials"."Calls Only" = 1)))*100` |
| Combined Activities % | `(countif(("Potentials"."Activities Involved" = 1) AND ("Potentials"."Tasks Only" = 0) AND ("Potentials"."Events Only" = 0) AND ("Potentials"."Calls Only" = 0) AND ("Potentials"."Forecast Type" = 'Won'))/countif(("Potentials"."Activities Involved" = 1) AND ("Potentials"."Tasks Only" = 0) AND ("Potentials"."Events Only" = 0) AND ("Potentials"."Calls Only" = 0)))*100` |
| No Activities % | `(countif(("Potentials"."Activities Involved" = 0) AND ("Potentials"."Forecast Type" = 'Won'))/countif(("Potentials"."Activities Involved" = 0)))*100` |
| Conversion Rate | `count("Potentials"."Converted from Lead")*100/count("Leads"."Id")` |
| Avg days to convert a Lead | `sum(datediff("Potentials"."Created Time","Leads"."Created Time"))/count("Leads"."Id")` |
| Avg. time taken to convert a Lead to Potential | `sum(datediff("Potentials"."Created Time","Leads"."Created Time"))/count("Potentials"."Converted from Lead")` |
| Open Amount | `sumif("Potentials"."Forecast Type" = 'Open',"Potentials"."Amount")` |
| Avg. time taken to convert a Lead to Deals | `sum(datediff("Potentials"."Created Time","Leads"."Created Time"))/count("Potentials"."Converted from Lead")` |
| Package Ratio | `round(100*(count_if("Potentials"."Built Using Packages?" = true)/(count_if("Potentials"."Amount" > 160))),2)` |
| RMR Sales Run Rate | `(count_if(("Potentials"."Alarm Monitoring Plan" != 'Opt Out' or "Potentials"."Alarm Monitoring Plan" != null or "Potentials"."Alarm Monitoring Plan" != 'Existing Subscriber') and ("Potentials"."Pick Service Plan" != 'Opt Out' or "Potentials"."Pick Service Plan" != null or "Potentials"."Pick Service Plan" != 'Existing Subscriber')))/count_if("Potentials"."Forecast Type" = 'Won')*100` |
| Sales Run-Rate Annualized | `52*running_sum("Potentials"."Won Amount")/week(max("Potentials"."Created Time"))` |
| L4B Sales Annual Run-Rate | `sum_if("Potentials"."Commercial?" = 'Yes' and "Potentials"."Forecast Type" = 'Won',"Potentials"."Amount",0)` |
| L4B Sales Annual Run-Rate Annualized | `52*running_sum("Potentials"."L4B Sales Annual Run-Rate")/week(max("Potentials"."Created Time"))` |
| RMR Sales-Run Rate Last Week | `lag("Potentials"."RMR Sales Run Rate",1)` |
| Revenue | `sum("Potentials"."Amount")` |
