defmodule Tymeslot.Integrations.Calendar.UndecryptableCredentialsTest do
  @moduledoc """
  One calendar integration whose stored credentials no longer decrypt (a
  changed key, a corrupt row) must stay that integration's problem: it is
  flagged for reconnection, and it never takes down the owner's availability,
  their dashboard, or the background sweeps that serve every other user.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Runtime.EventFetcher
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.FallbackSyncSweepWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  @moduletag :capture_log

  # Random bytes stand in for ciphertext whose key is genuinely gone.
  defp insert_undecryptable(attrs) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          username_encrypted: :crypto.strong_rand_bytes(40),
          password_encrypted: :crypto.strong_rand_bytes(40)
        ],
        attrs
      )
    )
  end

  # A subscribed feed is read from its cached events, so it is a calendar
  # that reads successfully without any provider HTTP.
  defp insert_readable_feed(user) do
    insert(:calendar_integration,
      user: user,
      provider: "ics_url",
      base_url: "https://feeds.example.com",
      username_encrypted: nil,
      password_encrypted: nil,
      subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/team.ics"),
      is_active: true
    )
  end

  defp reload(integration), do: Repo.get!(CalendarIntegrationSchema, integration.id)

  describe "the owner's active calendars" do
    test "lists the readable ones decrypted and flags the unreadable one for reconnection" do
      user = insert(:user)
      healthy = insert(:calendar_integration, user: user, name: "A healthy")
      stale = insert_undecryptable(user: user, name: "B stale")

      assert [listed] = Management.list_active_calendar_integrations(user.id)
      assert listed.id == healthy.id
      assert listed.password == "password123"

      assert %{needs_reauth: true, sync_error: sync_error} = reload(stale)
      assert sync_error == ReauthHandling.reauth_error_message(:credentials_undecryptable)
      refute reload(healthy).needs_reauth
    end
  end

  describe "availability" do
    test "fails closed instead of crashing when a calendar cannot be read" do
      user = insert(:user)
      stale = insert_undecryptable(user: user)
      today = Date.utc_today()

      assert {:error, :all_calendars_unavailable} =
               EventFetcher.get_events_for_range_fresh(user.id, today, Date.add(today, 7))

      assert reload(stale).needs_reauth
    end

    test "fails closed when one calendar reads and another cannot be read" do
      user = insert(:user)
      insert_readable_feed(user)
      insert_undecryptable(user: user)
      today = Date.utc_today()

      assert {:error, :some_calendars_unavailable} =
               EventFetcher.get_events_for_range_fresh(user.id, today, Date.add(today, 7))
    end

    test "does not fail when the unreadable integration's calendars all show only" do
      # Its calendar list is stored unencrypted, so the choice is still known.
      user = insert(:user)
      insert_readable_feed(user)

      stale =
        insert_undecryptable(
          user: user,
          calendar_list: [%{id: "/cal/a/", selected: true, blocks_availability: false}]
        )

      today = Date.utc_today()

      assert {:ok, _events} =
               EventFetcher.get_events_for_range_fresh(user.id, today, Date.add(today, 7))

      assert reload(stale).needs_reauth
    end

    test "fails closed when the unreadable integration has nothing selected" do
      # Read as before the blocking choice: Google and Outlook read the
      # primary calendar of such an integration.
      user = insert(:user)
      insert_readable_feed(user)

      insert_undecryptable(
        user: user,
        calendar_list: [%{id: "/cal/a/", selected: false, blocks_availability: false}]
      )

      today = Date.utc_today()

      assert {:error, :some_calendars_unavailable} =
               EventFetcher.get_events_for_range_fresh(user.id, today, Date.add(today, 7))
    end

    test "fails closed when the unreadable integration has a blocking calendar" do
      user = insert(:user)
      insert_readable_feed(user)

      insert_undecryptable(
        user: user,
        calendar_list: [
          %{id: "/cal/a/", selected: true, blocks_availability: false},
          %{id: "/cal/b/", selected: true}
        ]
      )

      today = Date.utc_today()

      assert {:error, :some_calendars_unavailable} =
               EventFetcher.get_events_for_range_fresh(user.id, today, Date.add(today, 7))
    end
  end

  describe "the dashboard" do
    test "the calendar list still shows every integration, the unreadable one included" do
      user = insert(:user)
      healthy = insert(:calendar_integration, user: user, name: "A healthy")
      stale = insert_undecryptable(user: user, name: "B stale")

      assert Enum.sort([healthy.id, stale.id]) ==
               user.id |> Calendar.list_integrations() |> Enum.map(& &1.id) |> Enum.sort()
    end

    # The status never decrypts credentials, so an unreadable integration
    # still counts as connected (it needs reconnecting, which the calendar
    # page says) rather than raising or reading as "connect a calendar".
    test "the sidebar status counts the unreadable integration" do
      user = insert(:user)
      insert_undecryptable(user: user)

      assert %{has_calendar: true} = DashboardContext.get_integration_status(user.id)
    end
  end

  describe "the fallback sync sweep" do
    test "still schedules every other user's calendar" do
      insert_undecryptable(provider: "google")
      healthy = insert(:calendar_integration, provider: "google")

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => healthy.id}
      )
    end
  end

  describe "reconnecting an unreadable integration" do
    test "the lookup by account finds the row instead of raising" do
      user = insert(:user)
      stale = insert_undecryptable(user: user, provider: "google", provider_account_id: "acct-1")

      assert {:ok, %{id: id}} =
               CalendarIntegrationQueries.get_by_account_for_user(user.id, "google", "acct-1")

      assert id == stale.id

      assert {:ok, %{id: ^id}} =
               CalendarIntegrationQueries.get_any_by_account_for_user(user.id, "google", "acct-1")

      assert {:ok, %{id: ^id}} =
               CalendarIntegrationQueries.get_by_user_and_provider(user.id, "google")
    end
  end
end
