defmodule TymeslotWeb.OnboardingPreferencesExampleTest do
  @moduledoc """
  The worked-example sentence on each scheduling-preference step reflects the
  value the organiser has chosen, updating live as they click presets — so the
  explanation stays accurate rather than quoting a fixed 15-min / 2-week / 3-hour
  example regardless of the actual setting.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import TymeslotWeb.OnboardingTestHelpers

  setup tags do
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "buffer time example" do
    test "reflects both buffers around a 1:00 PM to 2:00 PM meeting", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_scheduling_steps(view)

      html = view |> element("button[phx-value-buffer_before_minutes='30']") |> render_click()
      assert html =~ "from 01:00 PM to 02:00 PM"
      assert html =~ "start at 02:30 PM at the earliest"
      # The after-buffer is still the default 15.
      assert html =~ "must end by 12:45 PM"

      html = view |> element("button[phx-value-buffer_after_minutes='60']") |> render_click()
      assert html =~ "start at 02:30 PM at the earliest"
      assert html =~ "must end by 12:00 PM"
    end

    test "uses a no-buffer phrasing when both are zero", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_scheduling_steps(view)

      view |> element("button[phx-value-buffer_before_minutes='0']") |> render_click()
      html = view |> element("button[phx-value-buffer_after_minutes='0']") |> render_click()

      assert html =~ "right next to an existing meeting"
      refute html =~ "at the earliest"
    end
  end

  describe "booking window example" do
    test "reflects the chosen window", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_booking_window_step(view)

      html = view |> element("button[phx-value-advance_booking_days='30']") |> render_click()
      assert html =~ "up to 1 month ahead"

      html = view |> element("button[phx-value-advance_booking_days='90']") |> render_click()
      assert html =~ "up to 3 months ahead"
    end
  end

  describe "minimum notice example" do
    test "reflects the chosen notice", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_minimum_notice_step(view)

      html = view |> element("button[phx-value-min_advance_hours='24']") |> render_click()
      assert html =~ "With 1 day of notice"

      html = view |> element("button[phx-value-min_advance_hours='0']") |> render_click()
      assert html =~ "no minimum notice"
    end
  end
end
