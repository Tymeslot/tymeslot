defmodule TymeslotWeb.Live.Scheduling.NoCalendarReadinessTest do
  @moduledoc """
  A booking page whose organiser has connected no bookable calendar is an
  ordinary product state, not a crash. The visitor must be told, once, inside
  the organiser's own theme — never through the dispatcher's last-resort
  "Theme Error" card, whose Retry button reloads a page that cannot change.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :scheduling
  @moduletag :live

  import Tymeslot.Factory

  # The card's own strings, from the `errors` gettext domain. The heading is
  # matched from its apostrophe onwards, which HEEx escapes to `&#39;`.
  @heading "show this scheduling page yet"
  @call_to_action "If you are the organizer, please connect a calendar in your dashboard."

  # `LinkAccessPolicy.reason_to_message(:no_calendar)`, from `booking`. The
  # apostrophe is typographic in the catalogue and survives HTML escaping.
  @explanation "This scheduling page isn’t available right now. The organizer hasn’t connected a calendar yet."

  @themes [{"1", "quill"}, {"2", "rhythm"}]

  defp seed_organizer(theme_id, username) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: username,
        booking_theme: theme_id,
        timezone: "Etc/UTC"
      )

    insert(:meeting_type, user: user, name: "Quick Chat", duration_minutes: 30, is_active: true)

    %{user: user, profile: profile}
  end

  defp occurrences(haystack, needle),
    do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  for {theme_id, theme_name} <- @themes do
    describe "booking page with no bookable calendar (#{theme_name})" do
      setup do
        seed_organizer(unquote(theme_id), "no-cal-#{unquote(theme_name)}")
      end

      test "renders the readiness card inside the organiser's theme", %{
        conn: conn,
        profile: profile
      } do
        {:ok, view, _html} = live(conn, "/#{profile.username}")
        html = render(view)

        # The theme wrapper proves the theme's own LiveView rendered: the
        # dispatcher's fallback card carries no wrapper and no branding.
        assert html =~ "#{unquote(theme_name)}-theme-wrapper"
        assert has_element?(view, "[data-testid='readiness-notice']")
        assert html =~ @heading
        assert html =~ @explanation
        assert html =~ @call_to_action
      end

      test "never shows the theme-crash card or its dead Retry button", %{
        conn: conn,
        profile: profile
      } do
        {:ok, view, _html} = live(conn, "/#{profile.username}")
        html = render(view)

        refute html =~ "Theme Error"
        refute has_element?(view, "#theme-error-retry-button")
      end

      test "does not leak the internal reason code to the visitor", %{
        conn: conn,
        profile: profile
      } do
        {:ok, _view, _html} = live(conn, "/#{profile.username}")

        html = html_response(get(conn, "/#{profile.username}"), 200)

        refute html =~ "Reason code"
        refute html =~ "no_calendar"
      end

      test "states the reason exactly once on the full page", %{conn: conn, profile: profile} do
        # The whole document, layouts included: the message used to arrive as a
        # flash on top of the card, and the scheduling layout renders a flash
        # group of its own over the root layout's, so it appeared three times.
        html = html_response(get(conn, "/#{profile.username}"), 200)

        assert occurrences(html, @explanation) == 1
      end

      test "a read-only calendar is not a bookable one", %{
        conn: conn,
        user: user,
        profile: profile
      } do
        insert(:calendar_integration, user: user, provider: "ics_url", is_active: true)

        {:ok, view, _html} = live(conn, "/#{profile.username}")

        assert render(view) =~ @heading
      end

      test "a bookable calendar renders the booking flow instead", %{
        conn: conn,
        user: user,
        profile: profile
      } do
        insert(:calendar_integration, user: user, provider: "caldav", is_active: true)

        {:ok, view, _html} = live(conn, "/#{profile.username}")
        html = render(view)

        refute html =~ @heading
        assert html =~ "Quick Chat"
      end
    end
  end
end
