defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSendingToggleTest do
  @moduledoc "Exercises SMTP setup disclosure, activation boundaries and platform switching."

  use TymeslotWeb.LiveCase, async: false

  @moduletag :emails
  @moduletag :live
  @moduletag :security

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.EmailSendingTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Settings
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Repo

  @attrs %{
    "host" => "smtp.example.com",
    "security" => "starttls",
    "username" => "toggle-fixture-account",
    "password" => "toggle-fixture-secret",
    "from_address" => "bookings@example.com",
    "from_name" => "Appointments"
  }

  setup :setup_dashboard_user

  setup do
    with_config(:tymeslot, user_smtp_enabled: true)
    :ok
  end

  test "requires authentication before settings can be reached" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/dashboard/settings")
    assert path =~ "/auth/"
  end

  test "hides the section when deployment has not enabled the feature", %{conn: conn} do
    with_config(:tymeslot, user_smtp_enabled: false)
    {:ok, view, html} = live(conn, ~p"/dashboard/settings")
    refute html =~ "user-smtp-form"
    refute has_element?(view, "#email-sending-settings")
  end

  test "the SMTP section follows the user's supported dashboard language", context do
    context.user |> Changeset.change(locale: "de") |> Repo.update!()
    {:ok, _view, html} = open_smtp_settings(context.conn)

    translated =
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_email_sending", "Email sending")
      end)

    refute translated == "Email sending"
    assert html =~ translated
  end

  test "the platform sender starts with a named switch and no SMTP configuration", context do
    {:ok, view, html} = live(context.conn, ~p"/dashboard/settings")
    assert html =~ "Use custom sending email"
    refute html =~ "Using platform sender"

    assert has_element?(
             view,
             "#use-custom-smtp[role='switch'][aria-checked='false']"
           )

    refute has_element?(view, "#smtp-custom-settings")
    refute has_element?(view, "#user-smtp-form")
    refute has_element?(view, "#smtp-enable")

    html = view |> element("#use-custom-smtp") |> render_click()
    assert has_element?(view, "#use-custom-smtp[aria-checked='true']")
    assert has_element?(view, "#user-smtp-form")
    assert html =~ "Test and save your SMTP settings to activate this sending identity."
    assert {:error, :not_found} = EmailSending.get_settings(context.user)

    view |> element("#use-custom-smtp") |> render_click()
    refute has_element?(view, "#user-smtp-form")
    assert has_element?(view, "#use-custom-smtp[aria-checked='false']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "closed setup rejects form submissions and picker events", context do
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{
      "smtp" => Map.put(@attrs, "host", "127.0.0.1")
    })

    view
    |> with_target("#email-sending-settings")
    |> render_change("validate_smtp", %{"smtp" => @attrs})

    view
    |> with_target("#email-sending-settings")
    |> render_click("toggle_smtp_security_dropdown")

    refute has_element?(view, "#user-smtp-form")
    refute has_element?(view, "#smtp-error")
    assert has_element?(view, "#use-custom-smtp[aria-checked='false']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "saved disabled settings stay collapsed and opening setup does not activate them",
       context do
    original = saved_smtp_settings(context.user, @attrs)
    {:ok, view, html} = live(context.conn, ~p"/dashboard/settings")
    refute has_element?(view, "#user-smtp-form")
    refute html =~ @attrs["host"]
    refute html =~ @attrs["password"]

    view |> with_target("#email-sending-settings") |> render_click("enable_smtp")
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert Settings.version(current) == {original.id, original.revision}

    html = view |> element("#use-custom-smtp") |> render_click()
    assert has_element?(view, "#smtp-host[value='smtp.example.com']")
    assert has_element?(view, "input[name='smtp[username]'][value='']")
    assert has_element?(view, "input[name='smtp[password]'][value='']")
    refute html =~ @attrs["username"]
    refute html =~ @attrs["password"]
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled

    refute has_element?(view, "#smtp-enable")
    view |> with_target("#email-sending-settings") |> render_click("enable_smtp")
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert Settings.version(current) == {original.id, original.revision}
  end

  test "closing disabled setup discards unsaved values and retains its stored identity",
       context do
    original = saved_smtp_settings(context.user, @attrs)
    {:ok, view, _html} = open_smtp_settings(context.conn)

    view
    |> form("#user-smtp-form", smtp: Map.put(@attrs, "from_name", "Unsaved edit"))
    |> render_change()

    view |> element("#use-custom-smtp") |> render_click()
    refute has_element?(view, "#user-smtp-form")
    row = Repo.get!(UserSmtpSettingsSchema, original.id)
    assert row.revision == original.revision + 1
    assert row.tested_revision == row.revision
    assert row.username_encrypted == original.username_encrypted
    assert row.password_encrypted == original.password_encrypted

    html = view |> element("#use-custom-smtp") |> render_click()
    assert has_element?(view, "#smtp-from-name[value='Appointments']")
    refute html =~ "Unsaved edit"
    refute html =~ @attrs["password"]
  end

  test "switching off an enabled identity disables sending while retaining encrypted settings",
       context do
    original = saved_smtp_settings(context.user, @attrs, enabled: true)
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")
    assert has_element?(view, "#use-custom-smtp[aria-checked='true']")
    assert has_element?(view, "#user-smtp-form")

    view |> element("#use-custom-smtp") |> render_click()
    assert has_element?(view, "#use-custom-smtp[aria-checked='false']")
    refute has_element?(view, "#user-smtp-form")
    row = Repo.get!(UserSmtpSettingsSchema, original.id)
    refute row.enabled
    assert row.revision == original.revision + 1
    assert row.username_encrypted == original.username_encrypted
    assert row.password_encrypted == original.password_encrypted
  end

  test "a stale switch-off leaves the current enabled identity visible", context do
    original = saved_smtp_settings(context.user, @attrs, enabled: true)
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    {:ok, disabled} =
      EmailSending.disable_settings(context.user, {original.id, original.revision})

    {:ok, current} = EmailSending.enable_settings(context.user, Settings.version(disabled))

    view |> element("#use-custom-smtp") |> render_click()
    assert has_element?(view, "#use-custom-smtp[aria-checked='true']")
    assert has_element?(view, "#user-smtp-form")
    assert has_element?(view, "#smtp-error[role='alert']")
    {:ok, after_attempt} = EmailSending.get_settings(context.user)
    assert after_attempt.enabled
    assert Settings.version(after_attempt) == Settings.version(current)
  end

  test "a disabled snapshot cannot hide an identity another tab has enabled", context do
    original = saved_smtp_settings(context.user, @attrs)
    {:ok, view, _html} = open_smtp_settings(context.conn)
    {:ok, current} = EmailSending.enable_settings(context.user, {original.id, original.revision})

    view |> element("#use-custom-smtp") |> render_click()

    assert has_element?(view, "#use-custom-smtp[aria-checked='true']")
    assert has_element?(view, "#user-smtp-form")
    assert has_element?(view, "#smtp-error[role='alert']")
    {:ok, after_attempt} = EmailSending.get_settings(context.user)
    assert after_attempt.enabled
    assert Settings.version(after_attempt) == Settings.version(current)
  end

  test "an empty snapshot cannot hide an identity another tab has created and enabled", context do
    {:ok, view, _html} = open_smtp_settings(context.conn)
    current = saved_smtp_settings(context.user, @attrs, enabled: true)

    view |> element("#use-custom-smtp") |> render_click()

    assert has_element?(view, "#use-custom-smtp[aria-checked='true']")
    assert has_element?(view, "#user-smtp-form")
    assert has_element?(view, "#smtp-error[role='alert']")
    {:ok, after_attempt} = EmailSending.get_settings(context.user)
    assert after_attempt.enabled
    assert Settings.version(after_attempt) == {current.id, current.revision}
  end
end
