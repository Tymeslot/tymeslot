defmodule Tymeslot.Repo.Migrations.MoveBookingPagesOffSeriesSlug do
  @moduledoc """
  `series` became a reserved booking page slug when booking series arrived:
  `/<username>/series/<series_uid>` is routed ahead of
  `/<username>/<page>/<slug>`, so a page already at `series` could no longer
  be reached under its own address. The page changeset refuses the slug from
  now on; this migration moves any page that took it before.

  Each such page moves to `series-page`, or `series-page-2`, `series-page-3`
  and so on, whichever is first free within its profile: not the slug of
  another of its pages, not a former address of one (a redirect row), and
  not the effective slug of one of its owner's meeting types (the custom
  slug, or the one derived from the name when there is none). The old
  address is then recorded as a redirect to the page, exactly as a rename
  from the dashboard records it, so a link to `/<username>/series` keeps
  leading to the page.

  A page not at `series` is untouched, so the migration is safe to run
  again. There is no `down`: moving a page back would make it unreachable
  again.
  """
  use Ecto.Migration

  # Moving the colliding rows is the whole of this migration; it runs one
  # set of statements over the few pages at `series`, with no changeset to
  # run them through.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  def up do
    execute("""
    DO $$
    DECLARE
      page record;
      candidate text;
      n integer;
    BEGIN
      FOR page IN
        SELECT bp.id, bp.profile_id, pr.user_id
        FROM booking_pages bp
        JOIN profiles pr ON pr.id = bp.profile_id
        WHERE lower(bp.slug) = 'series'
        ORDER BY bp.id
      LOOP
        n := 1;

        LOOP
          candidate := CASE WHEN n = 1 THEN 'series-page' ELSE 'series-page-' || n END;

          EXIT WHEN NOT EXISTS (
              SELECT 1 FROM booking_pages
              WHERE profile_id = page.profile_id AND lower(slug) = candidate
            )
            AND NOT EXISTS (
              SELECT 1 FROM booking_page_redirects
              WHERE profile_id = page.profile_id AND lower(slug) = candidate
            )
            AND NOT EXISTS (
              SELECT 1 FROM meeting_types mt
              WHERE mt.user_id = page.user_id
                AND CASE
                  WHEN coalesce(mt.slug, '') <> '' THEN lower(mt.slug)
                  ELSE trim(both '-' from regexp_replace(lower(mt.name), '[^a-z0-9]+', '-', 'g'))
                END = candidate
            );

          n := n + 1;
        END LOOP;

        UPDATE booking_pages
        SET slug = candidate, updated_at = now() AT TIME ZONE 'UTC'
        WHERE id = page.id;

        INSERT INTO booking_page_redirects (profile_id, slug, booking_page_id, inserted_at, updated_at)
        VALUES (page.profile_id, 'series', page.id, now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
        ON CONFLICT (profile_id, slug)
        DO UPDATE SET booking_page_id = EXCLUDED.booking_page_id, updated_at = EXCLUDED.updated_at;
      END LOOP;
    END
    $$;
    """)
  end

  def down, do: :ok
end
