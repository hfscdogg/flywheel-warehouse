-- Query Table: Written Business SQL
-- Workspace: Zoho CRM Reports (769101000000007003), view id 769101000010678071
-- Folder: Zenatta. Rows at capture: 1,911
-- Extracted 2026-08-24 from Edit Query (full text)

SELECT
		 P."D&E Effective Date" as "Date",
		 P."ID" as "Potential ID",
		 P."Amount" as "Written Business"
FROM  "Potentials" AS  P
WHERE	 P."D&E Used?"  = 'Yes'
 AND	P."D&E Effective Date"  is not null
