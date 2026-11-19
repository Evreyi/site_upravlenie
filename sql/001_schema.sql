-- Apply once in a NEW Supabase project, using SQL Editor as database owner.
-- PostgreSQL is the authoritative store. Auth passwords belong to Supabase Auth.
BEGIN;
CREATE SCHEMA vektor;
REVOKE ALL ON SCHEMA vektor FROM PUBLIC, anon, authenticated;
CREATE TABLE vektor.warehouses(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,name text NOT NULL UNIQUE,address text NOT NULL);
CREATE TABLE vektor.profiles(
 id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 120),email text NOT NULL,
 requested_role text NOT NULL CHECK(requested_role IN ('customer','office','driver','warehouse','director')),
 role text CHECK(role IN ('customer','office','driver','warehouse','director','admin')),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','active','rejected','blocked')),
 sections text[] NOT NULL DEFAULT '{}',warehouse_id bigint REFERENCES vektor.warehouses(id),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(status<>'active' OR role IS NOT NULL),CHECK(role<>'warehouse' OR status<>'active' OR warehouse_id IS NOT NULL)
);
CREATE TABLE vektor.vehicles(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,name text NOT NULL,registration text NOT NULL UNIQUE,
 capacity_kg numeric(12,2) NOT NULL CHECK(capacity_kg BETWEEN 1 AND 20000),volume_m3 numeric(12,3) NOT NULL CHECK(volume_m3 BETWEEN 0.1 AND 90));
CREATE TABLE vektor.routes(origin text NOT NULL,destination text NOT NULL,km integer NOT NULL CHECK(km>0),PRIMARY KEY(origin,destination),CHECK(origin<>destination));
INSERT INTO vektor.routes VALUES ('Новороссийск','Краснодар',150),('Новороссийск','Анапа',54),('Новороссийск','Ростов-на-Дону',350),('Новороссийск','Сочи',280),('Краснодар','Анапа',170),('Краснодар','Ростов-на-Дону',280),('Краснодар','Сочи',290),('Анапа','Ростов-на-Дону',390),('Анапа','Сочи',330),('Ростов-на-Дону','Сочи',550);
CREATE TABLE vektor.trips(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,origin text NOT NULL,destination text NOT NULL CHECK(destination<>origin),
 driver_id uuid NOT NULL REFERENCES vektor.profiles(id),vehicle_id bigint NOT NULL REFERENCES vektor.vehicles(id),
 status text NOT NULL DEFAULT 'forming' CHECK(status IN ('forming','in_transit','completed')),
 created_by uuid NOT NULL REFERENCES vektor.profiles(id),created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX one_active_driver ON vektor.trips(driver_id) WHERE status<>'completed';
CREATE UNIQUE INDEX one_active_vehicle ON vektor.trips(vehicle_id) WHERE status<>'completed';
CREATE TABLE vektor.orders(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 owner_id uuid NOT NULL REFERENCES vektor.profiles(id),created_by uuid NOT NULL REFERENCES vektor.profiles(id),
 origin text NOT NULL,destination text NOT NULL CHECK(origin<>destination),pickup_address text NOT NULL,delivery_address text NOT NULL,
 cargo text NOT NULL CHECK(length(cargo) BETWEEN 1 AND 200),weight_kg numeric(12,2) NOT NULL CHECK(weight_kg BETWEEN 0.01 AND 20000),
 volume_m3 numeric(12,3) NOT NULL CHECK(volume_m3 BETWEEN 0.001 AND 90),shipment_type text NOT NULL CHECK(shipment_type IN ('shared','dedicated')),
 requested_date date NOT NULL,estimated_price_kopecks bigint NOT NULL CHECK(estimated_price_kopecks>=0),distance_km integer NOT NULL CHECK(distance_km>0),
 quote_version text NOT NULL DEFAULT 'demo-v1',status text NOT NULL DEFAULT 'new' CHECK(status IN ('new','accepted','at_warehouse','in_transit','delivered')),
 trip_id bigint REFERENCES vektor.trips(id),warehouse_id bigint REFERENCES vektor.warehouses(id),warehouse_ready boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),CHECK(status NOT IN ('in_transit','delivered') OR trip_id IS NOT NULL));
CREATE INDEX orders_owner ON vektor.orders(owner_id);CREATE INDEX orders_trip ON vektor.orders(trip_id);CREATE INDEX orders_warehouse ON vektor.orders(warehouse_id);
CREATE TABLE vektor.events(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor_id uuid REFERENCES vektor.profiles(id),entity text NOT NULL,entity_id text NOT NULL,action text NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE FUNCTION vektor.need(ok boolean,message text) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$ BEGIN IF ok IS NOT TRUE THEN RAISE EXCEPTION USING MESSAGE=message,ERRCODE='P0001'; END IF; END $$;
CREATE FUNCTION vektor.valid_text(v text,label text,maxlen integer DEFAULT 200) RETURNS text LANGUAGE plpgsql SET search_path='' AS $$ BEGIN PERFORM vektor.need(length(btrim(v)) BETWEEN 1 AND maxlen,'Проверьте поле: '||label);RETURN btrim(v);END $$;
CREATE FUNCTION vektor.default_sections(r text) RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path='' AS $$ SELECT CASE r WHEN 'customer' THEN ARRAY['orders'] WHEN 'office' THEN ARRAY['orders','trips'] WHEN 'driver' THEN ARRAY['trips'] WHEN 'warehouse' THEN ARRAY['warehouse'] WHEN 'director' THEN ARRAY['orders','trips','reports'] WHEN 'admin' THEN ARRAY['orders','trips','warehouse','reports','users','settings'] ELSE ARRAY[]::text[] END $$;
CREATE FUNCTION vektor.context(section text DEFAULT NULL,roles text[] DEFAULT NULL) RETURNS vektor.profiles LANGUAGE plpgsql SET search_path='' AS $$ DECLARE p vektor.profiles;BEGIN SELECT * INTO p FROM vektor.profiles WHERE id=auth.uid();PERFORM vektor.need(p.id IS NOT NULL,'Войдите в аккаунт');PERFORM vektor.need(p.status='active','Аккаунт не одобрен или заблокирован');IF p.role<>'admin' THEN PERFORM vektor.need(section IS NULL OR section=ANY(p.sections),'Раздел недоступен');PERFORM vektor.need(roles IS NULL OR p.role=ANY(roles),'Действие недоступно для вашей роли');END IF;RETURN p;END $$;
CREATE FUNCTION vektor.on_signup() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE r text; n text;BEGIN
 r=NEW.raw_user_meta_data->>'requested_role';IF r IS NULL OR r NOT IN ('customer','office','driver','warehouse','director') THEN r='customer';END IF;
 n=left(coalesce(nullif(btrim(NEW.raw_user_meta_data->>'name'),''),'Новый пользователь'),120);
 INSERT INTO vektor.profiles(id,name,email,requested_role) VALUES(NEW.id,n,coalesce(NEW.email,''),r);RETURN NEW;END $$;
CREATE TRIGGER vektor_new_auth_user AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION vektor.on_signup();
CREATE FUNCTION vektor.sync_email() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN UPDATE vektor.profiles SET email=coalesce(NEW.email,''),updated_at=now() WHERE id=NEW.id;RETURN NEW;END $$;
CREATE TRIGGER vektor_email_changed AFTER UPDATE OF email ON auth.users FOR EACH ROW EXECUTE FUNCTION vektor.sync_email();
CREATE FUNCTION vektor.estimate(d jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$ DECLARE k integer; w numeric;v numeric;rub numeric;BEGIN
 PERFORM vektor.need(jsonb_typeof(d->'weight_kg')='number' AND jsonb_typeof(d->'volume_m3')='number','Укажите вес и объём числами');w=(d->>'weight_kg')::numeric;v=(d->>'volume_m3')::numeric;
 PERFORM vektor.need(w BETWEEN 0.01 AND 20000 AND v BETWEEN 0.001 AND 90,'Вес или объём вне допустимого диапазона');PERFORM vektor.need(d->>'shipment_type' IN ('shared','dedicated'),'Неизвестный тип перевозки');
 SELECT km INTO k FROM vektor.routes WHERE (origin=d->>'origin' AND destination=d->>'destination') OR (destination=d->>'origin' AND origin=d->>'destination');PERFORM vektor.need(k IS NOT NULL,'Выберите разные города из справочника');
 rub=CASE WHEN d->>'shipment_type'='dedicated' THEN greatest(8000,k*65) ELSE greatest(2000,k*4+greatest(w*8,v*1800)) END;
 RETURN jsonb_build_object('distance_km',k,'estimated_price_kopecks',round(rub*100)::bigint,'quote_version','demo-v1','preliminary',true);END $$;
CREATE FUNCTION public.vektor_profile() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE p vektor.profiles;BEGIN SELECT * INTO p FROM vektor.profiles WHERE id=auth.uid();PERFORM vektor.need(p.id IS NOT NULL,'Профиль не найден. Выполните миграцию до регистрации аккаунтов.');RETURN to_jsonb(p);END $$;
CREATE FUNCTION public.vektor_quote(p_data jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN PERFORM vektor.context('orders',ARRAY['customer','office']);RETURN vektor.estimate(p_data);END $$;
CREATE FUNCTION public.vektor_workspace() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE p vektor.profiles;result jsonb;os jsonb;ts jsonb;BEGIN
 p=vektor.context();
 SELECT coalesce(jsonb_agg(CASE WHEN p.role IN ('driver','warehouse') OR (p.role='office' AND NOT 'orders'=ANY(p.sections)) THEN to_jsonb(x)-'estimated_price_kopecks'-'owner_id'-'created_by'-'quote_version' ELSE to_jsonb(x) END),'[]'::jsonb) INTO os FROM
 (SELECT o.*,a.name AS owner_name FROM vektor.orders o JOIN vektor.profiles a ON a.id=o.owner_id LEFT JOIN vektor.trips t ON t.id=o.trip_id WHERE
 (p.role='admin' OR (p.role IN ('office','director') AND p.sections && ARRAY['orders','trips','reports']) OR (p.role='customer' AND 'orders'=ANY(p.sections) AND o.owner_id=p.id) OR (p.role='driver' AND 'trips'=ANY(p.sections) AND t.driver_id=p.id) OR (p.role='warehouse' AND 'warehouse'=ANY(p.sections) AND o.warehouse_id=p.warehouse_id)) ORDER BY o.id DESC LIMIT 500) x;
 SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) INTO ts FROM
 (SELECT t.*,a.name AS driver_name,v.name AS vehicle_name,v.registration,v.capacity_kg,v.volume_m3 FROM vektor.trips t JOIN vektor.profiles a ON a.id=t.driver_id JOIN vektor.vehicles v ON v.id=t.vehicle_id WHERE p.role='admin' OR (p.role IN ('office','director') AND p.sections && ARRAY['trips','reports']) OR (p.role='driver' AND 'trips'=ANY(p.sections) AND t.driver_id=p.id) ORDER BY t.id DESC LIMIT 500) x;
 result=jsonb_build_object('account',to_jsonb(p),'orders',os,'trips',ts,'users','[]'::jsonb,'drivers','[]'::jsonb,'customers','[]'::jsonb,'vehicles','[]'::jsonb,'warehouses','[]'::jsonb,'cities',(SELECT jsonb_agg(city ORDER BY city) FROM (SELECT origin AS city FROM vektor.routes UNION SELECT destination FROM vektor.routes) c));
 IF p.role='admin' OR (p.role='office' AND p.sections && ARRAY['orders','trips']) THEN
 result=result||jsonb_build_object('drivers',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name)),'[]'::jsonb) FROM vektor.profiles WHERE role='driver' AND status='active'),'customers',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name)),'[]'::jsonb) FROM vektor.profiles WHERE role='customer' AND status='active'),'vehicles',(SELECT coalesce(jsonb_agg(to_jsonb(v)),'[]'::jsonb) FROM vektor.vehicles v),'warehouses',(SELECT coalesce(jsonb_agg(to_jsonb(w)),'[]'::jsonb) FROM vektor.warehouses w));
 ELSIF p.role='warehouse' THEN result=result||jsonb_build_object('warehouses',(SELECT coalesce(jsonb_agg(to_jsonb(w)),'[]'::jsonb) FROM vektor.warehouses w WHERE id=p.warehouse_id));END IF;
 IF p.role='admin' THEN result=result||jsonb_build_object('users',(SELECT coalesce(jsonb_agg(to_jsonb(u)),'[]'::jsonb) FROM (SELECT * FROM vektor.profiles ORDER BY created_at DESC LIMIT 500)u));END IF;
 RETURN result;END $$;
CREATE FUNCTION public.vektor_apply(p_action text,p_data jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p vektor.profiles;o vektor.orders;t vektor.trips;a vektor.profiles;v vektor.vehicles; q jsonb;owner uuid;ident bigint;trip bigint;wh bigint;cnt integer;kg numeric;vol numeric;dedicated boolean;r text;st text;permissions text[];driver uuid;ent text;
BEGIN
 -- One transactional lock prevents assignment/dispatch races in the initial version.
 PERFORM pg_advisory_xact_lock(781934);
 p=vektor.context();
 IF p_action='create_order' THEN
 p=vektor.context('orders',ARRAY['customer','office']);q=vektor.estimate(p_data);owner=CASE WHEN p.role='customer' THEN p.id ELSE (p_data->>'owner_id')::uuid END;
 PERFORM vektor.need(EXISTS(SELECT 1 FROM vektor.profiles WHERE id=owner AND role='customer' AND status='active'),'Заказчик не найден или не одобрен');
 PERFORM vektor.need((p_data->>'requested_date')::date >= (now() AT TIME ZONE 'Europe/Moscow')::date,'Дата отправки уже прошла');
 INSERT INTO vektor.orders(owner_id,created_by,origin,destination,pickup_address,delivery_address,cargo,weight_kg,volume_m3,shipment_type,requested_date,estimated_price_kopecks,distance_km)
 VALUES(owner,p.id,p_data->>'origin',p_data->>'destination',vektor.valid_text(p_data->>'pickup_address','Адрес забора',500),vektor.valid_text(p_data->>'delivery_address','Адрес доставки',500),vektor.valid_text(p_data->>'cargo','Груз'),(p_data->>'weight_kg')::numeric,(p_data->>'volume_m3')::numeric,p_data->>'shipment_type',(p_data->>'requested_date')::date,(q->>'estimated_price_kopecks')::bigint,(q->>'distance_km')::integer) RETURNING id INTO ident;ent='order';
 ELSIF p_action IN ('accept','assign','receive','ready','deliver') THEN
 IF p_action IN ('accept','assign') THEN p=vektor.context('orders',ARRAY['office']);IF p_action='assign' THEN PERFORM vektor.context('trips',ARRAY['office']);END IF;
 ELSIF p_action IN ('receive','ready') THEN p=vektor.context('warehouse',ARRAY['warehouse']);ELSE p=vektor.context('trips',ARRAY['driver']);END IF;
 ident=(p_data->>'id')::bigint;SELECT * INTO o FROM vektor.orders WHERE id=ident FOR UPDATE;PERFORM vektor.need(o.id IS NOT NULL,'Заявка недоступна');ent='order';
 IF p_action='accept' THEN PERFORM vektor.need(o.status='new','Заявка уже обработана');UPDATE vektor.orders SET status='accepted' WHERE id=ident;
 ELSIF p_action='assign' THEN
 PERFORM vektor.need(o.status IN ('accepted','at_warehouse'),'Сначала примите заявку в работу');trip=(p_data->>'trip_id')::bigint;wh=(p_data->>'warehouse_id')::bigint;
 PERFORM vektor.need(o.status<>'at_warehouse' OR o.warehouse_id IS NOT DISTINCT FROM wh,'Принятый груз нельзя перенести на другой склад назначением рейса');
 SELECT * INTO t FROM vektor.trips WHERE id=trip FOR UPDATE;PERFORM vektor.need(t.id IS NOT NULL AND t.status='forming','Рейс недоступен для загрузки');PERFORM vektor.need(t.origin=o.origin AND t.destination=o.destination,'Направления не совпадают');SELECT * INTO v FROM vektor.vehicles WHERE id=t.vehicle_id;
 SELECT count(*),coalesce(sum(weight_kg),0),coalesce(sum(volume_m3),0),coalesce(bool_or(shipment_type='dedicated'),false) INTO cnt,kg,vol,dedicated FROM vektor.orders WHERE trip_id=trip AND id<>ident;
 PERFORM vektor.need(NOT dedicated AND NOT(cnt>0 AND o.shipment_type='dedicated'),'Выделенная машина занята другой заявкой');PERFORM vektor.need(kg+o.weight_kg<=v.capacity_kg AND vol+o.volume_m3<=v.volume_m3,'Недостаточно вместимости машины');
 UPDATE vektor.orders SET trip_id=trip,warehouse_id=wh WHERE id=ident;
 ELSIF p_action IN ('receive','ready') THEN
 PERFORM vektor.need(o.warehouse_id IS NOT NULL AND (p.role='admin' OR o.warehouse_id=p.warehouse_id),'Груз недоступен этому складу');
 IF p_action='receive' THEN PERFORM vektor.need(o.status='accepted','Груз нельзя принять на этом этапе');UPDATE vektor.orders SET status='at_warehouse' WHERE id=ident;
 ELSE PERFORM vektor.need(o.status='at_warehouse','Груз ещё не принят');UPDATE vektor.orders SET warehouse_ready=true WHERE id=ident;END IF;
 ELSE SELECT * INTO t FROM vektor.trips WHERE id=o.trip_id FOR UPDATE;PERFORM vektor.need(p.role='admin' OR t.driver_id=p.id,'Рейс назначен другому водителю');PERFORM vektor.need(o.status='in_transit','Груз ещё не в пути или уже доставлен');UPDATE vektor.orders SET status='delivered' WHERE id=ident;UPDATE vektor.trips SET status='completed' WHERE id=t.id AND NOT EXISTS(SELECT 1 FROM vektor.orders WHERE trip_id=t.id AND status<>'delivered');END IF;
 UPDATE vektor.orders SET updated_at=now() WHERE id=ident;
 ELSIF p_action='create_trip' THEN
 p=vektor.context('trips',ARRAY['office']);driver=(p_data->>'driver_id')::uuid;
 PERFORM vektor.need(EXISTS(SELECT 1 FROM vektor.profiles WHERE id=driver AND role='driver' AND status='active'),'Водитель не одобрен');
 PERFORM vektor.need(EXISTS(SELECT 1 FROM vektor.routes WHERE (origin=p_data->>'origin' AND destination=p_data->>'destination') OR (destination=p_data->>'origin' AND origin=p_data->>'destination')),'Неизвестное направление');
 INSERT INTO vektor.trips(origin,destination,driver_id,vehicle_id,created_by) VALUES(p_data->>'origin',p_data->>'destination',driver,(p_data->>'vehicle_id')::bigint,p.id) RETURNING id INTO ident;ent='trip';
 ELSIF p_action='start' THEN
 p=vektor.context('trips',ARRAY['office']);ident=(p_data->>'id')::bigint;SELECT * INTO t FROM vektor.trips WHERE id=ident FOR UPDATE;PERFORM vektor.need(t.status='forming','Рейс уже отправлен или недоступен');
 PERFORM vektor.need(EXISTS(SELECT 1 FROM vektor.profiles WHERE id=t.driver_id AND role='driver' AND status='active'),'Водитель заблокирован');
 PERFORM vektor.need(EXISTS(SELECT 1 FROM vektor.orders WHERE trip_id=ident),'Рейс пуст');PERFORM vektor.need(NOT EXISTS(SELECT 1 FROM vektor.orders WHERE trip_id=ident AND (status NOT IN ('accepted','at_warehouse') OR (warehouse_id IS NOT NULL AND (status<>'at_warehouse' OR NOT warehouse_ready)))),'Склад должен принять и подготовить все грузы');
 UPDATE vektor.trips SET status='in_transit' WHERE id=ident;UPDATE vektor.orders SET status='in_transit',updated_at=now() WHERE trip_id=ident;ent='trip';
 ELSIF p_action='create_warehouse' THEN
 PERFORM vektor.context('settings',ARRAY[]::text[]);INSERT INTO vektor.warehouses(name,address) VALUES(vektor.valid_text(p_data->>'name','Название',120),vektor.valid_text(p_data->>'address','Адрес',500)) RETURNING id INTO ident;ent='warehouse';
 ELSIF p_action='create_vehicle' THEN
 PERFORM vektor.context('settings',ARRAY[]::text[]);INSERT INTO vektor.vehicles(name,registration,capacity_kg,volume_m3) VALUES(vektor.valid_text(p_data->>'name','Модель',120),vektor.valid_text(p_data->>'registration','Госномер',30),(p_data->>'capacity_kg')::numeric,(p_data->>'volume_m3')::numeric) RETURNING id INTO ident;ent='vehicle';
 ELSIF p_action='update_account' THEN
 PERFORM vektor.context('users',ARRAY[]::text[]);owner=(p_data->>'id')::uuid;PERFORM vektor.need(owner<>p.id,'Нельзя изменять собственные права');SELECT * INTO a FROM vektor.profiles WHERE id=owner FOR UPDATE;PERFORM vektor.need(a.id IS NOT NULL,'Аккаунт не найден');
 r=p_data->>'role';st=p_data->>'status';PERFORM vektor.need(r IN ('customer','office','driver','warehouse','director','admin') AND st IN ('active','rejected','blocked'),'Неизвестная роль или статус');
 PERFORM vektor.need(jsonb_typeof(p_data->'sections')='array','Укажите разделы доступа');SELECT coalesce(array_agg(DISTINCT x),ARRAY[]::text[]) INTO permissions FROM jsonb_array_elements_text(p_data->'sections') x;
 PERFORM vektor.need(permissions <@ vektor.default_sections(r),'Разделы не соответствуют роли');IF r='admin' THEN permissions=vektor.default_sections(r);END IF;PERFORM vektor.need(st<>'active' OR cardinality(permissions)>0,'Оставьте хотя бы один раздел');
 wh=CASE WHEN r='warehouse' THEN (p_data->>'warehouse_id')::bigint ELSE NULL END;PERFORM vektor.need(r<>'warehouse' OR st<>'active' OR wh IS NOT NULL,'Назначьте склад');
 IF a.role='driver' AND (r<>'driver' OR st<>'active') THEN PERFORM vektor.need(NOT EXISTS(SELECT 1 FROM vektor.trips WHERE driver_id=owner AND status<>'completed'),'У водителя есть незавершённый рейс');END IF;
 IF a.role='admin' AND (r<>'admin' OR st<>'active') THEN PERFORM vektor.need(EXISTS(SELECT 1 FROM vektor.profiles WHERE role='admin' AND status='active' AND id<>owner),'Нельзя отключить последнего администратора');END IF;
 UPDATE vektor.profiles SET role=r,status=st,sections=permissions,warehouse_id=wh,updated_at=now() WHERE id=owner;
 INSERT INTO vektor.events(actor_id,entity,entity_id,action) VALUES(p.id,'account',owner::text,p_action);RETURN jsonb_build_object('ok',true);
 ELSE RAISE EXCEPTION 'Неизвестное действие';END IF;
 INSERT INTO vektor.events(actor_id,entity,entity_id,action) VALUES(p.id,ent,ident::text,p_action);RETURN jsonb_build_object('id',ident,'ok',true);
END $$;
CREATE FUNCTION public.vektor_audit() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN PERFORM vektor.context('users',ARRAY[]::text[]);RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM (SELECT e.*,p.name AS actor_name FROM vektor.events e LEFT JOIN vektor.profiles p ON p.id=e.actor_id ORDER BY e.id DESC LIMIT 200)x);END $$;
-- Defense in depth: tables are private, direct grants are absent, RLS defaults to deny.
ALTER TABLE vektor.profiles ENABLE ROW LEVEL SECURITY;ALTER TABLE vektor.orders ENABLE ROW LEVEL SECURITY;ALTER TABLE vektor.trips ENABLE ROW LEVEL SECURITY;ALTER TABLE vektor.vehicles ENABLE ROW LEVEL SECURITY;ALTER TABLE vektor.warehouses ENABLE ROW LEVEL SECURITY;ALTER TABLE vektor.routes ENABLE ROW LEVEL SECURITY;ALTER TABLE vektor.events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA vektor FROM PUBLIC,anon,authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA vektor FROM PUBLIC,anon,authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA vektor FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.vektor_profile(),public.vektor_workspace(),public.vektor_quote(jsonb),public.vektor_apply(text,jsonb),public.vektor_audit() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vektor_profile(),public.vektor_workspace(),public.vektor_quote(jsonb),public.vektor_apply(text,jsonb),public.vektor_audit() TO authenticated;
COMMIT;
