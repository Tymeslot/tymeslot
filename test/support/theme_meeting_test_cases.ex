defmodule TymeslotWeb.ThemeMeetingTestCases do
  @moduledoc """
  Shared test logic for theme meeting pages (cancel confirmed, reschedule).
  """
  use TymeslotWeb, :verified_routes

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.Assertions
  import Tymeslot.Factory

  alias Tymeslot.TestMocks

  @doc """
  Sets up a user, profile, theme customization, and meeting for theme tests.
  """
  @spec setup_theme_meeting(map()) :: {:ok, keyword()}
  def setup_theme_meeting(attrs) do
    TestMocks.setup_subscription_mocks()

    user_name = Map.get(attrs, :user_name)
    theme_id = Map.get(attrs, :theme_id)
    username = Map.get(attrs, :username)
    color_scheme = Map.get(attrs, :color_scheme)
    background_value = Map.get(attrs, :background_value)
    start_time = Map.get(attrs, :start_time)
    duration = Map.get(attrs, :duration)
    attendee_timezone = Map.get(attrs, :attendee_timezone, "UTC")

    user = insert(:user, name: user_name)
    profile = insert(:profile, user: user, username: username, booking_theme: theme_id)

    insert(:theme_customization,
      profile: profile,
      theme_id: theme_id,
      color_scheme: color_scheme,
      background_type: "gradient",
      background_value: background_value
    )

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_name: user.name,
        start_time: start_time,
        duration: duration,
        attendee_timezone: attendee_timezone,
        status: "confirmed"
      )

    {:ok, user: user, profile: profile, meeting: meeting}
  end

  @doc """
  Sets up the view for the cancel confirmed page.
  """
  @spec setup_cancel_confirmed_view(Plug.Conn.t(), term(), term()) :: map()
  def setup_cancel_confirmed_view(conn, profile, meeting) do
    {:ok, view, _html} =
      live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel-confirmed")

    %{view: view}
  end

  @doc """
  Sets up the view for the reschedule page.
  """
  @spec setup_reschedule_view(Plug.Conn.t(), term(), term()) :: map()
  def setup_reschedule_view(conn, profile, meeting) do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/reschedule")
    %{view: view}
  end

  @doc """
  Tests the cancel confirmed page rendering and navigation.
  """
  @spec test_cancel_confirmed_page(term()) :: term()
  def test_cancel_confirmed_page(view) do
    assert render(view) =~ "Meeting Cancelled"
    assert render(view) =~ "Your meeting has been successfully cancelled"
    assert render(view) =~ "Cancellation emails have been sent"

    assert {:error, {redirect_type, %{to: to}}} =
             view
             |> element("button", "Schedule a New Meeting")
             |> render_click()

    assert redirect_type in [:redirect, :live_redirect]
    assert to == "/"
  end

  @doc """
  Tests the reschedule page rendering common elements.
  """
  @spec test_reschedule_page_rendering(term()) :: term()
  def test_reschedule_page_rendering(view) do
    assert render(view) =~ "Reschedule Appointment"
    assert render(view) =~ "Select a new time for your meeting"
  end

  @doc """
  Tests the reschedule page's "Choose New Time" navigation.

  The CTA must return to the organiser's scheduling page carrying the
  `reschedule_meeting_uid` query param — without it the restarted booking
  loses its reschedule context and silently creates a duplicate meeting
  instead of moving the existing one.
  """
  @spec test_reschedule_page_navigation(term(), String.t(), String.t(), String.t()) :: term()
  def test_reschedule_page_navigation(view, button_text, profile_username, meeting_uid) do
    assert {:error, {redirect_type, %{to: to}}} =
             view
             |> element("button", button_text)
             |> render_click()

    assert redirect_type in [:redirect, :live_redirect]
    assert to == "/#{profile_username}?reschedule_meeting_uid=#{meeting_uid}"
  end

  @doc """
  Asserts that meeting details (date, time, organizer, duration) are rendered
  in the meeting's attendee timezone — not the raw UTC value the meeting is
  stored as. Also verifies the attendee's zone label is what's shown.
  """
  @spec assert_meeting_details_rendered(term(), term(), String.t(), integer()) :: term()
  def assert_meeting_details_rendered(view, meeting, organizer_name, duration) do
    html = render(view)

    local_time = shift_to_attendee_zone(meeting)

    formatted_date = Calendar.strftime(local_time, "%B %d, %Y")
    formatted_time = Calendar.strftime(local_time, "%-I:%M %p")
    raw_utc_time = Calendar.strftime(meeting.start_time, "%-I:%M %p")

    assert html =~ formatted_date
    assert html =~ formatted_time
    assert html =~ organizer_name
    assert html =~ "#{duration} min"
    assert html =~ local_time.time_zone

    if formatted_time != raw_utc_time do
      refute html =~ raw_utc_time
    end
  end

  # Mirrors the production shift in `LocalizationHelpers.to_attendee_datetime/2`
  # so the expectation reflects what the page is actually meant to render.
  defp shift_to_attendee_zone(%{start_time: start_time, attendee_timezone: timezone})
       when is_binary(timezone) and timezone != "" do
    case DateTime.shift_zone(start_time, timezone) do
      {:ok, shifted} -> shifted
      _error -> start_time
    end
  end

  defp shift_to_attendee_zone(%{start_time: start_time}), do: start_time

  # --- Locale-switched helpers ---

  @doc """
  Sets up the cancel confirmed view with a specific locale query param.
  """
  @spec setup_cancel_confirmed_view(Plug.Conn.t(), term(), term(), String.t()) :: map()
  def setup_cancel_confirmed_view(conn, profile, meeting, locale) do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel-confirmed?locale=#{locale}"
      )

    %{view: view}
  end

  @doc """
  Sets up the reschedule view with a specific locale query param.
  """
  @spec setup_reschedule_view(Plug.Conn.t(), term(), term(), String.t()) :: map()
  def setup_reschedule_view(conn, profile, meeting, locale) do
    {:ok, view, _html} =
      live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/reschedule?locale=#{locale}")

    %{view: view}
  end

  @doc """
  Sets up the cancel view with a specific locale query param.
  """
  @spec setup_cancel_view(Plug.Conn.t(), term(), term(), String.t()) :: map()
  def setup_cancel_view(conn, profile, meeting, locale) do
    {:ok, view, _html} =
      live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel?locale=#{locale}")

    %{view: view}
  end

  @doc """
  Tests that the cancel confirmed page renders translated strings for a given locale.
  Verifies that English strings are replaced with the locale's translations.
  """
  @spec test_cancel_confirmed_translations(term(), String.t()) :: term()
  def test_cancel_confirmed_translations(view, locale) do
    html = render(view)
    translations = translated_cancel_confirmed_strings(locale)

    # Translated strings must appear
    assert html =~ translations.meeting_cancelled
    assert html =~ translations.successfully_cancelled
    assert html =~ translations.cancellation_emails_sent

    # English originals must not appear
    refute html =~ "Meeting Cancelled"
    refute html =~ "Your meeting has been successfully cancelled."
    refute html =~ "Cancellation emails have been sent"
  end

  @doc """
  Tests that the cancel page renders translated strings for a given locale.
  """
  @spec test_cancel_translations(term(), String.t()) :: term()
  def test_cancel_translations(view, locale) do
    html = render(view)
    translations = translated_cancel_strings(locale)

    assert html =~ translations.cancel_appointment
    assert html =~ translations.are_you_sure
    assert html =~ translations.cancellation_email_warning
    assert html =~ translations.yes_cancel
    assert html =~ translations.keep_meeting

    refute html =~ "Cancel Appointment"
    refute html =~ "Are you sure you want to cancel this appointment?"
    refute html =~ "A cancellation email will be sent to all participants"
    refute html =~ "Yes, Cancel Meeting"
    refute html =~ "Keep Meeting"
  end

  @doc """
  Tests that the cancel page in meeting_kept state renders translated strings.
  Triggers the keep_meeting event and verifies the confirmed view is translated.
  """
  @spec test_cancel_kept_translations(term(), String.t()) :: term()
  def test_cancel_kept_translations(view, locale) do
    render_click(view, "keep_meeting")
    html = render(view)
    translations = translated_cancel_kept_strings(locale)

    assert html =~ translations.meeting_confirmed
    assert html =~ translations.still_scheduled
    assert html =~ translations.look_forward
    assert html =~ translations.done

    refute html =~ "Meeting Confirmed"
    refute html =~ "Great! Your meeting is still scheduled as planned."
    refute html =~ "We look forward to seeing you at the scheduled time."
    refute html =~ "Done"
  end

  @doc """
  Tests that the reschedule page renders translated strings for a given locale.
  """
  @spec test_reschedule_translations(term(), String.t()) :: term()
  def test_reschedule_translations(view, locale) do
    html = render(view)
    translations = translated_reschedule_strings(locale)

    assert html =~ translations.reschedule_appointment
    assert html =~ translations.select_new_time

    refute html =~ "Reschedule Appointment"
    refute html =~ "Select a new time for your meeting"
  end

  # --- Convenience wrappers that set up a view and run translation assertions ---

  @doc """
  Tests all three meeting pages (cancel, cancel confirmed, reschedule)
  render correctly in the given locale. Sets up each view with a locale
  query param and asserts translated strings appear instead of English.
  """
  @spec test_all_meeting_pages_in_locale(Plug.Conn.t(), map(), String.t()) :: term()
  def test_all_meeting_pages_in_locale(conn, %{profile: profile, meeting: meeting}, locale) do
    %{view: cancel_view} = setup_cancel_view(conn, profile, meeting, locale)
    test_cancel_translations(cancel_view, locale)

    # Test meeting_kept state on a fresh cancel view (keep_meeting mutates the view)
    %{view: cancel_kept_view} = setup_cancel_view(conn, profile, meeting, locale)
    test_cancel_kept_translations(cancel_kept_view, locale)

    %{view: confirmed_view} = setup_cancel_confirmed_view(conn, profile, meeting, locale)
    test_cancel_confirmed_translations(confirmed_view, locale)

    %{view: reschedule_view} = setup_reschedule_view(conn, profile, meeting, locale)
    test_reschedule_translations(reschedule_view, locale)
  end

  # German translations for each page — German is the test locale because
  # its strings are visually distinct from English in every case.

  defp translated_cancel_confirmed_strings("de") do
    %{
      meeting_cancelled: "Termin abgesagt",
      successfully_cancelled: "Ihr Termin wurde erfolgreich abgesagt.",
      cancellation_emails_sent: "Die Absage-E-Mails wurden an alle Teilnehmer versendet."
    }
  end

  defp translated_cancel_kept_strings("de") do
    %{
      meeting_confirmed: "Termin bestätigt",
      still_scheduled: "Großartig! Ihr Termin findet weiterhin wie geplant statt.",
      look_forward: "Wir freuen uns, Sie zur geplanten Zeit zu begrüßen.",
      done: "Fertig"
    }
  end

  defp translated_cancel_strings("de") do
    %{
      cancel_appointment: "Termin absagen",
      are_you_sure: "Sind Sie sicher, dass Sie diesen Termin absagen möchten?",
      cancellation_email_warning: "Eine Absage-E-Mail wird an alle Teilnehmer gesendet",
      yes_cancel: "Ja, Termin absagen",
      keep_meeting: "Termin beibehalten"
    }
  end

  defp translated_reschedule_strings("de") do
    %{
      reschedule_appointment: "Termin verschieben",
      select_new_time: "Wählen Sie eine neue Zeit für Ihren Termin"
    }
  end
end
