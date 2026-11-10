defmodule TymeslotWeb.E2E.DateTimePickerTest do
  @moduledoc """
  The date and time pickers in a real browser: the keyboard model, the focus
  they move, the `input` event LiveView's `phx-change` listens for, and a panel
  that stays inside a phone-width embed. LiveViewTest cannot see any of those:
  it never runs the hook, and the panels only exist once the hook draws them.

  A booking page's Date question and the create-event modal are the two
  journeys; the rest pins what went wrong in the review of `<.select>`.
  """
  use TymeslotWeb.BrowserCase, async: false

  import Ecto.Query, only: [where: 3]
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.E2E.BookerSteps

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias TymeslotWeb.Endpoint

  @moduletag :e2e
  @moduletag :ui

  @question "cf-start"

  describe "the create-event modal" do
    feature "dates and times chosen by keyboard, by mouse and by typing reach the server", %{
      session: session
    } do
      session = open_create_modal(session)

      # Keyboard: open the end date's calendar, one day on, Enter.
      end_date = hidden_value(session, "end-date")
      next_day = end_date |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601()

      session
      |> click(css("#create-event-end-date-trigger"))
      |> assert_open("create-event-end-date")
      |> assert_active_date(end_date)
      |> send_keys([:right_arrow, :enter])
      |> assert_closed("create-event-end-date")
      |> assert_active_element("create-event-end-date-trigger")
      |> assert_hidden("end-date", next_day)

      # Mouse: the time list, then the half-past option.
      session
      |> click(css("#create-event-start-time-trigger"))
      |> assert_has(css("#create-event-start-time-time-panel [role='option']", minimum: 96))
      |> click(css("#create-event-start-time-time-panel [role='option']", text: "10:30 AM"))
      |> assert_closed("create-event-start-time")
      |> assert_hidden("start-time", "10:30")

      # Typing: a 12-hour time in a field showing either clock, committed by Tab.
      session
      |> fill_in(css("#create-event-end-time"), with: "3:45 pm")
      |> send_keys([:tab])
      |> assert_hidden("end-time", "15:45")

      # The server has taken them: an unrelated re-render keeps every value.
      session
      |> click(css("#create-event-title"))
      |> send_keys(["Picker lunch"])

      assert_hidden(session, "end-date", next_day)
      assert_hidden(session, "start-time", "10:30")

      assert_text_value(session, "create-event-start-time", time_text("10:30"))

      click(session, css("[phx-click='save_event']"))

      eventually(fn -> not has?(session, css("#create-event-modal")) end, timeout: 5000)
    end

    feature "Escape closes the calendar and leaves the modal open", %{session: session} do
      session = open_create_modal(session)

      session
      |> click(css("#create-event-start-date-trigger"))
      |> assert_open("create-event-start-date")
      |> send_keys([:escape])
      |> assert_closed("create-event-start-date")
      |> assert_has(css("#create-event-modal"))
    end

    feature "pressing the button of an open calendar closes it", %{session: session} do
      session = open_create_modal(session)

      session
      |> click(css("#create-event-start-date-trigger"))
      |> assert_open("create-event-start-date")
      |> click(css("#create-event-start-date-trigger"))
      |> assert_closed("create-event-start-date")

      assert [false] =
               evaluate_script(session, """
               return [document.getElementById("create-event-start-date-date-panel").matches(":popover-open")];
               """)
    end

    feature "a field out of view opens nothing and leaves Escape to the page", %{session: session} do
      session = open_create_modal(session)

      session =
        execute_script(session, """
        const control = document.querySelector("#create-event-start-date-field [data-picker-part]");
        control.getBoundingClientRect = () => ({top: -500, bottom: -460, left: 0, width: 100});
        document.getElementById("create-event-start-date-trigger").click();
        """)

      assert ["false", false] =
               evaluate_script(session, """
               const trigger = document.getElementById("create-event-start-date-trigger");
               const panel = document.getElementById("create-event-start-date-date-panel");
               return [trigger.getAttribute("aria-expanded"), panel.matches(":popover-open")];
               """)

      # Nothing is left swallowing Escape: it reaches the page's own listeners.
      assert [true] =
               evaluate_script(session, """
               let reached = false;
               const mark = () => (reached = true);
               window.addEventListener("keydown", mark);
               document.body.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", bubbles: true}));
               window.removeEventListener("keydown", mark);
               return [reached];
               """)
    end

    feature "a browser without popovers shows the native control and no panel", %{
      session: session
    } do
      session = open_create_modal(session)

      assert ["none", "none", "block"] =
               session
               |> execute_script("""
               document.getElementById("create-event-start-date-field").dataset.pickerForceNative = "";
               """)
               |> evaluate_script("""
               const field = document.getElementById("create-event-start-date-field");
               const display = (selector) => getComputedStyle(field.querySelector(selector)).display;
               return [display("[data-picker-part]"), getComputedStyle(document.getElementById("create-event-start-date-date-panel")).display, display("[data-picker-native]")];
               """)
    end
  end

  describe "a question's limits in the question editor" do
    feature "switching the question from Date to Time gives the limit a time list", %{
      session: session
    } do
      {session, user} = log_in_via_browser(session)
      meeting_type = insert(:meeting_type, user: user)

      session =
        session
        |> visit("/dashboard/meeting-settings")
        |> wait_for_live()
        |> click(css("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']"))
        |> click(css("[role='tab']", text: "Questions"))
        |> click(css("button", text: "Add question"))
        |> assert_has(css("#definition_type-trigger"))
        |> choose_type("Date")
        |> assert_has(css("#definition_max-field[data-picker-kind='date']"))
        |> choose_type("Time")
        |> assert_has(css("#definition_max-field[data-picker-kind='time']"))
        |> click(css("#definition_max-trigger"))
        |> assert_open("definition_max")
        |> click(css("#definition_max-time-panel [role='option']", text: "3:45 PM"))

      eventually(
        fn ->
          assert ["15:45"] =
                   evaluate_script(session, """
                   return [document.querySelector("#definition_max-field [data-picker-value]").value];
                   """)
        end,
        timeout: 3000
      )
    end
  end

  describe "a booking page's Date question" do
    feature "a day chosen in the panel answers the question and the booking goes through", %{
      session: session
    } do
      {profile, slug} = organiser_with_date_question()
      tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

      session =
        session
        |> visit("/#{profile.username}/#{slug}?theme=1")
        |> wait_for_live()
        |> pick_first_slot()
        |> assert_has(css("#cq-input-#{@question}-trigger"))
        |> click(css("#cq-input-#{@question}-trigger"))
        |> assert_open("cq-input-#{@question}")
        |> click(css("#cq-input-#{@question}-date-panel [data-date='#{tomorrow}']"))
        |> assert_closed("cq-input-#{@question}")

      assert [^tomorrow] =
               evaluate_script(session, """
               return [document.querySelector("#cq-input-#{@question}-field [data-picker-value]").value];
               """)

      # A validation re-render on the way must not cost the visible value.
      eventually(
        fn ->
          assert [text] =
                   evaluate_script(session, """
                   return [document.getElementById("cq-input-#{@question}").value];
                   """)

          assert text != ""
        end,
        timeout: 3000
      )

      session
      |> click(css("[data-intent='continue']"))
      |> submit_booking_form()

      assert_answer_stored(profile, tomorrow)
    end

    feature "typing the date also answers, and Enter moves on", %{session: session} do
      {profile, slug} = organiser_with_date_question()
      date = Date.add(Date.utc_today(), 2)

      session
      |> visit("/#{profile.username}/#{slug}?theme=2")
      |> wait_for_live()
      |> pick_first_slot()
      |> assert_has(css("#cq-input-#{@question}"))
      |> fill_in(css("#cq-input-#{@question}"), with: Date.to_iso8601(date))
      |> send_keys([:enter])
      |> assert_has(css("[data-testid='booking-form']"))
    end

    feature "the panel stays inside a phone-width embed iframe", %{session: session} do
      {profile, slug} = organiser_with_date_question()

      profile =
        profile
        |> Changeset.change(allowed_embed_domains: [URI.parse(Endpoint.url()).host])
        |> Repo.update!()

      session =
        session
        |> visit("/#{profile.username}/#{slug}?theme=1")
        |> wait_for_live()
        |> execute_script(
          """
          const frame = document.createElement("iframe");
          frame.id = "embed-frame";
          frame.referrerPolicy = "no-referrer";
          frame.style.width = "360px";
          frame.style.height = "640px";
          frame.src = arguments[0];
          document.body.replaceChildren(frame);
          """,
          ["/#{profile.username}/#{slug}?theme=2&embed=1&parent-origin=#{Endpoint.url()}"]
        )
        |> focus_frame(css("#embed-frame"))
        |> assert_has(css("[data-phx-main].phx-connected"))
        |> pick_first_slot()
        |> assert_has(css("#cq-input-#{@question}-trigger"))
        |> click(css("#cq-input-#{@question}-trigger"))
        |> assert_open("cq-input-#{@question}")

      [rect] =
        evaluate_script(session, """
        const r = document.getElementById("cq-input-#{@question}-date-panel").getBoundingClientRect();
        return [{top: r.top, bottom: r.bottom, left: r.left, right: r.right,
                 width: document.documentElement.clientWidth,
                 height: document.documentElement.clientHeight}];
        """)

      assert rect["top"] >= 0 and rect["left"] >= 0
      assert rect["right"] <= rect["width"]
      assert rect["bottom"] <= rect["height"]
      assert rect["bottom"] > rect["top"]
    end
  end

  defp choose_type(session, label) do
    session
    |> click(css("#definition_type-trigger"))
    |> click(css("#definition_type-panel [role='option']", text: label))
  end

  defp open_create_modal(session) do
    {session, user} = log_in_via_browser(session)
    insert(:calendar_integration, user: user, is_active: true)

    session
    |> visit("/dashboard/calendar")
    |> wait_for_live()
    |> assert_has(css("#calendar-create-zone"))
    |> simulate_grid_drag()
    |> assert_has(css("#create-event-start-date-field"))
  end

  # As `dashboard_calendar_test.exs` opens it: the hook snaps real mouse events
  # to the grid.
  defp simulate_grid_drag(session) do
    execute_script(session, """
    const col = document.querySelector('[data-day-col]');
    const rect = col.getBoundingClientRect();
    const x = rect.left + Math.floor(rect.width / 2);
    const y = rect.top + 100;
    const base = { bubbles: true, cancelable: true, view: window, button: 0 };
    col.dispatchEvent(new MouseEvent('mousedown', { ...base, clientX: x, clientY: y }));
    document.dispatchEvent(new MouseEvent('mousemove', { ...base, clientX: x, clientY: y + 30 }));
    document.dispatchEvent(new MouseEvent('mouseup',   { ...base, clientX: x, clientY: y + 30 }));
    """)

    session
  end

  defp time_text("10:30"), do: "10:30 AM"

  defp hidden_value(session, name) do
    [value] =
      evaluate_script(session, """
      return [document.querySelector("#create-event-time-form [name='#{name}']").value];
      """)

    value
  end

  defp assert_hidden(session, name, value) do
    eventually(fn -> assert hidden_value(session, name) == value end, timeout: 3000)
    session
  end

  defp assert_text_value(session, id, value) do
    eventually(
      fn ->
        assert [^value] =
                 evaluate_script(session, "return [document.getElementById('#{id}').value];")
      end,
      timeout: 3000
    )

    session
  end

  defp assert_open(session, id) do
    assert_has(
      session,
      css("##{id}-date-panel [data-date], ##{id}-time-panel [role='option']", minimum: 1)
    )

    assert_has(session, css("##{id}-trigger[aria-expanded='true']"))
  end

  defp assert_closed(session, id) do
    assert_has(session, css("##{id}-trigger[aria-expanded='false']"))
  end

  defp assert_active_date(session, iso) do
    eventually(
      fn ->
        assert [^iso] = evaluate_script(session, "return [document.activeElement.dataset.date];")
      end,
      timeout: 3000
    )

    session
  end

  defp assert_active_element(session, id) do
    eventually(
      fn ->
        assert [^id] = evaluate_script(session, "return [document.activeElement.id];")
      end,
      timeout: 3000
    )

    session
  end

  defp organiser_with_date_question do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)

    insert(:calendar_integration, user: user, user_id: user.id, is_active: true)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Date Chat",
        duration_minutes: 30,
        is_active: true
      )

    {:ok, _meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{
        "custom_fields" => [
          %{
            "id" => @question,
            "type" => "date",
            "label" => "Start date",
            "required" => true,
            "position" => 0
          }
        ]
      })

    {profile, Slugs.to_slug(meeting_type)}
  end

  defp assert_answer_stored(profile, iso) do
    eventually(
      fn ->
        answers =
          MeetingSchema
          |> where([m], m.organizer_user_id == ^profile.user_id)
          |> Repo.all()
          |> Enum.flat_map(&Map.values(&1.custom_field_answers))

        assert iso in answers
      end,
      timeout: 3000
    )
  end
end
