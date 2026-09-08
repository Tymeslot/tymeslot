defmodule TymeslotWeb.Live.Scheduling.BookingAccessibilityTest do
  @moduledoc """
  Accessibility contract for the public booking page, checked against both
  themes at the rendered-page level.

  These are the defects an accessibility audit reported against the live
  booking page, expressed as assertions so they cannot come back: an unnamed
  timezone search box, a `<label>` bound to nothing, a trigger whose
  `aria-label` replaced its own visible text, and an autoplaying background
  video with no way to stop it.

  The contracts themselves live in `TymeslotWeb.AccessibilityAssertions`, which
  the dashboard timezone dropdown shares. This module owns reaching each step
  of the booking flow and saying which contract applies there.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers
  import TymeslotWeb.AccessibilityAssertions

  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  @themes [{"1", "quill"}, {"2", "rhythm"}]
  @timezone "America/New_York"

  defp mount_booking_page(conn, theme_id, name) do
    %{profile: profile} = seed_booking_account(theme_id, name, @timezone)
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=#{@timezone}")
    view
  end

  # The timezone selector lives on the schedule step, one duration choice in.
  defp advance_to_schedule_step(view) do
    view
    |> element("button[data-testid='duration-option'][data-duration='quick-chat']")
    |> render_click()

    view |> element("button[data-testid='next-step']") |> render_click()

    view
  end

  defp document(view), do: view |> render() |> Floki.parse_document!()

  describe "timezone selector" do
    for {theme_id, theme} <- @themes do
      @tag :capture_log
      test "#{theme}: the trigger's accessible name contains its visible text", %{conn: conn} do
        doc =
          conn
          |> mount_booking_page(unquote(theme_id), "tz-name-#{unquote(theme)}")
          |> advance_to_schedule_step()
          |> document()

        assert_named_by_visible_text(doc, "button.timezone-trigger", [
          "Your timezone",
          "New York"
        ])
      end

      @tag :capture_log
      test "#{theme}: the trigger announces the dialog it opens", %{conn: conn} do
        doc =
          conn
          |> mount_booking_page(unquote(theme_id), "tz-popup-#{unquote(theme)}")
          |> advance_to_schedule_step()
          |> document()

        assert_announces_dialog(doc, "button.timezone-trigger")
      end

      @tag :capture_log
      test "#{theme}: the timezone search box has an accessible name", %{conn: conn} do
        view =
          conn
          |> mount_booking_page(unquote(theme_id), "tz-search-#{unquote(theme)}")
          |> advance_to_schedule_step()

        view |> element("button.timezone-trigger") |> render_click()

        assert_input_named(document(view), ".timezone-search")
      end
    end
  end

  describe "form labels" do
    for {theme_id, theme} <- @themes do
      # The booking form is the step that carries the labels worth checking:
      # name, email, message and any custom questions. The schedule step it
      # used to be checked on renders almost none, so the sweep there passed
      # without ever seeing the form it was written for.
      @tag :capture_log
      test "#{theme}: no label on the booking form is bound to nothing", %{conn: conn} do
        view = mount_booking_page(conn, unquote(theme_id), "labels-#{unquote(theme)}")

        advance_to_booking_form(view, unquote(theme))

        assert_no_orphan_labels(document(view), "#{unquote(theme)} booking form")
      end
    end
  end

  describe "background video" do
    for {theme_id, theme} <- @themes do
      @tag :capture_log
      test "#{theme}: a video background ships a control to stop it", %{conn: conn} do
        %{profile: profile} =
          seed_booking_account(unquote(theme_id), "motion-#{unquote(theme)}", @timezone)

        insert(:theme_customization,
          profile: profile,
          theme_id: unquote(theme_id),
          background_type: "video",
          background_value: "preset:rhythm-default"
        )

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=#{@timezone}")

        doc = document(view)

        # WCAG 2.2.2: the background is an autoplaying loop running well past
        # five seconds alongside the booking form.
        assert [_video | _rest] = Floki.find(doc, "video")

        [toggle] = Floki.find(doc, "#background-motion-toggle")

        assert Floki.attribute([toggle], "phx-hook") == ["BackgroundMotionToggle"]
        assert [name] = Floki.attribute([toggle], "aria-label")
        assert name != ""

        # Both names are rendered up front: the hook swaps them client-side, so
        # the control still reads correctly for a visitor whose stored choice
        # the server never sees.
        assert [_pause] = Floki.attribute([toggle], "data-label-pause")
        assert [_play] = Floki.attribute([toggle], "data-label-play")
      end

      @tag :capture_log
      test "#{theme}: no control is rendered without a video background", %{conn: conn} do
        %{profile: profile} =
          seed_booking_account(unquote(theme_id), "nomotion-#{unquote(theme)}", @timezone)

        # Rhythm defaults to a video background, so the gradient has to be
        # chosen explicitly to reach the no-video branch.
        insert(:theme_customization,
          profile: profile,
          theme_id: unquote(theme_id),
          background_type: "gradient",
          background_value: "gradient_1"
        )

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=#{@timezone}")
        doc = document(view)

        # A pause button that pauses nothing is worse than no button.
        assert Floki.find(doc, "video") == []
        assert Floki.find(doc, "#background-motion-toggle") == []
      end
    end
  end
end
