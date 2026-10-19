defmodule Tymeslot.Integrations.Calendar.BlockingTest do
  @moduledoc """
  The owner's choice whether a calendar blocks availability, and the rule
  that a calendar bookings go to always does: refused when asked to make one
  show only, made to block when chosen, never demoted again.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.OwnerActions
  alias Tymeslot.Integrations.Calendar.Primary
  alias Tymeslot.Integrations.Calendar.Runtime.EventFetcher
  alias Tymeslot.MeetingTypes
  alias Tymeslot.TestMocks

  @moduletag :capture_log

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    %{user: user, profile: profile} = create_bookable_profile(timezone: "Etc/UTC")
    %{user: user, profile: profile}
  end

  defp google_integration(user, calendar_list, attrs \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          user: user,
          provider: "google",
          is_active: true,
          oauth_scope: "https://www.googleapis.com/auth/calendar",
          calendar_list: calendar_list
        ],
        attrs
      )
    )
  end

  defp blocks?(integration, calendar_id) do
    CalendarIntegrationSchema
    |> Repo.get!(integration.id)
    |> Map.fetch!(:calendar_list)
    |> Enum.find(&(&1.id == calendar_id))
    |> Map.fetch!(:blocks_availability)
  end

  defp calendars do
    [
      %{id: "work", name: "Work", selected: true, primary: true},
      %{id: "team", name: "Team", selected: true},
      %{id: "rota", name: "Rota", selected: true, blocks_availability: false}
    ]
  end

  describe "OwnerActions.set_calendar_blocking/4" do
    test "makes a calendar show only and blocking again", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")

      assert {:ok, _updated} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "team", false)

      refute blocks?(integration, "team")

      assert {:ok, _updated} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "team", true)

      assert blocks?(integration, "team")
    end

    test "refuses to make the integration's booking calendar show only", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")

      assert {:error, :booking_calendar} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "work", false)

      assert blocks?(integration, "work")
    end

    test "refuses the provider's primary when no booking calendar is stored", %{user: user} do
      integration = google_integration(user, calendars())

      assert {:error, :booking_calendar} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "work", false)
    end

    test "refuses the path a CalDAV connection books into when none is stored", %{user: user} do
      # The booking client falls back to the first selected writable path.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: ["/cal/shared/", "/cal/home/", "/cal/team/"],
          calendar_list: [
            %{id: "/cal/shared/", path: "/cal/shared/", selected: true, read_only: true},
            %{id: "/cal/home/", path: "/cal/home/", selected: true},
            %{id: "/cal/team/", path: "/cal/team/", selected: true}
          ]
        )

      assert {:error, :booking_calendar} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "/cal/home/", false)

      assert {:ok, _updated} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "/cal/team/", false)
    end

    test "refuses a calendar a meeting type books into", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")

      insert(:meeting_type,
        user: user,
        calendar_integration_id: integration.id,
        target_calendar_id: "team"
      )

      assert {:error, :booking_calendar} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "team", false)

      assert blocks?(integration, "team")
    end

    test "answers not found for another organiser's calendar and an unknown one", %{user: user} do
      integration = google_integration(user, calendars())
      stranger = insert(:user)

      assert {:error, :not_found} =
               OwnerActions.set_calendar_blocking(stranger.id, integration.id, "team", false)

      assert {:error, :not_found} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "nope", false)

      assert blocks?(integration, "team")
    end
  end

  describe "OwnerActions.set_calendar_state/4" do
    defp state_of(integration, calendar_id) do
      CalendarIntegrationSchema
      |> Repo.get!(integration.id)
      |> Map.fetch!(:calendar_list)
      |> Enum.find(&(&1.id == calendar_id))
      |> Blocking.state()
    end

    test "moves a calendar between off, show only and show and block", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")

      for state <- [:off, :block, :show, :off, :show, :block] do
        assert {:ok, _updated} =
                 OwnerActions.set_calendar_state(user.id, integration.id, "team", state)

        assert state_of(integration, "team") == state
      end
    end

    test "keeps a booking calendar showing and blocking", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")

      for state <- [:off, :show] do
        assert {:error, :booking_calendar} =
                 OwnerActions.set_calendar_state(user.id, integration.id, "work", state)
      end

      assert state_of(integration, "work") == :block
    end

    test "never shows a calendar shared as busy times only", %{user: user} do
      integration =
        google_integration(user, [
          %{id: "boss", selected: false, read_only: true, free_busy_only: true}
        ])

      assert {:error, :free_busy_only} =
               OwnerActions.set_calendar_state(user.id, integration.id, "boss", :show)

      assert {:ok, _updated} =
               OwnerActions.set_calendar_state(user.id, integration.id, "boss", :block)

      assert state_of(integration, "boss") == :block
    end
  end

  describe "a meeting type naming a booking calendar" do
    test "makes a show-only calendar block when created against it", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")

      assert {:ok, _meeting_type} =
               MeetingTypes.create_meeting_type(%{
                 user_id: user.id,
                 name: "Rota call",
                 duration_minutes: 30,
                 calendar_integration_id: integration.id,
                 target_calendar_id: "rota"
               })

      assert blocks?(integration, "rota")
    end

    test "makes it block when edited to book into it", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")
      meeting_type = insert(:meeting_type, user: user)

      assert {:ok, _updated} =
               MeetingTypes.update_meeting_type(meeting_type, %{
                 calendar_integration_id: integration.id,
                 target_calendar_id: "rota"
               })

      assert blocks?(integration, "rota")
    end

    test "is refused as not found when the owner is gone", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")
      meeting_type = insert(:meeting_type, user: user)
      Repo.delete!(user)

      assert {:error, :not_found} =
               MeetingTypes.update_meeting_type(meeting_type, %{
                 calendar_integration_id: integration.id,
                 target_calendar_id: "rota"
               })
    end

    test "leaves it blocking once the meeting type moves away or is deleted", %{user: user} do
      integration = google_integration(user, calendars(), default_booking_calendar_id: "work")
      meeting_type = insert(:meeting_type, user: user)

      {:ok, meeting_type} =
        MeetingTypes.update_meeting_type(meeting_type, %{
          calendar_integration_id: integration.id,
          target_calendar_id: "rota"
        })

      {:ok, meeting_type} =
        MeetingTypes.update_meeting_type(meeting_type, %{target_calendar_id: "team"})

      assert blocks?(integration, "rota")

      Repo.delete!(meeting_type)
      assert blocks?(integration, "rota")

      assert {:ok, _updated} =
               OwnerActions.set_calendar_blocking(user.id, integration.id, "rota", false)
    end
  end

  describe "storing an integration's booking calendar" do
    test "a new connection's booking calendar blocks", %{user: user} do
      assert {:ok, integration} =
               Management.create_calendar_integration(%{
                 user_id: user.id,
                 provider: "google",
                 name: "Google",
                 base_url: "https://www.googleapis.com/calendar/v3",
                 oauth_scope: "https://www.googleapis.com/auth/calendar",
                 calendar_list: [
                   %{
                     id: "work",
                     name: "Work",
                     selected: true,
                     primary: true,
                     blocks_availability: false
                   }
                 ]
               })

      assert Repo.get!(CalendarIntegrationSchema, integration.id).default_booking_calendar_id ==
               "work"

      assert blocks?(integration, "work")
    end

    test "making a calendar the primary makes its booking calendar block", %{user: user} do
      integration =
        google_integration(user, [
          %{id: "work", name: "Work", selected: true, primary: true, blocks_availability: false}
        ])

      assert {:ok, updated} =
               Primary.set_primary_calendar_integration(user.id, integration.id)

      assert updated.default_booking_calendar_id == "work"
      assert blocks?(integration, "work")
    end
  end

  describe "the booking page after a change" do
    setup %{user: user} do
      stub(
        Tymeslot.CalendarMock,
        :get_events_for_range_fresh,
        &EventFetcher.get_events_for_range_fresh/3
      )

      date = next_bookable_weekday()

      # Only the team calendar is busy at 2 PM; unticking it leaves the work
      # calendar selected, so the account is still read calendar by calendar.
      stub(GoogleCalendarAPIMock, :list_events, fn
        _integration, "work", _from, _to ->
          {:ok, []}

        _integration, "team", _from, _to ->
          start = DateTime.new!(date, ~T[14:00:00], "Etc/UTC")

          {:ok,
           [
             %{
               "id" => "team-event",
               "status" => "confirmed",
               "start" => %{"dateTime" => DateTime.to_iso8601(start)},
               "end" => %{
                 "dateTime" => start |> DateTime.add(30, :minute) |> DateTime.to_iso8601()
               }
             }
           ]}
      end)

      integration =
        google_integration(
          user,
          [
            %{id: "team", name: "Team", selected: true},
            %{id: "work", name: "Work", selected: true, primary: true}
          ],
          default_booking_calendar_id: "work"
        )

      %{date: date, integration: integration}
    end

    test "frees a calendar's times at once when it is set to show only", ctx do
      refute "2:00 PM" in offered(ctx.profile, ctx.date, "30min")

      {:ok, _updated} =
        OwnerActions.set_calendar_blocking(ctx.user.id, ctx.integration.id, "team", false)

      assert "2:00 PM" in offered(ctx.profile, ctx.date, "30min")
    end

    test "frees a calendar's times at once when a reconnect replaces the selection", ctx do
      refute "2:00 PM" in offered(ctx.profile, ctx.date, "30min")

      list = Enum.map(ctx.integration.calendar_list, &%{&1 | selected: &1.id == "work"})

      {:ok, _updated} = Blocking.replace_selection(ctx.integration, list, %{})

      assert "2:00 PM" in offered(ctx.profile, ctx.date, "30min")
    end

    test "frees a calendar's times at once when its connection is switched off", ctx do
      # The switch runs under the primary lock, which drops the cache once
      # it commits.
      refute "2:00 PM" in offered(ctx.profile, ctx.date, "30min")

      {:ok, _updated} = OwnerActions.toggle_integration(ctx.user.id, ctx.integration.id)

      assert "2:00 PM" in offered(ctx.profile, ctx.date, "30min")
    end

    test "blocks a calendar's times at once when its connection is switched back on", ctx do
      {:ok, off} = OwnerActions.toggle_integration(ctx.user.id, ctx.integration.id)

      # Seeds the cache with the answer computed without the connection.
      assert "2:00 PM" in offered(ctx.profile, ctx.date, "30min")

      {:ok, %{is_active: true}} = OwnerActions.toggle_integration(ctx.user.id, off.id)

      refute "2:00 PM" in offered(ctx.profile, ctx.date, "30min")
    end

    test "frees a calendar's times at once when its connection is paused", ctx do
      refute "2:00 PM" in offered(ctx.profile, ctx.date, "30min")

      {:ok, %{is_active: false}} = Management.pause_integration(ctx.integration)

      assert "2:00 PM" in offered(ctx.profile, ctx.date, "30min")
    end

    test "frees a calendar's times at once when it is switched off", ctx do
      refute "2:00 PM" in offered(ctx.profile, ctx.date, "30min")

      {:ok, _updated} =
        OwnerActions.set_calendar_state(ctx.user.id, ctx.integration.id, "team", :off)

      assert "2:00 PM" in offered(ctx.profile, ctx.date, "30min")
    end
  end
end
