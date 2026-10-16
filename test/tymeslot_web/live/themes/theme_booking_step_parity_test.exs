defmodule TymeslotWeb.Live.Themes.ThemeBookingStepParityTest do
  @moduledoc """
  Behaviour every theme's steps share, whatever they look like: choosing the
  meeting type already chosen keeps it chosen, and the booking form marks the
  name and the email as required while leaving empty fields to its own
  messages, and it carries the honeypot and the reCAPTCHA hook, token and
  notice.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

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

  @duration_option "button[data-testid='duration-option']"

  for theme <- ThemeTestMatrix.all() do
    @tag :capture_log
    test "theme #{theme.slug}: choosing the chosen meeting type again keeps it chosen",
         %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "reselect-#{unquote(theme.slug)}", "Etc/UTC")

      {:ok, view, _html} = live(conn, "/#{profile.username}")

      view |> element(@duration_option) |> render_click()
      view |> element(@duration_option) |> render_click()

      assert has_element?(view, "button[data-testid='next-step']")
      refute has_element?(view, "button[data-testid='next-step'][disabled]")
    end

    @tag :capture_log
    test "theme #{theme.slug}: the booking form requires a name and an email", %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "required-#{unquote(theme.slug)}", "Etc/UTC")

      view = navigate_to_booking_form(conn, profile, nil)

      assert has_element?(view, "label[for='booking-form_name'] span.text-red-500")
      assert has_element?(view, "label[for='booking-form_email'] span.text-red-500")

      # The attribute on the control is what assistive technology reads; the
      # `*` above is only the sighted cue.
      assert has_element?(view, "input#booking-form_name[required]")
      assert has_element?(view, "input#booking-form_email[required]")

      # The form answers an empty field with its own message, so the browser
      # must not block the submit first.
      assert has_element?(view, "form#booking-form[novalidate]")
    end

    @tag :capture_log
    test "theme #{theme.slug}: the booking form carries the anti-spam fields", %{conn: conn} do
      old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
      old_env = Map.new(~w(RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY), &{&1, System.get_env(&1)})

      on_exit(fn ->
        Application.put_env(:tymeslot, :recaptcha, old_cfg)

        Enum.each(old_env, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      Application.put_env(:tymeslot, :recaptcha,
        booking_enabled: true,
        booking_action: "booking_form"
      )

      System.put_env("RECAPTCHA_SITE_KEY", "test_site_key")
      System.put_env("RECAPTCHA_SECRET_KEY", "test_secret_key")

      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "antispam-#{unquote(theme.slug)}", "Etc/UTC")

      view = navigate_to_booking_form(conn, profile, nil)

      assert has_element?(view, "form#booking-form input[name='booking[website]']")
      assert has_element?(view, "form#booking-form[phx-hook='RecaptchaV3']")
      assert has_element?(view, "form#booking-form input[name='booking[g-recaptcha-response]']")
      assert has_element?(view, ".recaptcha-notice")
    end
  end
end
