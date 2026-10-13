-- Review attachments may now also be files stored in Cloudinary (the folder the
-- API uploads to, "grogu"). Still refused: any other remote host, so a review
-- cannot embed an arbitrary image (tracking pixels, hotlinks).
--
-- Replaces grogu_media_json from 007 with the same behaviour plus the
-- Cloudinary delivery URL form:
--   https://res.cloudinary.com/<cloud>/<image|video>/upload/[v<digits>/]grogu/<name>

CREATE OR REPLACE FUNCTION grogu_media_json(p_media jsonb) RETURNS jsonb
  LANGUAGE plpgsql AS $$
DECLARE
  m      jsonb;
  v_out  jsonb := '[]'::jsonb;
  v_url  text;
  v_kind text;
BEGIN
  IF p_media IS NULL OR jsonb_typeof(p_media) = 'null' THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_media) <> 'array' THEN
    RAISE EXCEPTION 'Attachments must be a list.' USING ERRCODE = 'GR005';
  END IF;
  IF jsonb_array_length(p_media) > 6 THEN
    RAISE EXCEPTION 'You can attach up to 6 files.' USING ERRCODE = 'GR005';
  END IF;

  FOR m IN SELECT value FROM jsonb_array_elements(p_media) LOOP
    v_url  := m ->> 'url';
    v_kind := m ->> 'kind';

    IF v_url IS NULL OR v_url ~ '\.\.' OR NOT (
         v_url ~ '^/uploads/[A-Za-z0-9._-]+$'
      OR v_url ~ '^https://res\.cloudinary\.com/[A-Za-z0-9_-]+/(image|video)/upload/(v[0-9]+/)?grogu/[A-Za-z0-9._-]+$'
    ) THEN
      RAISE EXCEPTION 'Attachments must be files uploaded to Grogu.' USING ERRCODE = 'GR005';
    END IF;
    IF v_kind IS NULL OR v_kind NOT IN ('image', 'video') THEN
      RAISE EXCEPTION 'Each attachment must be an image or a video.' USING ERRCODE = 'GR005';
    END IF;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'url',  v_url,
      'kind', v_kind,
      'name', left(coalesce(m ->> 'name', ''), 120)));
  END LOOP;

  RETURN v_out;
END;
$$;
