-- =====================================================================
--  SEGURIDAD DEL SERVIDOR — Control de Abastecimiento URIP III (Supabase)
--  La llave "publishable" del index.html es pública por diseño: la seguridad
--  real son estas reglas (RLS). Sin ellas, cualquiera podría leer o borrar datos
--  usando la llave desde fuera de la app.
--
--  CÓMO USAR: Supabase > SQL Editor > pegar todo > Run.
--  ANTES: haga una copia de seguridad (Database > Backups) y pruébelo primero
--  en un proyecto de prueba. El script reemplaza las políticas (RLS) de las
--  tablas listadas abajo por las de este archivo.
-- =====================================================================

-- ---------- 1. ¿Quién es administrador? ----------
create or replace function public.es_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and rol = 'admin');
$$;
revoke all on function public.es_admin() from public;
grant execute on function public.es_admin() to authenticated;

-- ---------- 2. Activar RLS y quitar políticas anteriores ----------
do $$
declare t text; p record;
begin
  foreach t in array array['perfiles','vehiculos','abastecimientos','abastecimientos_orden','vehiculos_orden'] loop
    if to_regclass('public.'||t) is not null then
      execute format('alter table public.%I enable row level security', t);
      for p in select policyname from pg_policies where schemaname='public' and tablename=t loop
        execute format('drop policy %I on public.%I', p.policyname, t);
      end loop;
    end if;
  end loop;
end $$;

-- ---------- 3. perfiles: cada quien ve el suyo; el admin ve todos. Nadie los cambia desde la app ----------
create policy perfiles_leer on public.perfiles for select to authenticated
  using (id = auth.uid() or public.es_admin());

-- ---------- 4. vehiculos: los usuarios leen; solo el admin crea, cambia o borra ----------
create policy vehiculos_leer   on public.vehiculos for select to authenticated using (true);
create policy vehiculos_crear  on public.vehiculos for insert to authenticated with check (public.es_admin());
create policy vehiculos_editar on public.vehiculos for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy vehiculos_borrar on public.vehiculos for delete to authenticated using (public.es_admin());
-- (Los usuarios reportan mantenimiento con la función registrar_mantenimiento, que debe ser SECURITY DEFINER.)

-- ---------- 5. abastecimientos: cada usuario registra a su nombre; solo el admin corrige o borra ----------
create policy abast_leer   on public.abastecimientos for select to authenticated using (true);
create policy abast_crear  on public.abastecimientos for insert to authenticated with check (uid = auth.uid());
create policy abast_editar on public.abastecimientos for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy abast_borrar on public.abastecimientos for delete to authenticated using (public.es_admin());

-- ---------- 6. abastecimientos_orden: cualquiera (sin usuario) puede REGISTRAR, solo el admin puede VER ----------
create policy orden_crear  on public.abastecimientos_orden for insert to anon, authenticated with check (true);
create policy orden_leer   on public.abastecimientos_orden for select to authenticated using (public.es_admin());
create policy orden_editar on public.abastecimientos_orden for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy orden_borrar on public.abastecimientos_orden for delete to authenticated using (public.es_admin());

-- ---------- 7. vehiculos_orden (vehículos guardados de la pantalla "con orden") ----------
do $$ begin
  if to_regclass('public.vehiculos_orden') is not null then
    execute 'create policy vo_leer   on public.vehiculos_orden for select to anon, authenticated using (true)';
    execute 'create policy vo_crear  on public.vehiculos_orden for insert to anon, authenticated with check (true)';
    execute 'create policy vo_editar on public.vehiculos_orden for update to anon, authenticated using (true) with check (true)';
    -- Borrar: solo el administrador. (En la app, "Quitar" seguirá quitándolo de ese teléfono.)
    execute 'create policy vo_borrar on public.vehiculos_orden for delete to authenticated using (public.es_admin())';
  end if;
end $$;

-- ---------- 8. Límites de datos (evitan textos gigantes o cifras absurdas) ----------
-- NOT VALID = no revisa los registros viejos, solo los nuevos.
alter table public.abastecimientos drop constraint if exists abast_limites;
alter table public.abastecimientos add constraint abast_limites check (
  kilometraje between 0 and 2000000 and lempiras > 0 and lempiras <= 50000 and litros > 0 and litros <= 1000
  and char_length(coalesce(gasolinera,'')) <= 80 and char_length(coalesce(usuario,'')) <= 120) not valid;

alter table public.abastecimientos_orden drop constraint if exists orden_limites;
alter table public.abastecimientos_orden add constraint orden_limites check (
  kilometraje between 0 and 2000000 and lempiras > 0 and lempiras <= 50000 and litros > 0 and litros <= 1000
  and char_length(coalesce(placa,''))<=15 and char_length(coalesce(marca,''))<=30 and char_length(coalesce(modelo,''))<=30
  and char_length(coalesce(tipo,''))<=25 and char_length(coalesce(color,''))<=25 and char_length(coalesce(anio,''))<=4
  and char_length(coalesce(motor,''))<=25 and char_length(coalesce(chasis,''))<=25 and char_length(coalesce(numero_equipo,''))<=15
  and char_length(coalesce(asignado_a,''))<=50 and char_length(coalesce(conductor,''))<=60
  and char_length(coalesce(gasolinera,''))<=80 and char_length(coalesce(texto_boleta,''))<=4000
  and char_length(coalesce(boleta_url,''))<=300 and char_length(coalesce(factura_url,''))<=300) not valid;

-- ---------- 9. Fotos (Storage): solo JPG de hasta 5 MB y NUNCA se pueden sobrescribir ni borrar desde la app ----------
update storage.buckets set file_size_limit = 5242880, allowed_mime_types = array['image/jpeg']
  where id in ('facturas','ordenes');

do $$ declare p record; begin
  for p in select policyname from pg_policies
           where schemaname='storage' and tablename='objects'
             and (coalesce(qual,'')||coalesce(with_check,'')) ~ '(facturas|ordenes)' loop
    execute format('drop policy %I on storage.objects', p.policyname);
  end loop;
end $$;

create policy urip_facturas_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'facturas' and name ~ '^[0-9a-f-]{36}\.jpg$');
create policy urip_ordenes_subir on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'ordenes' and name ~ '^(boletas|facturas)/[0-9a-f-]{36}\.jpg$');
create policy urip_fotos_admin on storage.objects for all to authenticated
  using (bucket_id in ('facturas','ordenes') and public.es_admin())
  with check (bucket_id in ('facturas','ordenes') and public.es_admin());
-- Las fotos se ven con su enlace público (los buckets siguen siendo públicos). Si prefiere que
-- nadie fuera de la app pueda abrirlas, haga privados los buckets y avíseme para cambiar la app
-- a enlaces firmados temporales.

-- ---------- 10. Recomendado en el panel de Supabase (no es SQL) ----------
-- Authentication > Providers > Email: desactive "Allow new users to sign up" (solo el admin crea cuentas).
-- Authentication > Rate limits: deje los límites de intentos de inicio de sesión activos.
-- Authentication > URL Configuration: Site URL = la dirección real de la app.
