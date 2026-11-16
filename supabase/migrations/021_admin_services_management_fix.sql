-- Migration: 021_admin_services_management_fix.sql
-- Description: Fix admin services management: status constraints, is_available column, RLS permissions, and safe RPCs for toggle & deletion

-- 1. التأكد من وجود عمود is_available في جدول services
ALTER TABLE public.services 
ADD COLUMN IF NOT EXISTS is_available BOOLEAN NOT NULL DEFAULT true;

-- 2. تحديث قيد التحقق status ليشمل 'paused' بالإضافة إلى 'active', 'inactive', 'pending'
ALTER TABLE public.services DROP CONSTRAINT IF EXISTS services_status_check;
ALTER TABLE public.services ADD CONSTRAINT services_status_check 
CHECK (status IN ('active', 'inactive', 'pending', 'paused'));

-- 3. تحديث سياسات الأمان RLS لجدول services لضمان تحكم الأدمن الكامل
DROP POLICY IF EXISTS "services_update" ON public.services;
CREATE POLICY "services_update" ON public.services FOR UPDATE TO authenticated
USING (
  provider_id = public.get_my_provider_id() OR 
  public.is_admin()
)
WITH CHECK (
  provider_id = public.get_my_provider_id() OR 
  public.is_admin()
);

DROP POLICY IF EXISTS "services_delete" ON public.services;
CREATE POLICY "services_delete" ON public.services FOR DELETE TO authenticated
USING (
  provider_id = public.get_my_provider_id() OR 
  public.is_admin()
);

-- 4. إجراء مخزن RPC لتبديل حالة توفر وتفعيل الخدمة للأدمن بأمان تام
CREATE OR REPLACE FUNCTION public.admin_toggle_service_availability(
  p_service_id UUID,
  p_is_available BOOLEAN,
  p_status TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_new_status TEXT;
  v_updated_row RECORD;
BEGIN
  -- تحديد الحالة المستهدفة
  IF p_status IS NOT NULL AND p_status IN ('active', 'inactive', 'paused', 'pending') THEN
    v_new_status := p_status;
  ELSIF p_is_available IS TRUE THEN
    v_new_status := 'active';
  ELSE
    v_new_status := 'inactive';
  END IF;

  -- تحديث الخدمة
  UPDATE public.services
  SET 
    is_available = p_is_available,
    status = v_new_status,
    updated_at = now()
  WHERE id = p_service_id
  RETURNING id, name, status, is_available INTO v_updated_row;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'الخدمة غير موجودة'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'id', v_updated_row.id,
    'status', v_updated_row.status,
    'is_available', v_updated_row.is_available
  );
END;
$$;

ALTER FUNCTION public.admin_toggle_service_availability(UUID, BOOLEAN, TEXT) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.admin_toggle_service_availability(UUID, BOOLEAN, TEXT) TO authenticated, service_role;

-- 5. إجراء مخزن RPC لحذف أو أرشفة الخدمة بأمان دون انتهاك قيود الحجوزات السابقة
CREATE OR REPLACE FUNCTION public.admin_delete_service(p_service_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_has_bookings BOOLEAN;
BEGIN
  -- فحص هل توجد حجوزات مرتبطة بالخدمة
  SELECT EXISTS (
    SELECT 1 FROM public.booking_items WHERE service_id = p_service_id
  ) INTO v_has_bookings;

  IF v_has_bookings THEN
    -- أرشفة ناعمة عبر تغيير الحالة لـ inactive لمنع خطأ foreign key RESTRICT
    UPDATE public.services
    SET status = 'inactive', is_available = false, updated_at = now()
    WHERE id = p_service_id;

    RETURN jsonb_build_object(
      'success', true,
      'soft_deleted', true,
      'message', 'تم إيقاف الخدمة وأرشفتها نظراً لوجود حجوزات سابقة مرتبطة بها'
    );
  ELSE
    -- حذف كامل
    DELETE FROM public.services WHERE id = p_service_id;
    RETURN jsonb_build_object(
      'success', true,
      'soft_deleted', false,
      'message', 'تم حذف الخدمة نهائياً'
    );
  END IF;
END;
$$;

ALTER FUNCTION public.admin_delete_service(UUID) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.admin_delete_service(UUID) TO authenticated, service_role;

