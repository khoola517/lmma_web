-- Migration: 020_review_reply_notifications_and_permissions.sql
-- Description: Enable provider reply schema, RLS permissions, automated timestamps, and customer notifications for review replies

-- 1. التأكد من توفر أعمدة رد مقدم الخدمة وتاريخ الرد في جدول التقييمات
ALTER TABLE public.reviews 
ADD COLUMN IF NOT EXISTS provider_reply TEXT,
ADD COLUMN IF NOT EXISTS provider_reply_at TIMESTAMPTZ;

-- 2. تحديث سياسات الأمان (RLS) للسماح لمقدم الخدمة بتعديل التقييم لإضافة رده
-- يسمح للعميل بتعديل تقييمه، وللمسؤول، ولمقدم الخدمة صاحب الخدمة بالرد
DROP POLICY IF EXISTS "reviews_update" ON public.reviews;
CREATE POLICY "reviews_update" ON public.reviews FOR UPDATE TO authenticated
USING (
    customer_id = auth.uid() 
    OR public.is_admin()
    OR EXISTS (
        SELECT 1 FROM public.services s
        JOIN public.provider_profiles pp ON pp.id = s.provider_id
        WHERE s.id = reviews.service_id AND pp.user_id = auth.uid()
    )
)
WITH CHECK (
    customer_id = auth.uid() 
    OR public.is_admin()
    OR EXISTS (
        SELECT 1 FROM public.services s
        JOIN public.provider_profiles pp ON pp.id = s.provider_id
        WHERE s.id = reviews.service_id AND pp.user_id = auth.uid()
    )
);

-- 3. دالة ومحفز لتحديث توقيت الرد تلقائياً (BEFORE UPDATE)
CREATE OR REPLACE FUNCTION public.handle_review_reply_timestamps()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.provider_reply IS DISTINCT FROM OLD.provider_reply THEN
    IF NEW.provider_reply IS NOT NULL AND trim(NEW.provider_reply) <> '' THEN
      NEW.provider_reply_at := now();
    ELSE
      NEW.provider_reply := NULL;
      NEW.provider_reply_at := NULL;
    END IF;
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.handle_review_reply_timestamps() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_review_reply_timestamps ON public.reviews;
CREATE TRIGGER trg_review_reply_timestamps
BEFORE UPDATE ON public.reviews
FOR EACH ROW
EXECUTE FUNCTION public.handle_review_reply_timestamps();

-- 4. دالة ومحفز لإرسال إشعار فوري للعميل عند رد مقدم الخدمة (AFTER UPDATE)
CREATE OR REPLACE FUNCTION public.on_review_reply_notification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_service_name TEXT;
  v_provider_name TEXT;
  v_reply_excerpt TEXT;
BEGIN
  -- يتم إرسال الإشعار فقط عند إضافة أو تعديل رد فعلي غير فارغ
  IF NEW.provider_reply IS DISTINCT FROM OLD.provider_reply 
     AND NEW.provider_reply IS NOT NULL 
     AND trim(NEW.provider_reply) <> '' THEN
    
    -- جلب اسم الخدمة واسم مقدم الخدمة للظهور بالإشعار
    SELECT s.name, pp.business_name
    INTO v_service_name, v_provider_name
    FROM public.services s
    LEFT JOIN public.provider_profiles pp ON pp.id = s.provider_id
    WHERE s.id = NEW.service_id;

    -- تجهيز مقتطف من الرد (بحد أقصى 70 حرفاً)
    v_reply_excerpt := trim(NEW.provider_reply);
    IF length(v_reply_excerpt) > 70 THEN
      v_reply_excerpt := substr(v_reply_excerpt, 1, 67) || '...';
    END IF;

    -- إدراج الإشعار للعميل
    INSERT INTO public.notifications (
      user_id,
      title,
      body,
      type,
      related_booking_id
    ) VALUES (
      NEW.customer_id,
      'رد جديد على تقييمك 💬',
      'قام ' || COALESCE(v_provider_name, 'مقدم الخدمة') || ' بالرد على تقييمك لخدمة (' || COALESCE(v_service_name, 'الخدمة') || '): "' || v_reply_excerpt || '"',
      'review_reply',
      NEW.booking_id
    );
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.on_review_reply_notification() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_review_reply_notification ON public.reviews;
CREATE TRIGGER trg_review_reply_notification
AFTER UPDATE ON public.reviews
FOR EACH ROW
EXECUTE FUNCTION public.on_review_reply_notification();

-- 5. التأكد من تمكين Realtime لجدولي reviews و notifications
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.reviews;
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;

