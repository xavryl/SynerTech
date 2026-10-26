-- =====================================================================
-- POS v1 — MySQL schema
-- MySQL 8.0.16 or newer (CHECK constraints are enforced from 8.0.16).
-- Runs as-is on:
--   * a local/LAN MySQL server
--   * Google Cloud SQL for MySQL
--   * AWS RDS for MySQL / Aurora MySQL
--
-- Load with the mysql command-line client (the DELIMITER lines are
-- client commands, not SQL):
--   mysql -u root -p -e "CREATE DATABASE pos CHARACTER SET utf8mb4"
--   mysql -u root -p pos < schema.sql
--
-- Same design as sqlite/schema.sql. Differences:
--   * Timestamps are DATETIME in the session time zone. Set the server
--     (or every connection) to store time:  SET time_zone = '+08:00';
--   * Invoice numbers come from invoice_counter: gap-free and safe with
--     several cashiers paying at the same moment.
--   * Paid invoices are fully locked, totals included.
--   * Keep the default sql_mode (STRICT_TRANS_TABLES) so bad values are
--     rejected instead of silently truncated.
--
-- Conventions (identical in every version so the app logic is shared):
--   * Money     = BIGINT centavos.             ₱112.50 -> 11250
--   * Quantity  = INT thousandths (milli).     2 pcs -> 2000, 1.5 m -> 1500
--   * Rates     = INT basis points.            12% -> 1200, 20% -> 2000
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
-- Discount and VAT rules here are a starting point. Verify them against
-- current BIR revenue regulations and DTI joint orders before go-live.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Store setup
-- ---------------------------------------------------------------------

-- Exactly one row.
CREATE TABLE store_settings (
    id                  TINYINT      NOT NULL PRIMARY KEY CHECK (id = 1),
    store_name          VARCHAR(150) NOT NULL,
    address             VARCHAR(255) NOT NULL DEFAULT '',
    tin                 VARCHAR(30)  NOT NULL DEFAULT '',
    is_vat_registered   BOOLEAN      NOT NULL DEFAULT TRUE,
    vat_rate_bp         INT          NOT NULL DEFAULT 1200,
    return_window_days  INT          NOT NULL DEFAULT 7,
    -- TRUE  = clerk prints an order slip, cashier takes payment
    -- FALSE = one person does both
    two_step_checkout   BOOLEAN      NOT NULL DEFAULT TRUE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Exactly one row. Incremented inside the paying transaction, so a
-- rolled-back payment does not burn a number (BIR wants no gaps).
CREATE TABLE invoice_counter (
    id       TINYINT NOT NULL PRIMARY KEY CHECK (id = 1),
    last_no  BIGINT  NOT NULL DEFAULT 0
) ENGINE = InnoDB;

-- Permissions are nested and enforced by the app:
--   clerk   = build orders / slips
--   cashier = clerk + take payment, open/close shift
--   manager = everything + voids, returns past the window, price edits
CREATE TABLE employees (
    employee_id  BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    full_name    VARCHAR(150) NOT NULL,
    role         VARCHAR(10)  NOT NULL CHECK (role IN ('clerk', 'cashier', 'manager')),
    pin_hash     VARCHAR(255) NOT NULL,   -- bcrypt/argon2 hash, never the raw PIN
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------

CREATE TABLE categories (
    category_id  BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name         VARCHAR(100) NOT NULL UNIQUE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE suppliers (
    supplier_id     BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name            VARCHAR(150) NOT NULL,
    contact_person  VARCHAR(150),
    phone           VARCHAR(40),
    email           VARCHAR(150),
    address         VARCHAR(255),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE products (
    product_id        BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sku               VARCHAR(64)  NOT NULL UNIQUE,
    barcode           VARCHAR(64)  UNIQUE,            -- NULL if the item has none
    name              VARCHAR(200) NOT NULL,
    category_id       BIGINT       NOT NULL,
    supplier_id       BIGINT,
    unit              VARCHAR(10)  NOT NULL DEFAULT 'pc',   -- pc, box, m, kg, L ...
    allow_fractional  BOOLEAN      NOT NULL DEFAULT FALSE,
    -- Shelf price. VAT-inclusive when the store is VAT-registered.
    price_cents       BIGINT       NOT NULL CHECK (price_cents >= 0),
    cost_cents        BIGINT       NOT NULL DEFAULT 0 CHECK (cost_cents >= 0),
    vat_status        VARCHAR(10)  NOT NULL DEFAULT 'vatable'
                      CHECK (vat_status IN ('vatable', 'exempt', 'zero_rated')),
    -- sc_pwd          = 20% + VAT exemption for SC/PWD (e.g. medicine)
    -- basic_necessity = 5% for SC (basic necessities / prime commodities)
    discount_class    VARCHAR(20)  NOT NULL DEFAULT 'none'
                      CHECK (discount_class IN ('none', 'sc_pwd', 'basic_necessity')),
    -- Cached on-hand count, maintained from stock_movements. Never update directly.
    stock_milli       BIGINT       NOT NULL DEFAULT 0,
    reorder_milli     BIGINT       NOT NULL DEFAULT 0,
    is_active         BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_products_name (name),
    FOREIGN KEY (category_id) REFERENCES categories (category_id),
    FOREIGN KEY (supplier_id) REFERENCES suppliers (supplier_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Customers and discounts
-- ---------------------------------------------------------------------

-- Walk-ins get no row; transactions.customer_id is NULL for them.
CREATE TABLE customers (
    customer_id   BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    full_name     VARCHAR(150) NOT NULL,
    phone         VARCHAR(40),
    email         VARCHAR(150),
    is_member     BOOLEAN      NOT NULL DEFAULT FALSE,
    member_since  DATE,
    created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Applied per line item. One discount per line; the app picks the best.
CREATE TABLE discount_types (
    discount_type_id  BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    code              VARCHAR(20)  NOT NULL UNIQUE,
    name              VARCHAR(100) NOT NULL,
    rate_bp           INT          NOT NULL CHECK (rate_bp BETWEEN 0 AND 10000),
    vat_exempt        BOOLEAN      NOT NULL DEFAULT FALSE,   -- remove VAT before discounting
    beneficiary_type  VARCHAR(3)   CHECK (beneficiary_type IN ('SC', 'PWD')),        -- NULL = anyone
    product_class     VARCHAR(20)  CHECK (product_class IN ('sc_pwd', 'basic_necessity')),  -- NULL = any
    -- Max purchase amount per beneficiary per week (basic necessities).
    weekly_cap_cents  BIGINT,
    valid_from        DATE,
    valid_to          DATE,
    is_active         BOOLEAN      NOT NULL DEFAULT TRUE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Sales
-- ---------------------------------------------------------------------

CREATE TABLE shifts (
    shift_id             BIGINT   NOT NULL AUTO_INCREMENT PRIMARY KEY,
    cashier_id           BIGINT   NOT NULL,
    opened_at            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at            DATETIME,
    opening_cash_cents   BIGINT   NOT NULL DEFAULT 0,
    counted_cash_cents   BIGINT,     -- counted at close
    expected_cash_cents  BIGINT,     -- opening + cash sales - cash refunds
    FOREIGN KEY (cashier_id) REFERENCES employees (employee_id)
) ENGINE = InnoDB;

-- Lifecycle: pending (order slip) -> paid -> (voided)
--                                 \-> voided (abandoned slip)
-- Payment: insert payments rows, then
--   UPDATE transactions SET status = 'paid', cashier_id = ?, shift_id = ? ...
-- and the triggers assign the invoice number, freeze totals, deduct stock.
CREATE TABLE transactions (
    transaction_id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    invoice_no              BIGINT       UNIQUE,
    status                  VARCHAR(10)  NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'paid', 'voided')),
    customer_id             BIGINT,
    clerk_id                BIGINT       NOT NULL,
    cashier_id              BIGINT,
    shift_id                BIGINT,

    -- SC / PWD details, required on the invoice by BIR
    beneficiary_type        VARCHAR(3)   CHECK (beneficiary_type IN ('SC', 'PWD')),
    beneficiary_id_no       VARCHAR(50),
    beneficiary_name        VARCHAR(150),

    -- Frozen from the line items when paid.
    gross_cents             BIGINT       NOT NULL DEFAULT 0,
    vat_removed_cents       BIGINT       NOT NULL DEFAULT 0,
    discount_cents          BIGINT       NOT NULL DEFAULT 0,
    total_cents             BIGINT       NOT NULL DEFAULT 0,   -- amount due
    vatable_sales_cents     BIGINT       NOT NULL DEFAULT 0,   -- net of VAT
    vat_cents               BIGINT       NOT NULL DEFAULT 0,
    vat_exempt_sales_cents  BIGINT       NOT NULL DEFAULT 0,
    zero_rated_sales_cents  BIGINT       NOT NULL DEFAULT 0,

    created_at              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    paid_at                 DATETIME,
    voided_at               DATETIME,
    voided_by               BIGINT,
    void_reason             VARCHAR(255),

    CHECK ((beneficiary_type IS NULL) = (beneficiary_id_no IS NULL)),
    CHECK (beneficiary_type IS NULL OR beneficiary_name IS NOT NULL),
    CHECK (status <> 'paid' OR cashier_id IS NOT NULL),
    CHECK (status <> 'voided'
           OR (voided_at IS NOT NULL AND voided_by IS NOT NULL AND void_reason IS NOT NULL)),

    INDEX idx_transactions_status (status, created_at),
    INDEX idx_transactions_paid_at (paid_at),
    INDEX idx_transactions_beneficiary (beneficiary_id_no, paid_at),
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id),
    FOREIGN KEY (clerk_id)    REFERENCES employees (employee_id),
    FOREIGN KEY (cashier_id)  REFERENCES employees (employee_id),
    FOREIGN KEY (shift_id)    REFERENCES shifts (shift_id),
    FOREIGN KEY (voided_by)   REFERENCES employees (employee_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE transaction_items (
    transaction_item_id  BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
    transaction_id       BIGINT      NOT NULL,
    product_id           BIGINT      NOT NULL,
    qty_milli            INT         NOT NULL CHECK (qty_milli > 0),
    unit_price_cents     BIGINT      NOT NULL CHECK (unit_price_cents >= 0),  -- price at time of sale
    tax_treatment        VARCHAR(10) NOT NULL
                         CHECK (tax_treatment IN ('vatable', 'exempt', 'zero_rated', 'non_vat')),
    discount_type_id     BIGINT,
    gross_cents          BIGINT      NOT NULL CHECK (gross_cents >= 0),
    vat_removed_cents    BIGINT      NOT NULL DEFAULT 0 CHECK (vat_removed_cents >= 0),
    discount_cents       BIGINT      NOT NULL DEFAULT 0 CHECK (discount_cents >= 0),
    net_cents            BIGINT      NOT NULL CHECK (net_cents >= 0),
    vat_cents            BIGINT      NOT NULL DEFAULT 0 CHECK (vat_cents >= 0),

    CHECK (net_cents = gross_cents - vat_removed_cents - discount_cents),
    CHECK (tax_treatment = 'vatable' OR vat_cents = 0),
    CHECK (vat_removed_cents = 0 OR tax_treatment = 'exempt'),
    CHECK (discount_cents = 0 OR discount_type_id IS NOT NULL),

    FOREIGN KEY (transaction_id)   REFERENCES transactions (transaction_id),
    FOREIGN KEY (product_id)       REFERENCES products (product_id),
    FOREIGN KEY (discount_type_id) REFERENCES discount_types (discount_type_id)
) ENGINE = InnoDB;


-- ---------------------------------------------------------------------
-- Returns
-- ---------------------------------------------------------------------

-- Refund: cash_refund_cents = total credit.
-- Exchange: new items go on a NEW transaction paid with an
-- 'exchange_credit' payment pointing here; leftover credit is refunded.
CREATE TABLE returns (
    return_id                BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    original_transaction_id  BIGINT       NOT NULL,
    processed_by             BIGINT       NOT NULL,
    approved_by              BIGINT,
    shift_id                 BIGINT,
    resolution               VARCHAR(10)  NOT NULL CHECK (resolution IN ('refund', 'exchange')),
    reason                   VARCHAR(255) NOT NULL,
    cash_refund_cents        BIGINT       NOT NULL DEFAULT 0 CHECK (cash_refund_cents >= 0),
    created_at               DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (original_transaction_id) REFERENCES transactions (transaction_id),
    FOREIGN KEY (processed_by)            REFERENCES employees (employee_id),
    FOREIGN KEY (approved_by)             REFERENCES employees (employee_id),
    FOREIGN KEY (shift_id)                REFERENCES shifts (shift_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE return_items (
    return_item_id       BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
    return_id            BIGINT      NOT NULL,
    transaction_item_id  BIGINT      NOT NULL,
    qty_milli            INT         NOT NULL CHECK (qty_milli > 0),
    -- round(original net_cents × returned qty / sold qty)
    credit_cents         BIGINT      NOT NULL CHECK (credit_cents >= 0),
    item_condition       VARCHAR(10) NOT NULL CHECK (item_condition IN ('resellable', 'damaged')),
    FOREIGN KEY (return_id)           REFERENCES returns (return_id),
    FOREIGN KEY (transaction_item_id) REFERENCES transaction_items (transaction_item_id)
) ENGINE = InnoDB;

CREATE TABLE payments (
    payment_id      BIGINT      NOT NULL AUTO_INCREMENT PRIMARY KEY,
    transaction_id  BIGINT      NOT NULL,
    method          VARCHAR(20) NOT NULL
                    CHECK (method IN ('cash', 'ewallet', 'card', 'exchange_credit')),
    amount_cents    BIGINT      NOT NULL CHECK (amount_cents > 0),
    tendered_cents  BIGINT,     -- cash only; change = tendered - amount
    reference_no    VARCHAR(100),
    return_id       BIGINT,     -- exchange_credit only
    created_at      DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CHECK (method <> 'cash' OR tendered_cents >= amount_cents),
    CHECK ((method = 'exchange_credit') = (return_id IS NOT NULL)),

    FOREIGN KEY (transaction_id) REFERENCES transactions (transaction_id),
    FOREIGN KEY (return_id)      REFERENCES returns (return_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- Append-only stock ledger. products.stock_milli is the running sum.
CREATE TABLE stock_movements (
    movement_id      BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    product_id       BIGINT       NOT NULL,
    qty_milli        INT          NOT NULL CHECK (qty_milli <> 0),   -- + in, - out
    reason           VARCHAR(12)  NOT NULL
                     CHECK (reason IN ('stock_in', 'sale', 'sale_void', 'return', 'adjustment')),
    transaction_id   BIGINT,
    return_item_id   BIGINT,
    supplier_id      BIGINT,
    unit_cost_cents  BIGINT,
    employee_id      BIGINT,
    note             VARCHAR(255),
    created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stock_movements_product (product_id, created_at),
    FOREIGN KEY (product_id)     REFERENCES products (product_id),
    FOREIGN KEY (transaction_id) REFERENCES transactions (transaction_id),
    FOREIGN KEY (return_item_id) REFERENCES return_items (return_item_id),
    FOREIGN KEY (supplier_id)    REFERENCES suppliers (supplier_id),
    FOREIGN KEY (employee_id)    REFERENCES employees (employee_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;


-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------

-- Live totals of any transaction, computed from its lines.
-- VAT-exempt sales are shown before the SC/PWD discount (usual receipt layout).
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
       stock_milli / 1000   AS on_hand,
       reorder_milli / 1000 AS reorder_level
FROM products
WHERE is_active AND stock_milli <= reorder_milli;

-- Basis for the end-of-day (Z) reading.
CREATE VIEW v_daily_sales AS
SELECT DATE(paid_at)                                                        AS sales_date,
       MIN(invoice_no)                                                      AS first_invoice,
       MAX(invoice_no)                                                      AS last_invoice,
       SUM(status = 'paid')                                                 AS paid_count,
       SUM(status = 'voided')                                               AS voided_count,
       SUM(CASE WHEN status = 'paid' THEN gross_cents END)                  AS gross_cents,
       SUM(CASE WHEN status = 'paid' THEN discount_cents END)               AS discount_cents,
       SUM(CASE WHEN status = 'paid' THEN vat_removed_cents END)            AS vat_removed_cents,
       SUM(CASE WHEN status = 'paid' THEN total_cents END)                  AS net_sales_cents,
       SUM(CASE WHEN status = 'paid' THEN vatable_sales_cents END)          AS vatable_sales_cents,
       SUM(CASE WHEN status = 'paid' THEN vat_cents END)                    AS vat_cents,
       SUM(CASE WHEN status = 'paid' THEN vat_exempt_sales_cents END)       AS vat_exempt_sales_cents
FROM transactions
WHERE paid_at IS NOT NULL      -- voids of paid invoices still count here
GROUP BY DATE(paid_at);


-- ---------------------------------------------------------------------
-- Triggers
-- MySQL allows one event per trigger, and a trigger cannot write to the
-- table that fired it, so status changes set NEW.* in BEFORE UPDATE and
-- write stock in AFTER UPDATE.
-- ---------------------------------------------------------------------

DELIMITER $$

-- Stock: keep products.stock_milli equal to the sum of its movements.
CREATE TRIGGER stock_movements_apply
AFTER INSERT ON stock_movements
FOR EACH ROW
BEGIN
    UPDATE products
    SET stock_milli = stock_milli + NEW.qty_milli
    WHERE product_id = NEW.product_id;
END$$

-- The stock ledger is append-only: fix mistakes with an 'adjustment' row.
CREATE TRIGGER stock_movements_no_update
BEFORE UPDATE ON stock_movements
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'stock movements cannot be changed; add an adjustment instead';
END$$

CREATE TRIGGER stock_movements_no_delete
BEFORE DELETE ON stock_movements
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'stock movements cannot be changed; add an adjustment instead';
END$$

-- Lines can only change while the order is pending; whole-unit products
-- cannot be sold in fractions.
CREATE TRIGGER items_before_insert
BEFORE INSERT ON transaction_items
FOR EACH ROW
BEGIN
    IF (SELECT status FROM transactions WHERE transaction_id = NEW.transaction_id) <> 'pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'transaction is no longer pending';
    END IF;
    IF MOD(NEW.qty_milli, 1000) <> 0
       AND NOT (SELECT allow_fractional FROM products WHERE product_id = NEW.product_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'this product is sold in whole units only';
    END IF;
END$$

CREATE TRIGGER items_before_update
BEFORE UPDATE ON transaction_items
FOR EACH ROW
BEGIN
    IF (SELECT status FROM transactions WHERE transaction_id = OLD.transaction_id) <> 'pending'
       OR (SELECT status FROM transactions WHERE transaction_id = NEW.transaction_id) <> 'pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'transaction is no longer pending';
    END IF;
    IF MOD(NEW.qty_milli, 1000) <> 0
       AND NOT (SELECT allow_fractional FROM products WHERE product_id = NEW.product_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'this product is sold in whole units only';
    END IF;
END$$

CREATE TRIGGER items_before_delete
BEFORE DELETE ON transaction_items
FOR EACH ROW
BEGIN
    IF (SELECT status FROM transactions WHERE transaction_id = OLD.transaction_id) <> 'pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'transaction is no longer pending';
    END IF;
END$$

-- Payments can only change while the order is pending; exchange credit
-- cannot exceed what the return is worth.
CREATE TRIGGER payments_before_insert
BEFORE INSERT ON payments
FOR EACH ROW
BEGIN
    IF (SELECT status FROM transactions WHERE transaction_id = NEW.transaction_id) <> 'pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'transaction is no longer pending';
    END IF;
    IF NEW.method = 'exchange_credit' AND
       NEW.amount_cents
       + (SELECT COALESCE(SUM(amount_cents), 0) FROM payments WHERE return_id = NEW.return_id)
       + (SELECT cash_refund_cents FROM returns WHERE return_id = NEW.return_id)
       > (SELECT COALESCE(SUM(credit_cents), 0) FROM return_items WHERE return_id = NEW.return_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'exchange credit exceeds the value of the return';
    END IF;
END$$

CREATE TRIGGER payments_before_update
BEFORE UPDATE ON payments
FOR EACH ROW
BEGIN
    IF (SELECT status FROM transactions WHERE transaction_id = OLD.transaction_id) <> 'pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'transaction is no longer pending';
    END IF;
END$$

CREATE TRIGGER payments_before_delete
BEFORE DELETE ON payments
FOR EACH ROW
BEGIN
    IF (SELECT status FROM transactions WHERE transaction_id = OLD.transaction_id) <> 'pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'transaction is no longer pending';
    END IF;
END$$

-- New transactions always start as an empty pending order.
CREATE TRIGGER transactions_before_insert
BEFORE INSERT ON transactions
FOR EACH ROW
BEGIN
    IF NEW.status <> 'pending' OR NEW.invoice_no IS NOT NULL OR NEW.paid_at IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'new transactions must start as pending';
    END IF;
END$$

-- Status flow, locking, and the payment step.
--   pending -> paid     checks payments, assigns invoice no., freezes totals
--   pending -> voided   abandoned slip
--   paid    -> voided   only if the sale has no returns
-- A paid transaction can only be voided; a voided one cannot change at all.
CREATE TRIGGER transactions_before_update
BEFORE UPDATE ON transactions
FOR EACH ROW
BEGIN
    DECLARE v_lines       INT;
    DECLARE v_total       BIGINT;
    DECLARE v_paid        BIGINT;
    DECLARE v_no          BIGINT;
    DECLARE v_gross       BIGINT;
    DECLARE v_vat_removed BIGINT;
    DECLARE v_discount    BIGINT;
    DECLARE v_vatable     BIGINT;
    DECLARE v_vat         BIGINT;
    DECLARE v_exempt      BIGINT;
    DECLARE v_zero        BIGINT;

    IF OLD.status = 'voided' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'voided transactions cannot be changed';
    END IF;

    IF NEW.status <> OLD.status AND NOT (
           (OLD.status = 'pending' AND NEW.status IN ('paid', 'voided'))
        OR (OLD.status = 'paid'    AND NEW.status = 'voided')) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'invalid status change';
    END IF;

    IF OLD.status = 'paid' THEN
        -- everything except the status and void fields is frozen
        IF NOT (    NEW.transaction_id         <=> OLD.transaction_id
                AND NEW.invoice_no             <=> OLD.invoice_no
                AND NEW.customer_id            <=> OLD.customer_id
                AND NEW.clerk_id               <=> OLD.clerk_id
                AND NEW.cashier_id             <=> OLD.cashier_id
                AND NEW.shift_id               <=> OLD.shift_id
                AND NEW.beneficiary_type       <=> OLD.beneficiary_type
                AND NEW.beneficiary_id_no      <=> OLD.beneficiary_id_no
                AND NEW.beneficiary_name       <=> OLD.beneficiary_name
                AND NEW.gross_cents            <=> OLD.gross_cents
                AND NEW.vat_removed_cents      <=> OLD.vat_removed_cents
                AND NEW.discount_cents         <=> OLD.discount_cents
                AND NEW.total_cents            <=> OLD.total_cents
                AND NEW.vatable_sales_cents    <=> OLD.vatable_sales_cents
                AND NEW.vat_cents              <=> OLD.vat_cents
                AND NEW.vat_exempt_sales_cents <=> OLD.vat_exempt_sales_cents
                AND NEW.zero_rated_sales_cents <=> OLD.zero_rated_sales_cents
                AND NEW.created_at             <=> OLD.created_at
                AND NEW.paid_at                <=> OLD.paid_at) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'paid transactions are locked; only voiding is allowed';
        END IF;
        IF NEW.status = 'voided' AND
           EXISTS (SELECT 1 FROM returns WHERE original_transaction_id = NEW.transaction_id) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'this sale has returns; process a return instead of a void';
        END IF;
    END IF;

    IF OLD.status = 'pending' AND NEW.status = 'paid' THEN
        SELECT COUNT(*), COALESCE(SUM(net_cents), 0) INTO v_lines, v_total
        FROM transaction_items WHERE transaction_id = NEW.transaction_id;
        IF v_lines = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'cannot pay an empty order';
        END IF;

        SELECT COALESCE(SUM(amount_cents), 0) INTO v_paid
        FROM payments WHERE transaction_id = NEW.transaction_id;
        IF v_paid <> v_total THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'payments must equal the amount due';
        END IF;

        SELECT last_no + 1 INTO v_no FROM invoice_counter WHERE id = 1 FOR UPDATE;
        UPDATE invoice_counter SET last_no = v_no WHERE id = 1;
        SET NEW.invoice_no = v_no;
        SET NEW.paid_at    = CURRENT_TIMESTAMP;

        -- same sums as v_transaction_totals, read straight from the lines
        SELECT COALESCE(SUM(gross_cents), 0),
               COALESCE(SUM(vat_removed_cents), 0),
               COALESCE(SUM(discount_cents), 0),
               COALESCE(SUM(CASE WHEN tax_treatment = 'vatable' THEN net_cents - vat_cents END), 0),
               COALESCE(SUM(vat_cents), 0),
               COALESCE(SUM(CASE WHEN tax_treatment = 'exempt' THEN gross_cents - vat_removed_cents END), 0),
               COALESCE(SUM(CASE WHEN tax_treatment = 'zero_rated' THEN net_cents END), 0)
        INTO v_gross, v_vat_removed, v_discount, v_vatable, v_vat, v_exempt, v_zero
        FROM transaction_items
        WHERE transaction_id = NEW.transaction_id;

        SET NEW.gross_cents            = v_gross;
        SET NEW.vat_removed_cents      = v_vat_removed;
        SET NEW.discount_cents         = v_discount;
        SET NEW.total_cents            = v_total;
        SET NEW.vatable_sales_cents    = v_vatable;
        SET NEW.vat_cents              = v_vat;
        SET NEW.vat_exempt_sales_cents = v_exempt;
        SET NEW.zero_rated_sales_cents = v_zero;
    ELSEIF NEW.status = 'pending' AND (NEW.invoice_no IS NOT NULL OR NEW.paid_at IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'invoice number and paid time are set by the payment step';
    END IF;
END$$

-- After paying, deduct stock; after voiding a paid sale, put it back.
CREATE TRIGGER transactions_after_update
AFTER UPDATE ON transactions
FOR EACH ROW
BEGIN
    IF OLD.status = 'pending' AND NEW.status = 'paid' THEN
        INSERT INTO stock_movements (product_id, qty_milli, reason, transaction_id, employee_id)
        SELECT product_id, -qty_milli, 'sale', transaction_id, NEW.cashier_id
        FROM transaction_items
        WHERE transaction_id = NEW.transaction_id;
    ELSEIF OLD.status = 'paid' AND NEW.status = 'voided' THEN
        INSERT INTO stock_movements (product_id, qty_milli, reason, transaction_id, employee_id)
        SELECT product_id, qty_milli, 'sale_void', transaction_id, NEW.voided_by
        FROM transaction_items
        WHERE transaction_id = NEW.transaction_id;
    END IF;
END$$

CREATE TRIGGER transactions_before_delete
BEFORE DELETE ON transactions
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'transactions cannot be deleted; void them instead';
END$$

-- Returns: item must come from the original paid sale, and you cannot
-- return more than was bought (across all returns of that line).
CREATE TRIGGER return_items_before_insert
BEFORE INSERT ON return_items
FOR EACH ROW
BEGIN
    DECLARE v_item_txn BIGINT;
    DECLARE v_sold     INT;
    DECLARE v_orig_txn BIGINT;

    SELECT transaction_id, qty_milli INTO v_item_txn, v_sold
    FROM transaction_items WHERE transaction_item_id = NEW.transaction_item_id;
    SELECT original_transaction_id INTO v_orig_txn
    FROM returns WHERE return_id = NEW.return_id;

    IF NOT (v_item_txn <=> v_orig_txn) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'item is not from the original transaction';
    END IF;
    IF (SELECT status FROM transactions WHERE transaction_id = v_orig_txn) <> 'paid' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'original transaction is not paid';
    END IF;
    IF NEW.qty_milli
       + (SELECT COALESCE(SUM(qty_milli), 0) FROM return_items
          WHERE transaction_item_id = NEW.transaction_item_id)
       > v_sold THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'returning more than was sold';
    END IF;
END$$

-- Resellable returns go back into stock.
CREATE TRIGGER return_items_after_insert
AFTER INSERT ON return_items
FOR EACH ROW
BEGIN
    IF NEW.item_condition = 'resellable' THEN
        INSERT INTO stock_movements (product_id, qty_milli, reason, return_item_id, employee_id)
        SELECT ti.product_id, NEW.qty_milli, 'return', NEW.return_item_id, r.processed_by
        FROM transaction_items ti, returns r
        WHERE ti.transaction_item_id = NEW.transaction_item_id
          AND r.return_id = NEW.return_id;
    END IF;
END$$

-- Cash refunded plus exchange credit used cannot exceed the return's value.
CREATE TRIGGER returns_before_update
BEFORE UPDATE ON returns
FOR EACH ROW
BEGIN
    IF NEW.cash_refund_cents
       + (SELECT COALESCE(SUM(amount_cents), 0) FROM payments WHERE return_id = NEW.return_id)
       > (SELECT COALESCE(SUM(credit_cents), 0) FROM return_items WHERE return_id = NEW.return_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'refund exceeds the value of the return';
    END IF;
END$$

DELIMITER ;


-- ---------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------

INSERT INTO store_settings (id, store_name) VALUES (1, 'My Store');
INSERT INTO invoice_counter (id, last_no) VALUES (1, 0);

-- weekly_cap_cents for SC_BN_5 is left NULL on purpose: set it from the
-- current DTI joint administrative order.
INSERT INTO discount_types (code, name, rate_bp, vat_exempt, beneficiary_type, product_class)
VALUES
    ('SC_20',   'Senior Citizen 20% (VAT-exempt)',     2000, TRUE,  'SC',  'sc_pwd'),
    ('PWD_20',  'PWD 20% (VAT-exempt)',                2000, TRUE,  'PWD', 'sc_pwd'),
    ('SC_BN_5', 'Senior Citizen 5% basic necessities',  500, FALSE, 'SC',  'basic_necessity');
