defmodule TymeslotWeb.Dashboard.ThemeSettings.BookingTextFormTest do
  use TymeslotWeb.LiveCase, async: true

  @moduledoc """
  The form is the only place an organiser learns that one heading replaces a
  different sentence in each theme, and the only guard against publishing a
  half-filled introduction. Both are behaviour, not decoration.
  """
  @moduletag :themes
  @moduletag :live

  import Ecto.Changeset, only: [change: 2]
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Repo

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    profile = profile |> change(%{username: "text-owner", full_name: "Sarah"}) |> Repo.update!()
    {:ok, profile: profile}
  end

  describe "the form" do
    test "offers the customisation, switched off, on the theme page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/theme")

      assert html =~ "Booking Page Text"
      assert html =~ "Use my own wording"
      # The wording fields stay hidden until the organiser opts in.
      refute html =~ "Your heading replaces:"
    end

    test "reveals the fields and both themes' defaults once switched on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      html = toggle_on(view)

      assert html =~ "Your heading replaces:"
      # A single heading displaces a different sentence in each theme, so the
      # organiser has to be shown both, not only their current theme's.
      assert html =~ "Let&#39;s Connect!"
      assert html =~ "Schedule with Sarah"
      assert html =~ "your current theme"
    end
  end

  describe "saving" do
    test "persists the wording and reports it", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      # The wording fields only exist once the organiser has opted in, which is
      # the same order a browser produces.
      toggle_on(view)
      submit(view, Map.merge(complete_text(), %{"booking_text_enabled" => "true"}))

      # The component forwards its flash to the parent via `send(self(), ...)`,
      # so it lands on the next render rather than in the submit's return value.
      assert render(view) =~ "Booking page text updated"

      saved = Repo.reload!(profile)
      assert saved.booking_text_enabled
      assert saved.booking_heading == "Ready to grow your business?"
      assert saved.booking_greeting == "I am Sarah."
      assert saved.booking_instruction == "Choose a session."
    end

    test "refuses to publish a half-filled introduction", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      toggle_on(view)

      html =
        submit(
          view,
          Map.merge(complete_text(), %{
            "booking_text_enabled" => "true",
            "booking_heading" => ""
          })
        )

      assert html =~ "can&#39;t be blank"
      refute Repo.reload!(profile).booking_text_enabled
    end

    test "switching off keeps the wording, so switching back on restores it", %{
      conn: conn,
      profile: profile
    } do
      profile =
        profile
        |> change(%{
          booking_text_enabled: true,
          booking_heading: "Ready to grow your business?",
          booking_greeting: "I am Sarah.",
          booking_instruction: "Choose a session."
        })
        |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      submit(view, %{"booking_text_enabled" => "false"})

      saved = Repo.reload!(profile)
      refute saved.booking_text_enabled
      assert saved.booking_heading == "Ready to grow your business?"
    end
  end

  describe "the preview" do
    test "frames the organiser's own booking page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/theme")

      assert html =~ ~s(<iframe)
      assert html =~ "/text-owner?"
      # Preview display mode, so the framed page pins CSP frame-ancestors to
      # 'self' rather than refusing to render inside the dashboard.
      assert html =~ "preview=true"
    end

    test "offers no frame until the booking page has a username", %{
      conn: conn,
      profile: profile
    } do
      profile |> change(%{username: nil}) |> Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/dashboard/theme")

      assert html =~ "No preview yet"
      refute html =~ ~s(<iframe)
    end
  end

  defp complete_text do
    %{
      "booking_heading" => "Ready to grow your business?",
      "booking_greeting" => "I am Sarah.",
      "booking_instruction" => "Choose a session."
    }
  end

  defp toggle_on(view) do
    view
    |> form("#booking-text-form form", profile_schema: %{"booking_text_enabled" => "true"})
    |> render_change()
  end

  defp submit(view, params) do
    view
    |> form("#booking-text-form form", profile_schema: params)
    |> render_submit()
  end
end
