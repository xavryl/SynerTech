-- =====================================================================
-- Walkthrough: run after schema.sql on a fresh database.
--   1. stock-in from a supplier
--   2. Senior Citizen sale (20% VAT-exempt + 5% basic necessity)
--   3. regular sale of a fractional item (2.5 m of wire)
--   4. refund return
--   5. exchange return
-- Line amounts are what the app would compute (see schema.sql header).
-- Each step is wrapped in a transaction so it saves all-or-nothing.
-- =====================================================================

PRAGMA foreign_keys = ON;

-- ---- setup ---------------------------------------------------------

INSERT INTO employees (employee_id, full_name, role, pin_hash) VALUES
    (1, 'Clerk One',   'clerk',   '<hash>'),
    (2, 'Cashier One', 'cashier', '<hash>'),
    (3, 'Manager One', 'manager', '<hash>');

INSERT INTO categories (category_id, name) VALUES
    (1, 'Medicine'), (2, 'Grocery'), (3, 'Electrical');

INSERT INTO suppliers (supplier_id, name) VALUES (1, 'Main Distributor');

INSERT INTO products
    (product_id, sku, barcode, name, category_id, supplier_id, unit,
     allow_fractional, price_cents, cost_cents, vat_status, discount_class, reorder_milli)
VALUES
    (1, 'MED-0001', '4800000000011', 'Paracetamol 500mg (box of 20)', 1, 1, 'box', 0, 11200, 8000, 'vatable', 'sc_pwd',          5000),
    (2, 'GRO-0001', NULL,            'Rice, regular milled',          2, 1, 'kg',  1,  5600, 4500, 'exempt',  'basic_necessity', 20000),
    (3, 'ELE-0001', NULL,            'THHN wire #14',                 3, 1, 'm',   1,  3500, 2200, 'vatable', 'none',            50000),
    (4, 'ELE-0002', '4800000000028', 'Electrical tape',               3, 1, 'pc',  0,  3500, 2000, 'vatable', 'none',            5000);

-- ---- 1. stock-in -----------------------------------------------------

BEGIN;
INSERT INTO stock_movements (product_id, qty_milli, reason, supplier_id, unit_cost_cents, employee_id) VALUES
    (1,  10000, 'stock_in', 1, 8000, 3),   -- 10 boxes
    (2,  50000, 'stock_in', 1, 4500, 3),   -- 50 kg
    (3, 100000, 'stock_in', 1, 2200, 3),   -- 100 m
    (4,  10000, 'stock_in', 1, 2000, 3);   -- 10 pcs
COMMIT;

INSERT INTO shifts (shift_id, cashier_id, opening_cash_cents) VALUES (1, 2, 100000);

-- ---- 2. Senior Citizen sale -------------------------------------------
-- Clerk builds the order and checks the SC ID before printing the slip.
--   Paracetamol ×2: gross 22400 -> base 20000 (VAT removed 2400) -> 20% 4000 -> net 16000
--   Rice 2 kg:      gross 11200 -> exempt item, 5% 560                       -> net 10640
--   Amount due: 26640 (₱266.40)

BEGIN;
INSERT INTO transactions (transaction_id, clerk_id, beneficiary_type, beneficiary_id_no, beneficiary_name)
VALUES (1, 1, 'SC', 'SC-12345', 'Juan Dela Cruz');

INSERT INTO transaction_items
    (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment,
     discount_type_id, gross_cents, vat_removed_cents, discount_cents, net_cents, vat_cents)
VALUES
    (1, 1, 2000, 11200, 'exempt', (SELECT discount_type_id FROM discount_types WHERE code = 'SC_20'),
        22400, 2400, 4000, 16000, 0),
    (1, 2, 2000,  5600, 'exempt', (SELECT discount_type_id FROM discount_types WHERE code = 'SC_BN_5'),
        11200,    0,  560, 10640, 0);
COMMIT;

-- The slip shows live totals while pending:
SELECT 'slip #1' AS step, * FROM v_transaction_totals WHERE transaction_id = 1;

-- Cashier takes ₱300 cash and marks it paid.
BEGIN;
INSERT INTO payments (transaction_id, method, amount_cents, tendered_cents) VALUES (1, 'cash', 26640, 30000);
UPDATE transactions SET status = 'paid', cashier_id = 2, shift_id = 1 WHERE transaction_id = 1;
COMMIT;

-- ---- 3. regular sale, 2.5 m of wire -----------------------------------
--   gross 8750, vatable: VAT = 8750 - round(8750 / 1.12) = 8750 - 7813 = 937

BEGIN;
INSERT INTO transactions (transaction_id, clerk_id) VALUES (2, 1);
INSERT INTO transaction_items
    (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment,
     gross_cents, net_cents, vat_cents)
VALUES (2, 3, 2500, 3500, 'vatable', 8750, 8750, 937);
INSERT INTO payments (transaction_id, method, amount_cents, tendered_cents) VALUES (2, 'cash', 8750, 10000);
UPDATE transactions SET status = 'paid', cashier_id = 2, shift_id = 1 WHERE transaction_id = 2;
COMMIT;

-- ---- 4. refund: 1 box of paracetamol from invoice 1 -------------------
--   credit = round(16000 × 1 / 2) = 8000 (what the SC actually paid)

BEGIN;
INSERT INTO returns (return_id, original_transaction_id, processed_by, shift_id, resolution, reason)
VALUES (1, 1, 2, 1, 'refund', 'Wrong dosage bought');
INSERT INTO return_items (return_id, transaction_item_id, qty_milli, credit_cents, item_condition)
VALUES (1, (SELECT transaction_item_id FROM transaction_items WHERE transaction_id = 1 AND product_id = 1),
        1000, 8000, 'resellable');
UPDATE returns SET cash_refund_cents = 8000 WHERE return_id = 1;
COMMIT;

-- ---- 5. exchange: 1 m of damaged wire from invoice 2 for 1 tape -------
--   credit = round(8750 × 1000 / 2500) = 3500; tape costs 3500 -> equal value

BEGIN;
INSERT INTO returns (return_id, original_transaction_id, processed_by, shift_id, resolution, reason)
VALUES (2, 2, 2, 1, 'exchange', 'Insulation cut');
INSERT INTO return_items (return_id, transaction_item_id, qty_milli, credit_cents, item_condition)
VALUES (2, (SELECT transaction_item_id FROM transaction_items WHERE transaction_id = 2),
        1000, 3500, 'damaged');

INSERT INTO transactions (transaction_id, clerk_id) VALUES (3, 2);
INSERT INTO transaction_items
    (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment,
     gross_cents, net_cents, vat_cents)
VALUES (3, 4, 1000, 3500, 'vatable', 3500, 3500, 375);
INSERT INTO payments (transaction_id, method, amount_cents, return_id) VALUES (3, 'exchange_credit', 3500, 2);
UPDATE transactions SET status = 'paid', cashier_id = 2, shift_id = 1 WHERE transaction_id = 3;
COMMIT;

-- ---- results ---------------------------------------------------------

SELECT 'invoices' AS step, transaction_id, invoice_no, status, beneficiary_type,
       gross_cents, vat_removed_cents, discount_cents, total_cents,
       vatable_sales_cents, vat_cents, vat_exempt_sales_cents
FROM transactions ORDER BY transaction_id;

-- Expected on hand: paracetamol 9 (10 - 2 + 1 resellable),
-- rice 48, wire 97.5 (damaged metre not restocked), tape 9.
SELECT 'stock' AS step, sku, name, stock_milli / 1000.0 AS on_hand FROM products;

SELECT 'z-reading' AS step, * FROM v_daily_sales;
