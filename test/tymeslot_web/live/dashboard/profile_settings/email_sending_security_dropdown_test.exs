defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSendingSecurityDropdownTest do
  @moduledoc """
  Exercises the single SMTP connection-security picker without sending mail.

  The browser submits only a security mode; the server derives its SMTP port.
  SMTP delivery and persistence are covered by EmailSendingComponentTest.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :emails
  @moduletag :live

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.EmailSendingTestHelpers

  alias Tymeslot.EmailSending

  @attrs %{
    "host" => "smtp.example.com",
    "security" => "starttls",
    "username" => "security-picker-account",
    "password" => "security-picker-secret",
    "from_address" => "bookings@example.com",
    "from_name" => "Appointments"
  }

  setup :setup_dashboard_user

  setup do
    with_config(:tymeslot, user_smtp_enabled: true)
    :ok
  end

  test "one connection-security picker replaces separate port and TLS controls", context do
    {:ok, view, _html} = open_smtp_settings(context.conn)
    assert has_element?(view, "label[for='smtp-security-trigger']", "Connection security")

    assert has_element?(
             view,
             "#smtp-security-trigger[aria-expanded='false'][aria-haspopup='dialog']"
           )

    assert has_element?(
             view,
             "#smtp-security[type='hidden'][name='smtp[security]'][value='starttls']"
           )

    assert has_element?(view, "#smtp-security-value", "Required STARTTLS (port 587)")
    refute has_element?(view, "[name='smtp[port]']")
    refute has_element?(view, "#smtp-port-trigger")

    view |> element("#smtp-security-trigger") |> render_click()

    assert has_element?(view, "#smtp-security-trigger[aria-expanded='true']")

    assert has_element?(
             view,
             "#smtp-security-dropdown-panel.brand-card[role='dialog'][aria-label='Connection security']"
           )

    assert has_element?(view, "#smtp-security-option-starttls[type='radio'][checked]")
    assert has_element?(view, "#smtp-security-option-implicit_tls[type='radio']")
    refute has_element?(view, "#smtp-security-option-implicit_tls[checked]")
    refute has_element?(view, "[name='smtp[port]']")

    view |> element("#smtp-security-dropdown") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#smtp-security-dropdown-panel")
    assert_push_event(view, "focus", %{id: "smtp-security-trigger"})

    view |> element("#smtp-security-trigger") |> render_click()
    view |> element("#smtp-security-option-starttls") |> render_click()
    refute has_element?(view, "#smtp-security-dropdown-panel")
    assert_push_event(view, "focus", %{id: "smtp-security-trigger"})

    view |> element("#smtp-security-trigger") |> render_click()

    assert has_element?(
             view,
             "#smtp-security-dropdown[phx-click-away='close_smtp_security_dropdown']"
           )

    view |> with_target("#email-sending-settings") |> render_click("close_smtp_security_dropdown")
    refute has_element?(view, "#smtp-security-dropdown-panel")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "mode choices validate without submitting a port, retaining credentials or saving",
       context do
    {:ok, view, _html} = open_smtp_settings(context.conn)

    for {mode, label} <- [
          {"implicit_tls", "Implicit TLS (port 465)"},
          {"starttls", "Required STARTTLS (port 587)"}
        ] do
      view |> element("#smtp-security-trigger") |> render_click()

      html =
        view
        |> form("#user-smtp-form", smtp: Map.put(@attrs, "security", mode))
        |> render_change(%{"_target" => ["smtp", "security"]})

      assert has_element?(view, "#smtp-security[value='#{mode}']")
      assert has_element?(view, "#smtp-security-value", label)
      refute has_element?(view, "[name='smtp[port]']")
      refute has_element?(view, "#smtp-security-dropdown-panel")
      assert_push_event(view, "focus", %{id: "smtp-security-trigger"})
      refute html =~ @attrs["username"]
      refute html =~ @attrs["password"]
    end

    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "an invalid mode is rejected and correcting it clears security and derived-port errors",
       context do
    {:ok, view, _html} = open_smtp_settings(context.conn)

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{
      "smtp" => Map.merge(@attrs, %{"security" => "none", "port" => "587"})
    })

    assert has_element?(
             view,
             "#smtp-security-trigger[aria-invalid='true'][aria-describedby='smtp-security-error']"
           )

    assert has_element?(view, "#smtp-security-error[role='alert']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    view |> element("#smtp-security-trigger") |> render_click()

    view
    |> form("#user-smtp-form", smtp: Map.put(@attrs, "security", "implicit_tls"))
    |> render_change(%{"_target" => ["smtp", "security"]})

    refute has_element?(view, "#smtp-security-trigger[aria-invalid]")
    refute has_element?(view, "#smtp-security-error")
    assert has_element?(view, "#smtp-security[value='implicit_tls']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end
end
