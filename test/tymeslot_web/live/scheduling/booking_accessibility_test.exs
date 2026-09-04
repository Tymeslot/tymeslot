defmodule TymeslotWeb.Live.Scheduling.BookingAccessibilityTest do
  @moduledoc """
  Accessibility contract for the public booking page, checked against both
  themes at the rendered-page level.

  These are the defects an accessibility audit reported against the live
  booking page, expressed as assertions so they cannot come back: an unnamed
  timezone search box, a `<label>` bound to nothing, a trigger whose
  `aria-label` replaced its own visible text, and an autoplaying background
  video with no way to stop it.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers

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

  # Approximates the accessible name for a button: aria-label wins outright if
  # present, otherwise the name comes from the element's own text.
  defp accessible_name(element) do
    case Floki.attribute(element, "aria-label") do
      [label | _rest] -> label
      [] -> element |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()
    end
  end

  describe "timezone selector" do
    for {theme_id, theme} <- @themes do
      @tag :capture_log
      test "#{theme}: the trigger's accessible name contains its visible text", %{conn: conn} do
        doc =
          conn
          |> mount_booking_page(unquote(theme_id), "tz-name-#{unquote(theme)}")
          |> advance_to_schedule_step()
          |> document()

        [trigger] = Floki.find(doc, "button.timezone-trigger")

        # WCAG 2.5.3 Label in Name: an aria-label of "Select timezone" replaced
        # the visible timezone, leaving speech-input users unable to activate
        # the control by what they can see.
        assert Floki.attribute(trigger, "aria-label") == []

        name = accessible_name(trigger)
        assert name =~ "Your timezone"
        assert name =~ "New York"
      end

      @tag :capture_log
      test "#{theme}: the trigger announces the dialog it opens", %{conn: conn} do
        doc =
          conn
          |> mount_booking_page(unquote(theme_id), "tz-popup-#{unquote(theme)}")
          |> advance_to_schedule_step()
          |> document()

        [trigger] = Floki.find(doc, "button.timezone-trigger")

        # aria-haspopup="true" means "menu"; the panel is a dialog.
        assert Floki.attribute(trigger, "aria-haspopup") == ["dialog"]
      end

      @tag :capture_log
      test "#{theme}: the timezone search box has an accessible name", %{conn: conn} do
        view =
          conn
          |> mount_booking_page(unquote(theme_id), "tz-search-#{unquote(theme)}")
          |> advance_to_schedule_step()

        view |> element("button.timezone-trigger") |> render_click()

        inputs = view |> document() |> Floki.find(".timezone-search")

        # Anchored: an empty list would otherwise pass the check below.
        assert length(inputs) == 1

        # A placeholder is not an accessible name — it disappears on input and
        # several screen readers never announce it.
        assert [label] = Floki.attribute(inputs, "aria-label")
        assert label != ""
      end
    end
  end

  describe "form labels" do
    for {theme_id, theme} <- @themes do
      @tag :capture_log
      test "#{theme}: no label element is bound to nothing", %{conn: conn} do
        doc =
          conn
          |> mount_booking_page(unquote(theme_id), "labels-#{unquote(theme)}")
          |> advance_to_schedule_step()
          |> document()

        labels = Floki.find(doc, "label")

        orphans =
          Enum.reject(labels, fn label ->
            Floki.attribute([label], "for") != [] or
              Floki.find([label], "input, select, textarea") != []
          end)

        assert orphans == []
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
