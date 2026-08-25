-- Query Table: Subscription Churn Last 12 Months (Weekly)
-- Workspace: Zoho CRM Reports (769101000000007003), view id 769101000007614002
-- Folder: Zenatta. Rows at capture: 158
-- Extracted 2026-08-24 from Edit Query (full text)

SELECT
		 DD."Date" as 'Date',
		 abs_week(DD."Date") as 'Week',
		 to_percentage(100 * count_if(S."Expired Date"  is not null) / COUNT(S."Subscription ID")) as 'Churn Rate',
		 count_if(S."Expired Date"  is not null) as 'Expired Subs',
		 COUNT(S."Subscription ID") as 'Live Subs'
FROM  "Date Dimension" AS  DD
LEFT JOIN "Subscriptions (Zoho Finance)" AS  S ON DD."Date"  >= S."Start Date"
	 AND	(DD."Date"  <= add_months(S."Expired Date", 12)
	 OR	S."Expired Date"  IS NULL)
WHERE	 DD."Weekday"  = 7
 AND	add_month(Today(), -36)  <= DD."Date"
 AND	add_date(Today(), 6)  >= DD."Date"
GROUP BY  DD."Date"
ORDER BY DD."Date" DESC
