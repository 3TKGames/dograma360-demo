-- Doğrama360 üyelik, şirket hesabı ve çalışan yetkileri
-- Supabase SQL Editor'da mevcut supabase-setup.sql dosyasından SONRA çalıştırılır.
-- Not: Plan değişikliği yalnızca güvenilir ödeme webhook'u / service_role ile yapılmalıdır.

create extension if not exists pgcrypto;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.organization_subscriptions (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  plan text not null default 'free' check (plan in ('free', 'personal', 'company')),
  status text not null default 'active' check (status in ('active', 'past_due', 'cancelled')),
  current_period_end timestamptz,
  provider_customer_id text,
  provider_subscription_id text,
  updated_at timestamptz not null default now()
);

create table if not exists public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  role text not null check (role in ('owner', 'employee')),
  status text not null default 'invited' check (status in ('invited', 'active', 'suspended')),
  invited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create unique index if not exists organization_members_org_email_unique
on public.organization_members (organization_id, lower(email));

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  status text not null default 'active',
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Telefon, e-posta, adres ve özel notlar çalışan sorgularına hiç dönmez.
create table if not exists public.customer_private_details (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  phone text,
  email text,
  address text,
  private_notes text,
  updated_at timestamptz not null default now()
);

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete restrict,
  name text not null,
  location text,
  status text not null default 'measurement',
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.measurements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  product_type text not null,
  width_mm numeric(12,2) not null check (width_mm > 0),
  height_mm numeric(12,2) not null check (height_mm > 0),
  quantity integer not null default 1 check (quantity > 0),
  room_or_location text,
  technical_data jsonb not null default '{}'::jsonb,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.is_organization_member(target_organization uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_members member
    where member.organization_id = target_organization
      and member.user_id = (select auth.uid())
      and member.status = 'active'
  );
$$;

create or replace function public.is_organization_owner(target_organization uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_members member
    where member.organization_id = target_organization
      and member.user_id = (select auth.uid())
      and member.role = 'owner'
      and member.status = 'active'
  );
$$;

create or replace function public.create_organization_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  owner_email text;
begin
  select email into owner_email from auth.users where id = new.owner_user_id;

  insert into public.organization_subscriptions (organization_id, plan)
  values (new.id, 'free')
  on conflict (organization_id) do nothing;

  insert into public.organization_members (
    organization_id, user_id, email, role, status, invited_by
  ) values (
    new.id, new.owner_user_id, coalesce(owner_email, ''), 'owner', 'active', new.owner_user_id
  ) on conflict (organization_id, user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists organizations_create_defaults on public.organizations;
create trigger organizations_create_defaults
after insert on public.organizations
for each row execute procedure public.create_organization_defaults();

create or replace function public.enforce_plan_limits()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  active_plan text;
  used_count integer;
begin
  select plan into active_plan
  from public.organization_subscriptions
  where organization_id = new.organization_id and status = 'active';

  active_plan := coalesce(active_plan, 'free');

  if tg_table_name = 'projects' then
    select count(*) into used_count from public.projects
    where organization_id = new.organization_id;

    if active_plan = 'free' and used_count >= 1 then
      raise exception 'Ücretsiz plan en fazla 1 proje kaydedebilir.' using errcode = 'P0001';
    elsif active_plan = 'personal' and used_count >= 20 then
      raise exception 'Kişisel plan en fazla 20 proje kaydedebilir.' using errcode = 'P0001';
    end if;
  elsif tg_table_name = 'customers' then
    select count(*) into used_count from public.customers
    where organization_id = new.organization_id;

    if active_plan = 'personal' and used_count >= 20 then
      raise exception 'Kişisel plan en fazla 20 müşteri kaydedebilir.' using errcode = 'P0001';
    end if;
  elsif tg_table_name = 'organization_members' then
    select count(*) into used_count from public.organization_members
    where organization_id = new.organization_id and status <> 'suspended';

    if active_plan <> 'company' and used_count >= 1 then
      raise exception 'Ek kullanıcı yalnızca Şirket planında kullanılabilir.' using errcode = 'P0001';
    elsif active_plan = 'company' and used_count >= 3 then
      raise exception 'Şirket planı en fazla 3 giriş hesabına izin verir.' using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists projects_plan_limit on public.projects;
create trigger projects_plan_limit before insert on public.projects
for each row execute procedure public.enforce_plan_limits();

drop trigger if exists customers_plan_limit on public.customers;
create trigger customers_plan_limit before insert on public.customers
for each row execute procedure public.enforce_plan_limits();

drop trigger if exists organization_members_plan_limit on public.organization_members;
create trigger organization_members_plan_limit before insert on public.organization_members
for each row execute procedure public.enforce_plan_limits();

alter table public.organizations enable row level security;
alter table public.organization_subscriptions enable row level security;
alter table public.organization_members enable row level security;
alter table public.customers enable row level security;
alter table public.customer_private_details enable row level security;
alter table public.projects enable row level security;
alter table public.measurements enable row level security;

revoke all on public.organization_subscriptions from anon, authenticated;
grant select on public.organization_subscriptions to authenticated;
grant select, insert, update on public.organizations to authenticated;
grant select on public.organization_members to authenticated;
grant select, insert, update, delete on public.customers to authenticated;
grant select, insert, update on public.customer_private_details to authenticated;
grant select, insert, update, delete on public.projects to authenticated;
grant select, insert, update, delete on public.measurements to authenticated;

drop policy if exists organizations_read_members on public.organizations;
create policy organizations_read_members on public.organizations for select to authenticated
using (public.is_organization_member(id));

drop policy if exists organizations_create_owner on public.organizations;
create policy organizations_create_owner on public.organizations for insert to authenticated
with check (owner_user_id = (select auth.uid()));

drop policy if exists organizations_update_owner on public.organizations;
create policy organizations_update_owner on public.organizations for update to authenticated
using (public.is_organization_owner(id))
with check (public.is_organization_owner(id));

drop policy if exists subscriptions_read_members on public.organization_subscriptions;
create policy subscriptions_read_members on public.organization_subscriptions for select to authenticated
using (public.is_organization_member(organization_id));

drop policy if exists members_read_self_or_owner on public.organization_members;
create policy members_read_self_or_owner on public.organization_members for select to authenticated
using (user_id = (select auth.uid()) or public.is_organization_owner(organization_id));

drop policy if exists customers_read_members on public.customers;
create policy customers_read_members on public.customers for select to authenticated
using (public.is_organization_member(organization_id));

drop policy if exists customers_insert_members on public.customers;
create policy customers_insert_members on public.customers for insert to authenticated
with check (
  public.is_organization_member(organization_id)
  and created_by = (select auth.uid())
);

drop policy if exists customers_update_owner on public.customers;
create policy customers_update_owner on public.customers for update to authenticated
using (public.is_organization_owner(organization_id))
with check (public.is_organization_owner(organization_id));

drop policy if exists customers_delete_owner on public.customers;
create policy customers_delete_owner on public.customers for delete to authenticated
using (public.is_organization_owner(organization_id));

drop policy if exists customer_private_owner_all on public.customer_private_details;
create policy customer_private_owner_all on public.customer_private_details for all to authenticated
using (
  exists (
    select 1 from public.customers customer
    where customer.id = customer_id
      and public.is_organization_owner(customer.organization_id)
  )
)
with check (
  exists (
    select 1 from public.customers customer
    where customer.id = customer_id
      and public.is_organization_owner(customer.organization_id)
  )
);

drop policy if exists projects_read_members on public.projects;
create policy projects_read_members on public.projects for select to authenticated
using (public.is_organization_member(organization_id));

drop policy if exists projects_insert_members on public.projects;
create policy projects_insert_members on public.projects for insert to authenticated
with check (
  public.is_organization_member(organization_id)
  and created_by = (select auth.uid())
);

drop policy if exists projects_update_members on public.projects;
create policy projects_update_members on public.projects for update to authenticated
using (public.is_organization_member(organization_id))
with check (public.is_organization_member(organization_id));

drop policy if exists projects_delete_owner on public.projects;
create policy projects_delete_owner on public.projects for delete to authenticated
using (public.is_organization_owner(organization_id));

drop policy if exists measurements_read_members on public.measurements;
create policy measurements_read_members on public.measurements for select to authenticated
using (public.is_organization_member(organization_id));

drop policy if exists measurements_insert_members on public.measurements;
create policy measurements_insert_members on public.measurements for insert to authenticated
with check (
  public.is_organization_member(organization_id)
  and created_by = (select auth.uid())
);

drop policy if exists measurements_update_members on public.measurements;
create policy measurements_update_members on public.measurements for update to authenticated
using (public.is_organization_member(organization_id))
with check (public.is_organization_member(organization_id));

drop policy if exists measurements_delete_owner on public.measurements;
create policy measurements_delete_owner on public.measurements for delete to authenticated
using (public.is_organization_owner(organization_id));

create index if not exists organization_members_user_idx on public.organization_members (user_id);
create index if not exists customers_organization_idx on public.customers (organization_id);
create index if not exists projects_organization_idx on public.projects (organization_id);
create index if not exists projects_customer_idx on public.projects (customer_id);
create index if not exists measurements_project_idx on public.measurements (project_id);
