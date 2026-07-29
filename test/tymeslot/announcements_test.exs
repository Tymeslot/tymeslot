defmodule Tymeslot.RaisingTestCatalog do
  @moduledoc false
  # Fixture catalog that always raises — used to verify safe_list/1 degrades gracefully.

  @spec list() :: no_return()
  def list, do: raise("catalog boom")
end

defmodule Tymeslot.ExpiringTestCatalog do
  @moduledoc false
  # Fixture catalog exercising the expiry filter. All three publish in the
  # distant past so the signup gate is never the reason an entry is hidden —
  # only `expires_at` differs between them.

  alias Tymeslot.Announcements.Announcement

  @spec list() :: [Announcement.t()]
  def list do
    [
      %Announcement{
        key: "expired_entry",
        title: "Expired",
        body: "Already past its expiry",
        published_at: ~U[2019-01-01 00:00:00Z],
        expires_at: ~U[2019-06-01 00:00:00Z]
      },
      %Announcement{
        key: "live_entry",
        title: "Live",
        body: "Expires far in the future",
        published_at: ~U[2019-01-01 00:00:00Z],
        expires_at: ~U[2099-01-01 00:00:00Z]
      },
      %Announcement{
        key: "evergreen_entry",
        title: "Evergreen",
        body: "Never expires",
        published_at: ~U[2019-01-01 00:00:00Z],
        expires_at: nil
      }
    ]
  end
end

defmodule Tymeslot.AllExpiredTestCatalog do
  @moduledoc false
  # Fixture catalog whose every entry has already expired — used to verify
  # `list_for/1` short-circuits before touching the database when no
  # candidate announcement could ever be shown.

  alias Tymeslot.Announcements.Announcement

  @spec list() :: [Announcement.t()]
  def list do
    [
      %Announcement{
        key: "long_gone",
        title: "Long gone",
        body: "Expired ages ago",
        published_at: ~U[2019-01-01 00:00:00Z],
        expires_at: ~U[2019-06-01 00:00:00Z]
      }
    ]
  end
end

defmodule Tymeslot.AnnouncementsTest do
  use Tymeslot.DataCase, async: false

  import ExUnit.CaptureLog

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.AllExpiredTestCatalog
  alias Tymeslot.Announcements
  alias Tymeslot.Announcements.AnnouncementQueries
  alias Tymeslot.Announcements.UserSeenAnnouncementSchema
  alias Tymeslot.AnnouncementsTestCatalog
  alias Tymeslot.ExpiringTestCatalog
  alias Tymeslot.RaisingTestCatalog
  alias Tymeslot.Repo

  describe "AnnouncementQueries.seen_keys_for/1" do
    test "returns the keys the user has marked seen" do
      user = insert(:user)
      other_user = insert(:user)

      Repo.insert!(%UserSeenAnnouncementSchema{
        user_id: user.id,
        announcement_key: "feature_a",
        seen_at: DateTime.utc_now(:second)
      })

      Repo.insert!(%UserSeenAnnouncementSchema{
        user_id: other_user.id,
        announcement_key: "feature_b",
        seen_at: DateTime.utc_now(:second)
      })

      assert AnnouncementQueries.seen_keys_for(user.id) == ["feature_a"]
    end
  end

  describe "AnnouncementQueries.mark_seen!/2" do
    test "writes a row" do
      user = insert(:user)

      assert :ok = AnnouncementQueries.mark_seen!(user.id, "feature_a")

      assert AnnouncementQueries.seen_keys_for(user.id) == ["feature_a"]
    end

    test "is idempotent — calling twice does not raise and does not duplicate" do
      user = insert(:user)

      assert :ok = AnnouncementQueries.mark_seen!(user.id, "feature_a")
      assert :ok = AnnouncementQueries.mark_seen!(user.id, "feature_a")

      assert AnnouncementQueries.seen_keys_for(user.id) == ["feature_a"]
    end

    test "does not raise when the user does not exist (FK violation) — logs and no-ops" do
      log =
        capture_log(fn ->
          # A non-existent user_id triggers an FK violation. Marking-seen is a
          # non-critical dashboard side effect, so it must swallow the error
          # and return :ok rather than crashing the LiveView.
          assert :ok = AnnouncementQueries.mark_seen!(-1, "feature_a")
        end)

      # The schema declares foreign_key_constraint(:user_id), so the FK violation
      # comes back as a changeset error rather than a raised Ecto.ConstraintError.
      assert log =~ "Failed to mark announcement seen"

      assert AnnouncementQueries.seen_keys_for(-1) == []
    end
  end

  describe "FK cascade on user delete" do
    test "deleting a user removes their seen records" do
      user = insert(:user)
      AnnouncementQueries.mark_seen!(user.id, "feature_a")
      assert AnnouncementQueries.seen_keys_for(user.id) == ["feature_a"]

      Repo.delete!(user)

      assert AnnouncementQueries.seen_keys_for(user.id) == []
    end
  end

  describe "Announcements.mark_seen!/2" do
    test "marks the announcement as seen" do
      user = insert(:user)

      assert :ok = Announcements.mark_seen!(user, "test_alpha")

      assert AnnouncementQueries.seen_keys_for(user.id) == ["test_alpha"]
    end

    test "is idempotent" do
      user = insert(:user)

      assert :ok = Announcements.mark_seen!(user, "test_alpha")
      assert :ok = Announcements.mark_seen!(user, "test_alpha")

      assert AnnouncementQueries.seen_keys_for(user.id) == ["test_alpha"]
    end

    test "is a no-op for a nil user rather than crashing" do
      # A modal event can arrive on a socket whose current_user is nil; the
      # context must guard this rather than raise a FunctionClauseError.
      assert :ok = Announcements.mark_seen!(nil, "test_alpha")
    end
  end

  describe "Announcements.list_for/1" do
    setup do
      previous = Application.get_env(:tymeslot, :announcement_catalogs, [])

      Application.put_env(:tymeslot, :announcement_catalogs, [
        AnnouncementsTestCatalog
      ])

      on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)

      :ok
    end

    test "returns all unseen announcements published after the user signed up" do
      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])

      assert [%{key: "test_alpha"}, %{key: "test_beta"}] =
               Announcements.list_for(user)
    end

    test "filters out announcements the user has already seen" do
      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])
      Announcements.mark_seen!(user, "test_alpha")

      assert [%{key: "test_beta"}] = Announcements.list_for(user)
    end

    test "filters out announcements published before the user signed up" do
      # User signed up after `test_alpha` (2026-01-01) but before `test_beta` (2026-02-01).
      user = insert(:user, inserted_at: ~N[2026-01-15 00:00:00])

      assert [%{key: "test_beta"}] = Announcements.list_for(user)
    end

    test "orders by published_at ascending" do
      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])

      result = Announcements.list_for(user)

      published_ats = Enum.map(result, & &1.published_at)
      assert published_ats == Enum.sort(published_ats, DateTime)
    end

    test "degrades gracefully when a catalog raises — returns entries from healthy catalogs" do
      Application.put_env(:tymeslot, :announcement_catalogs, [
        RaisingTestCatalog,
        AnnouncementsTestCatalog
      ])

      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])

      log =
        capture_log(fn ->
          result = Announcements.list_for(user)
          assert [%{key: "test_alpha"}, %{key: "test_beta"}] = result
        end)

      assert log =~ "Announcement catalog failed to load; skipping."
    end

    test "combines entries from multiple registered catalogs" do
      defmodule SecondTestCatalog do
        @moduledoc false
        alias Tymeslot.Announcements.Announcement

        @spec list() :: [Announcement.t()]
        def list do
          [
            %Announcement{
              key: "test_gamma",
              title: "Gamma",
              body: "Third",
              published_at: ~U[2026-03-01 00:00:00Z]
            }
          ]
        end
      end

      Application.put_env(:tymeslot, :announcement_catalogs, [
        AnnouncementsTestCatalog,
        __MODULE__.SecondTestCatalog
      ])

      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])
      keys = user |> Announcements.list_for() |> Enum.map(& &1.key)

      assert keys == ["test_alpha", "test_beta", "test_gamma"]
    end
  end

  describe "Announcements.list_for/1 expiry" do
    setup do
      previous = Application.get_env(:tymeslot, :announcement_catalogs, [])
      Application.put_env(:tymeslot, :announcement_catalogs, [ExpiringTestCatalog])
      on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)
      :ok
    end

    test "excludes announcements whose expires_at has passed but keeps live and evergreen ones" do
      user = insert(:user, inserted_at: ~N[2018-01-01 00:00:00])

      keys = user |> Announcements.list_for() |> Enum.map(& &1.key)

      assert "live_entry" in keys
      assert "evergreen_entry" in keys
      refute "expired_entry" in keys
    end
  end

  describe "Announcements.list_for/1 signup gate applies to admins" do
    setup do
      previous = Application.get_env(:tymeslot, :announcement_catalogs, [])
      Application.put_env(:tymeslot, :announcement_catalogs, [AnnouncementsTestCatalog])
      on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)
      :ok
    end

    test "an admin who signed up after publication sees no announcements — no bypass" do
      # Signed up after both test_alpha (2026-01-01) and test_beta (2026-02-01).
      admin = insert(:user, is_admin: true, inserted_at: ~N[2026-04-01 00:00:00])

      assert [] = Announcements.list_for(admin)
    end

    test "an admin who signed up before publication sees announcements published after signup" do
      # Signed up after test_alpha (2026-01-01) but before test_beta (2026-02-01).
      admin = insert(:user, is_admin: true, inserted_at: ~N[2026-01-15 00:00:00])

      assert [%{key: "test_beta"}] = Announcements.list_for(admin)
    end

    test "an admin and a non-admin with the same signup date see the same announcements" do
      inserted_at = ~N[2026-01-15 00:00:00]
      admin = insert(:user, is_admin: true, inserted_at: inserted_at)
      user = insert(:user, is_admin: false, inserted_at: inserted_at)

      assert Announcements.list_for(admin) == Announcements.list_for(user)
    end
  end

  describe "Announcements.list_for/1 query short-circuit" do
    test "does not query user_seen_announcements when the catalog yields no candidates" do
      previous = Application.get_env(:tymeslot, :announcement_catalogs, [])
      Application.put_env(:tymeslot, :announcement_catalogs, [AllExpiredTestCatalog])
      on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)

      user = insert(:user, inserted_at: ~N[2018-01-01 00:00:00])

      parent = self()
      ref = make_ref()
      handler_id = "announcements-query-spy-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, %{source: source}, _config ->
          send(parent, {:query_source, ref, source})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert [] = Announcements.list_for(user)

      # Drain any query events that did fire and assert none touched the
      # seen-announcements table — the all-expired catalog must short-circuit
      # before the per-user seen-keys read.
      refute_received {:query_source, ^ref, "user_seen_announcements"}
    end

    test "does query user_seen_announcements when a candidate exists" do
      previous = Application.get_env(:tymeslot, :announcement_catalogs, [])
      Application.put_env(:tymeslot, :announcement_catalogs, [AnnouncementsTestCatalog])
      on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)

      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])

      parent = self()
      ref = make_ref()
      handler_id = "announcements-query-spy-positive-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, %{source: source}, _config ->
          send(parent, {:query_source, ref, source})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert [_first | _rest] = Announcements.list_for(user)

      assert_received {:query_source, ^ref, "user_seen_announcements"}
    end
  end
end
