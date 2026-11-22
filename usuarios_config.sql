-- =====================================================================
--  USUARIOS Y CONFIGURACIÓN · Control de Abastecimiento URIP III
--  Ejecutar en Supabase → SQL Editor → Run, DESPUÉS de auditoria.sql.
--  Se puede volver a ejecutar sin perder datos.
-- =====================================================================

create extension if not exists pgcrypto;

-- 1) Columnas nuevas del perfil
alter table public.perfiles add column if not exists es_super boolean not null default false;
alter table public.perfiles add column if not exists activo   boolean not null default true;
alter table public.perfiles add column if not exists creado   timestamptz not null default now();

-- Funciones de apoyo (definidas también en auditoria.sql)
create or replace function public.es_super()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select es_super and activo from public.perfiles where id = auth.uid()), false);
$$;

-- =====================================================================
-- 2) ADMINISTRACIÓN DE USUARIOS (solo super usuarios)
-- =====================================================================

-- Lista de usuarios con correo y último acceso
create or replace function public.admin_listar_usuarios()
returns table (id uuid, nombre text, email text, rol text, es_super boolean, activo boolean, creado timestamptz, ultimo_acceso timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.es_super() then raise exception 'No tiene permiso para administrar usuarios'; end if;
  return query
    select p.id, p.nombre::text, u.email::text, p.rol::text, p.es_super, p.activo,
           coalesce(p.creado, u.created_at), u.last_sign_in_at
    from public.perfiles p left join auth.users u on u.id = p.id
    order by p.nombre;
end $$;

-- Crear usuario (cuenta de acceso + perfil)
create or replace function public.admin_crear_usuario(p_email text, p_password text, p_nombre text, p_rol text, p_super boolean default false)
returns uuid language plpgsql security definer set search_path = public, auth, extensions as $$
declare nuevo uuid := gen_random_uuid(); correo text := lower(trim(p_email));
begin
  if not public.es_super() then raise exception 'No tiene permiso para crear usuarios'; end if;
  if correo !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Correo electrónico no válido'; end if;
  if length(coalesce(p_password,'')) < 8 or p_password !~ '[0-9]' or p_password !~ '[A-Za-z]' then
    raise exception 'La contraseña debe tener 8 caracteres o más, con letras y números'; end if;
  if length(trim(coalesce(p_nombre,''))) < 3 then raise exception 'Escriba el nombre completo'; end if;
  if p_rol not in ('usuario','admin') then raise exception 'Rol no válido'; end if;
  if exists (select 1 from auth.users where lower(email) = correo) then raise exception 'Ya existe un usuario con ese correo electrónico'; end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', nuevo, 'authenticated', 'authenticated', correo,
          crypt(p_password, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('nombre', trim(p_nombre)),
          now(), now(), '', '', '', '');

  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), nuevo, nuevo::text,
          jsonb_build_object('sub', nuevo::text, 'email', correo, 'email_verified', true),
          'email', now(), now(), now());

  insert into public.perfiles (id, nombre, rol, es_super, activo)
  values (nuevo, trim(p_nombre), p_rol, (p_super and p_rol = 'admin'), true)
  on conflict (id) do update set nombre = excluded.nombre, rol = excluded.rol, es_super = excluded.es_super, activo = true;

  return nuevo;
end $$;

-- Actualizar nombre, rol, super usuario y estado (activo/inactivo)
create or replace function public.admin_actualizar_usuario(p_id uuid, p_nombre text, p_rol text, p_super boolean, p_activo boolean)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.es_super() then raise exception 'No tiene permiso para modificar usuarios'; end if;
  if p_rol not in ('usuario','admin') then raise exception 'Rol no válido'; end if;
  if length(trim(coalesce(p_nombre,''))) < 3 then raise exception 'Escriba el nombre completo'; end if;
  if p_id = auth.uid() and (p_activo = false or p_super = false or p_rol <> 'admin') then
    raise exception 'No puede quitarse a sí mismo el acceso ni el rol de super usuario'; end if;
  update public.perfiles
     set nombre = trim(p_nombre), rol = p_rol, es_super = (p_super and p_rol = 'admin'), activo = p_activo
   where id = p_id;
  if not found then raise exception 'El usuario no existe'; end if;
  -- Bloquea o desbloquea el inicio de sesión
  update auth.users set banned_until = case when p_activo then null else 'infinity'::timestamptz end where id = p_id;
end $$;

-- Restablecer contraseña de un usuario
create or replace function public.admin_cambiar_clave(p_id uuid, p_password text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  if not public.es_super() then raise exception 'No tiene permiso para cambiar contraseñas'; end if;
  if length(coalesce(p_password,'')) < 8 or p_password !~ '[0-9]' or p_password !~ '[A-Za-z]' then
    raise exception 'La contraseña debe tener 8 caracteres o más, con letras y números'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_id;
  if not found then raise exception 'El usuario no existe'; end if;
  insert into public.auditoria (usuario_id, usuario, accion, tabla, registro, detalle)
  select auth.uid(), (select nombre from public.perfiles where id = auth.uid()), 'cambio_clave', 'perfiles', p_id::text,
         jsonb_build_object('usuario', (select nombre from public.perfiles where id = p_id));
exception when undefined_table then null;  -- si la auditoría aún no existe
end $$;

revoke all on function public.admin_listar_usuarios() from public, anon;
revoke all on function public.admin_crear_usuario(text, text, text, text, boolean) from public, anon;
revoke all on function public.admin_actualizar_usuario(uuid, text, text, boolean, boolean) from public, anon;
revoke all on function public.admin_cambiar_clave(uuid, text) from public, anon;
grant execute on function public.admin_listar_usuarios() to authenticated;
grant execute on function public.admin_crear_usuario(text, text, text, text, boolean) to authenticated;
grant execute on function public.admin_actualizar_usuario(uuid, text, text, boolean, boolean) to authenticated;
grant execute on function public.admin_cambiar_clave(uuid, text) to authenticated;

-- Nadie puede cambiarse a sí mismo es_super / activo / rol desde la app (solo con las funciones anteriores)
create or replace function public.proteger_es_super()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.es_super() then
    if (tg_op = 'INSERT' and (new.es_super or new.activo = false)) or
       (tg_op = 'UPDATE' and (new.es_super is distinct from old.es_super or new.activo is distinct from old.activo or new.rol is distinct from old.rol)) then
      raise exception 'No tiene permiso para cambiar roles o estado de usuarios';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_proteger_es_super on public.perfiles;
create trigger trg_proteger_es_super before insert or update on public.perfiles
  for each row execute function public.proteger_es_super();

-- =====================================================================
-- 3) CONFIGURACIÓN DEL SISTEMA
-- =====================================================================
create table if not exists public.configuracion (
  clave            text primary key,
  valor            jsonb not null,
  actualizado      timestamptz not null default now(),
  actualizado_por  text
);
alter table public.configuracion enable row level security;

drop policy if exists configuracion_leer_publico on public.configuracion;
drop policy if exists configuracion_leer on public.configuracion;
drop policy if exists configuracion_insertar on public.configuracion;
drop policy if exists configuracion_modificar on public.configuracion;
-- Las gasolineras también se necesitan en "Abastecimiento con orden" (sin sesión)
create policy configuracion_leer_publico on public.configuracion for select to anon using (clave = 'gasolineras');
create policy configuracion_leer on public.configuracion for select to authenticated using (true);
create policy configuracion_insertar on public.configuracion for insert to authenticated with check (public.es_super());
create policy configuracion_modificar on public.configuracion for update to authenticated using (public.es_super()) with check (public.es_super());
grant select on public.configuracion to anon, authenticated;
grant insert, update on public.configuracion to authenticated;

-- Registrar en la auditoría los cambios de configuración
do $$ begin
  if to_regprocedure('public.auditoria_trg()') is not null then
    drop trigger if exists trg_auditoria on public.configuracion;
    create trigger trg_auditoria after insert or update or delete on public.configuracion
      for each row execute function public.auditoria_trg();
  end if;
end $$;

-- =====================================================================
-- 4) PRIMER SUPER USUARIO (cambie el correo, quite los -- y ejecute)
-- =====================================================================
-- update public.perfiles set es_super = true, rol = 'admin', activo = true
--   where id = (select id from auth.users where email = 'eduar.varela@gmail.com');
