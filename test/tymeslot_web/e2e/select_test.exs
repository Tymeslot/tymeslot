defmodule TymeslotWeb.E2E.SelectTest do
  @moduledoc """
  `<.select>` in a real browser: the keyboard model, the focus it moves, the
  `input` event LiveView's `phx-change` listens for, and a list that stays
  inside a phone-width embed. LiveViewTest cannot see any of those: it never
  runs the hook, and the option list only exists once the hook has drawn it.

  The touch device's native control is in `SelectTouchTest`, in a session of
  its own.
  """
  use TymeslotWeb.BrowserCase, async: false

  import TymeslotWeb.E2E.BookerSteps

  alias Ecto.Changeset
  alias Fluffy.Playwright.Keyboard
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias TymeslotWeb.Endpoint

  @moduletag :e2e
  @moduletag :ui

  @question "cf-region"

  describe "a dashboard form" do
    test "the keyboard commits a choice and phx-change hears it", %{session: session} do
      {session, _user} = log_in(session)

      session =
        session
        |> visit("/dashboard/embed")
        |> assert_has(by_css("#embed-layout-trigger"))
        |> assert_value("#embed-layout-field", "column")

      # Opening moves focus into the list, and Escape puts it back unchanged.
      session
      |> click(by_css("#embed-layout-trigger"))
      |> assert_open("embed-layout")
      |> assert_active_element("embed-layout-panel")
      |> Keyboard.press("Escape")
      |> assert_closed("embed-layout")
      |> assert_active_element("embed-layout-trigger")
      |> assert_value("#embed-layout-field", "column")

      # Arrow down, Enter: the second option, posted through phx-change.
      session
      |> Keyboard.press("ArrowDown")
      |> assert_open("embed-layout")
      |> Keyboard.press("ArrowDown")
      |> Keyboard.press("Enter")
      |> assert_closed("embed-layout")
      |> assert_active_element("embed-layout-trigger")
      |> assert_value("#embed-layout-field", "default")

      assert(
        session,
        attached(filter(by_css("#live-preview-container[data-layout='default']"), visible: false))
      )
    end
  end

  describe "the list on a dashboard page" do
    test "pressing the button of an open list closes it", %{session: session} do
      {session, _user} = log_in(session)

      session =
        session
        |> visit("/dashboard/embed")
        |> click(by_css("#embed-layout-trigger"))
        |> assert_open("embed-layout")

      session
      |> click(by_css("#embed-layout-trigger"))
      |> assert_closed("embed-layout")
      |> refute_has(by_css("#embed-layout-panel:popover-open"))
    end

    test "a button out of view leaves Escape to the page", %{session: session} do
      {session, _user} = log_in(session)

      session = visit(session, "/dashboard/embed")

      evaluate_script(session, """
      const probe = () => {
        let reached = false;
        const mark = () => (reached = true);
        window.addEventListener("keydown", mark);
        document.body.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", bubbles: true}));
        window.removeEventListener("keydown", mark);
        return reached;
      };
      window.__selectBaseline = probe();
      const trigger = document.getElementById("embed-layout-trigger");
      trigger.getBoundingClientRect = () => ({top: -500, bottom: -460, left: 0, width: 100});
      trigger.click();
      """)

      assert ["false", false, true, true] =
               evaluate_script(session, """
               const trigger = document.getElementById("embed-layout-trigger");
               const panel = document.getElementById("embed-layout-panel");
               const reachesWindow = () => {
                 let reached = false;
                 const mark = () => (reached = true);
                 window.addEventListener("keydown", mark);
                 document.body.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", bubbles: true}));
                 window.removeEventListener("keydown", mark);
                 return reached;
               };
               const baseline = window.__selectBaseline;
               return [trigger.getAttribute("aria-expanded"), panel.matches(":popover-open"), baseline, reachesWindow()];
               """)
    end
  end

  describe "the booking page's single select" do
    test "a mouse pick and a type-ahead pick both answer the question", %{session: session} do
      {profile, slug} = organiser_with_long_question()

      session =
        session
        |> visit("/#{profile.username}/#{slug}?theme=1")
        |> pick_first_slot()
        |> assert_has(by_css("#cq-input-#{@question}-trigger"))

      # By mouse.
      session
      |> click(by_css("#cq-input-#{@question}-trigger"))
      |> assert_open("cq-input-#{@question}")
      |> click(
        filter(by_css("#cq-input-#{@question}-panel [role='option']"), has_text: "Option 3")
      )
      |> assert_closed("cq-input-#{@question}")
      |> assert_value("#cq-input-#{@question}-field", "k3")

      # Type-ahead from the closed button lands on a later option; Enter commits.
      session
      |> Keyboard.type("option 5")
      |> assert_open("cq-input-#{@question}")
      |> Keyboard.press("Enter")
      |> assert_value("#cq-input-#{@question}-field", "k5")

      assert_has(session, filter(by_css("#cq-input-#{@question}-text"), has_text: "Option 5"),
        timeout: 3000
      )

      session
      |> click(by_css("[data-intent='continue']"))
      |> assert_has(by_test_id("booking-form"))
    end

    @tag Playwright.Test.use(viewport: %{width: 360, height: 640})
    test "the list stays inside a phone-width embed", %{session: session} do
      {profile, slug} = organiser_with_long_question()

      session =
        session
        |> visit("/#{profile.username}/#{slug}?theme=2")
        |> pick_first_slot()
        |> mark_embedded()
        |> assert_has(by_css("#cq-input-#{@question}-trigger"))
        |> click(by_css("#cq-input-#{@question}-trigger"))
        |> assert_open("cq-input-#{@question}")

      [rect] = panel_rect(session)

      assert rect["top"] >= 0 and rect["left"] >= 0
      assert rect["right"] <= rect["width"]
      assert rect["bottom"] <= rect["height"]
      assert rect["bottom"] > rect["top"]

      assert_no_horizontal_overflow(session, "phone-width embed with the select open")
    end
  end

  describe "in a real embed iframe" do
    test "the list stays inside a phone-width iframe", %{session: session} do
      {profile, slug} = organiser_with_long_question()

      profile =
        profile
        |> Changeset.change(allowed_embed_domains: [URI.parse(Endpoint.url()).host])
        |> Repo.update!()

      frame = frame_locator("#embed-frame")

      session =
        session
        |> visit("/#{profile.username}/#{slug}?theme=1")
        |> tap(
          &evaluate_script(
            &1,
            """
            const frame = document.createElement("iframe");
            frame.id = "embed-frame";
            frame.referrerPolicy = "no-referrer";
            frame.style.width = "360px";
            frame.style.height = "640px";
            frame.src = arg[0];
            document.body.replaceChildren(frame);
            """,
            nil,
            ["/#{profile.username}/#{slug}?theme=2&embed=1&parent-origin=#{Endpoint.url()}"]
          )
        )
        |> assert_has(by_css(frame, "[data-phx-main].phx-connected"))
        |> pick_first_slot(frame)
        |> assert_has(by_css(frame, "#cq-input-#{@question}-trigger"))
        |> click(by_css(frame, "#cq-input-#{@question}-trigger"))
        |> assert_open("cq-input-#{@question}", frame)

      [rect] = panel_rect(session, frame)

      assert rect["top"] >= 0 and rect["left"] >= 0
      assert rect["right"] <= rect["width"]
      assert rect["bottom"] <= rect["height"]
      assert rect["height"] == 640
    end
  end

  defp panel_rect(session, frame \\ nil) do
    evaluate_script(
      session,
      """
      const r = document.getElementById("cq-input-#{@question}-panel").getBoundingClientRect();
      return [{top: r.top, bottom: r.bottom, left: r.left, right: r.right,
               width: document.documentElement.clientWidth,
               height: document.documentElement.clientHeight}];
      """,
      frame
    )
  end

  defp assert_open(session, id, frame \\ nil) do
    assert_has(
      session,
      css_in(frame, "##{id}-panel [role='option']") |> filter(visible: true) |> first()
    )

    assert_has(session, css_in(frame, "##{id}-trigger[aria-expanded='true']"))
  end

  defp assert_closed(session, id) do
    assert_has(session, by_css("##{id}-trigger[aria-expanded='false']"))
  end

  defp assert_value(session, field, expected) do
    assert(session, value(by_css("#{field} [data-select-value]"), expected), timeout: 3000)
  end

  defp assert_active_element(session, id) do
    assert(session, focused(by_css("##{id}")), timeout: 3000)
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
