-- Query Table: Weekly Expected Revenue by Potential
-- Workspace: Zoho CRM Reports (769101000000007003), view id 769101000005302002
-- Folder: Zenatta. Rows at capture: ~354,647
-- Extracted 2026-08-24 from Edit Query (full text)

SELECT
		 DD."Date" as 'Date',
		 abs_week(DD."Date") as 'Week',
		 SH."Modified Week" as 'Modified Week',
		 SH."Probability (%)" as 'Probability %',
		 P."Id" as 'Potential ID',
		 P."Potential Owner Name" as 'Potential Owner',
		 P."Closing Date" as 'Closing Date',
		 abs_week(P."Closing Date") as 'Closing Week',
		 SH."Expected Revenue" as 'Expected Revenue',
		 SH."Id" as 'Stage History ID',
		 if(is_contains(SH."Stage", 'Closed Won')  = 1, SH."Amount", 0) as 'Closed Won Revenue',
		 if(SH."Probability (%)"  < 100, SH."Expected Revenue" * .33 / 100, NULL) as 'Pipeline Hours',
		 if(SH."Probability (%)"  < 100, SH."Expected Revenue", NULL) as 'Pipeline Hours Revenue',
		 if(SH."Probability (%)"  < 100
		 AND	P."Commercial?"  = 'Yes', SH."Expected Revenue", NULL) as 'L4B Pipeline Revenue',
		 P."Commercial?" as 'L4B',
		 IF(SH."Probability (%)"  = 100
		 AND	Year(DD."Date")  = Year(P."Closing Date")
		 AND	Week(DD."Date") - Week(P."Closing Date")  >= 0, SH."Expected Revenue", NULL) as 'Yearly Accrued Revenue',
		 IF(SH."Probability (%)"  = 100
		 AND	Year(DD."Date")  = Year(P."Closing Date")
		 AND	Week(DD."Date") - Week(P."Closing Date")  >= 0
		 AND	P."Commercial?"  = 'Yes', SH."Expected Revenue", NULL) as 'Yearly Accrued L4B Revenue',
		 (1 + (52 * (Year(DD."Date") -Year(P."Closing Date"))) + (Week(DD."Date") -Week(P."Closing Date"))) as 'Denominator',
		 IF(SH."Probability (%)"  = 100
		 AND	(DD."Date"  >= P."Closing Date"
		 AND	DD."Date"  <= add_date(P."Closing Date", 6))
		 AND	P."Commercial?"  = 'Yes', SH."Expected Revenue", NULL) as 'Yearly Week L4B Revenue',
		 P."Total Man Days" as 'Expected Man Days',
		 M."Days Spent" as 'Total Days Spent',
		 IF(P."Total Man Days"  >= M."Days Spent", 'On Time', concat('Spent ', M."Days Spent" -P."Total Man Days", ' days more')) as 'Completed on Time',
		 IF(abs_week(DD."Date")  = abs_week(M."Latest Meeting")
		 AND	P."Probability (%)"  = 100, P."FO Hours Sold", NULL) as 'FO Hours Sold',
		 M."Total Time Spent" as 'Total Hours Spent',
		 M."Latest Meeting" as 'Latest Meeting',
		 IF(abs_week(DD."Date")  = abs_week(P."Closing Date"), P."RMR Deal", NULL) as 'Weekly RMR Deal?',
		 IF(abs_week(DD."Date")  = abs_week(P."D&E Complete Date")
		 AND	P."D&E Used?"  = 'Yes', P."Amount", NULL) as 'Written Business',
		 abs_week(P."D&E Complete Date"),
		 abs_week(DD."Date"),
		 IF(year_week(DD."Date")  >= year_week(P."Closing Date")
		 AND	YEAR(DD."Date")  = YEAR(P."Closing Date"), P."RMR Deal", NULL) as 'RMR Deal?',
		 IF(year_week(DD."Date")  = year_week(P."Closing Date"), P."Built Using Packages?", NULL) as 'Packaged Deal?'
FROM  "Date Dimension" AS  DD
LEFT JOIN "Potentials" AS  P ON date(P."Created Time")  <= DD."Date"
LEFT JOIN(	SELECT
			 *,
			 abs_week("Modified Time") as 'Modified Week',
			 ROW_NUMBER() OVER(PARTITION BY "Potential Name" , abs_week("Modified Time")  ORDER BY "Modified Time" DESC ) as 'Week Row Number',
			 FIRST_VALUE("Modified Time") OVER(PARTITION BY "Potential Name"  ORDER BY "Modified Time" DESC ) as 'Last Modified Time',
			 LEAD("Modified Time") OVER(PARTITION BY "Potential Name"  ORDER BY "Modified Time" ) as 'Next Transition Time',
			 ROW_NUMBER() OVER(PARTITION BY "Potential Name"  ORDER BY "Modified Time" DESC ) as 'Potential Row Number'
	FROM  "Stage History"
) AS  SH ON (((date(SH."Modified Time")  <= DD."Date"
	 AND	add_date(date(SH."Next Transition Time"), 0)  >= DD."Date")
	 AND	SH."Week Row Number"  = 1)
	 OR	(DD."Date"  > date(SH."Last Modified Time")
	 AND	SH."Potential Row Number"  = 1
	 AND	SH."Probability (%)"  <= 100))
	 AND	SH."Potential Name"  = P."Id"
LEFT JOIN(	SELECT
			 COALESCE("POTENTIALID", "Related To") as 'Potential ID',
			 COUNT_DISTINCT(DATE("From")) as 'Days Spent',
			 CEIL(SUM("Duration (Man Hrs)")) as 'Total Time Spent',
			 MAX("To") as 'Latest Meeting',
			 MIN("From") as 'First Meeting'
	FROM  "Meetings"
	WHERE	 ("POTENTIALID"  IS NOT NULL
	 OR	("Related To"  IS NOT NULL
	 AND	"SEMODULE"  = 'Deals'))
	 AND	"Event Type"  IN ( 'Install - Warranty / Punchout'  , ' Finish Out'  , 'Finish-Out ($$$)'  )
	 AND	"Event Status"  IN ( 'Ready to Bill'  , 'Complete'  )
	GROUP BY  COALESCE("POTENTIALID", "Related To")
) AS  M ON M."Potential ID"  = P."Id"
	 AND	abs_week(DD."Date")  = abs_week(M."Latest Meeting")
WHERE	 DD."Weekday"  = 7
 AND	add_month(today(), -18)  <= DD."Date"
 AND	add_date(Today(), 6)  >= DD."Date"
 AND	SH."Probability (%)"  > 0
 AND	Year(P."Created Time")  >= (Year(TODAY()) -3)
ORDER BY DD."Date" DESC
