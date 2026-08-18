defmodule Tymeslot.Integrations.Calendar.ProviderAccountBackfillTest do
  @moduledoc """
  Tests that the provider_account_id backfill correctly handles pre-existing
  calendar integrations, including duplicate CalDAV rows that would violate
  the null-guard unique index.

  These tests drive the repair migration itself
  (20260329000001_backfill_calendar_provider_account_id) to ensure it is safe
  for all data shapes an open-source user might have. The migration module is
  loaded from `priv` and run through `Ecto.Migrator`; see
  `Tymeslot.Test.MigrationRunner`.

  Tests run non-async because they temporarily drop unique indexes to
  simulate the pre-migration database state.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :database

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_329_000_001

  setup do
    # Drop both provider_account_id-related indexes to simulate the
    # pre-migration state where duplicate rows can exist.
    Repo.query!("DROP INDEX IF EXISTS unique_active_calendar_null_account_per_user")
    Repo.query!("DROP INDEX IF EXISTS unique_active_calendar_account_per_user")

    :ok
  end

  describe "backfill with duplicate CalDAV integrations" do
    test "disambiguates rows sharing the same base_url" do
      user = insert(:user)

      row1_id = insert_raw_calendar_integration(user.id, "caldav", "https://dav.example.com")
      row2_id = insert_raw_calendar_integration(user.id, "caldav", "https://dav.example.com")

      run_backfill!()

      assert get_provider_account_id(row1_id) == "https://dav.example.com"
      assert get_provider_account_id(row2_id) == "https://dav.example.com||#{row2_id}"
    end

    test "leaves rows with distinct base_urls unchanged" do
      user = insert(:user)

      row1_id = insert_raw_calendar_integration(user.id, "caldav", "https://dav1.example.com")
      row2_id = insert_raw_calendar_integration(user.id, "caldav", "https://dav2.example.com")

      run_backfill!()

      assert get_provider_account_id(row1_id) == "https://dav1.example.com"
      assert get_provider_account_id(row2_id) == "https://dav2.example.com"
    end

    test "handles three or more duplicates" do
      user = insert(:user)
      url = "https://shared.example.com"

      row1_id = insert_raw_calendar_integration(user.id, "radicale", url)
      row2_id = insert_raw_calendar_integration(user.id, "radicale", url)
      row3_id = insert_raw_calendar_integration(user.id, "radicale", url)

      run_backfill!()

      assert get_provider_account_id(row1_id) == url
      assert get_provider_account_id(row2_id) == "#{url}||#{row2_id}"
      assert get_provider_account_id(row3_id) == "#{url}||#{row3_id}"
    end

    test "does not touch rows that already have provider_account_id" do
      user = insert(:user)

      existing = insert(:calendar_integration, user: user, provider_account_id: "custom-id")

      new_id = insert_raw_calendar_integration(user.id, "caldav", "https://new.example.com")

      run_backfill!()

      assert get_provider_account_id(existing.id) == "custom-id"
      assert get_provider_account_id(new_id) == "https://new.example.com"
    end

    test "does not touch Google/Outlook integrations with existing provider_account_id" do
      user = insert(:user)

      google =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: "goog-123"
        )

      outlook =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          provider_account_id: "ms-456"
        )

      run_backfill!()

      assert get_provider_account_id(google.id) == "goog-123"
      assert get_provider_account_id(outlook.id) == "ms-456"
    end

    test "handles inactive duplicate rows without disambiguating them" do
      user = insert(:user)
      url = "https://dav.example.com"

      active_id = insert_raw_calendar_integration(user.id, "caldav", url, is_active: true)
      inactive_id = insert_raw_calendar_integration(user.id, "caldav", url, is_active: false)

      run_backfill!()

      # The window function partitions by (user_id, provider, base_url) regardless
      # of is_active, so only the first row (by id) gets the plain base_url.
      # But since there are only two rows total and the window covers both,
      # the earlier one keeps base_url and the later gets '||<id>'.
      [first_id, second_id] = Enum.sort([active_id, inactive_id])
      assert get_provider_account_id(first_id) == url
      assert get_provider_account_id(second_id) == "#{url}||#{second_id}"
    end

    test "recreates the null-guard index over former duplicates" do
      user = insert(:user)

      insert_raw_calendar_integration(user.id, "caldav", "https://dav.example.com")
      insert_raw_calendar_integration(user.id, "caldav", "https://dav.example.com")

      # Creating the index is the migration's own second step, and the step
      # that failed for the reporting user: it only survives duplicate rows
      # because the backfill above it disambiguated them.
      run_backfill!()

      assert index_exists?("unique_active_calendar_null_account_per_user")
    end
  end

  # -- Helpers ----------------------------------------------------------------

  # `down/0` is a deliberate no-op and every step of `up/0` is idempotent (the
  # UPDATE only touches NULL rows, the index is `IF NOT EXISTS`), so the
  # version is dropped from the ledger and the migration re-applied.
  defp run_backfill! do
    MigrationRunner.replay!(@version)
  end

  defp index_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1)", [name])

    exists
  end

  defp insert_raw_calendar_integration(user_id, provider, base_url, opts \\ []) do
    is_active = Keyword.get(opts, :is_active, true)
    now = DateTime.utc_now(:second)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO calendar_integrations
          (user_id, provider, base_url, name, is_active,
           verify_ssl, calendar_paths, calendar_list, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, true, '{}', ARRAY[]::jsonb[], $6, $6)
        RETURNING id
        """,
        [user_id, provider, base_url, "Test #{provider}", is_active, now]
      )

    id
  end

  defp get_provider_account_id(id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT provider_account_id FROM calendar_integrations WHERE id = $1", [id])

    value
  end
end
