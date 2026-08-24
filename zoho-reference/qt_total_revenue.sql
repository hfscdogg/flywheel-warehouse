-- Query Table: Total Revenue
-- Workspace: Zoho CRM Reports (769101000000007003), view id 769101000010672002
-- Folder: Zenatta
-- Extracted 2026-08-24 from Edit Query (full text)

SELECT
		 DD."Date" as 'Date',
		 P."ID" as 'Deal ID',
		 P."Stage" as 'Stage',
		 P."Potential Name" as 'Potential Name',
		 P."Amount" as 'Total Revenue',
		 P."Probability (%)" as 'Probability (%)'
FROM  "Date Dimension" AS  DD
LEFT JOIN "Potentials" AS  P ON date(P."Closing Date")  = DD."Date"
WHERE	 P."Probability (%)"  = 100
 AND	P."Test Record"  = false
 AND	add_month(today(), -18)  <= DD."Date"
 AND	add_date(Today(), 0)  >= DD."Date"
