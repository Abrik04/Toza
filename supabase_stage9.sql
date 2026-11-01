-- ЭТАП 9. Онлайн-оплата Payme и Click.
-- Запускать после этапов 1–8. Файл можно запускать повторно.
-- Как: Supabase -> SQL Editor -> New query -> вставить весь файл -> Run.
--
-- Что внутри:
--  * orders получает поля paid_at / paid_via / paid_amount: по ним сайт, бот, админка и клинер видят «оплачено»;
--  * online_payments хранит каждую операцию Payme и Click (создана, оплачена, отменена, возврат);
--  * payme_* и click_* реализуют правила Payme Merchant API и Click Shop API. Их вызывает только платёжный сервер
--    (папка tozavoy-bot, команда `python -m tozavoy_bot.payserver`), и только с секретом бота (этап 7);
--  * при оплате клиенту в Telegram приходит сообщение «Оплата получена», а касса (этап 8) не просит клинера брать наличные.

-- 0. Проверка: всё, на что опирается этап, уже есть
do $$
declare
  need text[] := array['orders.id','orders.code','orders.total','orders.status','orders.details','orders.sel','orders.user_id','bot_outbox.kind','payments.order_id'];
  x text; miss text := '';
begin
  foreach x in array need loop
    if not exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = split_part(x, '.', 1) and column_name = split_part(x, '.', 2)) then
      miss := miss || ' ' || x;
    end if;
  end loop;
  if to_regprocedure('public._bot_ok(text)') is null then miss := miss || ' функция _bot_ok (этап 7)'; end if;
  if to_regprocedure('public._pay_on_done()') is null then miss := miss || ' функция _pay_on_done (этап 8)'; end if;
  if miss <> '' then raise exception 'Этап 9 остановлен: в базе нет:%. Сначала запустите этапы 1–8.', miss; end if;
end $$;

-- 1. Поля оплаты в заказе и таблица операций
alter table public.orders add column if not exists paid_at timestamptz;
alter table public.orders add column if not exists paid_via text;
alter table public.orders add column if not exists paid_amount int;

create table if not exists public.online_payments (
  id bigserial primary key,
  provider text not null check (provider in ('payme', 'click')),
  ext_id text not null,                      -- Payme: id транзакции; Click: click_trans_id
  order_id uuid not null references public.orders (id) on delete restrict,
  amount int not null,                       -- сумма в сумах
  state int not null,                        -- 1 создана, 2 оплачена, -1 отменена, -2 возврат после оплаты
  reason int,
  provider_time bigint,                      -- Payme: время запроса (мс)
  create_time bigint not null,               -- мс
  perform_time bigint,
  cancel_time bigint,
  created_at timestamptz not null default now(),
  unique (provider, ext_id)
);
create index if not exists online_payments_order_idx on public.online_payments (order_id);

alter table public.online_payments enable row level security;
revoke all on public.online_payments from anon, authenticated;
revoke all on sequence public.online_payments_id_seq from anon, authenticated;

-- 2. Помощники
create or replace function public._op_now() returns bigint language sql volatile as $$
  select (extract(epoch from clock_timestamp()) * 1000)::bigint
$$;

create or replace function public._op_uuid(t text) returns uuid language sql immutable as $$
  select case when t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then t::uuid end
$$;

create or replace function public._op_lock(p_order uuid) returns void language sql as $$
  select pg_advisory_xact_lock(hashtextextended('op:' || p_order::text, 0))
$$;

-- Заказ оплачен: ставим отметку и пишем клиенту в Telegram
create or replace function public._op_mark_paid(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare t public.online_payments; o record; v_tg bigint;
begin
  select * into t from public.online_payments where id = p_id;
  update public.orders set paid_at = now(), paid_via = t.provider, paid_amount = t.amount where id = t.order_id
    returning code, sel, user_id, details into o;
  begin
    v_tg := public._pay_tg_for(o.sel, o.user_id, o.details);
    if v_tg is not null then
      insert into public.bot_outbox (tg_id, kind, code, status, payload)
      values (v_tg, 'paid', o.code, 'paid', jsonb_build_object('amount', t.amount, 'provider', t.provider));
    end if;
  exception when others then null;
  end;
end $$;

create or replace function public._op_unpay(p_order uuid) returns void
language sql security definer set search_path = public as $$
  update public.orders set paid_at = null, paid_via = null, paid_amount = null where id = p_order
$$;

-- Проверка заказа по правилам Payme: -31050 нет заказа, -31001 неверная сумма, -31008 оплачен или отменён
create or replace function public._payme_validate(p_amount bigint, p_order text, out o_id uuid, out o_err int)
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  o_err := 0;
  o_id := public._op_uuid(p_order);
  if o_id is null then o_err := -31050; return; end if;
  select id, total, status, paid_at into o from public.orders where id = o_id;
  if not found then o_id := null; o_err := -31050; return; end if;
  if p_amount is distinct from coalesce(o.total, 0)::bigint * 100 then o_err := -31001; return; end if;
  if o.paid_at is not null or coalesce(o.status, 'new') = 'cancel' then o_err := -31008; return; end if;
end $$;

-- 3. Payme Merchant API
create or replace function public.payme_check(p_secret text, p_amount bigint, p_order text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v record;
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into v from public._payme_validate(p_amount, p_order);
  if v.o_err <> 0 then return jsonb_build_object('error', v.o_err); end if;
  return jsonb_build_object('result', jsonb_build_object('allow', true));
end $$;

create or replace function public.payme_create(p_secret text, p_id text, p_time bigint, p_amount bigint, p_order text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.online_payments; v record; now_ms bigint := public._op_now(); o_total int;
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into t from public.online_payments where provider = 'payme' and ext_id = p_id for update;
  if found then
    if t.state = 1 then
      if now_ms - t.create_time > 43200000 then
        update public.online_payments set state = -1, reason = 4, cancel_time = now_ms where id = t.id;
        return jsonb_build_object('error', -31008);
      end if;
      return jsonb_build_object('result', jsonb_build_object('create_time', t.create_time, 'transaction', t.id::text, 'state', 1));
    end if;
    return jsonb_build_object('error', -31008);
  end if;
  select * into v from public._payme_validate(p_amount, p_order);
  if v.o_err <> 0 then return jsonb_build_object('error', v.o_err); end if;
  perform public._op_lock(v.o_id);
  if exists (select 1 from public.online_payments where provider = 'payme' and order_id = v.o_id and state in (1, 2)) then
    return jsonb_build_object('error', -31099);
  end if;
  select coalesce(total, 0) into o_total from public.orders where id = v.o_id;
  begin
    insert into public.online_payments (provider, ext_id, order_id, amount, state, provider_time, create_time)
    values ('payme', p_id, v.o_id, o_total, 1, p_time, now_ms) returning * into t;
  exception when unique_violation then
    select * into t from public.online_payments where provider = 'payme' and ext_id = p_id;
  end;
  return jsonb_build_object('result', jsonb_build_object('create_time', t.create_time, 'transaction', t.id::text, 'state', t.state));
end $$;

create or replace function public.payme_perform(p_secret text, p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.online_payments; now_ms bigint := public._op_now();
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into t from public.online_payments where provider = 'payme' and ext_id = p_id;
  if not found then return jsonb_build_object('error', -31003); end if;
  perform public._op_lock(t.order_id);
  select * into t from public.online_payments where id = t.id for update;
  if t.state = 1 then
    if now_ms - t.create_time > 43200000 then
      update public.online_payments set state = -1, reason = 4, cancel_time = now_ms where id = t.id;
      return jsonb_build_object('error', -31008);
    end if;
    update public.online_payments set state = 2, perform_time = now_ms where id = t.id returning * into t;
    perform public._op_mark_paid(t.id);
  elsif t.state <> 2 then
    return jsonb_build_object('error', -31008);
  end if;
  return jsonb_build_object('result', jsonb_build_object('transaction', t.id::text, 'perform_time', t.perform_time, 'state', t.state));
end $$;

create or replace function public.payme_cancel(p_secret text, p_id text, p_reason int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.online_payments; now_ms bigint := public._op_now(); o_status text;
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into t from public.online_payments where provider = 'payme' and ext_id = p_id;
  if not found then return jsonb_build_object('error', -31003); end if;
  perform public._op_lock(t.order_id);
  select * into t from public.online_payments where id = t.id for update;
  if t.state = 1 then
    update public.online_payments set state = -1, reason = p_reason, cancel_time = now_ms where id = t.id returning * into t;
  elsif t.state = 2 then
    select status into o_status from public.orders where id = t.order_id;
    if coalesce(o_status, 'new') = 'done' then return jsonb_build_object('error', -31007); end if;   -- услуга уже оказана
    update public.online_payments set state = -2, reason = p_reason, cancel_time = now_ms where id = t.id returning * into t;
    perform public._op_unpay(t.order_id);
  end if;
  return jsonb_build_object('result', jsonb_build_object('transaction', t.id::text, 'cancel_time', t.cancel_time, 'state', t.state));
end $$;

create or replace function public.payme_check_tx(p_secret text, p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.online_payments;
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into t from public.online_payments where provider = 'payme' and ext_id = p_id;
  if not found then return jsonb_build_object('error', -31003); end if;
  return jsonb_build_object('result', jsonb_build_object('create_time', t.create_time, 'perform_time', coalesce(t.perform_time, 0),
    'cancel_time', coalesce(t.cancel_time, 0), 'transaction', t.id::text, 'state', t.state, 'reason', t.reason));
end $$;

create or replace function public.payme_statement(p_secret text, p_from bigint, p_to bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.ext_id, 'time', coalesce(t.provider_time, t.create_time), 'amount', t.amount::bigint * 100,
      'account', jsonb_build_object('order_id', t.order_id), 'create_time', t.create_time,
      'perform_time', coalesce(t.perform_time, 0), 'cancel_time', coalesce(t.cancel_time, 0),
      'transaction', t.id::text, 'state', t.state, 'reason', t.reason) order by t.create_time), '[]'::jsonb)
    into r from public.online_payments t
    where t.provider = 'payme' and t.create_time between p_from and p_to;
  return jsonb_build_object('result', jsonb_build_object('transactions', r));
end $$;

-- 4. Click Shop API (подпись проверяет платёжный сервер; здесь только состояние)
-- Коды Click: 0 успех, -2 неверная сумма, -4 уже оплачено, -5 заказ не найден, -6 транзакция не найдена, -9 отменена
create or replace function public.click_prepare(p_secret text, p_trans_id text, p_order text, p_amount numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; oid uuid; t public.online_payments;
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  oid := public._op_uuid(p_order);
  if oid is null then return jsonb_build_object('error', -5); end if;
  select id, total, status, paid_at into o from public.orders where id = oid;
  if not found then return jsonb_build_object('error', -5); end if;
  if abs(coalesce(p_amount, -1) - coalesce(o.total, 0)) > 0.01 then return jsonb_build_object('error', -2); end if;
  perform public._op_lock(oid);
  select * into t from public.online_payments where provider = 'click' and ext_id = p_trans_id for update;
  if found then
    if t.state = 1 then return jsonb_build_object('error', 0, 'merchant_prepare_id', t.id); end if;
    return jsonb_build_object('error', case when t.state = 2 then -4 else -9 end);
  end if;
  if o.paid_at is not null then return jsonb_build_object('error', -4); end if;
  if coalesce(o.status, 'new') = 'cancel' then return jsonb_build_object('error', -9); end if;
  insert into public.online_payments (provider, ext_id, order_id, amount, state, create_time)
    values ('click', p_trans_id, oid, coalesce(o.total, 0), 1, public._op_now()) returning * into t;
  return jsonb_build_object('error', 0, 'merchant_prepare_id', t.id);
end $$;

create or replace function public.click_complete(p_secret text, p_trans_id text, p_order text, p_prepare_id bigint, p_amount numeric, p_click_error int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.online_payments; o record; now_ms bigint := public._op_now();
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into t from public.online_payments where id = p_prepare_id and provider = 'click';
  if not found or t.ext_id <> p_trans_id then return jsonb_build_object('error', -6); end if;
  if t.order_id::text <> lower(coalesce(p_order, '')) then return jsonb_build_object('error', -5); end if;
  perform public._op_lock(t.order_id);
  select * into t from public.online_payments where id = t.id for update;
  if abs(coalesce(p_amount, -1) - t.amount) > 0.01 then return jsonb_build_object('error', -2); end if;
  if t.state = 2 then return jsonb_build_object('error', -4); end if;
  if t.state < 0 then return jsonb_build_object('error', -9); end if;
  if coalesce(p_click_error, 0) < 0 then
    update public.online_payments set state = -1, reason = abs(p_click_error), cancel_time = now_ms where id = t.id;
    return jsonb_build_object('error', -9);
  end if;
  select status, paid_at into o from public.orders where id = t.order_id;
  if o.paid_at is not null then
    update public.online_payments set state = -1, reason = 5, cancel_time = now_ms where id = t.id;
    return jsonb_build_object('error', -4);
  end if;
  if coalesce(o.status, 'new') = 'cancel' then
    update public.online_payments set state = -1, reason = 3, cancel_time = now_ms where id = t.id;
    return jsonb_build_object('error', -9);
  end if;
  update public.online_payments set state = 2, perform_time = now_ms where id = t.id;
  perform public._op_mark_paid(t.id);
  return jsonb_build_object('error', 0, 'merchant_confirm_id', t.id);
end $$;

-- 5. Для админки: список онлайн-оплат
create or replace function public.pay_online_list(p_days int default 90) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not public._pay_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x order by x.create_time desc), '[]'::jsonb) into r from (
    select t.id, t.provider, t.ext_id, t.order_id, o.code, t.amount, t.state, t.reason, t.create_time, t.perform_time, t.cancel_time,
           nullif(trim(substring(o.details from 'Клиент:([^\n]*)')), '') as client
    from public.online_payments t join public.orders o on o.id = t.order_id
    where t.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 90), 365)))
  ) x;
  return r;
end $$;

-- 6. Обновляем функции прошлых этапов
-- Касса (этап 8): заказ, оплаченный онлайн, не требует наличных
create or replace function public._pay_on_done() returns trigger language plpgsql security definer set search_path = public as $$
declare pid uuid; v_tg bigint;
begin
  if new.status is not distinct from old.status or new.status <> 'done' or not public._pay_is_cash(new.details) then return new; end if;
  if new.paid_at is not null then return new; end if;
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

-- «Мои заказы» в боте: добавляем номер заказа, способ оплаты и отметку «оплачено»
drop function if exists public.bot_my_orders(text, bigint);
create or replace function public.bot_my_orders(p_secret text, p_tg bigint)
returns table(code text, total int, status text, created_at timestamptz, visit_date text, plan int, id uuid, paid boolean, pay text)
language plpgsql security definer set search_path = public as $$
declare acc uuid;
begin
  if not public._bot_ok(p_secret) then raise exception 'forbidden' using errcode = '42501'; end if;
  select user_id into acc from public.tg_profiles where tg_id = p_tg;
  return query
    select o.code, o.total, o.status, o.created_at, o.sel ->> 'date',
           case when (o.sel ->> 'plan') ~ '^[0-9]+$' then (o.sel ->> 'plan')::int else 0 end,
           o.id, (o.paid_at is not null), nullif(trim((regexp_match(coalesce(o.details, ''), 'Оплата:\s*([^\n]*)'))[1]), '')
    from public.orders o
    where (acc is not null and o.user_id = acc) or o.sel ->> 'tg' = p_tg::text
    order by o.created_at desc limit 12;
end $$;

-- 7. Права
revoke all on function public._op_now(), public._op_uuid(text), public._op_lock(uuid), public._op_mark_paid(bigint),
  public._op_unpay(uuid), public._payme_validate(bigint, text) from public, anon, authenticated;
revoke all on function public.payme_check(text, bigint, text), public.payme_create(text, text, bigint, bigint, text),
  public.payme_perform(text, text), public.payme_cancel(text, text, int), public.payme_check_tx(text, text),
  public.payme_statement(text, bigint, bigint), public.click_prepare(text, text, text, numeric),
  public.click_complete(text, text, text, bigint, numeric, int), public.pay_online_list(int),
  public.bot_my_orders(text, bigint) from public;
grant execute on function public.payme_check(text, bigint, text), public.payme_create(text, text, bigint, bigint, text),
  public.payme_perform(text, text), public.payme_cancel(text, text, int), public.payme_check_tx(text, text),
  public.payme_statement(text, bigint, bigint), public.click_prepare(text, text, text, numeric),
  public.click_complete(text, text, text, bigint, numeric, int), public.bot_my_orders(text, bigint) to anon, authenticated;
grant execute on function public.pay_online_list(int) to authenticated;
