-- ЭТАП 5. Абонементы: автоматическое создание будущих уборок и график.
-- Как запустить: Supabase -> SQL Editor -> New query -> вставить весь файл -> Run.
-- Скрипт можно запускать повторно, повторный запуск ничего не ломает.
-- Он ничего не меняет в уже существующих таблицах и триггерах, только добавляет новые.

-- 1. Проверка: вошёл ли сотрудник (почта есть в таблице staff)
create or replace function public.abon_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.staff s where lower(s.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;

-- 2. Таблица абонементов
create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  order_id uuid,                       -- первый заказ (первая уборка)
  user_id uuid,
  code text,                           -- код первого заказа
  plan int not null default 0,         -- номер плана в config
  plan_name text,
  n int,                               -- уборок в месяц
  step int not null default 1,         -- 1 = каждую неделю, 2 = раз в 2 недели
  dow int,                             -- день недели: 0 = воскресенье ... 6 = суббота
  tm text not null default '10:00',    -- время уборки
  start_date date not null,            -- дата первой уборки
  next_date date not null,             -- от этой даты строятся следующие уборки
  price int not null default 0,        -- цена одной уборки без допуслуг
  assignee text,                       -- бригада
  status text not null default 'pending',   -- pending / active / cancelled
  pause_from date,
  pause_to date,
  sel jsonb,
  details text,
  note text
);
alter table public.subscriptions enable row level security;
drop policy if exists "abon staff read" on public.subscriptions;
create policy "abon staff read" on public.subscriptions for select using (public.abon_is_staff());
create index if not exists subscriptions_status_idx on public.subscriptions (status);

-- 3. Защита от дублей: одна уборка абонемента на одну дату
create unique index if not exists orders_abon_visit_uq
  on public.orders ((sel ->> 'sub'), (sel ->> 'date')) where sel ? 'sub';

-- 4. Новый заказ с абонементом создаёт заявку на абонемент (ждёт подтверждения).
--    Любая ошибка здесь не мешает оформить заказ.
create or replace function public.abon_on_order() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p int; d date; t text; m text[]; stp int; pr int;
begin
  begin
    if new.sel is null or jsonb_typeof(new.sel) <> 'object' or new.sel ? 'sub' then return new; end if;
    p := coalesce(nullif(new.sel ->> 'plan', '')::int, 0);
    if p <= 0 then return new; end if;
    t := nullif(new.sel ->> 'tm', '');
    begin d := nullif(new.sel ->> 'date', '')::date; exception when others then d := null; end;
    if d is null or t is null then
      m := regexp_match(coalesce(new.details, ''), 'Когда: (\d{1,2})\.(\d{1,2}) в (\d{1,2}):(\d{2})');
      if m is not null then
        if d is null then
          d := make_date(extract(year from now())::int, m[2]::int, m[1]::int);
          if d < current_date - 180 then d := d + interval '1 year'; end if;
        end if;
        if t is null then t := lpad(m[3], 2, '0') || ':' || m[4]; end if;
      end if;
    end if;
    if d is null then d := (new.created_at at time zone 'Asia/Tashkent')::date; end if;
    stp := case when coalesce(new.sel ->> 'ps', '1') = '2' then 14 else 7 end;
    pr := coalesce(nullif(new.sel ->> 'vp', '')::int, new.total, 0);
    insert into public.subscriptions(order_id, user_id, code, plan, plan_name, n, step, dow, tm, start_date, next_date, price, assignee, status, sel, details)
    values (new.id, new.user_id, new.code, p, coalesce(new.sel ->> 'pn', 'Абонемент'), nullif(new.sel ->> 'pm', '')::int,
            case when stp = 14 then 2 else 1 end, extract(dow from d)::int, coalesce(t, '10:00'), d, d + stp, pr,
            nullif(new.assignee, ''), 'pending', new.sel, new.details);
  exception when others then
    raise warning 'abon_on_order: %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists orders_abon_ai on public.orders;
create trigger orders_abon_ai after insert on public.orders for each row execute function public.abon_on_order();

-- 5. Текст заказа для будущей уборки: берём текст первого заказа и меняем нужные строки
create or replace function public.abon_visit_details(s public.subscriptions, d date, k int) returns text
language plpgsql immutable as $$
declare l text; res text[] := '{}'::text[];
begin
  foreach l in array string_to_array(coalesce(s.details, ''), E'\n') loop
    if l like 'Заказ %' then res := array_append(res, (l || '/' || k)::text);
    elsif l like 'Дополнительно:%' then res := array_append(res, 'Дополнительно: нет'::text);
    elsif l like 'Когда:%' then res := array_append(res, ('Когда: ' || to_char(d, 'DD.MM') || ' в ' || s.tm || ', абонемент: ' || lower(coalesce(s.plan_name, 'абонемент')))::text);
    elsif l like 'Итого:%' then res := array_append(res, ('Итого: ' || s.price || ' сум')::text);
    elsif l like 'Промокод:%' or l like 'Бонусы:%' or l like 'Код друга:%' or l like 'Следующие уборки:%' then null;
    else res := array_append(res, l);
    end if;
  end loop;
  return array_to_string(res, E'\n') || E'\nУборка №' || k || ' по абонементу';
end $$;

-- 6. Создание будущих уборок (по умолчанию на 21 день вперёд). Безопасно запускать сколько угодно раз.
create or replace function public.abon_gen_visits(p_horizon int default 21) returns int
language plpgsql security definer set search_path = public as $$
declare
  s public.subscriptions; d date; stp int; today date; lim date; n int := 0; cnt int; rc int;
begin
  today := (now() at time zone 'Asia/Tashkent')::date;
  lim := today + greatest(coalesce(p_horizon, 21), 1);
  for s in select * from public.subscriptions where status = 'active' loop
    stp := case when s.step = 2 then 14 else 7 end;
    d := s.next_date;
    if d < today then d := d + stp * ceil((today - d)::numeric / stp)::int; end if;
    while d <= lim loop
      if d > s.start_date and not (s.pause_from is not null and d >= s.pause_from and d <= coalesce(s.pause_to, date '9999-12-31')) then
        select count(*) into cnt from public.orders where sel ->> 'sub' = s.id::text;
        insert into public.orders(user_id, code, details, total, sel, status, assignee)
        values (s.user_id, s.code || '/' || (cnt + 2), public.abon_visit_details(s, d, cnt + 2), s.price,
                (coalesce(s.sel, '{}'::jsonb) - 'ext') || jsonb_build_object('sub', s.id, 'date', d, 'visit', cnt + 2, 'dow', extract(dow from d)::int, 'tm', s.tm),
                'new', s.assignee)
        on conflict ((sel ->> 'sub'), (sel ->> 'date')) where sel ? 'sub' do nothing;
        get diagnostics rc = row_count; n := n + rc;
      end if;
      d := d + stp;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.abon_gen_visits(int) from public, anon, authenticated;

-- 7. Функции для админ-панели (работают только для сотрудников из таблицы staff)
create or replace function public.abon_guard() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.abon_is_staff() then raise exception 'Нет доступа'; end if;
end $$;

-- подтвердить или изменить: ближайшая следующая дата, время, бригада
create or replace function public.abon_set(p_id uuid, p_next date, p_tm text, p_assignee text) returns int
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Asia/Tashkent')::date;
begin
  perform public.abon_guard();
  update public.subscriptions set status = 'active', next_date = p_next, tm = coalesce(nullif(p_tm, ''), tm),
         assignee = nullif(p_assignee, ''), dow = extract(dow from p_next)::int where id = p_id;
  if not found then raise exception 'Абонемент не найден'; end if;
  delete from public.orders where sel ->> 'sub' = p_id::text and status = 'new' and (sel ->> 'date')::date >= today;
  return public.abon_gen_visits(21);
end $$;

create or replace function public.abon_pause(p_id uuid, p_from date, p_to date) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.abon_guard();
  update public.subscriptions set pause_from = p_from, pause_to = p_to where id = p_id;
  delete from public.orders where sel ->> 'sub' = p_id::text and status = 'new'
    and (sel ->> 'date')::date >= p_from and (p_to is null or (sel ->> 'date')::date <= p_to);
end $$;

create or replace function public.abon_resume(p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
begin
  perform public.abon_guard();
  update public.subscriptions set pause_from = null, pause_to = null where id = p_id;
  return public.abon_gen_visits(21);
end $$;

create or replace function public.abon_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Asia/Tashkent')::date;
begin
  perform public.abon_guard();
  update public.subscriptions set status = 'cancelled' where id = p_id;
  delete from public.orders where sel ->> 'sub' = p_id::text and status = 'new' and (sel ->> 'date')::date >= today;
end $$;

create or replace function public.abon_generate(p_horizon int default 28) returns int
language plpgsql security definer set search_path = public as $$
begin
  perform public.abon_guard();
  return public.abon_gen_visits(coalesce(p_horizon, 28));
end $$;

-- 8. Ежедневное автоматическое создание уборок в 03:00 по Ташкенту (нужно расширение pg_cron).
--    Если расширение не включено, ничего страшного: уборки создаются кнопкой в админ-панели.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('tozavoy-abon-visits', '0 22 * * *', 'select public.abon_gen_visits(21)');
exception when others then
  raise notice 'pg_cron не включён (%). Включите Database -> Extensions -> pg_cron и запустите скрипт ещё раз.', sqlerrm;
end $$;
