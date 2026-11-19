-- Run ONLY after registering your own account and confirming its email.
-- Replace the email below. Run as database owner in Supabase SQL Editor.
DO $$
DECLARE target uuid;
BEGIN
 IF EXISTS(SELECT 1 FROM vektor.profiles WHERE role='admin') THEN RAISE EXCEPTION 'Первый администратор уже создан'; END IF;
 SELECT p.id INTO target FROM vektor.profiles p JOIN auth.users u ON u.id=p.id WHERE lower(u.email)=lower('REPLACE_WITH_YOUR_CONFIRMED_EMAIL') AND u.email_confirmed_at IS NOT NULL;
 IF target IS NULL THEN RAISE EXCEPTION 'Зарегистрируйте аккаунт и подтвердите почту, затем укажите его email';END IF;
 UPDATE vektor.profiles SET role='admin',status='active',sections=vektor.default_sections('admin'),updated_at=now() WHERE id=target;
 INSERT INTO vektor.events(actor_id,entity,entity_id,action) VALUES(target,'account',target::text,'first_admin');
END $$;
