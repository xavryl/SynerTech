-- =====================================================================
-- POS v1 — Supabase: staff login and row level security
-- Runs after 20261026000000_pos_schema.sql (a copy of postgresql/schema.sql).
--
-- Supabase exposes every table in "public" through its API, and the
-- browser holds the anon key. Row level security (RLS) is what stops a
-- clerk, or anyone with the key, from doing more than they should.
--
-- How staff log in:
--   1. Create the user in Supabase Auth (dashboard or auth.admin API).
--   2. Link it:  update employees set auth_user_id = '<auth user uuid>'
--                where employee_id = ...;
--   Every policy below looks up the logged-in user's employee row.
--
-- Triggers that write on the user's behalf (invoice counter, stock
-- ledger, cached stock) run as SECURITY DEFINER, so a cashier can
-- complete a sale without having write access to products or
-- stock_movements directly.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Link employees to Supabase Auth
-- ---------------------------------------------------------------------

alter table employees
    add column auth_user_id uuid unique references auth.users (id) on delete set null;

-- Supabase Auth handles the password; the PIN becomes an optional quick
-- manager override.
alter table employees alter column pin_hash drop not null;

-- The logged-in user's employee row, if active.
create function public.current_employee_id() returns bigint
language sql stable security definer set search_path = public as $$
    select employee_id from employees where auth_user_id = auth.uid() and is_active
$$;

create function public.current_employee_role() returns text
language sql stable security definer set search_path = public as $$
    select role from employees where auth_user_id = auth.uid() and is_active
$$;

-- Nobody outside the staff list gets anything.
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on function public.current_employee_id()   from anon;
revoke execute on function public.current_employee_role() from anon;

-- Staff can read employee names and roles, but never the PIN hash.
revoke select on employees from authenticated;
grant  select (employee_id, full_name, role, is_active, created_at, auth_user_id)
    on employees to authenticated;


-- ---------------------------------------------------------------------
-- Trigger functions run as the table owner
-- ---------------------------------------------------------------------

alter function trg_stock_movement_apply()       security definer set search_path = public;
alter function trg_stock_movement_immutable()   security definer set search_path = public;
alter function trg_items_guard()                security definer set search_path = public;
alter function trg_payments_guard()             security definer set search_path = public;
alter function trg_transactions_insert()        security definer set search_path = public;
alter function trg_transactions_before_update() security definer set search_path = public;
alter function trg_transactions_after_update()  security definer set search_path = public;
alter function trg_transactions_no_delete()     security definer set search_path = public;
alter function trg_return_items_check()         security definer set search_path = public;
alter function trg_return_items_restock()       security definer set search_path = public;
alter function trg_returns_refund_check()       security definer set search_path = public;


-- ---------------------------------------------------------------------
-- Row level security
-- Every table is locked by default once RLS is on; each policy below
-- opens one specific door. There are no DELETE policies except for
-- order lines and payments on pending orders: everything else is
-- deactivated or voided instead.
-- ---------------------------------------------------------------------

alter table store_settings     enable row level security;
alter table invoice_counter    enable row level security;   -- no policies: triggers only
alter table employees          enable row level security;
alter table categories         enable row level security;
alter table suppliers          enable row level security;
alter table products           enable row level security;
alter table customers          enable row level security;
alter table discount_types     enable row level security;
alter table shifts             enable row level security;
alter table transactions       enable row level security;
alter table transaction_items  enable row level security;
alter table returns            enable row level security;
alter table return_items       enable row level security;
alter table payments           enable row level security;
alter table stock_movements    enable row level security;

-- Any active staff member can read everything they are allowed to see.
create policy staff_read on store_settings    for select to authenticated using (current_employee_role() is not null);
create policy staff_read on employees         for select to authenticated using (current_employee_role() is not null);
create policy staff_read on categories        for select to authenticated using (current_employee_role() is not null);
create policy staff_read on suppliers         for select to authenticated using (current_employee_role() is not null);
create policy staff_read on products          for select to authenticated using (current_employee_role() is not null);
create policy staff_read on customers         for select to authenticated using (current_employee_role() is not null);
create policy staff_read on discount_types    for select to authenticated using (current_employee_role() is not null);
create policy staff_read on shifts            for select to authenticated using (current_employee_role() is not null);
create policy staff_read on transactions      for select to authenticated using (current_employee_role() is not null);
create policy staff_read on transaction_items for select to authenticated using (current_employee_role() is not null);
create policy staff_read on returns           for select to authenticated using (current_employee_role() is not null);
create policy staff_read on return_items      for select to authenticated using (current_employee_role() is not null);
create policy staff_read on payments          for select to authenticated using (current_employee_role() is not null);
create policy staff_read on stock_movements   for select to authenticated using (current_employee_role() is not null);

-- Managers maintain setup and the catalog.
create policy manager_write on store_settings for update to authenticated
    using (current_employee_role() = 'manager') with check (current_employee_role() = 'manager');

create policy manager_insert on employees for insert to authenticated
    with check (current_employee_role() = 'manager');
create policy manager_update on employees for update to authenticated
    using (current_employee_role() = 'manager') with check (current_employee_role() = 'manager');

create policy manager_insert on categories for insert to authenticated
    with check (current_employee_role() = 'manager');
create policy manager_update on categories for update to authenticated
    using (current_employee_role() = 'manager') with check (current_employee_role() = 'manager');

create policy manager_insert on suppliers for insert to authenticated
    with check (current_employee_role() = 'manager');
create policy manager_update on suppliers for update to authenticated
    using (current_employee_role() = 'manager') with check (current_employee_role() = 'manager');

create policy manager_insert on products for insert to authenticated
    with check (current_employee_role() = 'manager');
create policy manager_update on products for update to authenticated
    using (current_employee_role() = 'manager') with check (current_employee_role() = 'manager');

create policy manager_insert on discount_types for insert to authenticated
    with check (current_employee_role() = 'manager');
create policy manager_update on discount_types for update to authenticated
    using (current_employee_role() = 'manager') with check (current_employee_role() = 'manager');

-- Deliveries and count corrections. Sales, voids and returns write the
-- ledger through triggers, not through this policy.
create policy manager_insert on stock_movements for insert to authenticated
    with check (current_employee_role() = 'manager'
                and reason in ('stock_in', 'adjustment')
                and employee_id = current_employee_id());

-- Any staff member can register a customer or member.
create policy staff_insert on customers for insert to authenticated
    with check (current_employee_role() is not null);
create policy staff_update on customers for update to authenticated
    using (current_employee_role() is not null) with check (current_employee_role() is not null);

-- Cashiers open and close their own shifts; managers any shift.
create policy cashier_insert on shifts for insert to authenticated
    with check (current_employee_role() = 'manager'
                or (current_employee_role() = 'cashier' and cashier_id = current_employee_id()));
create policy cashier_update on shifts for update to authenticated
    using (current_employee_role() = 'manager'
           or (current_employee_role() = 'cashier' and cashier_id = current_employee_id()))
    with check (current_employee_role() = 'manager'
                or (current_employee_role() = 'cashier' and cashier_id = current_employee_id()));

-- Orders: any staff member starts one under their own name.
create policy staff_insert on transactions for insert to authenticated
    with check (current_employee_role() is not null and clerk_id = current_employee_id());

-- While pending, staff may edit the order. Marking it paid requires a
-- cashier or manager recording themselves as cashier; voiding requires
-- a manager recording themselves as voided_by.
create policy pending_update on transactions for update to authenticated
    using (status = 'pending' and current_employee_role() is not null)
    with check (
        case status
            when 'pending' then current_employee_role() is not null
            when 'paid'    then current_employee_role() in ('cashier', 'manager')
                                and cashier_id = current_employee_id()
            when 'voided'  then current_employee_role() = 'manager'
                                and voided_by = current_employee_id()
        end);

-- A paid sale can only be voided, by a manager.
create policy manager_void on transactions for update to authenticated
    using (status = 'paid' and current_employee_role() = 'manager')
    with check (status = 'voided' and voided_by = current_employee_id());

-- Order lines: any staff member, pending orders only (enforced by trigger).
create policy staff_insert on transaction_items for insert to authenticated
    with check (current_employee_role() is not null);
create policy staff_update on transaction_items for update to authenticated
    using (current_employee_role() is not null) with check (current_employee_role() is not null);
create policy staff_delete on transaction_items for delete to authenticated
    using (current_employee_role() is not null);

-- Payments: cashiers and managers, pending orders only (enforced by trigger).
create policy cashier_insert on payments for insert to authenticated
    with check (current_employee_role() in ('cashier', 'manager'));
create policy cashier_delete on payments for delete to authenticated
    using (current_employee_role() in ('cashier', 'manager'));

-- Returns: cashiers and managers, under their own name. An approver,
-- when given, must be a manager.
create policy cashier_insert on returns for insert to authenticated
    with check (current_employee_role() in ('cashier', 'manager')
                and processed_by = current_employee_id()
                and (approved_by is null
                     or (select e.role from employees e where e.employee_id = approved_by) = 'manager'));
create policy cashier_update on returns for update to authenticated
    using (current_employee_role() in ('cashier', 'manager'))
    with check (current_employee_role() in ('cashier', 'manager')
                and (approved_by is null
                     or (select e.role from employees e where e.employee_id = approved_by) = 'manager'));

create policy cashier_insert on return_items for insert to authenticated
    with check (current_employee_role() in ('cashier', 'manager'));
