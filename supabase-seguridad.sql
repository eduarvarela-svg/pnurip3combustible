-- =====================================================================
--  SEGURIDAD Y MANTENIMIENTO · Control de Abastecimiento URIP III
--  Ejecutar UNA vez en Supabase: SQL Editor → New query → pegar → Run.
--
--  ¿Qué hace?
--   1. Función es_admin(): sabe si el usuario conectado es administrador.
--   2. Reglas de acceso (RLS) para perfiles, vehiculos y abastecimientos:
--        · perfiles:        cada usuario solo ve su propio perfil; nadie puede
--                           cambiarse el rol desde la app (solo administradores).
--        · vehiculos:       todos los usuarios conectados los ven; solo los
--                           administradores los crean, editan o eliminan.
--        · abastecimientos: los usuarios conectados registran a su propio nombre
--                           y pueden consultar; solo administradores editan o borran.
--   3. Tabla "mantenimientos" (historial) y función registrar_mantenimiento()
--      para que CUALQUIER usuario pueda reportar un mantenimiento sin poder
--      tocar otros datos del vehículo.
--
--  IMPORTANTE: este script BORRA las reglas (policies) que ya existan en las
--  tablas perfiles, vehiculos y abastecimientos y las reemplaza por estas.
--  No toca las tablas del abastecimiento con orden ni el almacenamiento de fotos.
-- =====================================================================

-- 1) ¿Es administrador?
create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'admin');
$$;
revoke all on function public.es_admin() from public, anon;
grant execute on function public.es_admin() to authenticated;

-- Quitar reglas anteriores de estas tablas
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('perfiles','vehiculos','abastecimientos')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- 2a) PERFILES
alter table public.perfiles enable row level security;
create policy perfiles_ver_propio   on public.perfiles for select to authenticated using (id = auth.uid() or public.es_admin());
create policy perfiles_admin_todo   on public.perfiles for all    to authenticated using (public.es_admin()) with check (public.es_admin());

-- 2b) VEHÍCULOS
alter table public.vehiculos enable row level security;
create policy vehiculos_ver          on public.vehiculos for select to authenticated using (true);
create policy vehiculos_admin_crear  on public.vehiculos for insert to authenticated with check (public.es_admin());
create policy vehiculos_admin_editar on public.vehiculos for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy vehiculos_admin_borrar on public.vehiculos for delete to authenticated using (public.es_admin());

-- 2c) ABASTECIMIENTOS
alter table public.abastecimientos enable row level security;
create policy abast_ver           on public.abastecimientos for select to authenticated using (true);
create policy abast_registrar     on public.abastecimientos for insert to authenticated with check (uid::text = auth.uid()::text);
create policy abast_admin_editar  on public.abastecimientos for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy abast_admin_borrar  on public.abastecimientos for delete to authenticated using (public.es_admin());

-- 3) HISTORIAL DE MANTENIMIENTOS + función segura para reportarlos
create table if not exists public.mantenimientos(
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
alter table public.mantenimientos enable row level security;
drop policy if exists mant_ver on public.mantenimientos;
create policy mant_ver on public.mantenimientos for select to authenticated using (true);

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
