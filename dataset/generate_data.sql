-- Defaults to 10,000 rows; the launcher may set transaction_count first.
CREATE TABLE cafe_sales AS
WITH sales AS (
    SELECT i AS sale_id, ((i * 17) % 7)::INTEGER AS item_index,
           (((i * 13) % 5) + 1)::INTEGER AS quantity
    FROM range(COALESCE(getvariable('transaction_count')::BIGINT, 10000)) AS t(i)
)
SELECT sale_id,
       CASE item_index
           WHEN 0 THEN 'Coffee' WHEN 1 THEN 'Latte' WHEN 2 THEN 'Tea'
           WHEN 3 THEN 'Muffin' WHEN 4 THEN 'Sandwich'
           WHEN 5 THEN 'Cookie' ELSE 'Juice'
       END AS item,
       quantity,
       (CASE item_index
           WHEN 0 THEN 3.00 WHEN 1 THEN 5.25 WHEN 2 THEN 3.50
           WHEN 3 THEN 4.25 WHEN 4 THEN 8.75
           WHEN 5 THEN 2.50 ELSE 4.50
       END)::DECIMAL(8, 2) AS unit_price
FROM sales;
