-- =====================================================================
--  MIGRACIÓN SEGURA · Control de Abastecimiento URIP III
--  Ejecutar en Supabase → SQL Editor → New query → pegar → Run.
--  Es IDEMPOTENTE: se puede correr varias veces sin romper nada.
--
--  Qué hace:
--   1. Crea/completa las tablas y sus índices.
--   2. Añade validaciones (CHECK) a los datos.
--   3. Activa RLS y define permisos correctos en TODAS las tablas.
--   4. Protege el Storage (facturas / ordenes).
--   5. Evita que un usuario se cambie el rol o suplante el nombre.
--
--  ⚠️  ANTES DE EJECUTAR: haz un respaldo (Dashboard → Database → Backups)
--      o exporta las tablas. Nada de esto borra datos, pero es buena práctica.
-- =====================================================================


-- =====================================================================
--  BLOQUE 0 · DIAGNÓSTICO (opcional: ejecútalo solo, para ver el estado)
-- =====================================================================
-- select tablename, rowsecurity
--   from pg_tables where schemaname='public' order by tablename;
-- select schemaname, tablename, policyname, cmd, roles
--   from pg_policies where schemaname='public' order by tablename, policyname;


-- =====================================================================
--  BLOQUE 1 · ESQUEMA
-- =====================================================================

-- ---------- PERFILES ----------
create table if not exists public.perfiles (
  id     uuid primary key references auth.users(id) on delete cascade,
  nombre text not null default 'Usuario',
  rol    text not null default 'usuario' check (rol in ('admin','usuario'))
);

-- ---------- VEHÍCULOS ----------
create table if not exists public.vehiculos (
  id                   uuid primary key default gen_random_uuid(),
  marca                text,
  modelo               text,
  tipo                 text,
  color                text,
  anio                 text,
  placa                text,
  motor                text,
  chasis               text,
  numero_equipo        text,
  limite_mantenimiento numeric default 5000,
  km_base_mantenimiento numeric default 0
);

-- ---------- ABASTECIMIENTOS (usuarios con login) ----------
create table if not exists public.abastecimientos (
  id              uuid primary key default gen_random_uuid(),
  fecha           timestamptz not null default now(),
  vehiculo_id     text,
  vehiculo_desc   text,
  vehiculo_placa  text,
  marca           text,
  tipo            text,
  color           text,
  modelo          text,
  anio            text,
  motor           text,
  chasis          text,
  numero_equipo   text,
  gasolinera      text,
  kilometraje     numeric,
  lempiras        numeric,
  litros          numeric,
  foto_url        text,
  usuario         text,
  uid             uuid default auth.uid()
);

-- ---------- ABASTECIMIENTOS CON ORDEN (kiosco, sin login) ----------
create table if not exists public.abastecimientos_orden (
  id            uuid primary key default gen_random_uuid(),
  fecha         timestamptz not null default now(),
  placa         text,
  marca         text,
  modelo        text,
  tipo          text,
  color         text,
  anio          text,
  motor         text,
  chasis        text,
  numero_equipo text,
  asignado_a    text,
  conductor     text,
  texto_boleta  text,
  boleta_url    text,
  gasolinera    text,
  kilometraje   numeric,
  lempiras      numeric,
  litros        numeric,
  factura_url   text
);

-- ---------- VEHÍCULOS GUARDADOS (kiosco) ----------
create table if not exists public.vehiculos_orden (
  clave        text primary key,
  placa        text,
  marca        text,
  modelo       text,
  tipo         text,
  color        text,
  anio         text,
  motor        text,
  chasis       text,
  numero_equipo text,
  asignado_a   text,
  conductor    text,
  actualizado  timestamptz default now()
);

-- ---------- MANTENIMIENTOS ----------
create table if not exists public.mantenimientos (
  id          uuid primary key default gen_random_uuid(),
  vehiculo_id text not null,
  fecha       timestamptz not null default now(),
  kilometraje numeric not null,
  proximo_km  numeric,
  taller      text,
  conductor   text,
  usuario     text,
  uid         uuid default auth.uid()
);


-- =====================================================================
--  BLOQUE 2 · ÍNDICES (rendimiento de filtros y reportes)
-- =====================================================================
create index if not exists idx_abast_fecha      on public.abastecimientos (fecha desc);
create index if not exists idx_abast_vehiculo   on public.abastecimientos (vehiculo_id);
create index if not exists idx_abast_uid        on public.abastecimientos (uid);
create index if not exists idx_orden_fecha      on public.abastecimientos_orden (fecha desc);
create index if not exists idx_orden_placa      on public.abastecimientos_orden (placa);
create index if not exists idx_veh_placa        on public.vehiculos (placa);
create index if not exists idx_mant_vehiculo    on public.mantenimientos (vehiculo_id, fecha desc);


-- =====================================================================
--  BLOQUE 3 · VALIDACIONES (CHECK)
--  "not valid" = no revisa filas viejas (seguro en tablas con datos).
-- =====================================================================
do $$
begin
  if not exists (select 1 from pg_constraint where conname='ck_abast_valores') then
    alter table public.abastecimientos
      add constraint ck_abast_valores
      check (kilometraje >= 0 and lempiras > 0 and litros > 0) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conname='ck_orden_valores') then
    alter table public.abastecimientos_orden
      add constraint ck_orden_valores
      check (kilometraje >= 0 and lempiras > 0 and litros > 0) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conname='ck_veh_limite') then
    alter table public.vehiculos
      add constraint ck_veh_limite
      check (limite_mantenimiento between 1000 and 50000) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conname='ck_veh_kmbase') then
    alter table public.vehiculos
      add constraint ck_veh_kmbase
      check (km_base_mantenimiento >= 0) not valid;
  end if;
end $$;


-- =====================================================================
--  BLOQUE 4 · FUNCIÓN es_admin()
-- =====================================================================
create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'admin');
$$;
revoke all on function public.es_admin() from public, anon;
grant execute on function public.es_admin() to authenticated;


-- =====================================================================
--  BLOQUE 5 · RLS (Row Level Security)
-- =====================================================================

-- ---------- 5.1 PERFILES ----------
alter table public.perfiles enable row level security;
drop policy if exists perfiles_ver_propio on public.perfiles;
drop policy if exists perfiles_admin_todo on public.perfiles;
create policy perfiles_ver_propio on public.perfiles
  for select to authenticated using (id = auth.uid() or public.es_admin());
create policy perfiles_admin_todo on public.perfiles
  for all to authenticated using (public.es_admin()) with check (public.es_admin());

-- ---------- 5.2 VEHÍCULOS ----------
alter table public.vehiculos enable row level security;
drop policy if exists vehiculos_ver on public.vehiculos;
drop policy if exists vehiculos_admin_crear on public.vehiculos;
drop policy if exists vehiculos_admin_editar on public.vehiculos;
drop policy if exists vehiculos_admin_borrar on public.vehiculos;
create policy vehiculos_ver on public.vehiculos
  for select to authenticated using (true);
create policy vehiculos_admin_crear on public.vehiculos
  for insert to authenticated with check (public.es_admin());
create policy vehiculos_admin_editar on public.vehiculos
  for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy vehiculos_admin_borrar on public.vehiculos
  for delete to authenticated using (public.es_admin());

-- ---------- 5.3 ABASTECIMIENTOS ----------
alter table public.abastecimientos enable row level security;
drop policy if exists abast_ver on public.abastecimientos;
drop policy if exists abast_registrar on public.abastecimientos;
drop policy if exists abast_admin_editar on public.abastecimientos;
drop policy if exists abast_admin_borrar on public.abastecimientos;
create policy abast_ver on public.abastecimientos
  for select to authenticated using (true);
create policy abast_registrar on public.abastecimientos
  for insert to authenticated with check (uid::text = auth.uid()::text);
create policy abast_admin_editar on public.abastecimientos
  for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy abast_admin_borrar on public.abastecimientos
  for delete to authenticated using (public.es_admin());

-- ---------- 5.4 ABASTECIMIENTOS CON ORDEN ----------
-- El kiosco NO tiene login: se permite INSERT a anon.
-- Leer / editar / borrar: SOLO administradores.
alter table public.abastecimientos_orden enable row level security;
drop policy if exists orden_insert_publico on public.abastecimientos_orden;
drop policy if exists orden_ver_admin on public.abastecimientos_orden;
drop policy if exists orden_editar_admin on public.abastecimientos_orden;
drop policy if exists orden_borrar_admin on public.abastecimientos_orden;
create policy orden_insert_publico on public.abastecimientos_orden
  for insert to anon, authenticated
  with check (
    placa is not null and length(placa) <= 20
    and conductor is not null and length(conductor) <= 120
    and kilometraje >= 0 and lempiras > 0 and litros > 0
  );
create policy orden_ver_admin on public.abastecimientos_orden
  for select to authenticated using (public.es_admin());
create policy orden_editar_admin on public.abastecimientos_orden
  for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy orden_borrar_admin on public.abastecimientos_orden
  for delete to authenticated using (public.es_admin());

-- ---------- 5.5 VEHÍCULOS GUARDADOS (kiosco) ----------
-- CERRADO a anon: si no hay sesión, la app usa localStorage (ya lo hace).
alter table public.vehiculos_orden enable row level security;
drop policy if exists vo_all on public.vehiculos_orden;
drop policy if exists vo_ver on public.vehiculos_orden;
drop policy if exists vo_insert on public.vehiculos_orden;
drop policy if exists vo_update on public.vehiculos_orden;
drop policy if exists vo_delete on public.vehiculos_orden;
create policy vo_ver on public.vehiculos_orden
  for select to authenticated using (true);
create policy vo_insert on public.vehiculos_orden
  for insert to authenticated with check (true);
create policy vo_update on public.vehiculos_orden
  for update to authenticated using (true) with check (true);
create policy vo_delete on public.vehiculos_orden
  for delete to authenticated using (true);

-- ---------- 5.6 MANTENIMIENTOS ----------
alter table public.mantenimientos enable row level security;
drop policy if exists mant_ver on public.mantenimientos;
create policy mant_ver on public.mantenimientos
  for select to authenticated using (true);
-- (insert/update solo por la función registrar_mantenimiento, más abajo)


-- =====================================================================
--  BLOQUE 6 · ANTI-SUPLANTACIÓN
--  Fuerza uid = auth.uid() y toma el nombre real desde "perfiles".
-- =====================================================================
create or replace function public.abast_meta() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Debe iniciar sesión'; end if;
  new.uid := auth.uid();
  select coalesce(nombre,'Usuario') into new.usuario
    from public.perfiles where id = auth.uid();
  return new;
end $$;

drop trigger if exists trg_abast_meta on public.abastecimientos;
create trigger trg_abast_meta
  before insert on public.abastecimientos
  for each row execute function public.abast_meta();


-- =====================================================================
--  BLOQUE 7 · MANTENIMIENTO SEGURO (función existente, re-creada)
-- =====================================================================
create or replace function public.registrar_mantenimiento(
  p_vehiculo text, p_km numeric, p_taller text, p_conductor text, p_usuario text)
returns void language plpgsql security definer set search_path = public as $$
declare v_lim numeric; v_base numeric;
begin
  if auth.uid() is null then raise exception 'Debe iniciar sesión'; end if;
  if p_km is null or p_km <= 0 then raise exception 'Kilometraje no válido'; end if;
  if coalesce(trim(p_taller),'') = '' then raise exception 'Indique el taller'; end if;
  select coalesce(limite_mantenimiento,5000), coalesce(km_base_mantenimiento,0)
    into v_lim, v_base from public.vehiculos where id::text = p_vehiculo for update;
  if not found then raise exception 'Vehículo no encontrado'; end if;
  if p_km < v_base then raise exception 'El kilometraje es menor que el del último mantenimiento'; end if;
  update public.vehiculos set km_base_mantenimiento = p_km where id::text = p_vehiculo;
  insert into public.mantenimientos(vehiculo_id, kilometraje, proximo_km, taller, conductor, usuario)
  values (p_vehiculo, p_km, p_km + v_lim, left(p_taller,120), left(p_conductor,120), left(p_usuario,120));
end $$;
revoke all on function public.registrar_mantenimiento(text,numeric,text,text,text) from public, anon;
grant execute on function public.registrar_mantenimiento(text,numeric,text,text,text) to authenticated;


-- =====================================================================
--  BLOQUE 8 · CREAR PERFIL AUTOMÁTICO AL REGISTRAR USUARIO
--  (rol 'usuario' por defecto; un admin lo cambia después)
-- =====================================================================
create or replace function public.nuevo_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles(id, nombre, rol)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)), 'usuario')
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists trg_nuevo_perfil on auth.users;
create trigger trg_nuevo_perfil
  after insert on auth.users
  for each row execute function public.nuevo_perfil();


-- =====================================================================
--  BLOQUE 9 · STORAGE
--  ⚠️  Por defecto dejo los buckets PÚBLICOS para no romper la app
--      (la app usa getPublicUrl). Abajo está la opción PRIVADA.
-- =====================================================================

-- 9.1 Buckets (crear si no existen)
insert into storage.buckets (id, name, public)
values ('facturas','facturas', true), ('ordenes','ordenes', true)
on conflict (id) do nothing;

-- 9.2 facturas: suben usuarios con login; leen todos los autenticados
drop policy if exists "facturas_insert_auth" on storage.objects;
drop policy if exists "facturas_select_auth" on storage.objects;
drop policy if exists "facturas_update_auth" on storage.objects;
drop policy if exists "facturas_delete_owner" on storage.objects;
create policy "facturas_insert_auth" on storage.objects
  for insert to authenticated with check (bucket_id = 'facturas');
create policy "facturas_select_auth" on storage.objects
  for select to authenticated using (bucket_id = 'facturas');
create policy "facturas_update_auth" on storage.objects
  for update to authenticated using (bucket_id = 'facturas' and owner = auth.uid())
  with check (bucket_id = 'facturas');
create policy "facturas_delete_owner" on storage.objects
  for delete to authenticated using (bucket_id = 'facturas' and (owner = auth.uid() or public.es_admin()));

-- 9.3 ordenes: el kiosco (anon) sube boletas/facturas; solo admin lee
drop policy if exists "ordenes_insert_anon" on storage.objects;
drop policy if exists "ordenes_update_anon" on storage.objects;
drop policy if exists "ordenes_select_admin" on storage.objects;
drop policy if exists "ordenes_delete_admin" on storage.objects;
create policy "ordenes_insert_anon" on storage.objects
  for insert to anon, authenticated with check (bucket_id = 'ordenes');
create policy "ordenes_update_anon" on storage.objects
  for update to anon, authenticated using (bucket_id = 'ordenes') with check (bucket_id = 'ordenes');
create policy "ordenes_select_admin" on storage.objects
  for select to authenticated using (bucket_id = 'ordenes' and public.es_admin());
create policy "ordenes_delete_admin" on storage.objects
  for delete to authenticated using (bucket_id = 'ordenes' and public.es_admin());


-- =====================================================================
--  BLOQUE 10 · VERIFICACIÓN
-- =====================================================================
select t.tablename, t.rowsecurity as rls_activo,
       (select count(*) from pg_policies p
         where p.schemaname='public' and p.tablename=t.tablename) as n_politicas
  from pg_tables t
 where t.schemaname='public'
   and t.tablename in ('perfiles','vehiculos','abastecimientos',
                       'abastecimientos_orden','vehiculos_orden','mantenimientos')
 order by t.tablename;

-- =====================================================================
--  OPCIÓN AVANZADA (privacidad total de las fotos)
--  Descomenta SOLO si vas a cambiar la app a URLs firmadas.
-- ---------------------------------------------------------------------
-- update storage.buckets set public = false
--  where id in ('facturas','ordenes');
--
--  Y en index.html reemplaza:
--    sb.storage.from('facturas').getPublicUrl(path).data.publicUrl
--  por:
--    (await sb.storage.from('facturas').createSignedUrl(path, 3600)).data.signedUrl
--  (igual para 'ordenes'). Con eso las facturas dejan de ser públicas.
-- =====================================================================
