defmodule TymeslotWeb.Dashboard.ThemeSettings.BookingTextFormTest do
  use TymeslotWeb.LiveCase, async: true

  @moduledoc """
  The form is the only place an organiser learns that one heading replaces a
  different sentence in each theme, and the only guard against publishing a
  half-filled introduction. Both are behaviour, not decoration.

  It also has no save button, so the switch and the text fields each have to
  persist on their own; a change that silently stops writing would otherwise
  look identical to one that works.
  """
  @moduletag :themes
  @moduletag :live

  import Ecto.Changeset, only: [change: 2]
  import Tymeslot.DashboardTestHelpers

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
      assert html =~ ~s(aria-checked="false")
    end

    test "shows the fields greyed out rather than hidden while switched off", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/theme")

      # Present but inert: the organiser can read what the switch controls
      # without turning it on, and a disabled input posts nothing.
      assert html =~ "Your heading replaces:"
      assert html =~ "disabled"
    end

    test "names both themes' defaults, not only the current theme's", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/theme")

      # A single heading displaces a different sentence in each theme, so the
      # organiser has to be shown both.
      assert html =~ "Let&#39;s Connect!"
      assert html =~ "Schedule with Sarah"
      assert html =~ "your current theme"
    end
  end

  describe "the switch" do
    test "seeds the fields from the defaults so switching on is immediately valid", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      toggle(view)

      saved = Repo.reload!(profile)
      assert saved.booking_text_enabled
      # The current theme's default heading, not the other theme's.
      assert saved.booking_heading == "Let's Connect!"
      assert saved.booking_greeting == "Hi! I'm Sarah."
      assert saved.booking_instruction == "Pick an option below."
    end

    test "switching off resets the wording to the built-in defaults", %{
      conn: conn,
      profile: profile
    } do
      profile = enable_with_wording(profile)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      toggle(view)

      saved = Repo.reload!(profile)
      refute saved.booking_text_enabled
      # Cleared, not parked: a stale heading must not survive in the database,
      # or the booking page would silently resurrect it on the next switch-on.
      assert is_nil(saved.booking_heading)
      assert is_nil(saved.booking_greeting)
      assert is_nil(saved.booking_instruction)
    end

    test "reports the save rather than leaving the switch unexplained", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      assert toggle(view) =~ "All changes saved"
    end
  end

  describe "autosaving the wording" do
    test "persists a change without any submit", %{conn: conn, profile: profile} do
      profile = enable_with_wording(profile)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      html = edit(view, %{"booking_heading" => "Ready to grow your business?"})

      assert html =~ "All changes saved"
      assert Repo.reload!(profile).booking_heading == "Ready to grow your business?"
    end

    test "refuses to publish a half-filled introduction", %{conn: conn, profile: profile} do
      profile = enable_with_wording(profile)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      html = edit(view, %{"booking_heading" => ""})

      assert html =~ "can&#39;t be blank"
      assert html =~ "Unsaved changes"
      # The last good wording stands; a blank must not reach the public page.
      assert Repo.reload!(profile).booking_heading == "Ready to grow your business?"
    end

    test "rejects a heading past the cap even when the browser cap is bypassed", %{
      conn: conn,
      profile: profile
    } do
      profile = enable_with_wording(profile)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      html = edit(view, %{"booking_heading" => String.duplicate("a", 61)})

      assert html =~ "should be at most 60 character"
      assert Repo.reload!(profile).booking_heading == "Ready to grow your business?"
    end
  end

  describe "sanitisation at the save boundary" do
    # Malformed encoding cannot be exercised here: Plug rejects invalid UTF-8 on
    # urlencoded params before the handler runs. That branch is covered directly
    # in `Tymeslot.Profiles.BookingTextInputValidationTest`.
    test "keeps punctuation that a stricter sanitiser would strip", %{
      conn: conn,
      profile: profile
    } do
      profile = enable_with_wording(profile)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      edit(view, %{"booking_heading" => "Let's talk -- properly"})

      assert Repo.reload!(profile).booking_heading == "Let's talk -- properly"
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

  defp enable_with_wording(profile) do
    profile
    |> change(%{
      booking_text_enabled: true,
      booking_heading: "Ready to grow your business?",
      booking_greeting: "I am Sarah.",
      booking_instruction: "Choose a session."
    })
    |> Repo.update!()
  end

  defp toggle(view) do
    view |> element("#booking-text-form-enabled") |> render_click()
  end

  defp edit(view, params) do
    view
    |> form("#booking-text-form form", profile_schema: params)
    |> render_change()
  end
end
