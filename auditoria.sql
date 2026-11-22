-- =====================================================================
--  AUDITORÍA · Control de Abastecimiento URIP III
--  Ejecutar UNA VEZ en Supabase → SQL Editor → Run.
--  Se puede volver a ejecutar sin perder datos.
-- =====================================================================

-- 1) Marca de super usuario en los perfiles (solo ellos ven la auditoría)
alter table public.perfiles add column if not exists es_super boolean not null default false;

-- 2) Tabla de auditoría
create table if not exists public.auditoria (
  id          bigserial primary key,
  creado      timestamptz not null default now(),
  usuario_id  uuid,
  usuario     text,
  accion      text not null,          -- INSERT / UPDATE / DELETE / inicio_sesion / exportar_excel / ...
  tabla       text,
  registro    text,
  antes       jsonb,
  despues     jsonb,
  detalle     jsonb
);
create index if not exists auditoria_creado_idx on public.auditoria (creado desc);
create index if not exists auditoria_usuario_idx on public.auditoria (usuario_id);

-- 3) ¿El usuario actual es super usuario?
create or replace function public.es_super()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select es_super from public.perfiles where id = auth.uid()), false);
$$;

-- 4) Seguridad: solo los super usuarios LEEN la auditoría; nadie puede modificarla ni borrarla desde la app
alter table public.auditoria enable row level security;
drop policy if exists auditoria_select on public.auditoria;
create policy auditoria_select on public.auditoria for select to authenticated using (public.es_super());
revoke insert, update, delete on public.auditoria from anon, authenticated;

-- 5) Nadie puede darse a sí mismo el permiso de super usuario desde la app
create or replace function public.proteger_es_super()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.es_super() then
    if (tg_op = 'INSERT' and new.es_super) or (tg_op = 'UPDATE' and new.es_super is distinct from old.es_super) then
      raise exception 'No tiene permiso para cambiar el rol de super usuario';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_proteger_es_super on public.perfiles;
create trigger trg_proteger_es_super before insert or update on public.perfiles
  for each row execute function public.proteger_es_super();

-- 6) Registro automático de cambios (crear, modificar, eliminar) en las tablas de la app
create or replace function public.auditoria_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  nom text;
  fila jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  if uid is not null then select nombre into nom from public.perfiles where id = uid; end if;
  -- Las actualizaciones que no cambian nada no se registran
  if tg_op = 'UPDATE' and to_jsonb(old) = to_jsonb(new) then return new; end if;
  insert into public.auditoria (usuario_id, usuario, accion, tabla, registro, antes, despues)
  values (uid,
          coalesce(nom, case when uid is null then 'Sin usuario (abastecimiento con orden)' else 'Usuario' end),
          tg_op, tg_table_name, coalesce(fila->>'id', fila->>'clave', ''),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['abastecimientos','vehiculos','abastecimientos_orden','vehiculos_orden','perfiles','mantenimientos','configuracion'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_auditoria on public.%I', t);
      execute format('create trigger trg_auditoria after insert or update or delete on public.%I
                      for each row execute function public.auditoria_trg()', t);
    end if;
  end loop;
end $$;

-- 7) Eventos que envía la aplicación (inicio/cierre de sesión, descargas, envíos)
create or replace function public.registrar_auditoria(p_accion text, p_detalle jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nom text;
begin
  if uid is null then return; end if;                               -- solo usuarios con sesión
  if p_accion !~ '^[a-z_]{3,40}$' then return; end if;              -- nombres de acción válidos
  select nombre into nom from public.perfiles where id = uid;
  insert into public.auditoria (usuario_id, usuario, accion, detalle)
  values (uid, coalesce(nom, 'Usuario'), p_accion,
          case when p_detalle is not null and pg_column_size(p_detalle) < 4000 then p_detalle end);
end $$;
revoke all on function public.registrar_auditoria(text, jsonb) from public, anon;
grant execute on function public.registrar_auditoria(text, jsonb) to authenticated;

-- =====================================================================
-- 8) DAR PERMISO DE SUPER USUARIO (cambie el correo y ejecute esta línea).
--    El super usuario también debe tener rol = 'admin'.
-- =====================================================================
-- update public.perfiles set es_super = true, rol = 'admin'
--   where id = (select id from auth.users where email = 'eduar.varela@gmail.com');

-- Quitar el permiso:
-- update public.perfiles set es_super = false
--   where id = (select id from auth.users where email = 'correo@ejemplo.com');
