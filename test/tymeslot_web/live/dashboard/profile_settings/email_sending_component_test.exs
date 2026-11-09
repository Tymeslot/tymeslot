defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSendingComponentTest do
  @moduledoc """
  Exercises the authenticated SMTP settings flow through real TLS and SMTP.

  Only CA trust and DNS endpoints are substituted. Settings validation,
  asynchronous testing, version checks, activation and booking delivery use
  their production boundaries; the relay never sends to a real mailbox.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :live
  @moduletag :security

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Settings
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.FakeSmtpRelay
  alias Tymeslot.Workers.EmailWorker

  @attrs %{
    "host" => "smtp.example.com",
    "port" => "587",
    "security" => "starttls",
    "username" => "smtp-owner-account",
    "password" => "smtp-password-secret",
    "from_address" => "bookings@brand.example.com",
    "from_name" => "Brand appointments"
  }

  defmodule Destination do
    @moduledoc false
    @behaviour Tymeslot.EmailSending.Destination

    @impl Tymeslot.EmailSending.Destination
    def resolve(_host, _port) do
      {:ok,
       %{
         address: {127, 0, 0, 1},
         port: Application.fetch_env!(:tymeslot, :smtp_settings_test_port)
       }}
    end
  end

  setup_all do
    %{certificates: FakeSmtpRelay.certificates(~c"smtp.example.com")}
  end

  setup :setup_dashboard_user

  setup %{certificates: certificates} do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      user_smtp_destination_module: Destination,
      user_smtp_cacertfile: certificates.cacertfile,
      email_service_module: Tymeslot.Emails.EmailService
    )

    with_config(:swoosh, shared_test_process: self())
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

  test "a test/save, activation and real booking use the configured identity", context do
    use_relay(context.certificates, auth_users: credentials())
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")
    assert_state(view, "platform")

    html = save(view)
    assert_state(view, "disabled")
    assert html =~ "accepted"
    assert html =~ context.user.email
    refute_secrets(html)

    test_message = message()
    assert test_message =~ context.user.email
    assert test_message =~ "bookings@brand.example.com"

    {:ok, settings} = EmailSending.get_settings(context.user)
    refute settings.enabled

    view |> element("#smtp-enable") |> render_click()
    assert_state(view, "enabled")

    meeting =
      insert(:meeting,
        organizer_user_id: context.user.id,
        organizer_email: context.user.email
      )

    job =
      %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      |> EmailWorker.new()
      |> Oban.insert!()

    assert :ok = EmailWorker.perform(%{job | attempt: 1})
    assert message() =~ ~r/^From:.*bookings@brand.example.com/m
    assert message() =~ ~r/^From:.*bookings@brand.example.com/m

    view |> element("#smtp-use-platform") |> render_click()
    assert_state(view, "disabled")

    platform_meeting =
      insert(:meeting,
        organizer_user_id: context.user.id,
        organizer_email: context.user.email,
        start_time: DateTime.add(meeting.start_time, 2, :hour),
        end_time: DateTime.add(meeting.end_time, 2, :hour)
      )

    assert :ok =
             EmailWorker.perform(%Oban.Job{
               args: %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => platform_meeting.id
               },
               attempt: 1
             })

    platform_from = Application.fetch_env!(:tymeslot, :email)[:from_email]
    assert_receive {:email, organizer}
    assert_receive {:email, attendee}
    assert elem(organizer.from, 1) == platform_from
    assert elem(attendee.from, 1) == platform_from
    refute_received {:smtp_relay, {:message, _unexpected}}
  end

  test "saved credentials are blank in HTML and remain usable for blank edits", context do
    original = saved(context.user)
    use_relay(context.certificates, auth_users: credentials())
    {:ok, view, html} = live(context.conn, ~p"/dashboard/settings")
    refute_secrets(html)

    html =
      save(view, %{
        "username" => "",
        "password" => "",
        "from_name" => "Updated appointments"
      })

    refute_secrets(html)
    {:ok, current} = EmailSending.get_settings(context.user)
    assert current.from_name == "Updated appointments"
    assert current.revision == original.revision + 1

    row = Repo.get!(UserSmtpSettingsSchema, current.id)
    assert Encryption.decrypt(row.username_encrypted) == @attrs["username"]
    assert Encryption.decrypt(row.password_encrypted) == @attrs["password"]
  end

  test "validation reports invalid settings without reflecting submitted credentials", context do
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    html =
      view
      |> with_target("#email-sending-settings")
      |> render_submit("test_and_save_smtp", %{
        "smtp" => Map.merge(@attrs, %{"host" => "127.0.0.1", "port" => "25"})
      })

    refute_secrets(html)
    assert has_element?(view, "[aria-invalid='true']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    refute_received {:smtp_relay, _event}
  end

  test "an async failure is sanitized and preserves the active configuration", context do
    original = saved(context.user, enabled: true)

    use_relay(context.certificates,
      rcpt_reply: "553 5.7.1 smtp-password-secret provider-internal-detail"
    )

    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    log =
      capture_log(fn ->
        html = save(view, %{"from_name" => "Rejected replacement"})
        refute_secrets(html)
        refute html =~ "provider-internal-detail"
        assert has_element?(view, "[role='alert']")
      end)

    refute log =~ "smtp-password-secret"
    refute log =~ "provider-internal-detail"
    {:ok, after_failure} = EmailSending.get_settings(context.user)
    assert Settings.version(after_failure) == {original.id, original.revision}
    assert after_failure.enabled
    assert after_failure.from_name == original.from_name
  end

  test "the form stays responsive and rejects a duplicate submission while testing", context do
    reference = make_ref()
    use_relay(context.certificates, after_data: {:await, reference})
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    view |> form("#user-smtp-form", smtp: @attrs) |> render_submit()
    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 5_000
    on_exit(fn -> send(relay, {:ack, reference}) end)

    assert_state(view, "testing")
    refute_secrets(render(view))
    retained_state = :erlang.term_to_binary(:sys.get_state(view.pid))
    refute retained_state =~ @attrs["password"]
    refute retained_state =~ @attrs["username"]

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{"smtp" => @attrs})

    assert_state(view, "testing")
    refute_received {:smtp_relay, {:awaiting_ack, _duplicate, _reference}}
    assert {:error, :not_found} = EmailSending.get_settings(context.user)

    send(relay, {:ack, reference})
    render_async(view, 5_000)
    assert_state(view, "disabled")
  end

  test "a concurrent disable invalidates a test in flight instead of replacing settings",
       context do
    original = saved(context.user, enabled: true)
    reference = make_ref()
    use_relay(context.certificates, after_data: {:await, reference})
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    view
    |> form("#user-smtp-form", smtp: Map.put(@attrs, "from_name", "Stale replacement"))
    |> render_submit()

    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 5_000
    on_exit(fn -> send(relay, {:ack, reference}) end)

    assert {:ok, disabled} =
             EmailSending.disable_settings(context.user, {original.id, original.revision})

    send(relay, {:ack, reference})
    html = render_async(view, 5_000)
    assert has_element?(view, "[role='alert']")
    refute_secrets(html)

    {:ok, current} = EmailSending.get_settings(context.user)
    assert Settings.version(current) == Settings.version(disabled)
    refute current.enabled
    assert current.from_name == original.from_name
  end

  test "a stale tab cannot enable a newer configuration", context do
    original = saved(context.user)
    {:ok, first, _html} = live(context.conn, ~p"/dashboard/settings")
    {:ok, second, _html} = live(context.conn, ~p"/dashboard/settings")

    first |> element("#smtp-enable") |> render_click()
    first |> element("#smtp-use-platform") |> render_click()
    second |> element("#smtp-enable") |> render_click()

    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert current.revision == original.revision + 2
    assert has_element?(second, "[role='alert']")
  end

  test "edited form values must be tested before activation", context do
    saved(context.user)
    use_relay(context.certificates, auth_users: credentials())
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")
    edits = Map.put(@attrs, "from_name", "Untested form edits")
    view |> form("#user-smtp-form", smtp: edits) |> render_change()
    assert has_element?(view, "#smtp-enable[disabled]")

    view |> with_target("#email-sending-settings") |> render_click("enable_smtp")
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert current.from_name == @attrs["from_name"]

    save(view, edits)
    view |> element("#smtp-enable") |> render_click()
    {:ok, current} = EmailSending.get_settings(context.user)
    assert current.enabled
    assert current.from_name == "Untested form edits"
  end

  test "client-provided owner, row and revision never select another account", context do
    own = saved(context.user)
    foreign = saved(insert(:user), from_name: "Foreign owner")
    {:ok, view, html} = live(context.conn, ~p"/dashboard/settings")
    refute html =~ "Foreign owner"

    view
    |> with_target("#email-sending-settings")
    |> render_click("enable_smtp", %{
      "user_id" => foreign.user_id,
      "id" => foreign.id,
      "revision" => foreign.revision
    })

    assert Repo.get!(UserSmtpSettingsSchema, own.id).enabled
    refute Repo.get!(UserSmtpSettingsSchema, foreign.id).enabled
  end

  test "deletion requires confirmation and removes the saved identity", context do
    saved(context.user)
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")
    view |> with_target("#email-sending-settings") |> render_click("delete_smtp")
    assert {:ok, _still_saved} = EmailSending.get_settings(context.user)

    view |> element("#smtp-delete") |> render_click()
    assert has_element?(view, "#smtp-delete-confirm")

    view
    |> with_target("#email-sending-settings")
    |> render_click("cancel_delete_smtp")

    refute has_element?(view, "#smtp-delete-confirm")
    assert {:ok, _still_saved} = EmailSending.get_settings(context.user)

    view |> element("#smtp-delete") |> render_click()
    view |> element("#smtp-delete-confirm") |> render_click()
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    assert_state(view, "platform")
  end

  test "a stale deletion cannot remove settings recreated by another tab", context do
    original = saved(context.user)
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")
    view |> element("#smtp-delete") |> render_click()
    :ok = EmailSending.delete_settings(context.user, {original.id, original.revision})
    replacement = saved(context.user, from_name: "Recreated identity")

    view |> element("#smtp-delete-confirm") |> render_click()
    assert has_element?(view, "[role='alert']")
    {:ok, current} = EmailSending.get_settings(context.user)
    assert current.id == replacement.id
    assert current.from_name == "Recreated identity"
  end

  test "a forged mutation is rejected after feature disablement", context do
    saved(context.user)
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")
    with_config(:tymeslot, user_smtp_enabled: false)

    view
    |> with_target("#email-sending-settings")
    |> render_click("enable_smtp")

    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
  end

  test "exhausted test-send budget is shown without opening a connection", context do
    for _attempt <- 1..5, do: :ok = RateLimiter.consume(:user_smtp_test, context.user.id, 1)
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")
    html = save(view)
    assert has_element?(view, "[role='alert']")
    refute_secrets(html)
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    refute_received {:smtp_relay, _event}
  end

  test "an account unverified after mount cannot receive a test message", context do
    use_relay(context.certificates)
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")
    context.user |> Changeset.change(verified_at: nil) |> Repo.update!()
    save(view)
    assert has_element?(view, "[role='alert']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    refute_received {:smtp_relay, _event}
  end

  test "broken custom SMTP shows attention but password recovery uses the platform", context do
    saved(context.user, enabled: true)
    use_relay(context.certificates, auth: :reject)

    meeting =
      insert(:meeting,
        organizer_user_id: context.user.id,
        organizer_email: context.user.email,
        status: :cancelled
      )

    job =
      %{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}
      |> EmailWorker.new()
      |> Oban.insert!()

    assert {:error, _failure} = EmailWorker.perform(%{job | attempt: 1})
    {:ok, view, html} = live(context.conn, ~p"/dashboard/settings")
    assert_state(view, "attention")
    refute_secrets(html)

    {:ok, auth, _html} = live(build_conn(), ~p"/auth/reset-password")
    auth |> form("#reset-password-form", email: context.user.email) |> render_submit()
    assert_patch(auth, ~p"/auth/reset-password-sent")

    [reset_job] =
      all_enqueued(worker: EmailWorker, args: %{"action" => "send_password_reset"})

    assert :ok = EmailWorker.perform(%{reset_job | attempt: 1})
    assert_receive {:email, reset_email}
    assert Enum.map(reset_email.to, &elem(&1, 1)) == [context.user.email]
    assert elem(reset_email.from, 1) == Application.fetch_env!(:tymeslot, :email)[:from_email]
    refute_received {:smtp_relay, {:message, _unexpected}}
  end

  test "using the platform sender cancels a pending replacement test", context do
    original = saved(context.user, enabled: true)
    reference = make_ref()
    use_relay(context.certificates, after_data: {:await, reference})
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    view
    |> form("#user-smtp-form", smtp: Map.put(@attrs, "from_name", "Cancelled replacement"))
    |> render_submit()

    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 5_000
    on_exit(fn -> send(relay, {:ack, reference}) end)
    view |> element("#smtp-use-platform") |> render_click()
    send(relay, {:ack, reference})
    render_async(view, 5_000)
    assert_state(view, "disabled")
    refute has_element?(view, "#smtp-error")

    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert current.revision == original.revision + 1
    assert current.from_name == original.from_name
  end

  test "an invalid submission without a change event still blocks activation", context do
    saved(context.user)
    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{
      "smtp" => Map.put(@attrs, "host", "127.0.0.1")
    })

    assert has_element?(view, "#smtp-enable[disabled]")
    view |> with_target("#email-sending-settings") |> render_click("enable_smtp")
    {:ok, settings} = EmailSending.get_settings(context.user)
    refute settings.enabled
  end

  test "unknown historical status never exposes a stored provider reply", context do
    saved(context.user,
      enabled: true,
      last_error: "provider-internal-detail smtp-password-secret",
      last_failed_at: DateTime.utc_now()
    )

    {:ok, view, html} = live(context.conn, ~p"/dashboard/settings")
    assert_state(view, "attention")
    refute_secrets(html)
    refute html =~ "provider-internal-detail"
  end

  test "the SMTP section follows the user's supported dashboard language", context do
    context.user |> Changeset.change(locale: "de") |> Repo.update!()
    {:ok, _view, html} = live(context.conn, ~p"/dashboard/settings")

    translated =
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_email_sending", "Email sending")
      end)

    refute translated == "Email sending"
    assert html =~ translated
  end

  test "selecting implicit TLS pairs port 465 and tests the encrypted connection", context do
    use_relay(context.certificates,
      implicit_tls: context.certificates,
      auth_users: credentials()
    )

    {:ok, view, _html} = live(context.conn, ~p"/dashboard/settings")

    view
    |> with_target("#email-sending-settings")
    |> render_change("validate_smtp", %{
      "smtp" => Map.put(@attrs, "security", "implicit_tls"),
      "_target" => ["smtp", "security"]
    })

    assert has_element?(view, "#smtp-port option[value='465'][selected]")
    save(view, %{"port" => "465", "security" => "implicit_tls"})
    assert_state(view, "disabled")
    {:ok, settings} = EmailSending.get_settings(context.user)
    assert settings.port == 465
    assert settings.security == :implicit_tls
    assert_receive {:smtp_relay, {:tls_up, _information}}
  end

  defp saved(user, overrides \\ []) do
    attrs = %{
      user_id: user.id,
      host: @attrs["host"],
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt(@attrs["username"]),
      password_encrypted: Encryption.encrypt(@attrs["password"]),
      from_address: @attrs["from_address"],
      from_name: @attrs["from_name"],
      enabled: false,
      revision: 1,
      tested_revision: 1,
      tested_at: DateTime.utc_now()
    }

    Repo.insert!(struct!(UserSmtpSettingsSchema, Map.merge(attrs, Map.new(overrides))))
  end

  defp save(view, overrides \\ %{}) do
    view
    |> form("#user-smtp-form", smtp: Map.merge(@attrs, overrides))
    |> render_submit()

    render_async(view, 5_000)
  end

  defp use_relay(certificates, opts \\ []) do
    relay = FakeSmtpRelay.start(Keyword.put(opts, :starttls, certificates))
    with_config(:tymeslot, smtp_settings_test_port: relay.port)
  end

  defp credentials, do: %{@attrs["username"] => @attrs["password"]}

  defp message do
    assert_receive {:smtp_relay, {:message, body}}, 5_000
    body
  end

  defp assert_state(view, state),
    do: assert(has_element?(view, "#smtp-status[data-state='#{state}']"))

  defp refute_secrets(html) do
    refute html =~ @attrs["username"]
    refute html =~ @attrs["password"]
    refute html =~ "username_encrypted"
    refute html =~ "password_encrypted"
  end
end
