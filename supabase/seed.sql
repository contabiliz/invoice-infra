-- 1. Create the function
CREATE OR REPLACE FUNCTION public.create_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER -- Runs with elevated privileges
AS $$
BEGIN
  INSERT INTO public.users (id)
  VALUES (NEW.id);
  RETURN NEW;
END;
$$;

-- 2. Create the trigger on the auth.users table
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.create_user();

