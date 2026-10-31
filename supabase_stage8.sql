-- ЭТАП 8. Касса: учёт наличных, подтверждение оплаты клиентом и сдача денег владельцу.
-- Запускать после этапов 1–7. Файл можно запускать повторно.
-- Как: Supabase -> SQL Editor -> New query -> вставить весь файл -> Run.
--
-- Как это работает:
--  1. Клинер выполняет заказ с оплатой наличными и вносит в приложении, сколько денег получил (если сумма другая, нужна причина).
--  2. Независимо от клинера клиент получает сообщение в Telegram-боте: «Вы оплатили клинеру наличными?» и сам называет сумму.
--     Если бот не знает клиента, оплата остаётся «не подтверждена клиентом», и владелец видит это в админке.
--  3. База сравнивает два ответа. Если они расходятся, или клиент заплатил, а клинер ничего не внёс, заказ получает красный флаг.
--  4. Клинер сдаёт деньги владельцу (кнопка «Сдал деньги»), владелец подтверждает, сколько реально принял.
--     Не сдано за срок (по умолчанию 24 часа) или принято меньше заявленного: флаг «просрочено» или «недостача».

-- 0. Проверка: всё, на что опирается касса, уже есть в базе
do $$
declare
  need text[] := array['orders.id','orders.code','orders.details','orders.total','orders.status','orders.assignee','orders.sel','orders.user_id',
                       'staff.email','cleaners.name','cleaners.email','bot_outbox.kind','tg_profiles.phone'];
  x text; miss text := '';
begin
  foreach x in array need loop
    if not exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = split_part(x, '.', 1) and column_name = split_part(x, '.', 2)) then
      miss := miss || ' ' || x;
    end if;
  end loop;
  if to_regprocedure('public._bot_ok(text)') is null then miss := miss || ' функция _bot_ok (этап 7)'; end if;
  if miss <> '' then
    raise exception 'Этап 8 остановлен: в базе нет:%. Сначала запустите этапы 1–7 (если нет cleaners.email, напишите мне).', miss;
  end if;
end $$;

-- 1. Настройки и таблицы (прямого доступа через API нет: всё идёт через функции ниже)
create table if not exists public.pay_settings (k text primary key, v text not null);
insert into public.pay_settings (k, v) values ('due_hours', '24'), ('unrecorded_hours', '6') on conflict (k) do nothing;

create table if not exists public.cash_handovers (
  id uuid primary key default gen_random_uuid(),
  cleaner text not null,
  cleaner_email text,
  amount int not null,                 -- сколько клинер заявил к сдаче (сумма внесённых им платежей)
  reported_at timestamptz not null default now(),
  received_amount int,                 -- сколько принял владелец
  confirmed_at timestamptz,
  confirmed_by text,
  note text
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders (id) on delete cascade,
  code text,
  method text not null default 'cash',
  expected int not null,               -- сколько клиент должен заплатить (сумма заказа)
  amount int,                          -- сколько получил клинер (пусто = ещё не внёс)
  cleaner text,
  cleaner_email text,
  done_at timestamptz not null default now(),   -- когда заказ выполнен
  collected_at timestamptz,
  note text,
  client_answer text check (client_answer in ('ok', 'other', 'none')),   -- ответ клиента: отдал сумму / другую сумму / не платил
  client_amount int,
  client_at timestamptz,
  client_via text,
  due_at timestamptz,                  -- до какого времени сдать деньги владельцу
  handover_id uuid references public.cash_handovers (id) on delete set null
);
create index if not exists payments_cleaner_idx on public.payments (lower(cleaner));
create index if not exists payments_open_idx on public.payments (handover_id) where handover_id is null;

alter table public.pay_settings   enable row level security;
alter table public.cash_handovers enable row level security;
alter table public.payments       enable row level security;
revoke all on public.pay_settings, public.cash_handovers, public.payments from anon, authenticated;

-- 2. Помощники (клиентам API недоступны)
create or replace function public._pay_email() returns text language sql stable as $$
  select lower(coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', ''))
$$;

create or replace function public._pay_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff s where lower(s.email) = public._pay_email())
$$;

create or replace function public._pay_cleaner() returns text language sql stable security definer set search_path = public as $$
  select c.name from public.cleaners c where lower(c.email) = public._pay_email() limit 1
$$;

create or replace function public._pay_int(p_key text, p_default int) returns int language sql stable security definer set search_path = public as $$
  select coalesce((select v::int from public.pay_settings where k = p_key and v ~ '^[0-9]{1,4}$'), p_default)
$$;

-- наличные ли это: в тексте заказа строка «Оплата: наличные…»
create or replace function public._pay_is_cash(p_details text) returns boolean language sql immutable as $$
  select coalesce((regexp_match(coalesce(p_details, ''), 'Оплата:[^\n]*'))[1], '') ~* 'налич'
$$;

-- Telegram клиента: из заказа бота, из привязанного аккаунта или по номеру телефона в заказе (номер подтверждён Telegram)
create or replace function public._pay_tg_for(p_sel jsonb, p_user uuid, p_details text) returns bigint
language plpgsql stable security definer set search_path = public as $$
declare v bigint; ph text;
begin
  if (p_sel ->> 'tg') ~ '^[0-9]{1,18}$' then return (p_sel ->> 'tg')::bigint; end if;
  if p_user is not null then
    select tg_id into v from public.tg_profiles where user_id = p_user order by linked_at desc nulls last limit 1;
    if v is not null then return v; end if;
  end if;
  ph := right(regexp_replace(coalesce((regexp_match(coalesce(p_details, ''), 'Клиент:[^\n]*,\s*(\+?[0-9][0-9 ()-]{6,})\s*(?:\n|$)'))[1], ''), '\D', '', 'g'), 9);
  if length(ph) = 9 then
    select tg_id into v from public.tg_profiles where right(phone, 9) = ph order by created_at desc limit 1;
  end if;
  return v;
end $$;

-- Красные флаги по платежу
create or replace function public._pay_flags(p public.payments) returns text[] language plpgsql stable security definer set search_path = public as $$
declare f text[] := '{}';
begin
  if p.amount is null then
    if p.client_answer in ('ok', 'other') then f := array_append(f, 'client_paid_unrecorded');
    elsif now() > p.done_at + make_interval(hours => public._pay_int('unrecorded_hours', 6)) then f := array_append(f, 'unrecorded');
    end if;
  else
    if p.amount < p.expected then f := array_append(f, 'short'); end if;
    if p.client_answer is null then f := array_append(f, 'unconfirmed');
    elsif p.client_answer = 'none' and p.amount > 0 then f := array_append(f, 'conflict');
    elsif p.client_answer in ('ok', 'other') and coalesce(p.client_amount, -1) <> p.amount then f := array_append(f, 'conflict');
    end if;
    if p.handover_id is null and p.amount > 0 and now() > p.due_at then f := array_append(f, 'overdue'); end if;
  end if;
  return f;
end $$;

-- 3. Заказ выполнен с оплатой наличными: заводим запись в кассе и просим клиента сказать, сколько он отдал
create or replace function public._pay_on_done() returns trigger language plpgsql security definer set search_path = public as $$
declare pid uuid; v_tg bigint;
begin
  if new.status is not distinct from old.status or new.status <> 'done' or not public._pay_is_cash(new.details) then return new; end if;
  insert into public.payments (order_id, code, method, expected, cleaner, done_at)
  values (new.id, new.code, 'cash', coalesce(new.total, 0), nullif(trim(new.assignee), ''), now())
  on conflict (order_id) do nothing returning id into pid;
  if pid is null then select id into pid from public.payments where order_id = new.id; end if;
  v_tg := public._pay_tg_for(new.sel, new.user_id, new.details);
  if v_tg is not null and pid is not null then
    insert into public.bot_outbox (tg_id, kind, code, status, payload)
    values (v_tg, 'pay_ask', new.code, 'done', jsonb_build_object('payment', pid, 'total', new.total));
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists pay_on_done on public.orders;
create trigger pay_on_done after update of status on public.orders
  for each row execute function public._pay_on_done();

-- Уведомление о статусе (этап 7) теперь находит клиента и по телефону, а для «выполнен» с наличными шлёт один вопрос об оплате
create or replace function public._bot_notify_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_tg bigint;
begin
  if new.status is not distinct from old.status or coalesce(new.status, 'new') = 'new' then return new; end if;
  if new.status = 'done' and public._pay_is_cash(new.details) then return new; end if;
  v_tg := public._pay_tg_for(new.sel, new.user_id, new.details);
  if v_tg is not null then
    insert into public.bot_outbox (tg_id, kind, code, status, payload)
    values (v_tg, 'status', new.code, new.status,
            jsonb_build_object('date', new.sel ->> 'date', 'tm', new.sel ->> 'tm', 'total', new.total));
  end if;
  return new;
exception when others then
  return new;
end $$;

-- 4. Функции для приложения клинера и админки
create or replace function public.pay_snapshot(p_days int default 90) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st boolean := public._pay_staff(); me text := public._pay_cleaner(); pays jsonb; hands jsonb;
begin
  if not st and me is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x order by x.done_at desc), '[]'::jsonb) into pays from (
    select p.id, p.order_id, p.code, p.expected, p.amount, p.cleaner, p.done_at, p.collected_at, p.note,
           p.client_answer, p.client_amount, p.client_at, p.due_at, p.handover_id,
           public._pay_flags(p) as flags,
           nullif(trim(substring(o.details from 'Клиент:([^\n]*)')), '') as client,
           (p.amount is not null and p.client_answer in ('ok', 'other') and p.client_amount = p.amount) as verified
    from public.payments p join public.orders o on o.id = p.order_id
    where (st or lower(p.cleaner) = lower(me))
      and (p.done_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 90), 365))) or p.handover_id is null)
  ) x;
  select coalesce(jsonb_agg(h order by h.reported_at desc), '[]'::jsonb) into hands from (
    select h.id, h.cleaner, h.amount, h.reported_at, h.received_amount, h.confirmed_at, h.note
    from public.cash_handovers h
    where (st or lower(h.cleaner) = lower(me)) and h.reported_at > now() - interval '120 days'
  ) h;
  return jsonb_build_object('role', case when st then 'staff' else 'cleaner' end, 'me', me,
    'cfg', jsonb_build_object('due_hours', public._pay_int('due_hours', 24), 'unrecorded_hours', public._pay_int('unrecorded_hours', 6)),
    'payments', pays, 'handovers', hands);
end $$;

create or replace function public.pay_record(p_order uuid, p_amount int, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st boolean := public._pay_staff(); me text := public._pay_cleaner(); o record; pr public.payments; who text; id_ uuid;
begin
  if not st and me is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select id, code, total, details, assignee into o from public.orders where id = p_order;
  if not found then raise exception 'no_order'; end if;
  if not public._pay_is_cash(o.details) then raise exception 'not_cash'; end if;
  if not st and nullif(trim(o.assignee), '') is not null and lower(trim(o.assignee)) <> lower(me) then raise exception 'not_yours'; end if;
  select * into pr from public.payments where order_id = p_order;
  if found and pr.handover_id is not null then raise exception 'locked'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 1000000000 then raise exception 'bad_amount'; end if;
  if p_amount <> coalesce(o.total, 0) and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'note_required'; end if;
  who := coalesce(me, nullif(trim(o.assignee), ''));
  insert into public.payments (order_id, code, method, expected, amount, cleaner, cleaner_email, collected_at, note, due_at)
  values (o.id, o.code, 'cash', coalesce(o.total, 0), p_amount, who, public._pay_email(), now(), nullif(trim(p_note), ''),
          now() + make_interval(hours => public._pay_int('due_hours', 24)))
  on conflict (order_id) do update set amount = excluded.amount, cleaner = coalesce(excluded.cleaner, public.payments.cleaner),
    cleaner_email = excluded.cleaner_email, collected_at = now(), note = excluded.note, due_at = excluded.due_at
  returning id into id_;
  select * into pr from public.payments where id = id_;
  return jsonb_build_object('ok', true, 'id', id_, 'flags', public._pay_flags(pr));
end $$;

-- Клинер: «Сдал деньги владельцу» — собираем все его внесённые, но ещё не сданные платежи в одну сдачу
create or replace function public.pay_handover_report(p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me text := public._pay_cleaner(); tot int; n int; hid uuid;
begin
  if me is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(sum(amount), 0), count(*) into tot, n from public.payments
    where lower(cleaner) = lower(me) and handover_id is null and amount > 0;
  if n = 0 then raise exception 'nothing'; end if;
  insert into public.cash_handovers (cleaner, cleaner_email, amount, note) values (me, public._pay_email(), tot, nullif(trim(p_note), ''))
    returning id into hid;
  update public.payments set handover_id = hid where lower(cleaner) = lower(me) and handover_id is null and amount > 0;
  return jsonb_build_object('ok', true, 'id', hid, 'amount', tot, 'count', n);
end $$;

-- Владелец: подтверждает, сколько денег реально принял по сдаче
create or replace function public.pay_handover_confirm(p_id uuid, p_received int, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public._pay_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_received is null or p_received < 0 then raise exception 'bad_amount'; end if;
  update public.cash_handovers set received_amount = p_received, confirmed_at = now(), confirmed_by = public._pay_email(),
    note = coalesce(nullif(trim(p_note), ''), note)
  where id = p_id and confirmed_at is null;
  if not found then raise exception 'not_found'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Владелец: принял деньги у клинера лично, не дожидаясь отчёта клинера
create or replace function public.pay_owner_collect(p_cleaner text, p_received int default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tot int; n int; hid uuid;
begin
  if not public._pay_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(sum(amount), 0), count(*) into tot, n from public.payments
    where lower(cleaner) = lower(p_cleaner) and handover_id is null and amount > 0;
  if n = 0 then raise exception 'nothing'; end if;
  insert into public.cash_handovers (cleaner, amount, received_amount, confirmed_at, confirmed_by, note)
    values (p_cleaner, tot, coalesce(p_received, tot), now(), public._pay_email(), nullif(trim(p_note), '')) returning id into hid;
  update public.payments set handover_id = hid where lower(cleaner) = lower(p_cleaner) and handover_id is null and amount > 0;
  return jsonb_build_object('ok', true, 'id', hid, 'amount', tot, 'received', coalesce(p_received, tot));
end $$;

create or replace function public.pay_setting_set(p_key text, p_value int) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._pay_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_key not in ('due_hours', 'unrecorded_hours') or p_value is null or p_value < 1 or p_value > 720 then raise exception 'bad_value'; end if;
  insert into public.pay_settings (k, v) values (p_key, p_value::text) on conflict (k) do update set v = excluded.v;
  return true;
end $$;

-- 5. Для бота: клиент отвечает на вопрос об оплате
create or replace function public.bot_pay_answer(p_secret text, p_tg bigint, p_payment uuid, p_answer text, p_amount int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.payments; o record; amt int;
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_answer not in ('ok', 'other', 'none') then raise exception 'bad_answer'; end if;
  select * into p from public.payments where id = p_payment;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select sel, user_id, details into o from public.orders where id = p.order_id;
  if public._pay_tg_for(o.sel, o.user_id, o.details) is distinct from p_tg then return jsonb_build_object('ok', false, 'error', 'not_yours'); end if;
  amt := case p_answer when 'ok' then p.expected when 'none' then 0 else p_amount end;
  if amt is null or amt < 0 or amt > 1000000000 then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end if;
  update public.payments set client_answer = p_answer, client_amount = amt, client_at = now(), client_via = 'bot' where id = p_payment returning * into p;
  return jsonb_build_object('ok', true, 'flags', public._pay_flags(p),
    'verified', (p.amount is not null and p.client_answer in ('ok', 'other') and p.client_amount = p.amount));
end $$;

-- 6. Права
revoke all on function public._pay_email(), public._pay_staff(), public._pay_cleaner(), public._pay_int(text, int),
  public._pay_is_cash(text), public._pay_tg_for(jsonb, uuid, text), public._pay_flags(public.payments), public._pay_on_done() from public, anon, authenticated;
revoke all on function public.pay_snapshot(int), public.pay_record(uuid, int, text), public.pay_handover_report(text),
  public.pay_handover_confirm(uuid, int, text), public.pay_owner_collect(text, int, text), public.pay_setting_set(text, int),
  public.bot_pay_answer(text, bigint, uuid, text, int) from public;
grant execute on function public.pay_snapshot(int), public.pay_record(uuid, int, text), public.pay_handover_report(text),
  public.pay_handover_confirm(uuid, int, text), public.pay_owner_collect(text, int, text), public.pay_setting_set(text, int) to authenticated;
grant execute on function public.bot_pay_answer(text, bigint, uuid, text, int) to anon, authenticated;
