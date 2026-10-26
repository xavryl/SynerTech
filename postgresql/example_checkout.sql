-- =====================================================================
-- Walkthrough: run after schema.sql on a fresh database, e.g.
--   psql -d pos -f schema.sql -f example_checkout.sql
-- Same scenarios as sqlite/example_checkout.sql:
--   1. stock-in from a supplier
--   2. Senior Citizen sale (20% VAT-exempt + 5% basic necessity)
--   3. regular sale of a fractional item (2.5 m of wire)
--   4. refund return
--   5. exchange return
-- Each DO block runs as one database transaction: all-or-nothing.
-- In the app, the same steps are plain INSERT ... RETURNING calls
-- wrapped in BEGIN / COMMIT.
-- =====================================================================

-- ---- setup ---------------------------------------------------------

insert into employees (full_name, role, pin_hash) values
    ('Clerk One',   'clerk',   '<hash>'),
    ('Cashier One', 'cashier', '<hash>'),
    ('Manager One', 'manager', '<hash>');

insert into categories (name) values ('Medicine'), ('Grocery'), ('Electrical');
insert into suppliers (name) values ('Main Distributor');

insert into products
    (sku, barcode, name, category_id, supplier_id, unit, allow_fractional,
     price_cents, cost_cents, vat_status, discount_class, reorder_milli)
select v.sku, v.barcode, v.name, c.category_id, s.supplier_id, v.unit, v.frac,
       v.price, v.cost, v.vat, v.dclass, v.reorder
from (values
    ('MED-0001', '4800000000011', 'Paracetamol 500mg (box of 20)', 'Medicine',   'box', false, 11200, 8000, 'vatable', 'sc_pwd',          5000),
    ('GRO-0001', null,            'Rice, regular milled',          'Grocery',    'kg',  true,   5600, 4500, 'exempt',  'basic_necessity', 20000),
    ('ELE-0001', null,            'THHN wire #14',                 'Electrical', 'm',   true,   3500, 2200, 'vatable', 'none',            50000),
    ('ELE-0002', '4800000000028', 'Electrical tape',               'Electrical', 'pc',  false,  3500, 2000, 'vatable', 'none',            5000)
) as v (sku, barcode, name, category, unit, frac, price, cost, vat, dclass, reorder)
join categories c on c.name = v.category
cross join (select supplier_id from suppliers where name = 'Main Distributor') s;

-- ---- 1. stock-in -----------------------------------------------------

insert into stock_movements (product_id, qty_milli, reason, supplier_id, unit_cost_cents, employee_id)
select p.product_id, v.qty, 'stock_in', p.supplier_id, p.cost_cents,
       (select employee_id from employees where full_name = 'Manager One')
from (values ('MED-0001', 10000), ('GRO-0001', 50000), ('ELE-0001', 100000), ('ELE-0002', 10000))
     as v (sku, qty)
join products p on p.sku = v.sku;

insert into shifts (cashier_id, opening_cash_cents)
select employee_id, 100000 from employees where full_name = 'Cashier One';

-- ---- 2. Senior Citizen sale -------------------------------------------
--   Paracetamol ×2: gross 22400 -> base 20000 (VAT removed 2400) -> 20% 4000 -> net 16000
--   Rice 2 kg:      gross 11200 -> exempt item, 5% 560                       -> net 10640
--   Amount due: 26640 (₱266.40)

do $$
declare
    v_clerk   bigint := (select employee_id from employees where full_name = 'Clerk One');
    v_cashier bigint := (select employee_id from employees where full_name = 'Cashier One');
    v_shift   bigint := (select max(shift_id) from shifts);
    v_txn     bigint;
begin
    insert into transactions (clerk_id, beneficiary_type, beneficiary_id_no, beneficiary_name)
    values (v_clerk, 'SC', 'SC-12345', 'Juan Dela Cruz')
    returning transaction_id into v_txn;

    insert into transaction_items
        (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment,
         discount_type_id, gross_cents, vat_removed_cents, discount_cents, net_cents, vat_cents)
    values
        (v_txn, (select product_id from products where sku = 'MED-0001'), 2000, 11200, 'exempt',
         (select discount_type_id from discount_types where code = 'SC_20'), 22400, 2400, 4000, 16000, 0),
        (v_txn, (select product_id from products where sku = 'GRO-0001'), 2000,  5600, 'exempt',
         (select discount_type_id from discount_types where code = 'SC_BN_5'), 11200, 0, 560, 10640, 0);

    -- cashier takes ₱300 cash
    insert into payments (transaction_id, method, amount_cents, tendered_cents)
    values (v_txn, 'cash', 26640, 30000);

    update transactions set status = 'paid', cashier_id = v_cashier, shift_id = v_shift
    where transaction_id = v_txn;
end $$;

-- ---- 3. regular sale, 2.5 m of wire -----------------------------------
--   gross 8750, vatable: VAT = 8750 - round(8750 / 1.12) = 8750 - 7813 = 937

do $$
declare
    v_clerk   bigint := (select employee_id from employees where full_name = 'Clerk One');
    v_cashier bigint := (select employee_id from employees where full_name = 'Cashier One');
    v_shift   bigint := (select max(shift_id) from shifts);
    v_txn     bigint;
begin
    insert into transactions (clerk_id) values (v_clerk) returning transaction_id into v_txn;

    insert into transaction_items
        (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment,
         gross_cents, net_cents, vat_cents)
    values (v_txn, (select product_id from products where sku = 'ELE-0001'), 2500, 3500, 'vatable',
            8750, 8750, 937);

    insert into payments (transaction_id, method, amount_cents, tendered_cents)
    values (v_txn, 'cash', 8750, 10000);

    update transactions set status = 'paid', cashier_id = v_cashier, shift_id = v_shift
    where transaction_id = v_txn;
end $$;

-- ---- 4. refund: 1 box of paracetamol from invoice 1 -------------------
--   credit = round(16000 × 1 / 2) = 8000 (what the SC actually paid)

do $$
declare
    v_cashier bigint := (select employee_id from employees where full_name = 'Cashier One');
    v_orig    bigint := (select transaction_id from transactions where invoice_no = 1);
    v_ret     bigint;
begin
    insert into returns (original_transaction_id, processed_by, shift_id, resolution, reason)
    values (v_orig, v_cashier, (select max(shift_id) from shifts), 'refund', 'Wrong dosage bought')
    returning return_id into v_ret;

    insert into return_items (return_id, transaction_item_id, qty_milli, credit_cents, item_condition)
    select v_ret, ti.transaction_item_id, 1000, 8000, 'resellable'
    from transaction_items ti
    join products p on p.product_id = ti.product_id
    where ti.transaction_id = v_orig and p.sku = 'MED-0001';

    update returns set cash_refund_cents = 8000 where return_id = v_ret;
end $$;

-- ---- 5. exchange: 1 m of damaged wire from invoice 2 for 1 tape -------
--   credit = round(8750 × 1000 / 2500) = 3500; tape costs 3500 -> equal value

do $$
declare
    v_cashier bigint := (select employee_id from employees where full_name = 'Cashier One');
    v_shift   bigint := (select max(shift_id) from shifts);
    v_orig    bigint := (select transaction_id from transactions where invoice_no = 2);
    v_ret     bigint;
    v_txn     bigint;
begin
    insert into returns (original_transaction_id, processed_by, shift_id, resolution, reason)
    values (v_orig, v_cashier, v_shift, 'exchange', 'Insulation cut')
    returning return_id into v_ret;

    insert into return_items (return_id, transaction_item_id, qty_milli, credit_cents, item_condition)
    select v_ret, transaction_item_id, 1000, 3500, 'damaged'
    from transaction_items where transaction_id = v_orig;

    insert into transactions (clerk_id) values (v_cashier) returning transaction_id into v_txn;

    insert into transaction_items
        (transaction_id, product_id, qty_milli, unit_price_cents, tax_treatment,
         gross_cents, net_cents, vat_cents)
    values (v_txn, (select product_id from products where sku = 'ELE-0002'), 1000, 3500, 'vatable',
            3500, 3500, 375);

    insert into payments (transaction_id, method, amount_cents, return_id)
    values (v_txn, 'exchange_credit', 3500, v_ret);

    update transactions set status = 'paid', cashier_id = v_cashier, shift_id = v_shift
    where transaction_id = v_txn;
end $$;

-- ---- results ---------------------------------------------------------

select transaction_id, invoice_no, status, beneficiary_type,
       gross_cents, vat_removed_cents, discount_cents, total_cents,
       vatable_sales_cents, vat_cents, vat_exempt_sales_cents
from transactions order by transaction_id;

-- Expected on hand: paracetamol 9, rice 48, wire 97.5, tape 9.
select sku, name, stock_milli / 1000.0 as on_hand from products order by product_id;

select * from v_daily_sales;
