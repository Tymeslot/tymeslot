defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMeetingRemindersTest do
  @moduledoc """
  The reminder emails of a Tymeslot meeting booked from the side panel are
  chosen with the reminder picker the meeting type form uses: the common
  lead times a click away, any other typed with its unit, up to the limit a
  meeting type has. A lead time typed but never added goes in with Create,
  and Enter in its row adds it.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import Mox
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:more_options", %{
      "draft" => "d1",
      "title" => "",
      "start" => "2026-10-15T13:00",
      "end" => "2026-10-15T14:00",
      "all_day" => false,
      "calendar" => "#{context.integration.id}:work",
      "location" => "",
      "guests" => ["ada@example.com"],
      "free" => false
    })

    assert_reply(lv, %{opened: true})
    render_change(new_form(lv), %{"meeting" => "true", "guest_name" => "Ada Lovelace"})

    Map.put(context, :lv, lv)
  end

  defp new_form(lv), do: form(lv, "#calendar-panel-new-form")

  defp picker(lv, selector),
    do: element(lv, "#calendar-panel-meeting-reminders #{selector}")

  defp preset(lv, name), do: picker(lv, ~s([data-testid="reminder-preset-#{name}"]))

  defp open_custom(lv),
    do: lv |> picker(~s([data-testid="reminder-custom-toggle"])) |> render_click()

  defp type_custom(lv, value, unit) do
    lv
    |> picker(~s(input[name="reminder[value]"]))
    |> render_change(%{"reminder" => %{"value" => value, "unit" => unit}})
  end

  defp create_meeting(lv) do
    :erlang.trace(lv.pid, true, [:receive])
    render_submit(new_form(lv), %{"intent" => "create"})
  end

  defp booked_reminders do
    assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}
    params.reminders
  end

  test "a lead time of the host's own is added with its unit and booked", %{lv: lv} do
    open_custom(lv)
    type_custom(lv, "45", "minutes")
    lv |> picker(~s([data-testid="reminder-custom-add"])) |> render_click()

    assert has_element?(lv, "#calendar-panel-meeting-reminders", "45 minutes before")

    render_click(preset(lv, "1-days"))
    create_meeting(lv)

    assert booked_reminders() == [%{value: 45, unit: "minutes"}, %{value: 1, unit: "days"}]

    meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: @task_timeout)

    assert Enum.map(meeting.reminders, &{&1["value"], &1["unit"]}) == [
             {45, "minutes"},
             {1, "days"}
           ]
  end

  test "a lead time typed but never added goes in with Create", %{lv: lv} do
    open_custom(lv)
    type_custom(lv, "2", "hours")
    create_meeting(lv)

    assert booked_reminders() == [%{value: 2, unit: "hours"}]
  end

  test "Enter in the custom row adds the lead time and creates nothing", %{lv: lv} do
    open_custom(lv)
    :erlang.trace(lv.pid, true, [:receive])

    render_submit(new_form(lv), %{
      "intent" => "add_guest",
      "guest_email" => "",
      "reminder" => %{"value" => "3", "unit" => "days"}
    })

    assert has_element?(lv, "#calendar-panel-meeting-reminders", "3 days before")

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}},
                   100
  end

  test "a typed lead time that cannot be added keeps the panel open with the picker's reason",
       %{lv: lv} do
    open_custom(lv)
    type_custom(lv, "0", "minutes")
    create_meeting(lv)

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}},
                   100

    assert has_element?(lv, "#calendar-panel-meeting-reminders .form-error")
    assert has_element?(lv, "#calendar-panel-create")
  end

  test "a reminder taken off is not booked", %{lv: lv} do
    render_click(preset(lv, "30-minutes"))
    render_click(preset(lv, "1-hours"))

    lv
    # The 30-minute reminder is the only one in minutes.
    |> picker(~s([data-testid="reminder-remove"][phx-click*="minutes"]))
    |> render_click()

    refute has_element?(lv, "#calendar-panel-meeting-reminders", "30 minutes before")

    create_meeting(lv)
    assert booked_reminders() == [%{value: 1, unit: "hours"}]
  end

  test "no more than a meeting type's limit can be added", %{lv: lv} do
    for name <- ~w(30-minutes 1-hours 1-days), do: render_click(preset(lv, name))

    assert has_element?(
             lv,
             ~s(#calendar-panel-meeting-reminders [data-testid="reminder-custom-toggle"][disabled])
           )

    create_meeting(lv)
    assert length(booked_reminders()) == 3
  end

  test "a draft opened again after Cancel starts with no reminders", %{
    lv: lv,
    integration: integration
  } do
    render_click(preset(lv, "1-days"))
    assert has_element?(lv, "#calendar-panel-meeting-reminders .tag-semantic", "1 day before")

    # The draft has a guest, so Cancel asks first.
    lv |> element("#calendar-panel-new-cancel") |> render_click()
    lv |> element("#calendar-discard-draft-confirm") |> render_click()
    refute has_element?(lv, "#calendar-panel")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:more_options", %{
      "draft" => "d2",
      "title" => "",
      "start" => "2026-10-16T13:00",
      "end" => "2026-10-16T14:00",
      "all_day" => false,
      "calendar" => "#{integration.id}:work",
      "location" => "",
      "guests" => ["ada@example.com"],
      "free" => false
    })

    assert_reply(lv, %{opened: true})
    render_change(new_form(lv), %{"meeting" => "true", "guest_name" => "Ada Lovelace"})

    refute has_element?(lv, "#calendar-panel-meeting-reminders .tag-semantic")
    assert has_element?(lv, "#calendar-panel-meeting-reminders", "No reminders configured.")

    create_meeting(lv)
    assert booked_reminders() == []
  end

  test "below 640px the picker's controls take a 44px hit area", %{lv: lv} do
    assert has_element?(
             lv,
             "#calendar-panel-meeting-reminders[class~='max-sm:[&_button]:min-h-11'][class~='max-sm:[&_button]:min-w-11']"
           )
  end
end
