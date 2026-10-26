-- =====================================================================
-- POS v1 — SQLite schema
-- Scope: single-branch retail (pharmacy / convenience / hardware), PH.
--
-- Conventions
--   * Money     = INTEGER centavos.          ₱112.50 -> 11250
--   * Quantity  = INTEGER thousandths (milli). 2 pcs -> 2000, 1.5 m -> 1500
--   * Rates     = INTEGER basis points.       12% -> 1200, 20% -> 2000
--   * Time      = TEXT 'YYYY-MM-DD HH:MM:SS', store-local time.
--   * Booleans  = INTEGER 0/1.
--   * STRICT tables: SQLite rejects values of the wrong type.
--
-- The app must run this on EVERY new connection (it is OFF by default):
--   PRAGMA foreign_keys = ON;
-- And once, when creating the database file:
--   PRAGMA journal_mode = WAL;
--
-- Line math the app does before inserting a transaction_items row
-- (round half up to the centavo):
--   gross       = unit_price × qty
--   if the discount is VAT-exempt (SC/PWD 20%):
--       base = round(gross / 1.12);  vat_removed = gross - base
--   else:
--       base = gross;                vat_removed = 0
--   discount    = round(base × rate)
--   net         = base - discount
--   vat         = tax_treatment = 'vatable' ? net - round(net / 1.12) : 0
--
-- Example: ₱112 medicine, Senior Citizen
--   gross 11200 -> base 10000 (vat_removed 1200) -> discount 2000 -> net 8000
--
-- Discount and VAT rules here are a starting point. Verify them against
-- current BIR revenue regulations and DTI joint orders before go-live.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Store setup
-- ---------------------------------------------------------------------

-- Exactly one row.
CREATE TABLE store_settings (
    id                  INTEGER PRIMARY KEY CHECK (id = 1),
    store_name          TEXT    NOT NULL,
    address             TEXT    NOT NULL DEFAULT '',
    tin                 TEXT    NOT NULL DEFAULT '',
    is_vat_registered   INTEGER NOT NULL DEFAULT 1 CHECK (is_vat_registered IN (0, 1)),
    vat_rate_bp         INTEGER NOT NULL DEFAULT 1200,
    return_window_days  INTEGER NOT NULL DEFAULT 7,
    -- 1 = clerk prints an order slip, cashier takes payment (hardware, pharmacy)
    -- 0 = one person does both (sari-sari, convenience)
    two_step_checkout   INTEGER NOT NULL DEFAULT 1 CHECK (two_step_checkout IN (0, 1))
) STRICT;

-- Permissions are nested and enforced by the app:
--   clerk   = build orders / slips
--   cashier = clerk + take payment, open/close shift
--   manager = everything + voids, returns past the window, price edits
CREATE TABLE employees (
    employee_id  INTEGER PRIMARY KEY,
    full_name    TEXT    NOT NULL,
    role         TEXT    NOT NULL CHECK (role IN ('clerk', 'cashier', 'manager')),
    pin_hash     TEXT    NOT NULL,   -- bcrypt/argon2 hash, never the raw PIN
    is_active    INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at   TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
) STRICT;


-- ---------------------------------------------------------------------
-- Catalog and inventory
-- ---------------------------------------------------------------------

CREATE TABLE categories (
    category_id  INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL UNIQUE
) STRICT;

CREATE TABLE suppliers (
    supplier_id     INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL,
    contact_person  TEXT,
    phone           TEXT,
    email           TEXT,
    address         TEXT,
    is_active       INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1))
) STRICT;

CREATE TABLE products (
    product_id        INTEGER PRIMARY KEY,
    sku               TEXT    NOT NULL UNIQUE,
    barcode           TEXT    UNIQUE,            -- NULL if the item has none
    name              TEXT    NOT NULL,
    category_id       INTEGER NOT NULL REFERENCES categories (category_id),
    supplier_id       INTEGER REFERENCES suppliers (supplier_id),
    unit              TEXT    NOT NULL DEFAULT 'pc',   -- pc, box, m, kg, L ...
    allow_fractional  INTEGER NOT NULL DEFAULT 0 CHECK (allow_fractional IN (0, 1)),
    -- Shelf price. VAT-inclusive when the store is VAT-registered.
    price_cents       INTEGER NOT NULL CHECK (price_cents >= 0),
    cost_cents        INTEGER NOT NULL DEFAULT 0 CHECK (cost_cents >= 0),
    vat_status        TEXT    NOT NULL DEFAULT 'vatable'
                      CHECK (vat_status IN ('vatable', 'exempt', 'zero_rated')),
    -- Which statutory discount the item qualifies for:
    --   sc_pwd          = 20% + VAT exemption for SC/PWD (e.g. medicine)
    --   basic_necessity = 5% for SC (basic necessities / prime commodities)
    discount_class    TEXT    NOT NULL DEFAULT 'none'
                      CHECK (discount_class IN ('none', 'sc_pwd', 'basic_necessity')),
    -- Cached on-hand count. Maintained by the stock_movements trigger;
    -- never update it directly.
    stock_milli       INTEGER NOT NULL DEFAULT 0,
    reorder_milli     INTEGER NOT NULL DEFAULT 0,
    is_active         INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at        TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    updated_at        TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
) STRICT;

CREATE INDEX idx_products_name     ON products (name);
CREATE INDEX idx_products_category ON products (category_id);

-- Every change to stock is a row here: deliveries, sales, voids, returns,
-- and manual count corrections. products.stock_milli is the running sum.
CREATE TABLE stock_movements (
    movement_id      INTEGER PRIMARY KEY,
    product_id       INTEGER NOT NULL REFERENCES products (product_id),
    qty_milli        INTEGER NOT NULL CHECK (qty_milli <> 0),   -- + in, - out
    reason           TEXT    NOT NULL
                     CHECK (reason IN ('stock_in', 'sale', 'sale_void', 'return', 'adjustment')),
    transaction_id   INTEGER REFERENCES transactions (transaction_id),
    return_item_id   INTEGER REFERENCES return_items (return_item_id),
    supplier_id      INTEGER REFERENCES suppliers (supplier_id),
    unit_cost_cents  INTEGER,            -- stock_in only
    employee_id      INTEGER REFERENCES employees (employee_id),
    note             TEXT,
    created_at       TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
) STRICT;

CREATE INDEX idx_stock_movements_product ON stock_movements (product_id, created_at);


-- ---------------------------------------------------------------------
-- Customers and discounts
-- ---------------------------------------------------------------------

-- Walk-ins get no row; transactions.customer_id is NULL for them.
-- Membership is folded in here instead of a separate table.
CREATE TABLE customers (
    customer_id   INTEGER PRIMARY KEY,
    full_name     TEXT    NOT NULL,
    phone         TEXT,
    email         TEXT,
    is_member     INTEGER NOT NULL DEFAULT 0 CHECK (is_member IN (0, 1)),
    member_since  TEXT,
    created_at    TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
) STRICT;

-- Applied per line item, not per transaction: an SC buying medicine and
-- rice gets 20% (VAT-exempt) on the medicine and 5% on the rice.
-- Discounts do not stack: one discount per line, the app picks the best.
CREATE TABLE discount_types (
    discount_type_id   INTEGER PRIMARY KEY,
    code               TEXT    NOT NULL UNIQUE,
    name               TEXT    NOT NULL,
    rate_bp            INTEGER NOT NULL CHECK (rate_bp BETWEEN 0 AND 10000),
    vat_exempt         INTEGER NOT NULL DEFAULT 0 CHECK (vat_exempt IN (0, 1)),
    beneficiary_type   TEXT    CHECK (beneficiary_type IN ('SC', 'PWD')),  -- NULL = anyone
    product_class      TEXT    CHECK (product_class IN ('sc_pwd', 'basic_necessity')),  -- NULL = any product
    -- Max purchase amount per beneficiary per week (basic necessities).
    -- The app checks it against past sales with the same beneficiary_id_no.
    weekly_cap_cents   INTEGER,
    valid_from         TEXT,
    valid_to           TEXT,
    is_active          INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1))
) STRICT;


-- ---------------------------------------------------------------------
-- Sales
-- ---------------------------------------------------------------------

CREATE TABLE shifts (
    shift_id             INTEGER PRIMARY KEY,
    cashier_id           INTEGER NOT NULL REFERENCES employees (employee_id),
    opened_at            TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    closed_at            TEXT,
    opening_cash_cents   INTEGER NOT NULL DEFAULT 0,
    counted_cash_cents   INTEGER,   -- what the cashier counted at close
    expected_cash_cents  INTEGER    -- opening + cash sales - cash refunds
) STRICT;

-- Lifecycle: pending (order slip) -> paid -> (voided)
--                                 \-> voided (abandoned slip)
-- Payment: insert payments rows, then
--   UPDATE transactions SET status = 'paid', cashier_id = ?, shift_id = ? ...
-- and the triggers assign the invoice number, copy totals, deduct stock.
CREATE TABLE transactions (
    transaction_id          INTEGER PRIMARY KEY,
    invoice_no              INTEGER UNIQUE,   -- set when paid; sequential, never reused
    status                  TEXT    NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'paid', 'voided')),
    customer_id             INTEGER REFERENCES customers (customer_id),
    clerk_id                INTEGER NOT NULL REFERENCES employees (employee_id),
    cashier_id              INTEGER REFERENCES employees (employee_id),
    shift_id                INTEGER REFERENCES shifts (shift_id),

    -- SC / PWD details, required on the invoice by BIR
    beneficiary_type        TEXT    CHECK (beneficiary_type IN ('SC', 'PWD')),
    beneficiary_id_no       TEXT,
    beneficiary_name        TEXT,

    -- Copied from the line items when paid, so a printed invoice never changes.
    gross_cents             INTEGER NOT NULL DEFAULT 0,
    vat_removed_cents       INTEGER NOT NULL DEFAULT 0,
    discount_cents          INTEGER NOT NULL DEFAULT 0,
    total_cents             INTEGER NOT NULL DEFAULT 0,   -- amount due
    vatable_sales_cents     INTEGER NOT NULL DEFAULT 0,   -- net of VAT
    vat_cents               INTEGER NOT NULL DEFAULT 0,
    vat_exempt_sales_cents  INTEGER NOT NULL DEFAULT 0,
    zero_rated_sales_cents  INTEGER NOT NULL DEFAULT 0,

    created_at              TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    paid_at                 TEXT,
    voided_at               TEXT,
    voided_by               INTEGER REFERENCES employees (employee_id),
    void_reason             TEXT,

    CHECK ((beneficiary_type IS NULL) = (beneficiary_id_no IS NULL)),
    CHECK (beneficiary_type IS NULL OR beneficiary_name IS NOT NULL),
    CHECK (status <> 'paid' OR cashier_id IS NOT NULL),
    CHECK (status <> 'voided'
           OR (voided_at IS NOT NULL AND voided_by IS NOT NULL AND void_reason IS NOT NULL))
) STRICT;

CREATE INDEX idx_transactions_status      ON transactions (status, created_at);
CREATE INDEX idx_transactions_paid_at     ON transactions (paid_at);
CREATE INDEX idx_transactions_beneficiary ON transactions (beneficiary_id_no, paid_at);

CREATE TABLE transaction_items (
    transaction_item_id  INTEGER PRIMARY KEY,
    transaction_id       INTEGER NOT NULL REFERENCES transactions (transaction_id),
    product_id           INTEGER NOT NULL REFERENCES products (product_id),
    qty_milli            INTEGER NOT NULL CHECK (qty_milli > 0),
    unit_price_cents     INTEGER NOT NULL CHECK (unit_price_cents >= 0),  -- price at time of sale
    -- Effective treatment for this line: 'exempt' when an SC/PWD VAT
    -- exemption applied, 'non_vat' when the store is not VAT-registered.
    tax_treatment        TEXT    NOT NULL
                         CHECK (tax_treatment IN ('vatable', 'exempt', 'zero_rated', 'non_vat')),
    discount_type_id     INTEGER REFERENCES discount_types (discount_type_id),
    gross_cents          INTEGER NOT NULL CHECK (gross_cents >= 0),
    vat_removed_cents    INTEGER NOT NULL DEFAULT 0 CHECK (vat_removed_cents >= 0),
    discount_cents       INTEGER NOT NULL DEFAULT 0 CHECK (discount_cents >= 0),
    net_cents            INTEGER NOT NULL CHECK (net_cents >= 0),   -- what the customer pays
    vat_cents            INTEGER NOT NULL DEFAULT 0 CHECK (vat_cents >= 0),  -- VAT inside net_cents

    CHECK (net_cents = gross_cents - vat_removed_cents - discount_cents),
    CHECK (tax_treatment = 'vatable' OR vat_cents = 0),
    CHECK (vat_removed_cents = 0 OR tax_treatment = 'exempt'),
    CHECK (discount_cents = 0 OR discount_type_id IS NOT NULL)
) STRICT;

CREATE INDEX idx_transaction_items_txn ON transaction_items (transaction_id);

CREATE TABLE payments (
    payment_id      INTEGER PRIMARY KEY,
    transaction_id  INTEGER NOT NULL REFERENCES transactions (transaction_id),
    method          TEXT    NOT NULL
                    CHECK (method IN ('cash', 'ewallet', 'card', 'exchange_credit')),
    amount_cents    INTEGER NOT NULL CHECK (amount_cents > 0),  -- applied to the bill
    tendered_cents  INTEGER,   -- cash only; change = tendered - amount
    reference_no    TEXT,      -- e-wallet / card reference
    return_id       INTEGER REFERENCES returns (return_id),  -- exchange_credit only
    created_at      TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),

    CHECK (method <> 'cash' OR tendered_cents >= amount_cents),
    CHECK ((method = 'exchange_credit') = (return_id IS NOT NULL))
) STRICT;

CREATE INDEX idx_payments_txn ON payments (transaction_id);


-- ---------------------------------------------------------------------
-- Returns
-- ---------------------------------------------------------------------

-- Refund: cash_refund_cents = total credit.
-- Exchange: new items go on a NEW transaction, paid (fully or partly)
-- with a payments row of method 'exchange_credit' pointing here; any
-- leftover credit is refunded in cash_refund_cents.
-- The return window (store_settings.return_window_days) is checked by the
-- app; past it, a manager must approve (approved_by).
CREATE TABLE returns (
    return_id                INTEGER PRIMARY KEY,
    original_transaction_id  INTEGER NOT NULL REFERENCES transactions (transaction_id),
    processed_by             INTEGER NOT NULL REFERENCES employees (employee_id),
    approved_by              INTEGER REFERENCES employees (employee_id),
    shift_id                 INTEGER REFERENCES shifts (shift_id),
    resolution               TEXT    NOT NULL CHECK (resolution IN ('refund', 'exchange')),
    reason                   TEXT    NOT NULL,
    cash_refund_cents        INTEGER NOT NULL DEFAULT 0 CHECK (cash_refund_cents >= 0),
    created_at               TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
) STRICT;

CREATE TABLE return_items (
    return_item_id       INTEGER PRIMARY KEY,
    return_id            INTEGER NOT NULL REFERENCES returns (return_id),
    transaction_item_id  INTEGER NOT NULL REFERENCES transaction_items (transaction_item_id),
    qty_milli            INTEGER NOT NULL CHECK (qty_milli > 0),
    -- What the customer actually paid for these units:
    -- round(original net_cents × returned qty / sold qty)
    credit_cents         INTEGER NOT NULL CHECK (credit_cents >= 0),
    -- resellable goes back on the shelf; damaged does not
    item_condition       TEXT    NOT NULL CHECK (item_condition IN ('resellable', 'damaged'))
) STRICT;

CREATE INDEX idx_return_items_item ON return_items (transaction_item_id);


-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------

-- Live totals of any transaction, computed from its lines. Use it to show
-- a pending order slip; the paid trigger copies it into transactions.
-- VAT-exempt sales are shown before the SC/PWD discount, the usual
-- receipt layout: VAT-exempt sales 100.00, less SC discount 20.00.
CREATE VIEW v_transaction_totals AS
SELECT t.transaction_id,
       COALESCE(SUM(i.gross_cents), 0)       AS gross_cents,
       COALESCE(SUM(i.vat_removed_cents), 0) AS vat_removed_cents,
       COALESCE(SUM(i.discount_cents), 0)    AS discount_cents,
       COALESCE(SUM(i.net_cents), 0)         AS total_cents,
       COALESCE(SUM(CASE WHEN i.tax_treatment = 'vatable'
                         THEN i.net_cents - i.vat_cents END), 0)               AS vatable_sales_cents,
       COALESCE(SUM(i.vat_cents), 0)                                           AS vat_cents,
       COALESCE(SUM(CASE WHEN i.tax_treatment = 'exempt'
                         THEN i.gross_cents - i.vat_removed_cents END), 0)     AS vat_exempt_sales_cents,
       COALESCE(SUM(CASE WHEN i.tax_treatment = 'zero_rated'
                         THEN i.net_cents END), 0)                             AS zero_rated_sales_cents,
       COUNT(i.transaction_item_id)                                            AS line_count
FROM transactions t
LEFT JOIN transaction_items i ON i.transaction_id = t.transaction_id
GROUP BY t.transaction_id;

CREATE VIEW v_low_stock AS
SELECT product_id, sku, name, unit,
       stock_milli / 1000.0   AS on_hand,
       reorder_milli / 1000.0 AS reorder_level
FROM products
WHERE is_active = 1 AND stock_milli <= reorder_milli;

-- Basis for the end-of-day (Z) reading.
CREATE VIEW v_daily_sales AS
SELECT date(paid_at)                        AS sales_date,
       MIN(invoice_no)                      AS first_invoice,
       MAX(invoice_no)                      AS last_invoice,
       SUM(status = 'paid')                 AS paid_count,
       SUM(status = 'voided')               AS voided_count,
       SUM(CASE WHEN status = 'paid' THEN gross_cents END)            AS gross_cents,
       SUM(CASE WHEN status = 'paid' THEN discount_cents END)         AS discount_cents,
       SUM(CASE WHEN status = 'paid' THEN vat_removed_cents END)      AS vat_removed_cents,
       SUM(CASE WHEN status = 'paid' THEN total_cents END)            AS net_sales_cents,
       SUM(CASE WHEN status = 'paid' THEN vatable_sales_cents END)    AS vatable_sales_cents,
       SUM(CASE WHEN status = 'paid' THEN vat_cents END)              AS vat_cents,
       SUM(CASE WHEN status = 'paid' THEN vat_exempt_sales_cents END) AS vat_exempt_sales_cents
FROM transactions
WHERE paid_at IS NOT NULL      -- voids of paid invoices still count here
GROUP BY date(paid_at);


-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------

-- Stock: keep products.stock_milli equal to the sum of its movements.
CREATE TRIGGER trg_stock_movement_apply
AFTER INSERT ON stock_movements
BEGIN
    UPDATE products
    SET stock_milli = stock_milli + NEW.qty_milli,
        updated_at  = datetime('now', 'localtime')
    WHERE product_id = NEW.product_id;
END;

-- Whole-unit products cannot be sold in fractions.
CREATE TRIGGER trg_items_whole_units_ins
BEFORE INSERT ON transaction_items
WHEN NEW.qty_milli % 1000 <> 0
 AND (SELECT allow_fractional FROM products WHERE product_id = NEW.product_id) = 0
BEGIN
    SELECT RAISE(ABORT, 'this product is sold in whole units only');
END;

CREATE TRIGGER trg_items_whole_units_upd
BEFORE UPDATE OF qty_milli, product_id ON transaction_items
WHEN NEW.qty_milli % 1000 <> 0
 AND (SELECT allow_fractional FROM products WHERE product_id = NEW.product_id) = 0
BEGIN
    SELECT RAISE(ABORT, 'this product is sold in whole units only');
END;

-- Lines and payments can only change while the order is pending.
CREATE TRIGGER trg_items_lock_ins
BEFORE INSERT ON transaction_items
WHEN (SELECT status FROM transactions WHERE transaction_id = NEW.transaction_id) <> 'pending'
BEGIN
    SELECT RAISE(ABORT, 'transaction is no longer pending');
END;

CREATE TRIGGER trg_items_lock_upd
BEFORE UPDATE ON transaction_items
WHEN (SELECT status FROM transactions WHERE transaction_id = OLD.transaction_id) <> 'pending'
BEGIN
    SELECT RAISE(ABORT, 'transaction is no longer pending');
END;

CREATE TRIGGER trg_items_lock_del
BEFORE DELETE ON transaction_items
WHEN (SELECT status FROM transactions WHERE transaction_id = OLD.transaction_id) <> 'pending'
BEGIN
    SELECT RAISE(ABORT, 'transaction is no longer pending');
END;

CREATE TRIGGER trg_payments_lock_ins
BEFORE INSERT ON payments
WHEN (SELECT status FROM transactions WHERE transaction_id = NEW.transaction_id) <> 'pending'
BEGIN
    SELECT RAISE(ABORT, 'transaction is no longer pending');
END;

-- Exchange credit cannot exceed what the return is worth.
CREATE TRIGGER trg_payments_exchange_credit
BEFORE INSERT ON payments
WHEN NEW.method = 'exchange_credit'
BEGIN
    SELECT RAISE(ABORT, 'exchange credit exceeds the value of the return')
    WHERE NEW.amount_cents
          + (SELECT COALESCE(SUM(amount_cents), 0) FROM payments WHERE return_id = NEW.return_id)
          + (SELECT cash_refund_cents FROM returns WHERE return_id = NEW.return_id)
        > (SELECT COALESCE(SUM(credit_cents), 0) FROM return_items WHERE return_id = NEW.return_id);
END;

-- The stock ledger is append-only: fix mistakes with an 'adjustment' row.
CREATE TRIGGER trg_stock_movements_no_update
BEFORE UPDATE ON stock_movements
BEGIN
    SELECT RAISE(ABORT, 'stock movements cannot be changed; add an adjustment instead');
END;

CREATE TRIGGER trg_stock_movements_no_delete
BEFORE DELETE ON stock_movements
BEGIN
    SELECT RAISE(ABORT, 'stock movements cannot be changed; add an adjustment instead');
END;

-- New transactions always start as an empty pending order.
CREATE TRIGGER trg_transactions_insert
BEFORE INSERT ON transactions
WHEN NEW.status <> 'pending' OR NEW.invoice_no IS NOT NULL OR NEW.paid_at IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'new transactions must start as pending');
END;

-- Transactions: transactions are never deleted, only voided.
CREATE TRIGGER trg_transactions_no_delete
BEFORE DELETE ON transactions
BEGIN
    SELECT RAISE(ABORT, 'transactions cannot be deleted; void them instead');
END;

-- A voided transaction is final.
CREATE TRIGGER trg_transactions_voided_final
BEFORE UPDATE ON transactions
WHEN OLD.status = 'voided'
BEGIN
    SELECT RAISE(ABORT, 'voided transactions cannot be changed');
END;

-- Allowed: pending -> paid, pending -> voided, paid -> voided.
CREATE TRIGGER trg_transactions_status_flow
BEFORE UPDATE OF status ON transactions
WHEN NEW.status <> OLD.status
 AND NOT (   (OLD.status = 'pending' AND NEW.status IN ('paid', 'voided'))
          OR (OLD.status = 'paid'    AND NEW.status = 'voided'))
BEGIN
    SELECT RAISE(ABORT, 'invalid status change');
END;

-- Before paying: must have items, and payments must equal the amount due.
CREATE TRIGGER trg_transactions_pay_check
BEFORE UPDATE OF status ON transactions
WHEN OLD.status = 'pending' AND NEW.status = 'paid'
BEGIN
    SELECT RAISE(ABORT, 'cannot pay an empty order')
    WHERE (SELECT line_count FROM v_transaction_totals
           WHERE transaction_id = NEW.transaction_id) = 0;

    SELECT RAISE(ABORT, 'payments must equal the amount due')
    WHERE (SELECT COALESCE(SUM(amount_cents), 0) FROM payments
           WHERE transaction_id = NEW.transaction_id)
       <> (SELECT total_cents FROM v_transaction_totals
           WHERE transaction_id = NEW.transaction_id);
END;

-- On payment: assign the next invoice number, freeze totals, deduct stock.
CREATE TRIGGER trg_transactions_paid
AFTER UPDATE OF status ON transactions
WHEN OLD.status = 'pending' AND NEW.status = 'paid'
BEGIN
    UPDATE transactions
    SET invoice_no = (SELECT COALESCE(MAX(invoice_no), 0) + 1 FROM transactions),
        paid_at    = datetime('now', 'localtime'),
        (gross_cents, vat_removed_cents, discount_cents, total_cents,
         vatable_sales_cents, vat_cents, vat_exempt_sales_cents, zero_rated_sales_cents)
          = (SELECT gross_cents, vat_removed_cents, discount_cents, total_cents,
                    vatable_sales_cents, vat_cents, vat_exempt_sales_cents, zero_rated_sales_cents
             FROM v_transaction_totals
             WHERE transaction_id = NEW.transaction_id)
    WHERE transaction_id = NEW.transaction_id;

    INSERT INTO stock_movements (product_id, qty_milli, reason, transaction_id, employee_id)
    SELECT product_id, -qty_milli, 'sale', transaction_id, NEW.cashier_id
    FROM transaction_items
    WHERE transaction_id = NEW.transaction_id;
END;

-- Voiding a paid sale puts its stock back. (Voiding a pending slip
-- touches no stock, since none was deducted.)
CREATE TRIGGER trg_transactions_void_paid
AFTER UPDATE OF status ON transactions
WHEN OLD.status = 'paid' AND NEW.status = 'voided'
BEGIN
    SELECT RAISE(ABORT, 'this sale has returns; process a return instead of a void')
    WHERE EXISTS (SELECT 1 FROM returns WHERE original_transaction_id = NEW.transaction_id);

    INSERT INTO stock_movements (product_id, qty_milli, reason, transaction_id, employee_id)
    SELECT product_id, qty_milli, 'sale_void', transaction_id, NEW.voided_by
    FROM transaction_items
    WHERE transaction_id = NEW.transaction_id;
END;

-- Returns: item must come from the original paid sale, and you cannot
-- return more than was bought (across all returns of that line).
CREATE TRIGGER trg_return_items_check
BEFORE INSERT ON return_items
BEGIN
    SELECT RAISE(ABORT, 'item is not from the original transaction')
    WHERE (SELECT transaction_id FROM transaction_items
           WHERE transaction_item_id = NEW.transaction_item_id)
       IS NOT (SELECT original_transaction_id FROM returns
               WHERE return_id = NEW.return_id);

    SELECT RAISE(ABORT, 'original transaction is not paid')
    WHERE (SELECT t.status FROM returns r
           JOIN transactions t ON t.transaction_id = r.original_transaction_id
           WHERE r.return_id = NEW.return_id) <> 'paid';

    SELECT RAISE(ABORT, 'returning more than was sold')
    WHERE NEW.qty_milli
          + (SELECT COALESCE(SUM(qty_milli), 0) FROM return_items
             WHERE transaction_item_id = NEW.transaction_item_id)
        > (SELECT qty_milli FROM transaction_items
           WHERE transaction_item_id = NEW.transaction_item_id);
END;

-- Cash refunded plus exchange credit used cannot exceed the return's value.
CREATE TRIGGER trg_returns_refund_check
BEFORE UPDATE OF cash_refund_cents ON returns
BEGIN
    SELECT RAISE(ABORT, 'refund exceeds the value of the return')
    WHERE NEW.cash_refund_cents
          + (SELECT COALESCE(SUM(amount_cents), 0) FROM payments WHERE return_id = NEW.return_id)
        > (SELECT COALESCE(SUM(credit_cents), 0) FROM return_items WHERE return_id = NEW.return_id);
END;

-- Resellable returns go back into stock.
CREATE TRIGGER trg_return_items_restock
AFTER INSERT ON return_items
WHEN NEW.item_condition = 'resellable'
BEGIN
    INSERT INTO stock_movements (product_id, qty_milli, reason, return_item_id, employee_id)
    SELECT ti.product_id, NEW.qty_milli, 'return', NEW.return_item_id, r.processed_by
    FROM transaction_items ti, returns r
    WHERE ti.transaction_item_id = NEW.transaction_item_id
      AND r.return_id = NEW.return_id;
END;


-- ---------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------

INSERT INTO store_settings (id, store_name) VALUES (1, 'My Store');

-- weekly_cap_cents for SC_BN_5 is left NULL on purpose: set it from the
-- current DTI joint administrative order.
INSERT INTO discount_types
    (code, name, rate_bp, vat_exempt, beneficiary_type, product_class)
VALUES
    ('SC_20',   'Senior Citizen 20% (VAT-exempt)',     2000, 1, 'SC',  'sc_pwd'),
    ('PWD_20',  'PWD 20% (VAT-exempt)',                2000, 1, 'PWD', 'sc_pwd'),
    ('SC_BN_5', 'Senior Citizen 5% basic necessities',  500, 0, 'SC',  'basic_necessity');
