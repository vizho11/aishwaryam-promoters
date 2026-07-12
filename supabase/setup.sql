-- Aishwaryam Promoters — Real Estate Admin App — Supabase setup script
-- Run this once in your Supabase project's SQL Editor (Database -> SQL Editor -> New query).
-- Safe to re-run: uses "if not exists" / "or replace" everywhere.

create extension if not exists pgcrypto;

-- ============================================================
-- ONE-TIME MIGRATION (only touches anything if the earlier generic "properties" schema
-- exists — a fresh install has no "properties" table, so this whole block is a no-op then)
-- ============================================================
-- Earlier versions of this script modeled inventory as generic "properties" (apartment/
-- villa/commercial/rented). This app is for land plots specifically, superseded below by
-- "plots" (layout/plot number, extent, facing, corner, road width, available/booked/sold).
do $$
begin
  if to_regclass('public.properties') is not null then
    drop function if exists admin_add_property(text, text, text, text, numeric);
    drop function if exists admin_update_property(text, uuid, text, text, text, numeric, text);
    drop function if exists admin_delete_property(text, uuid);
    drop function if exists list_properties(text, uuid, text);
    if exists (select 1 from information_schema.columns where table_name = 'leads' and column_name = 'property_id') then
      alter table leads rename column property_id to plot_id;
    end if;
    drop table properties cascade;
  end if;
end $$;

-- ============================================================
-- TABLES
-- ============================================================

-- Singleton admin passcode. Locked down: no direct anon access, only via RPC below.
create table if not exists admin_config (
  id boolean primary key default true check (id),
  passcode_hash text
);

-- Failed-auth tracker for rate limiting (employee_login, verify_employee_credentials, admin
-- passcode). Only failures get recorded (see record_auth_attempt below), so normal
-- correct-password usage never accumulates rows here no matter how frequent.
create table if not exists auth_attempts (
  id bigserial primary key,
  target text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists auth_attempts_target_idx on auth_attempts(target, attempted_at);

-- Employee accounts. Admin-provisioned, never self-signup. Locked down: no direct anon
-- access at all, only via the SECURITY DEFINER functions below. Paid a fixed monthly
-- salary, not commission — monthly_target stays purely as a sales KPI for the
-- dashboard/leaderboard, independent of how the employee is actually paid.
create table if not exists employees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null unique,
  phone text default '',
  password_hash text not null,
  job_role text not null default '',
  monthly_target numeric not null default 0,
  monthly_salary numeric not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
-- Migrating an existing install: add the new columns, drop the old commission one.
alter table employees add column if not exists job_role text not null default '';
alter table employees add column if not exists monthly_salary numeric not null default 0;
alter table employees drop column if exists commission_rate;
-- Team grouping for the Team Performance view: '' (e.g. the manager, ungrouped), 'A', or 'B'.
alter table employees add column if not exists team_group text not null default '';

-- Layouts / ventures: named groupings of plots. Price is driven by *position* within the
-- layout (corner/front/road-facing/back/no-road-connection), not by plot size — each layout
-- carries a small price/sqft table in layout_price_tiers. "lowest" and "highest" are always
-- present (the baseline and premium rate); the position-specific ones are optional extras.
create table if not exists layouts (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  num_plots int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists layout_price_tiers (
  id uuid primary key default gen_random_uuid(),
  layout_id uuid not null references layouts(id) on delete cascade,
  position text not null check (position in ('lowest','highest','corner','front','road_facing','back','no_road')),
  price_per_sqft numeric not null default 0,
  unique(layout_id, position)
);

-- Land inventory: individual parcels, or numbered plots within a layout/venture.
-- layout_name/plot_number stay blank for a standalone parcel with no layout grouping.
-- layout_id links to layouts (drives auto price calc); layout_name is kept in sync with it
-- for display so existing plot-label rendering doesn't need to change.
create table if not exists plots (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  layout_name text default '',
  plot_number text default '',
  type text not null default 'residential',
  location text default '',
  extent_value numeric not null default 0,
  extent_unit text not null default 'sqft',
  facing text default '',
  is_corner boolean not null default false,
  road_width_ft numeric,
  price numeric not null default 0,
  status text not null default 'available',
  listed_at timestamptz not null default now()
);
alter table plots add column if not exists layout_id uuid references layouts(id) on delete set null;
alter table plots add column if not exists is_front boolean not null default false;
alter table plots add column if not exists is_road_facing boolean not null default false;
alter table plots add column if not exists is_back boolean not null default false;
alter table plots add column if not exists has_no_road boolean not null default false;

-- Lead / client pipeline — the backbone conversion rate and follow-ups are computed from.
create table if not exists leads (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text not null,
  source text default '',
  plot_id uuid,
  status text not null default 'new',
  assigned_to uuid references employees(id) on delete set null,
  budget numeric default 0,
  notes text default '',
  closed_value numeric default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists leads_assigned_to_idx on leads(assigned_to);

-- Added separately (rather than inline above) so it applies whether "leads" was just
-- created fresh with a plot_id column, or already existed and had it renamed by the
-- migration block — either way this adds the FK exactly once.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'leads_plot_id_fkey') then
    alter table leads add constraint leads_plot_id_fkey foreign key (plot_id) references plots(id) on delete set null;
  end if;
end $$;

create table if not exists follow_ups (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references leads(id) on delete cascade,
  employee_id uuid not null references employees(id) on delete cascade,
  due_at timestamptz not null,
  notes text default '',
  status text not null default 'pending',
  completed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists follow_ups_employee_idx on follow_ups(employee_id);

-- One row per employee per day. check_in/out lat/lng are captured from the browser's
-- Geolocation API at the moment of check-in/out (nullable — a denied/unavailable GPS
-- permission still lets check-in/out succeed, just without coordinates).
create table if not exists daily_activity (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references employees(id) on delete cascade,
  activity_date date not null,
  calls_made int not null default 0,
  site_visits int not null default 0,
  meetings int not null default 0,
  new_leads int not null default 0,
  check_in_time timestamptz,
  check_in_lat numeric,
  check_in_lng numeric,
  check_out_time timestamptz,
  check_out_lat numeric,
  check_out_lng numeric,
  notes text default '',
  unique(employee_id, activity_date)
);
alter table daily_activity add column if not exists check_in_lat numeric;
alter table daily_activity add column if not exists check_in_lng numeric;
alter table daily_activity add column if not exists check_out_lat numeric;
alter table daily_activity add column if not exists check_out_lng numeric;

create table if not exists day_offs (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references employees(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  reason text default '',
  status text not null default 'pending',
  requested_at timestamptz not null default now(),
  decided_at timestamptz
);
create index if not exists day_offs_employee_idx on day_offs(employee_id);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
-- Unlike a public marketplace, none of this business data is meant to be openly readable —
-- it's an internal company tool. every table below gets RLS enabled with ZERO policies, so
-- there is no direct anon/authenticated read or write of any kind. The only way in or out is
-- through the SECURITY DEFINER functions further down, each of which re-verifies the caller's
-- admin passcode or employee email+password itself — a direct API call bypasses nothing.

alter table admin_config enable row level security;
alter table auth_attempts enable row level security;
alter table employees enable row level security;
alter table layouts enable row level security;
alter table layout_price_tiers enable row level security;
alter table plots enable row level security;
alter table leads enable row level security;
alter table follow_ups enable row level security;
alter table daily_activity enable row level security;
alter table day_offs enable row level security;

-- ============================================================
-- SECURE RPC FUNCTIONS (SECURITY DEFINER = runs with elevated privilege,
-- bypassing the RLS lockout above, but only doing exactly what's coded here)
-- ============================================================

-- Rate limiting ---------------------------------------------------------

create or replace function check_rate_limit(p_target text, p_max_attempts int default 8, p_window_minutes int default 15)
returns boolean
language sql security definer as $$
  select count(*) < p_max_attempts
  from auth_attempts
  where target = p_target and attempted_at > now() - (p_window_minutes || ' minutes')::interval;
$$;

create or replace function record_auth_attempt(p_target text)
returns void
language sql security definer as $$
  delete from auth_attempts where target = p_target and attempted_at < now() - interval '1 day';
  insert into auth_attempts(target) values (p_target);
$$;

-- Admin passcode ----------------------------------------------------------

create or replace function admin_passcode_is_set()
returns boolean
language sql security definer as $$
  select exists(select 1 from admin_config where passcode_hash is not null);
$$;

-- NOT callable by anon/authenticated (see revoke below) — only reachable from the Supabase
-- SQL editor (which runs as the postgres superuser and bypasses grants), e.g.:
-- select admin_set_passcode('yourpasscode');
create or replace function admin_set_passcode(p_passcode text)
returns boolean
language plpgsql security definer as $$
begin
  if exists(select 1 from admin_config where passcode_hash is not null) then
    return false; -- already set, refuse to overwrite silently
  end if;
  insert into admin_config (id, passcode_hash) values (true, crypt(p_passcode, gen_salt('bf')))
  on conflict (id) do update set passcode_hash = excluded.passcode_hash
  where admin_config.passcode_hash is null;
  return true;
end;
$$;
revoke execute on function admin_set_passcode(text) from public;

create or replace function admin_verify_passcode(p_passcode text)
returns boolean
language plpgsql security definer as $$
declare
  v_ok boolean;
begin
  if p_passcode is null or p_passcode = '' then
    return false;
  end if;
  if not check_rate_limit('admin') then
    return false;
  end if;
  select coalesce(
    (select passcode_hash = crypt(p_passcode, passcode_hash) from admin_config where id = true),
    false
  ) into v_ok;
  if not v_ok then
    perform record_auth_attempt('admin');
  end if;
  return v_ok;
end;
$$;

-- Employee auth -------------------------------------------------------------

create or replace function employee_login(p_email text, p_password text)
returns jsonb
language plpgsql security definer as $$
declare
  v_email text := lower(trim(p_email));
  v_emp employees%rowtype;
  v_target text := 'emp:' || v_email;
begin
  if not check_rate_limit(v_target) then
    return jsonb_build_object('success', false, 'error', 'too_many_attempts');
  end if;
  select * into v_emp from employees where lower(email) = v_email;
  if not found then
    perform record_auth_attempt(v_target);
    return jsonb_build_object('success', false, 'error', 'no_account');
  end if;
  if not v_emp.active then
    return jsonb_build_object('success', false, 'error', 'account_inactive');
  end if;
  if v_emp.password_hash = crypt(p_password, v_emp.password_hash) then
    return jsonb_build_object('success', true, 'employee', jsonb_build_object(
      'id', v_emp.id, 'name', v_emp.name, 'email', v_emp.email, 'phone', v_emp.phone,
      'job_role', v_emp.job_role, 'monthly_target', v_emp.monthly_target, 'monthly_salary', v_emp.monthly_salary
    ));
  else
    perform record_auth_attempt(v_target);
    return jsonb_build_object('success', false, 'error', 'wrong_password');
  end if;
end;
$$;

-- Shared helper: every employee-scoped function below calls this itself rather than trusting
-- the client's "I'm already logged in" state — so calling the API directly, bypassing the
-- app's UI entirely, verifies nothing for free. Rate-limited by employee id (separately from
-- employee_login's by-email limit, since the id isn't known until after a successful lookup),
-- so repeated wrong-password guesses against any employee-scoped RPC still get locked out.
create or replace function verify_employee_credentials(p_employee_id uuid, p_password text)
returns boolean
language plpgsql security definer as $$
declare
  v_target text := 'emp:' || coalesce(p_employee_id::text, 'null');
  v_ok boolean;
begin
  if p_employee_id is null or p_password is null then
    return false;
  end if;
  if not check_rate_limit(v_target) then
    return false;
  end if;
  select exists(
    select 1 from employees
    where id = p_employee_id and active and password_hash = crypt(p_password, password_hash)
  ) into v_ok;
  if not v_ok then
    perform record_auth_attempt(v_target);
  end if;
  return v_ok;
end;
$$;

-- Shared helper: true if either the admin passcode or an employee's own credentials check
-- out. Used by read functions that both admin and logged-in employees are allowed to call
-- (each scoped to their own rows further down, not a blanket "anyone can see everything").
create or replace function is_authorized(p_admin_passcode text, p_employee_id uuid, p_password text)
returns boolean
language plpgsql security definer as $$
begin
  if p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode) then
    return true;
  end if;
  if p_employee_id is not null and p_password is not null and verify_employee_credentials(p_employee_id, p_password) then
    return true;
  end if;
  return false;
end;
$$;

-- Employee management (admin-only writes) -------------------------------------

-- These three change shape (commission_rate -> job_role + monthly_salary), and Postgres
-- won't let CREATE OR REPLACE rename/add/remove parameters or return columns on an existing
-- function of the same name — so drop the old shapes first (no-op on a fresh install).
drop function if exists admin_list_employees(text);
drop function if exists admin_create_employee(text, text, text, text, text, numeric, numeric);
drop function if exists admin_update_employee(text, uuid, text, text, numeric, numeric, boolean);

create or replace function admin_list_employees(p_admin_passcode text)
returns table(id uuid, name text, email text, phone text, job_role text, monthly_target numeric,
              monthly_salary numeric, active boolean, created_at timestamptz, team_group text)
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then
    raise exception 'invalid admin passcode';
  end if;
  return query select e.id, e.name, e.email, e.phone, e.job_role, e.monthly_target, e.monthly_salary,
                      e.active, e.created_at, e.team_group
  from employees e order by e.created_at desc;
end;
$$;

create or replace function admin_create_employee(
  p_admin_passcode text, p_name text, p_email text, p_phone text, p_password text,
  p_job_role text, p_monthly_target numeric, p_monthly_salary numeric, p_team_group text default ''
) returns jsonb
language plpgsql security definer as $$
declare
  v_email text := lower(trim(p_email));
  v_id uuid;
begin
  if not admin_verify_passcode(p_admin_passcode) then
    return jsonb_build_object('success', false, 'error', 'invalid admin passcode');
  end if;
  if exists(select 1 from employees where lower(email) = v_email) then
    return jsonb_build_object('success', false, 'error', 'An account with this email already exists.');
  end if;
  insert into employees (name, email, phone, password_hash, job_role, monthly_target, monthly_salary, team_group)
    values (trim(p_name), v_email, coalesce(p_phone,''), crypt(p_password, gen_salt('bf')),
            coalesce(p_job_role,''), coalesce(p_monthly_target,0), coalesce(p_monthly_salary,0), coalesce(p_team_group,''))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id, 'email', v_email);
end;
$$;

create or replace function admin_update_employee(
  p_admin_passcode text, p_employee_id uuid, p_name text, p_phone text, p_job_role text,
  p_monthly_target numeric, p_monthly_salary numeric, p_active boolean, p_team_group text default ''
) returns boolean
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then return false; end if;
  update employees set name = trim(p_name), phone = coalesce(p_phone,''), job_role = coalesce(p_job_role,''),
    monthly_target = coalesce(p_monthly_target,0), monthly_salary = coalesce(p_monthly_salary,0),
    active = p_active, team_group = coalesce(p_team_group,'')
  where id = p_employee_id;
  return found;
end;
$$;

create or replace function admin_reset_employee_password(p_admin_passcode text, p_employee_id uuid, p_new_password text)
returns boolean
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then return false; end if;
  update employees set password_hash = crypt(p_new_password, gen_salt('bf')) where id = p_employee_id;
  return found;
end;
$$;

create or replace function admin_delete_employee(p_admin_passcode text, p_employee_id uuid)
returns boolean
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then return false; end if;
  delete from employees where id = p_employee_id;
  return found;
end;
$$;

-- Name-only projection (no email/phone/target/salary) for assignment dropdowns and the
-- leaderboard — visible to any logged-in employee or admin, not just admin.
create or replace function list_employees_public(p_admin_passcode text, p_employee_id uuid, p_password text)
returns table(id uuid, name text)
language plpgsql security definer as $$
begin
  if not is_authorized(p_admin_passcode, p_employee_id, p_password) then
    return;
  end if;
  return query select e.id, e.name from employees e where e.active order by e.name;
end;
$$;

-- Ranks employees by closed-won value within a given month. Visible to any logged-in employee
-- or admin — deliberately excludes salary/target, which stay private to the employee and
-- admin (see employee_login and admin_list_employees).
create or replace function get_leaderboard(p_admin_passcode text, p_employee_id uuid, p_password text, p_month_start date default date_trunc('month', now())::date)
returns table(employee_id uuid, name text, closed_count bigint, closed_value numeric)
language plpgsql security definer as $$
begin
  if not is_authorized(p_admin_passcode, p_employee_id, p_password) then
    return;
  end if;
  return query
    select e.id, e.name, count(l.id), coalesce(sum(l.closed_value), 0)
    from employees e
    left join leads l on l.assigned_to = e.id and l.status = 'closed_won'
      and l.updated_at >= p_month_start and l.updated_at < p_month_start + interval '1 month'
    where e.active
    group by e.id, e.name
    order by coalesce(sum(l.closed_value), 0) desc;
end;
$$;

-- Layouts (price tiers by position) ----------------------------------------------------

create or replace function admin_add_layout(p_admin_passcode text, p_name text, p_num_plots int, p_tiers jsonb)
returns jsonb
language plpgsql security definer as $$
declare
  v_id uuid;
begin
  if not admin_verify_passcode(p_admin_passcode) then
    return jsonb_build_object('success', false, 'error', 'invalid admin passcode');
  end if;
  if p_tiers is null or jsonb_array_length(p_tiers) = 0 then
    return jsonb_build_object('success', false, 'error', 'at least a lowest and highest price/sqft are required');
  end if;
  insert into layouts (name, num_plots) values (trim(p_name), coalesce(p_num_plots,0)) returning id into v_id;
  insert into layout_price_tiers (layout_id, position, price_per_sqft)
    select v_id, elem->>'position', coalesce((elem->>'price_per_sqft')::numeric, 0)
    from jsonb_array_elements(p_tiers) as elem;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function admin_update_layout(p_admin_passcode text, p_layout_id uuid, p_name text, p_num_plots int, p_tiers jsonb)
returns boolean
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then return false; end if;
  update layouts set name = trim(p_name), num_plots = coalesce(p_num_plots,0) where id = p_layout_id;
  if not found then return false; end if;
  delete from layout_price_tiers where layout_id = p_layout_id;
  insert into layout_price_tiers (layout_id, position, price_per_sqft)
    select p_layout_id, elem->>'position', coalesce((elem->>'price_per_sqft')::numeric, 0)
    from jsonb_array_elements(coalesce(p_tiers, '[]'::jsonb)) as elem;
  -- keep plots' cached layout_name in sync with a rename
  update plots set layout_name = trim(p_name) where layout_id = p_layout_id;
  return true;
end;
$$;

create or replace function admin_delete_layout(p_admin_passcode text, p_layout_id uuid)
returns boolean
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then return false; end if;
  delete from layouts where id = p_layout_id;
  return found;
end;
$$;

create or replace function list_layouts(p_admin_passcode text, p_employee_id uuid, p_password text)
returns table(id uuid, name text, num_plots int, created_at timestamptz, tiers jsonb)
language plpgsql security definer as $$
begin
  if not is_authorized(p_admin_passcode, p_employee_id, p_password) then
    return;
  end if;
  return query
    select l.id, l.name, l.num_plots, l.created_at,
      coalesce(jsonb_agg(jsonb_build_object('position', t.position, 'price_per_sqft', t.price_per_sqft))
        filter (where t.id is not null), '[]'::jsonb) as tiers
    from layouts l left join layout_price_tiers t on t.layout_id = l.id
    group by l.id order by l.name;
end;
$$;

-- Plots (land inventory) ------------------------------------------------------------------

create or replace function admin_add_plot(
  p_admin_passcode text, p_title text, p_layout_name text, p_plot_number text, p_type text,
  p_location text, p_extent_value numeric, p_extent_unit text, p_facing text, p_is_corner boolean,
  p_road_width_ft numeric, p_price numeric, p_layout_id uuid default null, p_is_front boolean default false,
  p_is_road_facing boolean default false, p_is_back boolean default false, p_has_no_road boolean default false
) returns jsonb
language plpgsql security definer as $$
declare
  v_id uuid;
begin
  if not admin_verify_passcode(p_admin_passcode) then
    return jsonb_build_object('success', false, 'error', 'invalid admin passcode');
  end if;
  insert into plots (title, layout_name, plot_number, type, location, extent_value, extent_unit, facing, is_corner,
                      road_width_ft, price, layout_id, is_front, is_road_facing, is_back, has_no_road)
    values (trim(p_title), coalesce(p_layout_name,''), coalesce(p_plot_number,''), p_type, coalesce(p_location,''),
            coalesce(p_extent_value,0), coalesce(p_extent_unit,'sqft'), coalesce(p_facing,''), coalesce(p_is_corner,false),
            p_road_width_ft, coalesce(p_price,0), p_layout_id, coalesce(p_is_front,false), coalesce(p_is_road_facing,false),
            coalesce(p_is_back,false), coalesce(p_has_no_road,false))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function admin_update_plot(
  p_admin_passcode text, p_plot_id uuid, p_title text, p_layout_name text, p_plot_number text, p_type text,
  p_location text, p_extent_value numeric, p_extent_unit text, p_facing text, p_is_corner boolean,
  p_road_width_ft numeric, p_price numeric, p_status text, p_layout_id uuid default null, p_is_front boolean default false,
  p_is_road_facing boolean default false, p_is_back boolean default false, p_has_no_road boolean default false
) returns boolean
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then return false; end if;
  update plots set title = trim(p_title), layout_name = coalesce(p_layout_name,''), plot_number = coalesce(p_plot_number,''),
    type = p_type, location = coalesce(p_location,''), extent_value = coalesce(p_extent_value,0),
    extent_unit = coalesce(p_extent_unit,'sqft'), facing = coalesce(p_facing,''), is_corner = coalesce(p_is_corner,false),
    road_width_ft = p_road_width_ft, price = coalesce(p_price,0), status = p_status, layout_id = p_layout_id,
    is_front = coalesce(p_is_front,false), is_road_facing = coalesce(p_is_road_facing,false),
    is_back = coalesce(p_is_back,false), has_no_road = coalesce(p_has_no_road,false)
  where id = p_plot_id;
  return found;
end;
$$;

create or replace function admin_delete_plot(p_admin_passcode text, p_plot_id uuid)
returns boolean
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then return false; end if;
  delete from plots where id = p_plot_id;
  return found;
end;
$$;

create or replace function list_plots(p_admin_passcode text, p_employee_id uuid, p_password text)
returns setof plots
language plpgsql security definer as $$
begin
  if not is_authorized(p_admin_passcode, p_employee_id, p_password) then
    return;
  end if;
  return query select * from plots order by listed_at desc;
end;
$$;

-- Leads / pipeline --------------------------------------------------------------

-- Postgres won't let CREATE OR REPLACE rename a parameter (p_property_id -> p_plot_id
-- below), only its body/return type — so the earlier "properties"-era signature has to be
-- dropped explicitly first. A no-op if it was never created (fresh install).
drop function if exists add_lead(text, uuid, text, text, text, text, uuid, numeric, text, uuid);

-- Employees may only create leads assigned to themselves; admin may assign to anyone
-- (including leaving it unassigned).
create or replace function add_lead(
  p_admin_passcode text, p_employee_id uuid, p_password text,
  p_name text, p_phone text, p_source text, p_plot_id uuid, p_budget numeric, p_notes text,
  p_assigned_to uuid
) returns jsonb
language plpgsql security definer as $$
declare
  v_is_admin boolean := p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode);
  v_assigned uuid;
  v_id uuid;
begin
  if not v_is_admin and not verify_employee_credentials(p_employee_id, p_password) then
    return jsonb_build_object('success', false, 'error', 'invalid credentials');
  end if;
  v_assigned := case when v_is_admin then p_assigned_to else p_employee_id end;
  insert into leads (name, phone, source, plot_id, assigned_to, budget, notes)
    values (trim(p_name), p_phone, coalesce(p_source,''), p_plot_id, v_assigned, coalesce(p_budget,0), coalesce(p_notes,''))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

-- Employees may only update leads assigned to them; admin may update any lead (including
-- reassigning it, via p_assigned_to).
create or replace function update_lead_status(
  p_admin_passcode text, p_employee_id uuid, p_password text,
  p_lead_id uuid, p_status text, p_closed_value numeric, p_notes text, p_assigned_to uuid
) returns boolean
language plpgsql security definer as $$
declare
  v_is_admin boolean := p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode);
begin
  if v_is_admin then
    update leads set status = p_status, closed_value = coalesce(p_closed_value, closed_value),
      notes = coalesce(p_notes, notes), assigned_to = coalesce(p_assigned_to, assigned_to), updated_at = now()
    where id = p_lead_id;
    return found;
  end if;
  if not verify_employee_credentials(p_employee_id, p_password) then
    return false;
  end if;
  update leads set status = p_status, closed_value = coalesce(p_closed_value, closed_value),
    notes = coalesce(p_notes, notes), updated_at = now()
  where id = p_lead_id and assigned_to = p_employee_id;
  return found;
end;
$$;

-- Admin sees every lead; an employee sees only leads assigned to them.
create or replace function list_leads(p_admin_passcode text, p_employee_id uuid, p_password text)
returns setof leads
language plpgsql security definer as $$
begin
  if p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode) then
    return query select * from leads order by created_at desc;
  end if;
  if verify_employee_credentials(p_employee_id, p_password) then
    return query select * from leads where assigned_to = p_employee_id order by created_at desc;
  end if;
  return;
end;
$$;

-- Follow-ups ----------------------------------------------------------------------

-- Must own the lead being followed up on (or be admin).
create or replace function add_follow_up(p_admin_passcode text, p_employee_id uuid, p_password text, p_lead_id uuid, p_due_at timestamptz, p_notes text)
returns jsonb
language plpgsql security definer as $$
declare
  v_is_admin boolean := p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode);
  v_owner uuid;
  v_id uuid;
begin
  if not v_is_admin and not verify_employee_credentials(p_employee_id, p_password) then
    return jsonb_build_object('success', false, 'error', 'invalid credentials');
  end if;
  select assigned_to into v_owner from leads where id = p_lead_id;
  if not v_is_admin and v_owner is distinct from p_employee_id then
    return jsonb_build_object('success', false, 'error', 'not your lead');
  end if;
  if v_owner is null then
    return jsonb_build_object('success', false, 'error', 'lead has no owner — assign it to an employee first');
  end if;
  insert into follow_ups (lead_id, employee_id, due_at, notes)
    values (p_lead_id, v_owner, p_due_at, coalesce(p_notes,''))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function complete_follow_up(p_admin_passcode text, p_employee_id uuid, p_password text, p_follow_up_id uuid)
returns boolean
language plpgsql security definer as $$
declare
  v_is_admin boolean := p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode);
begin
  if v_is_admin then
    update follow_ups set status = 'done', completed_at = now() where id = p_follow_up_id;
    return found;
  end if;
  if not verify_employee_credentials(p_employee_id, p_password) then return false; end if;
  update follow_ups set status = 'done', completed_at = now()
  where id = p_follow_up_id and employee_id = p_employee_id;
  return found;
end;
$$;

create or replace function list_follow_ups(p_admin_passcode text, p_employee_id uuid, p_password text)
returns setof follow_ups
language plpgsql security definer as $$
begin
  if p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode) then
    return query select * from follow_ups order by due_at asc;
  end if;
  if verify_employee_credentials(p_employee_id, p_password) then
    return query select * from follow_ups where employee_id = p_employee_id order by due_at asc;
  end if;
  return;
end;
$$;

-- Daily activity ---------------------------------------------------------------------

create or replace function log_activity(
  p_employee_id uuid, p_password text, p_activity_date date,
  p_calls_made int, p_site_visits int, p_meetings int, p_new_leads int, p_notes text
) returns boolean
language plpgsql security definer as $$
begin
  if not verify_employee_credentials(p_employee_id, p_password) then return false; end if;
  insert into daily_activity (employee_id, activity_date, calls_made, site_visits, meetings, new_leads, notes)
    values (p_employee_id, p_activity_date, coalesce(p_calls_made,0), coalesce(p_site_visits,0),
            coalesce(p_meetings,0), coalesce(p_new_leads,0), coalesce(p_notes,''))
  on conflict (employee_id, activity_date) do update set
    calls_made = excluded.calls_made, site_visits = excluded.site_visits,
    meetings = excluded.meetings, new_leads = excluded.new_leads, notes = excluded.notes;
  return true;
end;
$$;

-- Adding p_lat/p_lng changes the signature (2 args -> 4), so drop the old ones first —
-- same reasoning as add_lead/admin_update_employee above.
drop function if exists check_in(uuid, text);
drop function if exists check_out(uuid, text);

create or replace function check_in(p_employee_id uuid, p_password text, p_lat numeric, p_lng numeric)
returns boolean
language plpgsql security definer as $$
begin
  if not verify_employee_credentials(p_employee_id, p_password) then return false; end if;
  insert into daily_activity (employee_id, activity_date, check_in_time, check_in_lat, check_in_lng)
    values (p_employee_id, current_date, now(), p_lat, p_lng)
  on conflict (employee_id, activity_date) do update set
    check_in_time = coalesce(daily_activity.check_in_time, now()),
    check_in_lat = coalesce(daily_activity.check_in_lat, p_lat),
    check_in_lng = coalesce(daily_activity.check_in_lng, p_lng);
  return true;
end;
$$;

create or replace function check_out(p_employee_id uuid, p_password text, p_lat numeric, p_lng numeric)
returns boolean
language plpgsql security definer as $$
begin
  if not verify_employee_credentials(p_employee_id, p_password) then return false; end if;
  insert into daily_activity (employee_id, activity_date, check_out_time, check_out_lat, check_out_lng)
    values (p_employee_id, current_date, now(), p_lat, p_lng)
  on conflict (employee_id, activity_date) do update set
    check_out_time = now(), check_out_lat = p_lat, check_out_lng = p_lng;
  return true;
end;
$$;

create or replace function list_activity(p_admin_passcode text, p_employee_id uuid, p_password text)
returns setof daily_activity
language plpgsql security definer as $$
begin
  if p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode) then
    return query select * from daily_activity order by activity_date desc;
  end if;
  if verify_employee_credentials(p_employee_id, p_password) then
    return query select * from daily_activity where employee_id = p_employee_id order by activity_date desc;
  end if;
  return;
end;
$$;

-- Day-offs ----------------------------------------------------------------------------

create or replace function request_day_off(p_employee_id uuid, p_password text, p_start_date date, p_end_date date, p_reason text)
returns jsonb
language plpgsql security definer as $$
declare
  v_id uuid;
begin
  if not verify_employee_credentials(p_employee_id, p_password) then
    return jsonb_build_object('success', false, 'error', 'invalid credentials');
  end if;
  insert into day_offs (employee_id, start_date, end_date, reason)
    values (p_employee_id, p_start_date, p_end_date, coalesce(p_reason,''))
    returning id into v_id;
  return jsonb_build_object('success', true, 'id', v_id);
end;
$$;

create or replace function admin_decide_day_off(p_admin_passcode text, p_day_off_id uuid, p_decision text)
returns boolean
language plpgsql security definer as $$
begin
  if not admin_verify_passcode(p_admin_passcode) then return false; end if;
  if p_decision not in ('approved', 'rejected') then return false; end if;
  update day_offs set status = p_decision, decided_at = now() where id = p_day_off_id;
  return found;
end;
$$;

create or replace function list_day_offs(p_admin_passcode text, p_employee_id uuid, p_password text)
returns setof day_offs
language plpgsql security definer as $$
begin
  if p_admin_passcode is not null and p_admin_passcode <> '' and admin_verify_passcode(p_admin_passcode) then
    return query select * from day_offs order by requested_at desc;
  end if;
  if verify_employee_credentials(p_employee_id, p_password) then
    return query select * from day_offs where employee_id = p_employee_id order by requested_at desc;
  end if;
  return;
end;
$$;

-- Team-wide calendar of approved time off — names only, no reason (privacy for other
-- people's leave reasons), visible to any logged-in employee or admin.
create or replace function list_approved_day_offs_calendar(p_admin_passcode text, p_employee_id uuid, p_password text)
returns table(employee_name text, start_date date, end_date date)
language plpgsql security definer as $$
begin
  if not is_authorized(p_admin_passcode, p_employee_id, p_password) then
    return;
  end if;
  return query
    select e.name, d.start_date, d.end_date
    from day_offs d join employees e on e.id = d.employee_id
    where d.status = 'approved' and d.end_date >= current_date
    order by d.start_date;
end;
$$;
