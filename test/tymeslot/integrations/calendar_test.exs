defmodule Tymeslot.Integrations.CalendarTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.Primary
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.ColourWriteBackWorker
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  setup :verify_on_exit!

  describe "list_integrations/1" do
    test "returns integrations with primary flag" do
      user = insert(:user)
      insert(:profile, user: user)
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set integration1 as primary
      assert {:ok, _result} =
               Primary.set_primary_calendar_integration(user.id, integration1.id)

      integrations = Calendar.list_integrations(user.id)

      assert length(integrations) == 2
      i1 = Enum.find(integrations, &(&1.id == integration1.id))
      i2 = Enum.find(integrations, &(&1.id == integration2.id))

      assert i1.is_primary == true
      assert i2.is_primary == false
    end
  end

  describe "get_integration/2" do
    test "returns integration when found and belongs to user" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:ok, fetched} = Calendar.get_integration(integration.id, user.id)
      assert fetched.id == integration.id
    end

    test "returns error when not found" do
      user = insert(:user)
      assert {:error, :not_found} = Calendar.get_integration(999, user.id)
    end

    test "returns error when belongs to another user" do
      user1 = insert(:user)
      user2 = insert(:user)
      integration = insert(:calendar_integration, user: user1)

      assert {:error, :not_found} = Calendar.get_integration(integration.id, user2.id)
    end
  end

  describe "toggle_integration/2" do
    test "toggles active status" do
      user = insert(:user)
      insert(:profile, user: user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert {:ok, toggled} = Calendar.toggle_integration(user.id, integration.id)
      refute toggled.is_active

      assert {:ok, toggled_back} = Calendar.toggle_integration(user.id, integration.id)
      assert toggled_back.is_active
    end
  end

  describe "test_connection/1" do
    test "delegates to provider and records telemetry" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end ->
        {:ok, []}
      end)

      assert {:ok, "Google Calendar connection successful"} =
               Calendar.test_connection(integration)
    end
  end

  describe "calendar_module configuration" do
    setup do
      original_module = Application.get_env(:tymeslot, :calendar_module)

      on_exit(fn ->
        if original_module do
          Application.put_env(:tymeslot, :calendar_module, original_module)
        else
          Application.delete_env(:tymeslot, :calendar_module)
        end
      end)

      :ok
    end

    test "falls back to Operations when configured module does not exist" do
      Application.put_env(:tymeslot, :calendar_module, NonExistentModule)

      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "google", is_active: true)

      # Only the real Operations path reaches the provider API; calling the
      # configured module instead would raise `UndefinedFunctionError`.
      expect(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end ->
        {:ok, [%{"id" => "fallback-event", "summary" => "Fallback Event"}]}
      end)

      assert {:ok, [event]} =
               CalendarEvents.get_events_for_range_fresh(
                 user.id,
                 ~D[2026-01-05],
                 ~D[2026-01-06]
               )

      assert event.uid == "fallback-event"
    end
  end

  describe "writable_calendars/1" do
    test "excludes selected calendars that are read-only" do
      calendars =
        Enum.map(
          [
            %{id: "cal-1", selected: true, read_only: false},
            %{id: "cal-2", selected: true, read_only: true},
            %{id: "cal-3", selected: false, read_only: false}
          ],
          &CalendarEntry.normalize/1
        )

      assert Enum.map(Calendar.writable_calendars(calendars), & &1.id) == ["cal-1"]
    end
  end

  describe "all_selected_read_only?/1" do
    test "is true when every selected calendar is read-only" do
      calendars =
        Enum.map(
          [
            %{id: "cal-1", selected: true, read_only: true},
            %{id: "cal-2", selected: false, read_only: false}
          ],
          &CalendarEntry.normalize/1
        )

      assert Calendar.all_selected_read_only?(calendars)
    end

    test "is false when at least one selected calendar is writable" do
      calendars =
        Enum.map(
          [
            %{id: "cal-1", selected: true, read_only: true},
            %{id: "cal-2", selected: true, read_only: false}
          ],
          &CalendarEntry.normalize/1
        )

      refute Calendar.all_selected_read_only?(calendars)
    end

    test "is false when nothing is selected yet" do
      calendars =
        Enum.map(
          [%{id: "cal-1", selected: false, read_only: false}],
          &CalendarEntry.normalize/1
        )

      refute Calendar.all_selected_read_only?(calendars)
    end
  end

  describe "read_only_provider?/1" do
    test "is true for the providers that refuse every write" do
      assert Calendar.read_only_provider?(:ics_url)
    end

    test "is false for the providers a booking can be written to" do
      refute Calendar.read_only_provider?(:google)
      refute Calendar.read_only_provider?(:outlook)
      refute Calendar.read_only_provider?(:caldav)
      # Exchange joined this list when the EWS write path landed.
      refute Calendar.read_only_provider?(:exchange)
    end

    test "accepts the string form stored on an integration" do
      assert Calendar.read_only_provider?("ics_url")
      refute Calendar.read_only_provider?("google")
      refute Calendar.read_only_provider?("exchange")
    end

    test "is false for an unrecognised provider rather than raising" do
      refute Calendar.read_only_provider?(:nonesuch)
      refute Calendar.read_only_provider?("nonesuch")
      refute Calendar.read_only_provider?(nil)
    end
  end

  describe "default_booking_calendar/2" do
    test "falls back to a selected calendar when none is marked primary" do
      calendars =
        Enum.map(
          [
            %{id: "cal-1", selected: false},
            %{id: "cal-2", selected: true},
            %{id: "cal-3", selected: false}
          ],
          &CalendarEntry.normalize/1
        )

      assert %{id: "cal-2"} = Calendar.default_booking_calendar(calendars, nil)
    end

    test "falls through the ladder when the stored booking id matches no entry" do
      calendars =
        Enum.map(
          [%{id: "cal-1", selected: true}, %{id: "cal-2", primary: true}],
          &CalendarEntry.normalize/1
        )

      assert %{id: "cal-2"} = Calendar.default_booking_calendar(calendars, "stale-id")
    end

    test "skips a read-only first entry in favour of a writable one" do
      calendars =
        Enum.map(
          [
            %{id: "cal-1", read_only: true},
            %{id: "cal-2", read_only: false}
          ],
          &CalendarEntry.normalize/1
        )

      assert %{id: "cal-2"} = Calendar.default_booking_calendar(calendars, nil)
    end

    test "skips a booking id that now matches a read-only entry" do
      calendars =
        Enum.map(
          [
            %{id: "cal-1", read_only: true, primary: false},
            %{id: "cal-2", read_only: false, primary: true}
          ],
          &CalendarEntry.normalize/1
        )

      assert %{id: "cal-2"} = Calendar.default_booking_calendar(calendars, "cal-1")
    end

    test "returns nil when every entry is read-only" do
      calendars =
        Enum.map(
          [%{id: "cal-1", read_only: true}, %{id: "cal-2", read_only: true}],
          &CalendarEntry.normalize/1
        )

      assert Calendar.default_booking_calendar(calendars, nil) == nil
    end
  end

  describe "booking_target/1" do
    test "returns the entry matching default_booking_calendar_id" do
      calendars =
        Enum.map(
          [%{id: "cal-1", primary: true}, %{id: "cal-2"}],
          &CalendarEntry.normalize/1
        )

      integration = %{calendar_list: calendars, default_booking_calendar_id: "cal-2"}

      assert {:ok, %{id: "cal-2"}} = Calendar.booking_target(integration)
    end

    test "falls back to the provider-primary entry when no id is set" do
      calendars =
        Enum.map(
          [%{id: "cal-1"}, %{id: "cal-2", primary: true}],
          &CalendarEntry.normalize/1
        )

      integration = %{calendar_list: calendars, default_booking_calendar_id: nil}

      assert {:ok, %{id: "cal-2"}} = Calendar.booking_target(integration)
    end

    test "returns :none rather than guessing the first calendar" do
      calendars = Enum.map([%{id: "cal-1"}, %{id: "cal-2"}], &CalendarEntry.normalize/1)
      integration = %{calendar_list: calendars, default_booking_calendar_id: nil}

      assert Calendar.booking_target(integration) == :none
    end

    test "tags a booking id that now matches a read-only entry" do
      calendars =
        Enum.map(
          [%{id: "cal-1", read_only: true}, %{id: "cal-2", primary: true}],
          &CalendarEntry.normalize/1
        )

      integration = %{calendar_list: calendars, default_booking_calendar_id: "cal-1"}

      assert {:read_only, %{id: "cal-1"}} = Calendar.booking_target(integration)
    end
  end

  describe "set_event_colour/clear_event_colour" do
    setup do
      user = insert(:user)
      integ = insert(:calendar_integration, user: user)
      %{user: user, integ: integ}
    end

    test "sets a durable override for an external event", %{user: user, integ: integ} do
      assert {:ok, _override} =
               Calendar.set_event_colour(user.id, {:external, integ.id, "uid-1"}, "blueberry")

      assert Calendar.overrides_for(user.id) == %{{:external, integ.id, "uid-1"} => "blueberry"}
    end

    test "clears an override", %{user: user, integ: integ} do
      {:ok, _override} =
        Calendar.set_event_colour(user.id, {:external, integ.id, "uid-1"}, "blueberry")

      :ok = Calendar.clear_event_colour(user.id, {:external, integ.id, "uid-1"})
      assert Calendar.overrides_for(user.id) == %{}
    end

    test "sets a durable override for a meeting", %{user: user} do
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert {:ok, _override} = Calendar.set_event_colour(user.id, {:meeting, meeting.id}, "sage")
      assert Calendar.overrides_for(user.id) == %{{:meeting, meeting.id} => "sage"}
    end
  end

  describe "set_event_colour cross-tenant safety" do
    test "an override targeting another user's integration is refused and stores nothing" do
      user_a = insert(:user)
      user_b = insert(:user)
      integ_b = insert(:calendar_integration, user: user_b)

      assert {:error, :not_found} =
               Calendar.set_event_colour(user_a.id, {:external, integ_b.id, "uid-x"}, "blueberry")

      assert Calendar.overrides_for(user_a.id) == %{}
      assert Calendar.overrides_for(user_b.id) == %{}
      refute_enqueued(worker: ColourWriteBackWorker)
    end

    test "an override targeting another user's meeting is refused and stores nothing" do
      user_a = insert(:user)
      user_b = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user_b.id, organizer_email: user_b.email)

      assert {:error, :not_found} =
               Calendar.set_event_colour(user_a.id, {:meeting, meeting.id}, "sage")

      assert Calendar.overrides_for(user_a.id) == %{}
      assert Calendar.overrides_for(user_b.id) == %{}
    end

    test "clearing another user's override is refused and leaves it in place" do
      user_a = insert(:user)
      user_b = insert(:user)
      integ_b = insert(:calendar_integration, user: user_b)

      {:ok, _override} =
        Calendar.set_event_colour(user_b.id, {:external, integ_b.id, "uid-x"}, "blueberry")

      assert {:error, :not_found} =
               Calendar.clear_event_colour(user_a.id, {:external, integ_b.id, "uid-x"})

      assert Calendar.overrides_for(user_b.id) ==
               %{{:external, integ_b.id, "uid-x"} => "blueberry"}
    end

    test "a write-back job for a foreign integration is discarded before reading its events" do
      user_a = insert(:user)
      user_b = insert(:user)
      integ_b = insert(:calendar_integration, user: user_b, provider: "google")

      insert(:provider_calendar_event,
        calendar_integration: integ_b,
        uid: "uid-x",
        provider: "google"
      )

      assert {:discard, :not_owned} =
               perform_job(ColourWriteBackWorker, %{
                 "user_id" => user_a.id,
                 "integration_id" => integ_b.id,
                 "uid" => "uid-x",
                 "colour" => "blueberry"
               })
    end
  end

  # How each kind of integration is refreshed, through "refresh all".
  describe "refresh_all_integrations/1" do
    defp insert_subscription(user) do
      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
      )
    end

    test "a subscription is refreshed by enqueueing a feed sync, not by discovery" do
      user = insert(:user)
      subscription = insert_subscription(user)

      assert {:ok, [{_name, :ok}]} = Calendar.refresh_all_integrations(user.id)

      assert_enqueued(
        worker: SyncIcsCalendarWorker,
        args: %{"calendar_integration_id" => subscription.id}
      )
    end

    test "refreshing a subscription twice queues one sync and succeeds both times" do
      user = insert(:user)
      insert_subscription(user)

      assert {:ok, [{_name, :ok}]} = Calendar.refresh_all_integrations(user.id)
      assert {:ok, [{_name, :ok}]} = Calendar.refresh_all_integrations(user.id)

      assert [_one] = all_enqueued(worker: SyncIcsCalendarWorker)
    end

    test "any other provider re-runs discovery and persists the discovered list" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      expect(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
        {:ok, [%{"id" => "rediscovered", "summary" => "Rediscovered"}]}
      end)

      assert {:ok, [{_name, :ok}]} = Calendar.refresh_all_integrations(user.id)

      refute_enqueued(worker: SyncIcsCalendarWorker)
      {:ok, reloaded} = Calendar.get_integration(integration.id, user.id)
      assert [%CalendarEntry{id: "rediscovered"}] = reloaded.calendar_list
    end

    test "an Exchange mailbox takes discovery, never the feed worker" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        base_url: "https://exchange.example.com/EWS/Exchange.asmx"
      )

      assert {:ok, [_one]} = Calendar.refresh_all_integrations(user.id)
      refute_enqueued(worker: SyncIcsCalendarWorker)
    end
  end
end
