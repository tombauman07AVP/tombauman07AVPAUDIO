-- Ballroom Audio: email a plan sheet to people who have an account.
-- Run this once in Supabase (SQL Editor → New query → paste → Run). Safe to run again.
-- Needs the requests SQL first (it uses the same Resend key and the pg_net add-on).
--
-- Editors and admins can email an event's plan sheet from its page (the Email button).
-- They can only send to email addresses that have an account on the site.
-- Every share is kept in plan_shares and shows in Admin → Activity.

-- Who a plan was sent to, by whom, and the Resend request so the sender can see if it went.
create table if not exists public.plan_shares (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  user_id     uuid,
  user_name   text,
  event_id    text,
  event_name  text,
  recipients  text[] not null,
  request_id  bigint
);
create index if not exists plan_shares_user_at_idx on public.plan_shares (user_id, at desc);
alter table public.plan_shares enable row level security;
revoke all on table public.plan_shares from anon, authenticated;

-- The people a plan can go to: everyone with an account and an email address.
create or replace function public.share_people()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if public.my_role() not in ('editor','admin') then
    raise exception 'Only editors and admins can email plans' using errcode = '42501';
  end if;
  return coalesce((
    select json_agg(json_build_object('email', lower(email), 'name', name, 'role', role) order by lower(coalesce(nullif(name, ''), email)))
      from public.profiles
     where coalesce(email, '') <> ''), '[]'::json);
end $$;

-- Email one plan sheet. p_images are the signal path pictures: [{"id":"dg1","filename":"…png","content":"<base64>"}].
-- Returns {"id": share id, "test_sender": true when it is still using Resend's test address}.
create or replace function public.share_plan(p_event_id text, p_event_name text, p_to text[], p_subject text,
                                             p_html text, p_text text, p_images jsonb default '[]'::jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare v_key text; v_from text; v_reply text; v_to text[]; v_bad text[]; v_n int; v_att jsonb := '[]'::jsonb;
        v_img jsonb; v_body jsonb; v_req bigint; v_id bigint;
begin
  if public.my_role() not in ('editor','admin') then
    raise exception 'Only editors and admins can email plans' using errcode = '42501';
  end if;
  select array_agg(distinct lower(trim(x))) into v_to from unnest(coalesce(p_to, '{}')) x where trim(x) <> '';
  if v_to is null then raise exception 'Pick at least one person' using errcode = '22023'; end if;
  if array_length(v_to, 1) > 40 then raise exception 'That''s too many people for one email (40 at most)' using errcode = '22023'; end if;
  select array_agg(t) into v_bad from unnest(v_to) t
   where not exists (select 1 from public.profiles p where lower(p.email) = t);
  if v_bad is not null then
    raise exception 'Not on the site: %. Plans only go to people with an account.', array_to_string(v_bad, ', ') using errcode = '22023';
  end if;
  if coalesce(p_html, '') = '' or length(p_html) > 400000 then raise exception 'The plan sheet is empty or too big to email' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(p_images, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_images, '[]'::jsonb)) > 12 then
    raise exception 'Too many pictures for one email' using errcode = '22023';
  end if;
  select count(*) into v_n from public.plan_shares where user_id = auth.uid() and at > now() - interval '1 hour';
  if v_n >= 20 then raise exception 'That''s a lot of plans emailed in an hour. Try again a bit later.' using errcode = '22023'; end if;

  for v_img in select * from jsonb_array_elements(coalesce(p_images, '[]'::jsonb)) loop
    if coalesce(v_img->>'id', '') !~ '^[a-z0-9-]{1,40}$' or coalesce(v_img->>'content', '') !~ '^[A-Za-z0-9+/=]+$'
       or length(v_img->>'content') > 4000000 then
      raise exception 'One of the plan pictures couldn''t be attached' using errcode = '22023';
    end if;
    v_att := v_att || jsonb_build_array(jsonb_build_object(
      'filename', left(regexp_replace(coalesce(v_img->>'filename', v_img->>'id' || '.png'), '[^A-Za-z0-9._ -]', '', 'g'), 80),
      'content', v_img->>'content', 'content_id', v_img->>'id'));
  end loop;

  select value into v_key  from public.app_private where key = 'resend_key';
  select value into v_from from public.app_private where key = 'share_from';
  if coalesce(v_key, '') = '' then raise exception 'Email isn''t set up yet. An admin adds the Resend key in Admin → Requests.' using errcode = '22023'; end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    raise exception 'The database''s mail add-on (pg_net) isn''t switched on' using errcode = '22023';
  end if;
  select email into v_reply from public.profiles where id = auth.uid();

  v_body := jsonb_build_object(
    'from', coalesce(nullif(v_from, ''), 'Ballroom Audio <onboarding@resend.dev>'),
    'to', to_jsonb(v_to),
    'subject', left(coalesce(nullif(trim(p_subject), ''), 'Event plan'), 150),
    'html', p_html,
    'text', left(coalesce(p_text, ''), 100000));
  if coalesce(v_reply, '') <> '' then v_body := v_body || jsonb_build_object('reply_to', v_reply); end if;
  if jsonb_array_length(v_att) > 0 then v_body := v_body || jsonb_build_object('attachments', v_att); end if;
  v_req := net.http_post(url := 'https://api.resend.com/emails', body := v_body,
                         headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
                         timeout_milliseconds := 20000);

  insert into public.plan_shares (user_id, user_name, event_id, event_name, recipients, request_id)
  values (auth.uid(), public.my_name(), left(p_event_id, 40), left(p_event_name, 200), v_to, v_req)
  returning id into v_id;
  insert into public.activity_log (user_id, user_name, action, target, detail)
  values (auth.uid(), public.my_name(), 'shared', left(coalesce(p_event_name, 'Event'), 120),
          jsonb_build_object('event', left(p_event_id, 40), 'to', to_jsonb(v_to), 'share', v_id));
  return json_build_object('id', v_id, 'test_sender', coalesce(v_from, '') = '');
end $$;

-- Did Resend take it? Null while it's still sending. Only the sender (or an admin) can check.
create or replace function public.share_result(p_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare v_req bigint; r json;
begin
  select request_id into v_req from public.plan_shares
   where id = p_id and (user_id = auth.uid() or public.my_role() = 'admin');
  if v_req is null then raise exception 'That share isn''t there' using errcode = '22023'; end if;
  select json_build_object('status', status_code, 'content', left(content, 600), 'error', error_msg)
    into r from net._http_response where id = v_req;
  return r;
end $$;

-- Admins: the address shared plans come from. It must be on a domain you've verified in Resend.
create or replace function public.share_settings()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if public.my_role() <> 'admin' then raise exception 'Admins only' using errcode = '42501'; end if;
  return json_build_object('from', (select value from public.app_private where key = 'share_from'));
end $$;

create or replace function public.set_share_from(p_from text)
returns json language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(coalesce(p_from, '')), '');
begin
  if public.my_role() <> 'admin' then raise exception 'Admins only' using errcode = '42501'; end if;
  if v is not null and v !~ '^([^<>@]*<)?[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+>?$' then
    raise exception 'That doesn''t look like an email address' using errcode = '22023';
  end if;
  if v is not null and v !~ '<' then v := 'Ballroom Audio <' || v || '>'; end if;
  insert into public.app_private (key, value) values ('share_from', v)
    on conflict (key) do update set value = excluded.value;
  return public.share_settings();
end $$;

-- Who may call what.
revoke all on function public.share_people(), public.share_plan(text,text,text[],text,text,text,jsonb),
  public.share_result(bigint), public.share_settings(), public.set_share_from(text) from public, anon;
grant execute on function public.share_people(), public.share_plan(text,text,text[],text,text,text,jsonb),
  public.share_result(bigint), public.share_settings(), public.set_share_from(text) to authenticated;
