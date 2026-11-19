defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceContactSuggestionsTest do
  @moduledoc """
  Contact suggestions in the side panel's guest fields: both carry the
  anchor the `ContactSuggest` hook fills, and both take a guest typed as
  `Name <address>`, which is what choosing a contact fills in. In the New
  event state the name shows on the guest's chip, the first guest's becomes
  the meeting's guest name, and the others' go with their invitations; in
  the edit state the invited guest is written to the calendar with it.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_update, self(), payload})
      :ok
    end)

    context
  end

  defp new_draft(lv, integration) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:more_options", %{
      "draft" => "d1",
      "title" => "",
      "start" => "2026-10-15T13:00",
      "end" => "2026-10-15T14:00",
      "all_day" => false,
      "calendar" => "#{integration.id}:work",
      "location" => "",
      "guests" => [],
      "free" => false
    })

    assert_reply(lv, %{opened: true})
  end

  defp new_form(lv), do: form(lv, "#calendar-panel-new-form")

  defp add_guest(lv, typed),
    do: render_submit(new_form(lv), %{"intent" => "add_guest", "guest_email" => typed})

  defp trace(lv), do: :erlang.trace(lv.pid, true, [:receive])

  describe "a new event" do
    setup %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      new_draft(lv, integration)
      %{lv: lv}
    end

    test "suggests contacts under its guest field, adding through Add with the name", %{lv: lv} do
      [input_id] =
        Regex.run(~r/id="(calendar-panel-guest-email-\d+)"/, render(lv), capture: :all_but_first)

      assert has_element?(lv, ~s(##{input_id}[autocomplete="off"][inputmode="email"]))

      assert has_element?(
               lv,
               ~s(##{input_id}-contact-suggest[phx-hook="ContactSuggest"][data-input="#{input_id}"][data-submit][data-submitter="calendar-panel-guest-add"][data-named])
             )
    end

    test "a guest typed with a name shows it on the chip, at the address alone", %{lv: lv} do
      add_guest(lv, "Grace Hopper <Grace@Example.com>")

      assert has_element?(lv, "#calendar-panel-guests li", "Grace Hopper")

      assert has_element?(
               lv,
               ~s(#calendar-panel-guests input[name="guests[]"][value="grace@example.com"])
             )
    end

    test "the meeting is booked with the first guest's name and the others' names", %{lv: lv} do
      add_guest(lv, "Ada Lovelace <ada@example.com>")
      add_guest(lv, ~s("Hopper, Grace" <grace@example.com>))
      add_guest(lv, "ops@example.com")

      render_change(new_form(lv), %{"meeting" => "true"})
      assert has_element?(lv, ~s(input[name="guest_name"][value="Ada Lovelace"]))

      trace(lv)
      render_submit(new_form(lv), %{"intent" => "create"})

      assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}

      assert %{
               attendee_name: "Ada Lovelace",
               attendee_email: "ada@example.com",
               guest_emails: ["grace@example.com", "ops@example.com"],
               guest_names: %{"grace@example.com" => "Hopper, Grace"}
             } = params

      meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: @task_timeout)

      assert [
               %{email: "grace@example.com", name: "Hopper, Grace"},
               %{email: "ops@example.com", name: nil}
             ] = meeting.id |> GuestQueries.list_for_meeting() |> Enum.sort_by(& &1.email)
    end

    test "a contact left in the guest field goes in with Create, with its name", %{lv: lv} do
      add_guest(lv, "Ada Lovelace <ada@example.com>")

      render_change(new_form(lv), %{
        "meeting" => "true",
        "guest_email" => "Grace Hopper <grace@example.com>"
      })

      trace(lv)

      render_submit(new_form(lv), %{
        "intent" => "create",
        "guest_email" => "Grace Hopper <grace@example.com>"
      })

      assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}

      assert %{
               attendee_name: "Ada Lovelace",
               guest_emails: ["grace@example.com"],
               guest_names: %{"grace@example.com" => "Grace Hopper"}
             } = params
    end

    test "a guest name already typed is kept", %{lv: lv} do
      render_change(new_form(lv), %{"meeting" => "true", "guest_name" => "Countess of Lovelace"})
      add_guest(lv, "Ada Lovelace <ada@example.com>")

      assert has_element?(lv, ~s(input[name="guest_name"][value="Countess of Lovelace"]))
    end

    test "a removed guest's name goes with them", %{lv: lv} do
      add_guest(lv, "Ada Lovelace <ada@example.com>")
      add_guest(lv, "Grace Hopper <grace@example.com>")

      lv
      |> element(~s(#calendar-panel-guests button[aria-label="Remove grace@example.com"]))
      |> render_click()

      add_guest(lv, "grace@example.com")

      render_change(new_form(lv), %{"meeting" => "true"})
      trace(lv)
      render_submit(new_form(lv), %{"intent" => "create"})

      assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}
      assert params.guest_names == %{}
    end
  end

  describe "an event being edited" do
    setup %{conn: conn, integration: integration} do
      review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z], 60)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:edit", %{"id" => "event-#{review.id}"})

      %{lv: lv}
    end

    test "suggests contacts under its invite field, inviting with the name", %{lv: lv} do
      [input_id] =
        Regex.run(~r/id="(calendar-panel-guest-email-\d+)"/, render(lv), capture: :all_but_first)

      assert has_element?(lv, ~s(##{input_id}[autocomplete="off"]))

      assert has_element?(
               lv,
               ~s(##{input_id}-contact-suggest[data-input="#{input_id}"][data-submit][data-named])
             )

      refute has_element?(lv, ~s(##{input_id}-contact-suggest[data-submitter]))
    end

    test "a guest invited with a name is written to the calendar with it", %{lv: lv} do
      lv
      |> form("#calendar-panel-guest-form")
      |> render_submit(%{"email" => "Grace Hopper <Grace@Example.com>"})

      assert_receive {:provider_update, _task, payload}, @task_timeout

      assert [%{email: "grace@example.com", display_name: "Grace Hopper"}] =
               Enum.map(payload.attendees, &Map.take(&1, [:email, :display_name]))
    end
  end
end
