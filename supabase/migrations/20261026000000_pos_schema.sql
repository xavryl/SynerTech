-- =====================================================================
-- POS v1 — PostgreSQL schema
-- PostgreSQL 15 or newer. Runs as-is on:
--   * a local/LAN PostgreSQL server
--   * Supabase (see supabase/migrations for auth + row level security)
--   * Google Cloud SQL for PostgreSQL / AlloyDB
--   * AWS RDS for PostgreSQL / Aurora PostgreSQL
--
-- Same design as sqlite/schema.sql. Differences:
--   * Timestamps are timestamptz (UTC inside); reports use
--     store_settings.time_zone (default Asia/Manila).
--   * Yes/no columns are boolean.
--   * Invoice numbers come from invoice_counter: gap-free and safe with
--     several cashiers paying at the same moment.
--   * Paid invoices are fully locked, totals included.
--
-- Conventions (identical in every version so the app logic is shared):
--   * Money     = bigint centavos.             ₱112.50 -> 11250
--   * Quantity  = integer thousandths (milli). 2 pcs -> 2000, 1.5 m -> 1500
--   * Rates     = integer basis points.        12% -> 1200, 20% -> 2000
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
create table store_settings (
    id                  smallint primary key check (id = 1),
    store_name          text     not null,
    address             text     not null default '',
    tin                 text     not null default '',
    is_vat_registered   boolean  not null default true,
    vat_rate_bp         integer  not null default 1200,
    return_window_days  integer  not null default 7,
    -- true  = clerk prints an order slip, cashier takes payment
    -- false = one person does both
    two_step_checkout   boolean  not null default true,
    time_zone           text     not null default 'Asia/Manila'
);

-- Exactly one row. Incremented inside the paying transaction, so a
-- rolled-back payment does not burn a number (BIR wants no gaps).
create table invoice_counter (
    id       smallint primary key check (id = 1),
    last_no  bigint   not null default 0
);

-- Permissions are nested and enforced by the app:
--   clerk   = build orders / slips
--   cashier = clerk + take payment, open/close shift
--   manager = everything + voids, returns past the window, price edits
create table employees (
    employee_id  bigint      generated always as identity primary key,
    full_name    text        not null,
    role         text        not null check (role in ('clerk', 'cashier', 'manager')),
    pin_hash     text        not null,   -- bcrypt/argon2 hash, never the raw PIN
    is_active    boolean     not null default true,
    created_at   timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------

create table categories (
    category_id  bigint generated always as identity primary key,
    name         text   not null unique
);

create table suppliers (
    supplier_id     bigint  generated always as identity primary key,
    name            text    not null,
    contact_person  text,
    phone           text,
    email           text,
    address         text,
    is_active       boolean not null default true
);

create table products (
    product_id        bigint      generated always as identity primary key,
    sku               text        not null unique,
    barcode           text        unique,            -- null if the item has none
    name              text        not null,
    category_id       bigint      not null references categories (category_id),
    supplier_id       bigint      references suppliers (supplier_id),
    unit              text        not null default 'pc',   -- pc, box, m, kg, L ...
    allow_fractional  boolean     not null default false,
    -- Shelf price. VAT-inclusive when the store is VAT-registered.
    price_cents       bigint      not null check (price_cents >= 0),
    cost_cents        bigint      not null default 0 check (cost_cents >= 0),
    vat_status        text        not null default 'vatable'
                      check (vat_status in ('vatable', 'exempt', 'zero_rated')),
    -- sc_pwd          = 20% + VAT exemption for SC/PWD (e.g. medicine)
    -- basic_necessity = 5% for SC (basic necessities / prime commodities)
    discount_class    text        not null default 'none'
                      check (discount_class in ('none', 'sc_pwd', 'basic_necessity')),
    -- Cached on-hand count, maintained from stock_movements. Never update directly.
    stock_milli       bigint      not null default 0,
    reorder_milli     bigint      not null default 0,
    is_active         boolean     not null default true,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

create index idx_products_name     on products (name);
create index idx_products_category on products (category_id);


-- ---------------------------------------------------------------------
-- Customers and discounts
-- ---------------------------------------------------------------------

-- Walk-ins get no row; transactions.customer_id is null for them.
create table customers (
    customer_id   bigint      generated always as identity primary key,
    full_name     text        not null,
    phone         text,
    email         text,
    is_member     boolean     not null default false,
    member_since  date,
    created_at    timestamptz not null default now()
);

-- Applied per line item. One discount per line; the app picks the best.
create table discount_types (
    discount_type_id  bigint  generated always as identity primary key,
    code              text    not null unique,
    name              text    not null,
    rate_bp           integer not null check (rate_bp between 0 and 10000),
    vat_exempt        boolean not null default false,   -- remove VAT before discounting
    beneficiary_type  text    check (beneficiary_type in ('SC', 'PWD')),        -- null = anyone
    product_class     text    check (product_class in ('sc_pwd', 'basic_necessity')),  -- null = any
    -- Max purchase amount per beneficiary per week (basic necessities).
    weekly_cap_cents  bigint,
    valid_from        date,
    valid_to          date,
    is_active         boolean not null default true
);


-- ---------------------------------------------------------------------
-- Sales
-- ---------------------------------------------------------------------

create table shifts (
    shift_id             bigint      generated always as identity primary key,
    cashier_id           bigint      not null references employees (employee_id),
    opened_at            timestamptz not null default now(),
    closed_at            timestamptz,
    opening_cash_cents   bigint      not null default 0,
    counted_cash_cents   bigint,     -- counted at close
    expected_cash_cents  bigint      -- opening + cash sales - cash refunds
);

-- Lifecycle: pending (order slip) -> paid -> (voided)
--                                 \-> voided (abandoned slip)
-- Payment: insert payments rows, then
--   update transactions set status = 'paid', cashier_id = $1, shift_id = $2 ...
-- and the triggers assign the invoice number, freeze totals, deduct stock.
create table transactions (
    transaction_id          bigint      generated always as identity primary key,
    invoice_no              bigint      unique,
    status                  text        not null default 'pending'
                            check (status in ('pending', 'paid', 'voided')),
    customer_id             bigint      references customers (customer_id),
    clerk_id                bigint      not null references employees (employee_id),
    cashier_id              bigint      references employees (employee_id),
    shift_id                bigint      references shifts (shift_id),

    -- SC / PWD details, required on the invoice by BIR
    beneficiary_type        text        check (beneficiary_type in ('SC', 'PWD')),
    beneficiary_id_no       text,
    beneficiary_name        text,

    -- Frozen from the line items when paid.
    gross_cents             bigint      not null default 0,
    vat_removed_cents       bigint      not null default 0,
    discount_cents          bigint      not null default 0,
    total_cents             bigint      not null default 0,   -- amount due
    vatable_sales_cents     bigint      not null default 0,   -- net of VAT
    vat_cents               bigint      not null default 0,
    vat_exempt_sales_cents  bigint      not null default 0,
    zero_rated_sales_cents  bigint      not null default 0,

    created_at              timestamptz not null default now(),
    paid_at                 timestamptz,
    voided_at               timestamptz,
    voided_by               bigint      references employees (employee_id),
    void_reason             text,

    check ((beneficiary_type is null) = (beneficiary_id_no is null)),
    check (beneficiary_type is null or beneficiary_name is not null),
    check (status <> 'paid' or cashier_id is not null),
    check (status <> 'voided'
           or (voided_at is not null and voided_by is not null and void_reason is not null))
);

create index idx_transactions_status      on transactions (status, created_at);
create index idx_transactions_paid_at     on transactions (paid_at);
create index idx_transactions_beneficiary on transactions (beneficiary_id_no, paid_at);

create table transaction_items (
    transaction_item_id  bigint  generated always as identity primary key,
    transaction_id       bigint  not null references transactions (transaction_id),
    product_id           bigint  not null references products (product_id),
    qty_milli            integer not null check (qty_milli > 0),
    unit_price_cents     bigint  not null check (unit_price_cents >= 0),  -- price at time of sale
    tax_treatment        text    not null
                         check (tax_treatment in ('vatable', 'exempt', 'zero_rated', 'non_vat')),
    discount_type_id     bigint  references discount_types (discount_type_id),
    gross_cents          bigint  not null check (gross_cents >= 0),
    vat_removed_cents    bigint  not null default 0 check (vat_removed_cents >= 0),
    discount_cents       bigint  not null default 0 check (discount_cents >= 0),
    net_cents            bigint  not null check (net_cents >= 0),
    vat_cents            bigint  not null default 0 check (vat_cents >= 0),

    check (net_cents = gross_cents - vat_removed_cents - discount_cents),
    check (tax_treatment = 'vatable' or vat_cents = 0),
    check (vat_removed_cents = 0 or tax_treatment = 'exempt'),
    check (discount_cents = 0 or discount_type_id is not null)
);

create index idx_transaction_items_txn on transaction_items (transaction_id);


-- ---------------------------------------------------------------------
-- Returns
-- ---------------------------------------------------------------------

-- Refund: cash_refund_cents = total credit.
-- Exchange: new items go on a NEW transaction paid with an
-- 'exchange_credit' payment pointing here; leftover credit is refunded.
create table returns (
    return_id                bigint      generated always as identity primary key,
    original_transaction_id  bigint      not null references transactions (transaction_id),
    processed_by             bigint      not null references employees (employee_id),
    approved_by              bigint      references employees (employee_id),
    shift_id                 bigint      references shifts (shift_id),
    resolution               text        not null check (resolution in ('refund', 'exchange')),
    reason                   text        not null,
    cash_refund_cents        bigint      not null default 0 check (cash_refund_cents >= 0),
    created_at               timestamptz not null default now()
);

create table return_items (
    return_item_id       bigint  generated always as identity primary key,
    return_id            bigint  not null references returns (return_id),
    transaction_item_id  bigint  not null references transaction_items (transaction_item_id),
    qty_milli            integer not null check (qty_milli > 0),
    -- round(original net_cents × returned qty / sold qty)
    credit_cents         bigint  not null check (credit_cents >= 0),
    item_condition       text    not null check (item_condition in ('resellable', 'damaged'))
);

create index idx_return_items_item on return_items (transaction_item_id);

create table payments (
    payment_id      bigint      generated always as identity primary key,
    transaction_id  bigint      not null references transactions (transaction_id),
    method          text        not null
                    check (method in ('cash', 'ewallet', 'card', 'exchange_credit')),
    amount_cents    bigint      not null check (amount_cents > 0),
    tendered_cents  bigint,     -- cash only; change = tendered - amount
    reference_no    text,
    return_id       bigint      references returns (return_id),   -- exchange_credit only
    created_at      timestamptz not null default now(),

    check (method <> 'cash' or tendered_cents >= amount_cents),
    check ((method = 'exchange_credit') = (return_id is not null))
);

create index idx_payments_txn on payments (transaction_id);

-- Append-only stock ledger. products.stock_milli is the running sum.
create table stock_movements (
    movement_id      bigint      generated always as identity primary key,
    product_id       bigint      not null references products (product_id),
    qty_milli        integer     not null check (qty_milli <> 0),   -- + in, - out
    reason           text        not null
                     check (reason in ('stock_in', 'sale', 'sale_void', 'return', 'adjustment')),
    transaction_id   bigint      references transactions (transaction_id),
    return_item_id   bigint      references return_items (return_item_id),
    supplier_id      bigint      references suppliers (supplier_id),
    unit_cost_cents  bigint,
    employee_id      bigint      references employees (employee_id),
    note             text,
    created_at       timestamptz not null default now()
);

create index idx_stock_movements_product on stock_movements (product_id, created_at);


-- ---------------------------------------------------------------------
-- Views
-- security_invoker: the view applies the caller's row level security
-- (matters on Supabase; harmless elsewhere).
-- ---------------------------------------------------------------------

create view v_transaction_totals with (security_invoker = true) as
select t.transaction_id,
       coalesce(sum(i.gross_cents), 0)::bigint       as gross_cents,
       coalesce(sum(i.vat_removed_cents), 0)::bigint as vat_removed_cents,
       coalesce(sum(i.discount_cents), 0)::bigint    as discount_cents,
       coalesce(sum(i.net_cents), 0)::bigint         as total_cents,
       coalesce(sum(i.net_cents - i.vat_cents)
                filter (where i.tax_treatment = 'vatable'), 0)::bigint      as vatable_sales_cents,
       coalesce(sum(i.vat_cents), 0)::bigint                                as vat_cents,
       -- shown before the SC/PWD discount, the usual receipt layout
       coalesce(sum(i.gross_cents - i.vat_removed_cents)
                filter (where i.tax_treatment = 'exempt'), 0)::bigint      as vat_exempt_sales_cents,
       coalesce(sum(i.net_cents)
                filter (where i.tax_treatment = 'zero_rated'), 0)::bigint  as zero_rated_sales_cents,
       count(i.transaction_item_id)::integer                                as line_count
from transactions t
left join transaction_items i on i.transaction_id = t.transaction_id
group by t.transaction_id;

create view v_low_stock with (security_invoker = true) as
select product_id, sku, name, unit,
       stock_milli / 1000.0   as on_hand,
       reorder_milli / 1000.0 as reorder_level
from products
where is_active and stock_milli <= reorder_milli;

-- Basis for the end-of-day (Z) reading, by store-local date.
create view v_daily_sales with (security_invoker = true) as
select (t.paid_at at time zone s.time_zone)::date                          as sales_date,
       min(t.invoice_no)                                                   as first_invoice,
       max(t.invoice_no)                                                   as last_invoice,
       count(*) filter (where t.status = 'paid')                           as paid_count,
       count(*) filter (where t.status = 'voided')                         as voided_count,
       sum(t.gross_cents)            filter (where t.status = 'paid')      as gross_cents,
       sum(t.discount_cents)         filter (where t.status = 'paid')      as discount_cents,
       sum(t.vat_removed_cents)      filter (where t.status = 'paid')      as vat_removed_cents,
       sum(t.total_cents)            filter (where t.status = 'paid')      as net_sales_cents,
       sum(t.vatable_sales_cents)    filter (where t.status = 'paid')      as vatable_sales_cents,
       sum(t.vat_cents)              filter (where t.status = 'paid')      as vat_cents,
       sum(t.vat_exempt_sales_cents) filter (where t.status = 'paid')      as vat_exempt_sales_cents
from transactions t
cross join store_settings s
where t.paid_at is not null       -- voids of paid invoices still count here
group by 1;


-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------

-- Stock: keep products.stock_milli equal to the sum of its movements.
create function trg_stock_movement_apply() returns trigger
language plpgsql as $$
begin
    update products
    set stock_milli = stock_milli + new.qty_milli,
        updated_at  = now()
    where product_id = new.product_id;
    return null;
end $$;

create trigger stock_movement_apply
after insert on stock_movements
for each row execute function trg_stock_movement_apply();

-- The stock ledger is append-only: fix mistakes with an 'adjustment' row.
create function trg_stock_movement_immutable() returns trigger
language plpgsql as $$
begin
    raise exception 'stock movements cannot be changed; add an adjustment instead';
end $$;

create trigger stock_movement_immutable
before update or delete on stock_movements
for each row execute function trg_stock_movement_immutable();

-- Lines can only change while the order is pending; whole-unit products
-- cannot be sold in fractions.
create function trg_items_guard() returns trigger
language plpgsql as $$
begin
    if tg_op in ('UPDATE', 'DELETE') and
       (select status from transactions where transaction_id = old.transaction_id) <> 'pending' then
        raise exception 'transaction is no longer pending';
    end if;

    if tg_op in ('INSERT', 'UPDATE') then
        if (select status from transactions where transaction_id = new.transaction_id) <> 'pending' then
            raise exception 'transaction is no longer pending';
        end if;
        if new.qty_milli % 1000 <> 0 and
           not (select allow_fractional from products where product_id = new.product_id) then
            raise exception 'this product is sold in whole units only';
        end if;
        return new;
    end if;

    return old;
end $$;

create trigger items_guard
before insert or update or delete on transaction_items
for each row execute function trg_items_guard();

-- Payments can only change while the order is pending; exchange credit
-- cannot exceed what the return is worth.
create function trg_payments_guard() returns trigger
language plpgsql as $$
declare
    v_txn bigint := case when tg_op = 'DELETE' then old.transaction_id else new.transaction_id end;
begin
    if (select status from transactions where transaction_id = v_txn) <> 'pending' then
        raise exception 'transaction is no longer pending';
    end if;

    if tg_op = 'INSERT' and new.method = 'exchange_credit' and
       new.amount_cents
       + (select coalesce(sum(amount_cents), 0) from payments where return_id = new.return_id)
       + (select cash_refund_cents from returns where return_id = new.return_id)
       > (select coalesce(sum(credit_cents), 0) from return_items where return_id = new.return_id) then
        raise exception 'exchange credit exceeds the value of the return';
    end if;

    return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger payments_guard
before insert or update or delete on payments
for each row execute function trg_payments_guard();

-- New transactions always start as an empty pending order.
create function trg_transactions_insert() returns trigger
language plpgsql as $$
begin
    if new.status <> 'pending' or new.invoice_no is not null or new.paid_at is not null then
        raise exception 'new transactions must start as pending';
    end if;
    return new;
end $$;

create trigger transactions_insert
before insert on transactions
for each row execute function trg_transactions_insert();

-- Status flow, locking, and the payment step.
--   pending -> paid     checks payments, assigns invoice no., freezes totals
--   pending -> voided   abandoned slip
--   paid    -> voided   only if the sale has no returns
-- A paid transaction can only be voided; a voided one cannot change at all.
create function trg_transactions_before_update() returns trigger
language plpgsql as $$
declare
    v_unchanged transactions;
    v_tot       record;
    v_paid      bigint;
begin
    if old.status = 'voided' then
        raise exception 'voided transactions cannot be changed';
    end if;

    if new.status <> old.status and not (
           (old.status = 'pending' and new.status in ('paid', 'voided'))
        or (old.status = 'paid'    and new.status = 'voided')) then
        raise exception 'invalid status change';
    end if;

    if old.status = 'paid' then
        v_unchanged             := new;
        v_unchanged.status      := old.status;
        v_unchanged.voided_at   := old.voided_at;
        v_unchanged.voided_by   := old.voided_by;
        v_unchanged.void_reason := old.void_reason;
        if v_unchanged is distinct from old then
            raise exception 'paid transactions are locked; only voiding is allowed';
        end if;
        if new.status = 'voided' and
           exists (select 1 from returns where original_transaction_id = new.transaction_id) then
            raise exception 'this sale has returns; process a return instead of a void';
        end if;
    end if;

    if old.status = 'pending' and new.status = 'paid' then
        select * into v_tot from v_transaction_totals where transaction_id = new.transaction_id;
        if v_tot.line_count = 0 then
            raise exception 'cannot pay an empty order';
        end if;

        select coalesce(sum(amount_cents), 0) into v_paid
        from payments where transaction_id = new.transaction_id;
        if v_paid <> v_tot.total_cents then
            raise exception 'payments must equal the amount due';
        end if;

        update invoice_counter set last_no = last_no + 1 where id = 1
        returning last_no into new.invoice_no;

        new.paid_at                := now();
        new.gross_cents            := v_tot.gross_cents;
        new.vat_removed_cents      := v_tot.vat_removed_cents;
        new.discount_cents         := v_tot.discount_cents;
        new.total_cents            := v_tot.total_cents;
        new.vatable_sales_cents    := v_tot.vatable_sales_cents;
        new.vat_cents              := v_tot.vat_cents;
        new.vat_exempt_sales_cents := v_tot.vat_exempt_sales_cents;
        new.zero_rated_sales_cents := v_tot.zero_rated_sales_cents;
    elsif new.status = 'pending' and
          (new.invoice_no is not null or new.paid_at is not null) then
        raise exception 'invoice number and paid time are set by the payment step';
    end if;

    return new;
end $$;

create trigger transactions_before_update
before update on transactions
for each row execute function trg_transactions_before_update();

-- After paying, deduct stock; after voiding a paid sale, put it back.
create function trg_transactions_after_update() returns trigger
language plpgsql as $$
begin
    if old.status = 'pending' and new.status = 'paid' then
        insert into stock_movements (product_id, qty_milli, reason, transaction_id, employee_id)
        select product_id, -qty_milli, 'sale', transaction_id, new.cashier_id
        from transaction_items
        where transaction_id = new.transaction_id;
    elsif old.status = 'paid' and new.status = 'voided' then
        insert into stock_movements (product_id, qty_milli, reason, transaction_id, employee_id)
        select product_id, qty_milli, 'sale_void', transaction_id, new.voided_by
        from transaction_items
        where transaction_id = new.transaction_id;
    end if;
    return null;
end $$;

create trigger transactions_after_update
after update of status on transactions
for each row execute function trg_transactions_after_update();

create function trg_transactions_no_delete() returns trigger
language plpgsql as $$
begin
    raise exception 'transactions cannot be deleted; void them instead';
end $$;

create trigger transactions_no_delete
before delete on transactions
for each row execute function trg_transactions_no_delete();

-- Returns: item must come from the original paid sale, and you cannot
-- return more than was bought (across all returns of that line).
create function trg_return_items_check() returns trigger
language plpgsql as $$
declare
    v_item transaction_items;
    v_ret  returns;
begin
    select * into v_item from transaction_items where transaction_item_id = new.transaction_item_id;
    select * into v_ret  from returns           where return_id = new.return_id;

    if v_item.transaction_id is distinct from v_ret.original_transaction_id then
        raise exception 'item is not from the original transaction';
    end if;
    if (select status from transactions where transaction_id = v_ret.original_transaction_id) <> 'paid' then
        raise exception 'original transaction is not paid';
    end if;
    if new.qty_milli
       + (select coalesce(sum(qty_milli), 0) from return_items
          where transaction_item_id = new.transaction_item_id)
       > v_item.qty_milli then
        raise exception 'returning more than was sold';
    end if;
    return new;
end $$;

create trigger return_items_check
before insert on return_items
for each row execute function trg_return_items_check();

-- Resellable returns go back into stock.
create function trg_return_items_restock() returns trigger
language plpgsql as $$
begin
    if new.item_condition = 'resellable' then
        insert into stock_movements (product_id, qty_milli, reason, return_item_id, employee_id)
        select ti.product_id, new.qty_milli, 'return', new.return_item_id, r.processed_by
        from transaction_items ti, returns r
        where ti.transaction_item_id = new.transaction_item_id
          and r.return_id = new.return_id;
    end if;
    return null;
end $$;

create trigger return_items_restock
after insert on return_items
for each row execute function trg_return_items_restock();

-- Cash refunded plus exchange credit used cannot exceed the return's value.
create function trg_returns_refund_check() returns trigger
language plpgsql as $$
begin
    if new.cash_refund_cents
       + (select coalesce(sum(amount_cents), 0) from payments where return_id = new.return_id)
       > (select coalesce(sum(credit_cents), 0) from return_items where return_id = new.return_id) then
        raise exception 'refund exceeds the value of the return';
    end if;
    return new;
end $$;

create trigger returns_refund_check
before update of cash_refund_cents on returns
for each row execute function trg_returns_refund_check();


-- ---------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------

insert into store_settings (id, store_name) values (1, 'My Store');
insert into invoice_counter (id, last_no) values (1, 0);

-- weekly_cap_cents for SC_BN_5 is left null on purpose: set it from the
-- current DTI joint administrative order.
insert into discount_types (code, name, rate_bp, vat_exempt, beneficiary_type, product_class)
values
    ('SC_20',   'Senior Citizen 20% (VAT-exempt)',     2000, true,  'SC',  'sc_pwd'),
    ('PWD_20',  'PWD 20% (VAT-exempt)',                2000, true,  'PWD', 'sc_pwd'),
    ('SC_BN_5', 'Senior Citizen 5% basic necessities',  500, false, 'SC',  'basic_necessity');
