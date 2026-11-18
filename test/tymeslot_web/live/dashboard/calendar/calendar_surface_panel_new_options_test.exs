defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelNewOptionsTest do
  @moduledoc """
  What the side panel's New event state sets on a plain calendar event
  before it is created, as the old Quick Add did: one of the organiser's
  saved locations as its place, refused when it was deleted while the
  panel was open; reminders, several, each a notification or an email; and
  a repeat, so the series is created at once.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Venues
  alias Tymeslot.Workers.EmailWorker

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), payload})
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")
    Map.put(context, :lv, lv)
  end

  defp more_options(lv, integration, extra \\ %{}) do
    lv
    |> element("#calendar-canvas")
    |> render_hook(
      "calendar:more_options",
      Map.merge(
        %{
          "draft" => "d1",
          "title" => "Planning",
          "start" => "2026-10-15T13:00",
          "end" => "2026-10-15T14:00",
          "all_day" => false,
          "calendar" => integration && "#{integration.id}:work",
          "location" => "",
          "guests" => [],
          "free" => false
        },
        extra
      )
    )

    assert_reply(lv, %{opened: true})
  end

  defp new_form(lv), do: form(lv, "#calendar-panel-new-form")

  defp created(lv) do
    assert_receive {:provider_call, task_pid, payload}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    payload
  end

  # The add row's choices reach the form with its changes; Add is a plain
  # button, so Enter in the form never adds a reminder.
  defp add_reminder(lv, minutes, method) do
    render_change(new_form(lv), %{
      "event_reminder_minutes" => minutes,
      "event_reminder_method" => method
    })

    lv |> element("#calendar-panel-new-reminder-add") |> render_click()
  end

  defp outlook(user) do
    insert(:calendar_integration,
      user: user,
      name: "Outlook account",
      provider: "outlook",
      is_active: true,
      calendar_list: [%{"id" => "cal", "name" => "Calendar", "selected" => true}]
    )
  end

  # Implicit submission (Enter in a field) uses the form's first submit
  # button.
  defp first_submit(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#calendar-panel-new-form button[type=submit]")
    |> List.first()
  end

  describe "a saved location" do
    test "is offered beside Place, and written as the event's place", %{
      lv: lv,
      user: user,
      integration: integration
    } do
      venue = insert(:venue, user: user, name: "Head office", description: "12 High Street")
      more_options(lv, integration)

      # Labelled as it is written, so venues of one name can be told apart.
      assert has_element?(
               lv,
               ~s(#calendar-panel-new-venue option[value="#{venue.id}"]),
               "Head office (12 High Street)"
             )

      render_change(new_form(lv), %{"location_venue" => "#{venue.id}"})
      refute has_element?(lv, "#calendar-panel-new-location")

      render_submit(new_form(lv), %{"intent" => "create"})

      assert created(lv).location == Venues.display(venue)
      assert Venues.display(venue) == "Head office (12 High Street)"
    end

    test "deleted while the panel was open is refused, and nothing is written", %{
      lv: lv,
      user: user,
      integration: integration
    } do
      venue = insert(:venue, user: user, name: "Head office")
      more_options(lv, integration)
      render_change(new_form(lv), %{"location_venue" => "#{venue.id}"})

      Repo.delete!(venue)
      render_submit(new_form(lv), %{"intent" => "create"})

      refute_receive {:provider_call, _pid, _payload}, 100

      assert has_element?(
               lv,
               "#calendar-panel [role=status]",
               "That location can no longer be used. Please choose another one."
             )
    end

    test "someone else's is refused", %{lv: lv, user: user, integration: integration} do
      insert(:venue, user: user, name: "Head office")
      theirs = insert(:venue, name: "Someone else's office")
      more_options(lv, integration)

      render_submit(new_form(lv), %{"intent" => "create", "location_venue" => "#{theirs.id}"})

      refute_receive {:provider_call, _pid, _payload}, 100
    end

    test "is not offered to an organiser with none", %{lv: lv, integration: integration} do
      more_options(lv, integration)

      refute has_element?(lv, "#calendar-panel-new-venue")
      assert has_element?(lv, "#calendar-panel-new-location")
    end

    test "carries into the meeting when it is sent as a Tymeslot meeting", %{
      lv: lv,
      user: user,
      integration: integration
    } do
      venue = insert(:venue, user: user, name: "Head office")
      more_options(lv, integration, %{"guests" => ["ada@example.com"]})
      render_change(new_form(lv), %{"location_venue" => "#{venue.id}"})
      render_change(new_form(lv), %{"meeting" => "true"})

      assert has_element?(
               lv,
               ~s(#calendar-panel-meeting-location option[value="venue:#{venue.id}"][selected])
             )
    end
  end

  describe "reminders" do
    test "several, each a notification or an email, are written with the event", %{
      lv: lv,
      integration: integration
    } do
      more_options(lv, integration)

      add_reminder(lv, "10", "popup")
      add_reminder(lv, "1440", "email")
      add_reminder(lv, "30", "popup")

      assert has_element?(
               lv,
               "#calendar-panel-new-reminders li",
               "Notification 10 minutes before"
             )

      assert has_element?(lv, "#calendar-panel-new-reminders li", "Email 1 day before")

      lv
      |> element(
        ~s(#calendar-panel-new-reminders button[aria-label="Remove reminder Notification 30 minutes before"])
      )
      |> render_click()

      refute has_element?(lv, "#calendar-panel-new-reminders li", "30 minutes before")

      render_submit(new_form(lv), %{"intent" => "create"})

      assert created(lv).reminders == [
               %{method: :popup, minutes_before: 10},
               %{method: :email, minutes_before: 1440}
             ]
    end

    test "a lead time the row does not offer, or one already held, adds nothing", %{
      lv: lv,
      integration: integration
    } do
      more_options(lv, integration)

      add_reminder(lv, "7", "popup")
      add_reminder(lv, "10", "sms")
      refute has_element?(lv, "#calendar-panel-new-reminders li")

      add_reminder(lv, "10", "popup")
      add_reminder(lv, "10", "popup")

      assert [_one] =
               lv
               |> render()
               |> Floki.parse_document!()
               |> Floki.find("#calendar-panel-new-reminders li")
    end

    test "give way to a meeting's own reminder emails", %{lv: lv, integration: integration} do
      more_options(lv, integration, %{"guests" => ["ada@example.com"]})
      assert has_element?(lv, "#calendar-panel-new-reminders")

      render_change(new_form(lv), %{"meeting" => "true"})
      refute has_element?(lv, "#calendar-panel-new-reminders")
    end
  end

  describe "repeat" do
    test "a common pattern makes the event a series at once, its guests invited to it", %{
      lv: lv,
      integration: integration
    } do
      more_options(lv, integration, %{"guests" => ["grace@example.com"]})

      # 15 October 2026 is a Thursday.
      assert has_element?(
               lv,
               ~s(#calendar-panel-new-repeat-preset option[value="weekly"]),
               "Every week on Thursday"
             )

      render_change(new_form(lv), %{"repeat" => "weekly"})
      assert has_element?(lv, "#calendar-panel-new-repeat-summary")

      render_submit(new_form(lv), %{"intent" => "create"})
      created(lv)

      assert %{recurrence_rule: "FREQ=WEEKLY"} = Repo.one!(ProviderCalendarEventSchema)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_calendar_invitation", "attendee_email" => "grace@example.com"}
      )
    end

    test "Custom… opens the repeat editor inside the form, and its pattern is created", %{
      lv: lv,
      integration: integration
    } do
      more_options(lv, integration)

      render_change(new_form(lv), %{"repeat" => "custom"})

      assert has_element?(
               lv,
               "#calendar-panel-new-repeat #recurrence-editor-form-panel-new-repeat"
             )

      render_change(new_form(lv), %{
        "repeat" => "custom",
        "freq" => "daily",
        "interval" => "2",
        "end_type" => "count",
        "count" => "3"
      })

      assert has_element?(lv, "#calendar-panel-new-repeat-summary")

      render_submit(new_form(lv), %{"intent" => "create"})
      created(lv)

      assert %{recurrence_rule: "FREQ=DAILY;INTERVAL=2;COUNT=3"} =
               Repo.one!(ProviderCalendarEventSchema)
    end

    test "Does not repeat creates a one-off", %{lv: lv, integration: integration} do
      more_options(lv, integration)
      render_change(new_form(lv), %{"repeat" => "weekly"})
      render_change(new_form(lv), %{"repeat" => "none"})

      render_submit(new_form(lv), %{"intent" => "create"})
      created(lv)

      assert %{recurrence_rule: nil} = Repo.one!(ProviderCalendarEventSchema)
    end

    test "gives way to a Tymeslot meeting, which does not repeat", %{
      lv: lv,
      integration: integration
    } do
      more_options(lv, integration, %{"guests" => ["ada@example.com"]})
      assert has_element?(lv, "#calendar-panel-new-repeat")

      render_change(new_form(lv), %{"meeting" => "true"})
      refute has_element?(lv, "#calendar-panel-new-repeat")
    end
  end

  describe "Enter in the form" do
    test "submits with the guest field's Add, never Add reminder or Create", %{
      lv: lv,
      integration: integration
    } do
      more_options(lv, integration)

      assert ["calendar-panel-guest-add"] = Floki.attribute(first_submit(lv), "id")
      assert has_element?(lv, ~s(#calendar-panel-new-reminder-add[type="button"]))
    end

    test "does nothing where the guest field gives way", %{lv: lv, integration: integration} do
      more_options(lv, integration)
      render_change(new_form(lv), %{"group_event" => "true"})

      button = first_submit(lv)
      assert ["calendar-panel-new-enter"] = Floki.attribute(button, "id")
      assert Floki.attribute(button, "disabled") != []
    end
  end

  describe "on an Outlook calendar" do
    test "a single notification is offered, with no method to choose", %{
      conn: conn,
      user: user
    } do
      outlook = outlook(user)
      # Read as the calendar loads.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      more_options(lv, nil, %{"calendar" => "#{outlook.id}:cal"})

      refute has_element?(lv, "#calendar-panel-new-reminder-method")

      add_reminder(lv, "10", "email")

      assert has_element?(
               lv,
               "#calendar-panel-new-reminders li",
               "Notification 10 minutes before"
             )

      refute has_element?(lv, "#calendar-panel-new-reminder-add")

      render_submit(new_form(lv), %{"intent" => "create"})
      assert created(lv).reminders == [%{method: :popup, minutes_before: 10}]
    end
  end

  describe "a repeat the calendar refuses" do
    test "a repeat Outlook would refuse is refused before anything is written", %{
      conn: conn,
      user: user
    } do
      outlook = outlook(user)
      # Read as the calendar loads.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # 31 October: a monthly "on day 31" misses the shorter months.
      more_options(lv, nil, %{
        "calendar" => "#{outlook.id}:cal",
        "start" => "2026-10-31T10:00",
        "end" => "2026-10-31T11:00"
      })

      # A pattern Outlook takes is summed up under Repeat.
      render_change(new_form(lv), %{"repeat" => "weekly"})
      assert has_element?(lv, "#calendar-panel-new-repeat-summary")

      render_change(new_form(lv), %{
        "repeat" => "custom",
        "freq" => "monthly",
        "interval" => "1",
        "on" => "day",
        "end_type" => "never"
      })

      # The refused one is not, nor is the weekly one it replaced.
      refute has_element?(lv, "#calendar-panel-new-repeat-summary")

      render_submit(new_form(lv), %{"intent" => "create"})

      refute_receive {:provider_call, _pid, _payload}, 100
      assert has_element?(lv, "#calendar-panel [role=status]", "Couldn't save")
      assert Repo.all(ProviderCalendarEventSchema) == []

      # The pattern stays in the editor to be changed, rather than falling
      # back to "Does not repeat", which the next Create would make a one-off.
      assert has_element?(lv, ~s(#calendar-panel-new-repeat input[name="freq"][value="monthly"]))
    end
  end

  describe "repeat, after the draft stopped being a meeting" do
    test "a guest removed with the box still ticked leaves an event that repeats", %{
      lv: lv,
      integration: integration
    } do
      more_options(lv, integration, %{"guests" => ["ada@example.com"]})
      render_change(new_form(lv), %{"meeting" => "true"})
      refute has_element?(lv, "#calendar-panel-new-repeat")

      lv
      |> element(~s(#calendar-panel-guests button[aria-label="Remove ada@example.com"]))
      |> render_click()

      render_change(new_form(lv), %{"repeat" => "weekly"})
      render_submit(new_form(lv), %{"intent" => "create"})
      created(lv)

      assert %{recurrence_rule: "FREQ=WEEKLY"} = Repo.one!(ProviderCalendarEventSchema)
    end
  end

  describe "the repeat editor" do
    test "Custom… names its frequency apart from the Repeat select", %{
      lv: lv,
      integration: integration
    } do
      more_options(lv, integration)
      render_change(new_form(lv), %{"repeat" => "custom"})

      assert has_element?(
               lv,
               ~s(#recurrence-editor-form-panel-new-repeat-freq[aria-label="Repeat frequency"])
             )
    end
  end
end
