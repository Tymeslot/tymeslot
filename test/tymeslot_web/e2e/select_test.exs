defmodule TymeslotWeb.E2E.SelectTest do
  @moduledoc """
  `<.select>` in a real browser: the keyboard model, the focus it moves, the
  `input` event LiveView's `phx-change` listens for, and a list that stays
  inside a phone-width embed. LiveViewTest cannot see any of those: it never
  runs the hook, and the option list only exists once the hook has drawn it.

  On a device with a coarse pointer the page shows the native control instead;
  the Vitest suite covers what its choice does, and `pointer: coarse` itself
  is a CSS query this suite's desktop Chrome does not match.
  """
  use TymeslotWeb.BrowserCase, async: false

  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.E2E.BookerSteps

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles

  @moduletag :e2e
  @moduletag :ui

  @question "cf-region"

  describe "a dashboard form" do
    feature "the keyboard commits a choice and phx-change hears it", %{session: session} do
      {session, _user} = log_in_via_browser(session)

      session =
        session
        |> visit("/dashboard/embed")
        |> wait_for_live()
        |> assert_has(css("#embed-layout-trigger"))
        |> assert_value("#embed-layout-field", "column")

      # Opening moves focus into the list, and Escape puts it back unchanged.
      session
      |> click(css("#embed-layout-trigger"))
      |> assert_open("embed-layout")
      |> assert_active_element("embed-layout-panel")
      |> send_keys([:escape])
      |> assert_closed("embed-layout")
      |> assert_active_element("embed-layout-trigger")
      |> assert_value("#embed-layout-field", "column")

      # Arrow down, Enter: the second option, posted through phx-change.
      session
      |> send_keys([:down_arrow])
      |> assert_open("embed-layout")
      |> send_keys([:down_arrow, :enter])
      |> assert_closed("embed-layout")
      |> assert_active_element("embed-layout-trigger")
      |> assert_value("#embed-layout-field", "default")

      assert_has(session, css("#live-preview-container[data-layout='default']", visible: false))
    end
  end

  describe "the booking page's single select" do
    feature "a mouse pick and a type-ahead pick both answer the question", %{session: session} do
      {profile, slug} = organiser_with_long_question()

      session =
        session
        |> visit("/#{profile.username}/#{slug}?theme=1")
        |> wait_for_live()
        |> pick_first_slot()
        |> assert_has(css("#cq-input-#{@question}-trigger"))

      # By mouse.
      session
      |> click(css("#cq-input-#{@question}-trigger"))
      |> assert_open("cq-input-#{@question}")
      |> click(css("#cq-input-#{@question}-panel [role='option']", text: "Option 3"))
      |> assert_closed("cq-input-#{@question}")
      |> assert_value("#cq-input-#{@question}-field", "k3")

      # Type-ahead from the closed button lands on a later option; Enter commits.
      session
      |> send_keys(["option 5"])
      |> assert_open("cq-input-#{@question}")
      |> send_keys([:enter])
      |> assert_value("#cq-input-#{@question}-field", "k5")

      eventually(
        fn ->
          assert has?(session, css("#cq-input-#{@question}-text", text: "Option 5"))
        end,
        timeout: 3000
      )

      session
      |> click(css("[data-intent='continue']"))
      |> assert_has(css("[data-testid='booking-form']"))
    end

    feature "the list stays inside a phone-width embed", %{session: session} do
      {profile, slug} = organiser_with_long_question()

      session =
        session
        |> resize_window(360, 640)
        |> visit("/#{profile.username}/#{slug}?theme=2")
        |> wait_for_live()
        |> pick_first_slot()
        |> mark_embedded()
        |> assert_has(css("#cq-input-#{@question}-trigger"))
        |> click(css("#cq-input-#{@question}-trigger"))
        |> assert_open("cq-input-#{@question}")

      [rect] =
        evaluate_script(session, """
        const panel = document.getElementById("cq-input-#{@question}-panel");
        const r = panel.getBoundingClientRect();
        return [{top: r.top, bottom: r.bottom, left: r.left, right: r.right,
                 width: document.documentElement.clientWidth,
                 height: document.documentElement.clientHeight}];
        """)

      assert rect["top"] >= 0 and rect["left"] >= 0
      assert rect["right"] <= rect["width"]
      assert rect["bottom"] <= rect["height"]
      assert rect["bottom"] > rect["top"]

      assert_no_horizontal_overflow(session, "phone-width embed with the select open")
    end
  end

  defp assert_open(session, id) do
    assert_has(session, css("##{id}-panel [role='option']", minimum: 1))
    assert_has(session, css("##{id}-trigger[aria-expanded='true']"))
  end

  defp assert_closed(session, id) do
    assert_has(session, css("##{id}-trigger[aria-expanded='false']"))
  end

  defp assert_value(session, field, value) do
    eventually(
      fn ->
        assert [^value] =
                 evaluate_script(session, """
                 return [document.querySelector("#{field} [data-select-value]").value];
                 """)
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

  defp organiser_with_long_question do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)

    insert(:calendar_integration, user: user, user_id: user.id, is_active: true)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Select Chat",
        duration_minutes: 30,
        is_active: true
      )

    {:ok, _meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{
        "custom_fields" => [
          %{
            "id" => @question,
            "type" => "single_select",
            "label" => "Region",
            "required" => true,
            "position" => 0,
            "options" => for(i <- 1..8, do: %{"key" => "k#{i}", "label" => "Option #{i}"})
          }
        ]
      })

    {profile, Slugs.to_slug(meeting_type)}
  end
end
