-- =====================================================================
-- Walkthrough: run after schema.sql on a fresh database, e.g.
--   mysql -u root -p pos < example_checkout.sql
-- Same scenarios as sqlite/example_checkout.sql:
--   1. stock-in from a supplier
--   2. Senior Citizen sale (20% VAT-exempt + 5% basic necessity)
--   3. regular sale of a fractional item (2.5 m of wire)
--   4. refund return
--   5. exchange return
-- Each step is wrapped in START TRANSACTION / COMMIT: all-or-nothing.
-- =====================================================================

SET time_zone = '+08:00';

-- ---- setup ---------------------------------------------------------

INSERT INTO employees (full_name, role, pin_hash) VALUES
    ('Clerk One',   'clerk',   '<hash>'),
    ('Cashier One', 'cashier', '<hash>'),
    ('Manager One', 'manager', '<hash>');

SET @clerk   = (SELECT employee_id FROM employees WHERE full_name = 'Clerk One');
SET @cashier = (SELECT employee_id FROM employees WHERE full_name = 'Cashier One');
SET @manager = (SELECT employee_id FROM employees WHERE full_name = 'Manager One');

INSERT INTO categories (name) VALUES ('Medicine'), ('Grocery'), ('Electrical');
INSERT INTO suppliers (name) VALUES ('Main Distributor');
SET @supplier = LAST_INSERT_ID();

INSERT INTO products
    (sku, barcode, name, category_id, supplier_id, unit, allow_fractional,
     price_cents, cost_cents, vat_status, discount_class, reorder_milli)
VALUES
    ('MED-0001', '4800000000011', 'Paracetamol 500mg (box of 20)',
     (SELECT category_id FROM categories WHERE name = 'Medicine'),   @supplier, 'box', FALSE, 11200, 8000, 'vatable', 'sc_pwd',          5000),
    ('GRO-0001', NULL,            'Rice, regular milled',
     (SELECT category_id FROM categories WHERE name = 'Grocery'),    @supplier, 'kg',  TRUE,   5600, 4500, 'exempt',  'basic_necessity', 20000),
    ('ELE-0001', NULL,            'THHN wire #14',
     (SELECT category_id FROM categories WHERE name = 'Electrical'), @supplier, 'm',   TRUE,   3500, 2200, 'vatable', 'none',            50000),
    ('ELE-0002', '4800000000028', 'Electrical tape',
     (SELECT category_id FROM categories WHERE name = 'Electrical'), @supplier, 'pc',  FALSE,  3500, 2000, 'vatable', 'none',            5000);

SET @paracetamol = (SELECT product_id FROM products WHERE sku = 'MED-0001');
SET @rice        = (SELECT product_id FROM products WHERE sku = 'GRO-0001');
SET @wire        = (SELECT product_id FROM products WHERE sku = 'ELE-0001');
SET @tape        = (SELECT product_id FROM products WHERE sku = 'ELE-0002');

-- ---- 1. stock-in -----------------------------------------------------

START TRANSACTION;
INSERT INTO stock_movements (product_id, qty_milli, reason, supplier_id, unit_cost_cents, employee_id) VALUES
    (@paracetamol,  10000, 'stock_in', @supplier, 8000, @manager),   -- 10 boxes
    (@rice,         50000, 'stock_in', @supplier, 4500, @manager),   -- 50 kg
    (@wire,        100000, 'stock_in', @supplier, 2200, @manager),   -- 100 m
    (@tape,         10000, 'stock_in', @supplier, 2000, @manager);   -- 10 pcs
COMMIT;

INSERT INTO shifts (cashier_id, opening_cash_cents) VALUES (@cashier, 100000);
SET @shift = LAST_INSERT_ID();

-- ---- 2. Senior Citizen sale -------------------------------------------
--   Paracetamol ×2: gross 22400 -> base 20000 (VAT removed 2400) -> 20% 4000 -> net 16000
--   Rice 2 kg:      gross 11200 -> exempt item, 5% 560                       -> net 10640
--   Amount due: 26640 (₱266.40)

START TRANSACTION;
INSERT INTO transactions (clerk_id, beneficiary_type, beneficiary_id_no, beneficiary_name)
VALUES (@clerk, 'SC', 'SC-12345', 'Juan Dela Cruz');
SET @sale1 = LAST_INSERT_ID();

INSERT INTO transaction_items
    (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment,
     discount_type_id, gross_cents, vat_removed_cents, discount_cents, net_cents, vat_cents)
VALUES
    (@sale1, @paracetamol, 2000, 11200, 'exempt',
     (SELECT discount_type_id FROM discount_types WHERE code = 'SC_20'),   22400, 2400, 4000, 16000, 0),
    (@sale1, @rice,        2000,  5600, 'exempt',
     (SELECT discount_type_id FROM discount_types WHERE code = 'SC_BN_5'), 11200,    0,  560, 10640, 0);

-- cashier takes ₱300 cash
INSERT INTO payments (transaction_id, method, amount_cents, tendered_cents) VALUES (@sale1, 'cash', 26640, 30000);
UPDATE transactions SET status = 'paid', cashier_id = @cashier, shift_id = @shift WHERE transaction_id = @sale1;
COMMIT;

-- ---- 3. regular sale, 2.5 m of wire -----------------------------------
--   gross 8750, vatable: VAT = 8750 - round(8750 / 1.12) = 8750 - 7813 = 937

START TRANSACTION;
INSERT INTO transactions (clerk_id) VALUES (@clerk);
SET @sale2 = LAST_INSERT_ID();
INSERT INTO transaction_items
    (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment, gross_cents, net_cents, vat_cents)
VALUES (@sale2, @wire, 2500, 3500, 'vatable', 8750, 8750, 937);
INSERT INTO payments (transaction_id, method, amount_cents, tendered_cents) VALUES (@sale2, 'cash', 8750, 10000);
UPDATE transactions SET status = 'paid', cashier_id = @cashier, shift_id = @shift WHERE transaction_id = @sale2;
COMMIT;

-- ---- 4. refund: 1 box of paracetamol from sale 1 ----------------------
--   credit = round(16000 × 1 / 2) = 8000 (what the SC actually paid)

START TRANSACTION;
INSERT INTO returns (original_transaction_id, processed_by, shift_id, resolution, reason)
VALUES (@sale1, @cashier, @shift, 'refund', 'Wrong dosage bought');
SET @ret1 = LAST_INSERT_ID();
INSERT INTO return_items (return_id, transaction_item_id, qty_milli, credit_cents, item_condition)
VALUES (@ret1,
        (SELECT transaction_item_id FROM transaction_items WHERE transaction_id = @sale1 AND product_id = @paracetamol),
        1000, 8000, 'resellable');
UPDATE returns SET cash_refund_cents = 8000 WHERE return_id = @ret1;
COMMIT;

-- ---- 5. exchange: 1 m of damaged wire from sale 2 for 1 tape ----------
--   credit = round(8750 × 1000 / 2500) = 3500; tape costs 3500 -> equal value

START TRANSACTION;
INSERT INTO returns (original_transaction_id, processed_by, shift_id, resolution, reason)
VALUES (@sale2, @cashier, @shift, 'exchange', 'Insulation cut');
SET @ret2 = LAST_INSERT_ID();
INSERT INTO return_items (return_id, transaction_item_id, qty_milli, credit_cents, item_condition)
VALUES (@ret2,
        (SELECT transaction_item_id FROM transaction_items WHERE transaction_id = @sale2),
        1000, 3500, 'damaged');

INSERT INTO transactions (clerk_id) VALUES (@cashier);
SET @sale3 = LAST_INSERT_ID();
INSERT INTO transaction_items
    (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment, gross_cents, net_cents, vat_cents)
VALUES (@sale3, @tape, 1000, 3500, 'vatable', 3500, 3500, 375);
INSERT INTO payments (transaction_id, method, amount_cents, return_id) VALUES (@sale3, 'exchange_credit', 3500, @ret2);
UPDATE transactions SET status = 'paid', cashier_id = @cashier, shift_id = @shift WHERE transaction_id = @sale3;
COMMIT;

-- ---- results ---------------------------------------------------------

SELECT transaction_id, invoice_no, status, beneficiary_type,
       gross_cents, vat_removed_cents, discount_cents, total_cents,
       vatable_sales_cents, vat_cents, vat_exempt_sales_cents
FROM transactions ORDER BY transaction_id;

-- Expected on hand: paracetamol 9, rice 48, wire 97.5, tape 9.
SELECT sku, name, stock_milli / 1000 AS on_hand FROM products ORDER BY product_id;

SELECT * FROM v_daily_sales;
