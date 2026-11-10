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
  import Tymeslot.EmailSendingTestHelpers
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
  alias TymeslotWeb.Dashboard.ProfileSettings.EmailSending.ErrorMessages

  @attrs %{
    "host" => "smtp.example.com",
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

  test "test/save activates the configured identity for the next real booking", context do
    use_relay(context.certificates, auth_users: credentials())
    {:ok, view, html} = open_smtp_settings(context.conn)
    assert_state(view, "platform")
    assert html =~ "dashboard calendar invitations, updates and cancellations"
    assert html =~ "booking refund notices also use your SMTP identity"
    assert html =~ "Integration health, dispute and payout notices use the platform sender"

    html = save(view)
    assert_state(view, "enabled")
    assert html =~ "accepted"
    assert html =~ context.user.email
    refute_secrets(html)

    assert has_element?(
             view,
             "#app-flash-group-info",
             "SMTP connection healthy. Settings saved and active."
           )

    refute has_element?(view, "#app-flash-group-error")

    test_message = message()
    assert test_message =~ context.user.email
    assert test_message =~ "bookings@brand.example.com"

    {:ok, settings} = EmailSending.get_settings(context.user)
    assert settings.enabled
    assert settings.tested_revision == settings.revision
    refute has_element?(view, "#smtp-enable")

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

    view |> element("#use-custom-smtp") |> render_click()
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
    {:ok, view, html} = open_smtp_settings(context.conn)
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
    assert current.enabled
    assert current.revision > original.revision
    assert current.tested_revision == current.revision

    row = Repo.get!(UserSmtpSettingsSchema, current.id)
    assert Encryption.decrypt(row.username_encrypted) == @attrs["username"]
    assert Encryption.decrypt(row.password_encrypted) == @attrs["password"]
  end

  test "validation reports invalid settings without reflecting submitted credentials", context do
    {:ok, view, initial_html} = open_smtp_settings(context.conn)
    initial_ids = credential_ids(initial_html)

    html =
      view
      |> with_target("#email-sending-settings")
      |> render_submit("test_and_save_smtp", %{
        "smtp" => Map.merge(@attrs, %{"host" => "127.0.0.1", "port" => "25"})
      })

    refute_secrets(html)
    assert Enum.all?(initial_ids, &(not has_element?(view, "##{&1}")))
    assert length(credential_ids(html)) == 2
    assert has_element?(view, "[aria-invalid='true']")
    assert has_element?(view, "#app-flash-group-error", ErrorMessages.message(:invalid_settings))
    refute has_element?(view, "#app-flash-group-info")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    refute_received {:smtp_relay, _event}
  end

  test "public field validation keeps browser credential inputs stable without retaining secrets",
       context do
    {:ok, view, initial_html} = open_smtp_settings(context.conn)
    initial_ids = credential_ids(initial_html)
    assert length(initial_ids) == 2

    for field <- ~w(from_address from_name host security) do
      html =
        view
        |> with_target("#email-sending-settings")
        |> render_change("validate_smtp", %{
          "smtp" => @attrs,
          "_target" => ["smtp", field]
        })

      assert credential_ids(html) == initial_ids
      refute has_element?(view, "#app-flash-group-error")
      refute has_element?(view, "#app-flash-group-info")
      assert has_element?(view, "#smtp-from-address[value='#{@attrs["from_address"]}']")
      assert has_element?(view, "input[name='smtp[username]'][value='']")
      assert has_element?(view, "input[name='smtp[password]'][value='']")
      refute_secrets(html)
      retained_state = :erlang.term_to_binary(:sys.get_state(view.pid))
      refute retained_state =~ @attrs["username"]
      refute retained_state =~ @attrs["password"]
    end

    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    refute_received {:smtp_relay, _event}
  end

  test "an async failure is sanitized and preserves the active configuration", context do
    original = saved(context.user, enabled: true)

    use_relay(context.certificates,
      rcpt_reply: "553 5.7.1 smtp-password-secret provider-internal-detail"
    )

    {:ok, view, _html} = open_smtp_settings(context.conn)

    log =
      capture_log(fn ->
        html = save(view, %{"from_name" => "Rejected replacement"})
        refute_secrets(html)
        refute html =~ "provider-internal-detail"

        assert has_element?(
                 view,
                 "#app-flash-group-error",
                 ErrorMessages.message(:recipient_rejected)
               )

        refute has_element?(view, "#app-flash-group-info")
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
    {:ok, view, initial_html} = open_smtp_settings(context.conn)
    initial_ids = credential_ids(initial_html)

    view |> element("#smtp-security-trigger") |> render_click()
    assert has_element?(view, "#smtp-security-dropdown-panel")

    view |> form("#user-smtp-form", smtp: @attrs) |> render_submit()
    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 5_000
    on_exit(fn -> send(relay, {:ack, reference}) end)

    assert_state(view, "testing")
    refute has_element?(view, "#app-flash-group-info")
    refute has_element?(view, "#app-flash-group-error")
    assert Enum.all?(initial_ids, &(not has_element?(view, "##{&1}")))
    assert has_element?(view, "#user-smtp-form fieldset[disabled]")
    refute has_element?(view, "#smtp-security-dropdown-panel")

    view
    |> with_target("#email-sending-settings")
    |> render_click("toggle_smtp_security_dropdown")

    refute has_element?(view, "#smtp-security-dropdown-panel")

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
    assert_state(view, "enabled")
  end

  test "switching off cancels an initial test without saving an identity", context do
    reference = make_ref()
    use_relay(context.certificates, after_data: {:await, reference})
    {:ok, view, _html} = open_smtp_settings(context.conn)
    view |> form("#user-smtp-form", smtp: @attrs) |> render_submit()
    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 5_000
    on_exit(fn -> send(relay, {:ack, reference}) end)
    view |> element("#use-custom-smtp") |> render_click()
    assert has_element?(view, "#use-custom-smtp[aria-checked='false']")
    refute has_element?(view, "#user-smtp-form")
    send(relay, {:ack, reference})
    render_async(view, 5_000)
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    refute has_element?(view, "#smtp-error")
    refute has_element?(view, "#app-flash-group-info")
    refute has_element?(view, "#app-flash-group-error")
  end

  test "a concurrent disable invalidates a test in flight instead of replacing settings",
       context do
    original = saved(context.user, enabled: true)
    reference = make_ref()
    use_relay(context.certificates, after_data: {:await, reference})
    {:ok, view, _html} = open_smtp_settings(context.conn)

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
    assert has_element?(view, "#app-flash-group-error", ErrorMessages.message(:stale))
    refute has_element?(view, "#app-flash-group-info")
    refute_secrets(html)

    {:ok, current} = EmailSending.get_settings(context.user)
    assert Settings.version(current) == Settings.version(disabled)
    refute current.enabled
    assert current.from_name == original.from_name
  end

  test "a stale test/save cannot reactivate a configuration disabled in another tab", context do
    saved(context.user)
    use_relay(context.certificates, auth_users: credentials())
    {:ok, first, _html} = open_smtp_settings(context.conn)
    {:ok, second, _html} = open_smtp_settings(context.conn)
    save(first)
    first |> element("#use-custom-smtp") |> render_click()
    {:ok, disabled} = EmailSending.get_settings(context.user)
    save(second)
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert has_element?(second, "#app-flash-group-error", ErrorMessages.message(:stale))
    assert Settings.version(current) == Settings.version(disabled)
    assert has_element?(second, "[role='alert']")
  end

  test "edited form values must be tested before activation", context do
    saved(context.user)
    use_relay(context.certificates, auth_users: credentials())
    {:ok, view, _html} = open_smtp_settings(context.conn)
    edits = Map.put(@attrs, "from_name", "Untested form edits")
    view |> form("#user-smtp-form", smtp: edits) |> render_change()
    refute has_element?(view, "#smtp-enable")

    view |> with_target("#email-sending-settings") |> render_click("enable_smtp")
    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert current.from_name == @attrs["from_name"]

    save(view, edits)
    {:ok, current} = EmailSending.get_settings(context.user)
    assert current.enabled
    assert current.from_name == "Untested form edits"
  end

  test "client-provided owner, row, revision and activation never override the acting user",
       context do
    own = saved(context.user)
    foreign = saved(insert(:user), from_name: "Foreign owner")
    use_relay(context.certificates, auth_users: credentials())
    {:ok, view, html} = open_smtp_settings(context.conn)
    refute html =~ "Foreign owner"

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{
      "smtp" =>
        Map.merge(@attrs, %{
          "user_id" => foreign.user_id,
          "id" => foreign.id,
          "revision" => foreign.revision,
          "enabled" => false
        })
    })

    render_async(view, 5_000)
    assert Repo.get!(UserSmtpSettingsSchema, own.id).enabled
    refute Repo.get!(UserSmtpSettingsSchema, foreign.id).enabled
  end

  test "deletion requires confirmation and removes the saved identity", context do
    saved(context.user)
    {:ok, view, _html} = open_smtp_settings(context.conn)
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
    assert has_element?(view, "#use-custom-smtp[aria-checked='false']")
    refute has_element?(view, "#user-smtp-form")
  end

  test "a stale deletion cannot remove settings recreated by another tab", context do
    original = saved(context.user)
    {:ok, view, _html} = open_smtp_settings(context.conn)
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
    {:ok, view, _html} = open_smtp_settings(context.conn)
    with_config(:tymeslot, user_smtp_enabled: false)

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{"smtp" => @attrs})

    {:ok, current} = EmailSending.get_settings(context.user)
    refute current.enabled
    assert has_element?(view, "#app-flash-group-error", ErrorMessages.message(:feature_disabled))
  end

  test "exhausted test-send budget is shown without opening a connection", context do
    for _attempt <- 1..5, do: :ok = RateLimiter.consume(:user_smtp_test, context.user.id, 1)
    {:ok, view, _html} = open_smtp_settings(context.conn)
    html = save(view)
    assert has_element?(view, "#app-flash-group-error", ErrorMessages.message(:rate_limited))
    refute_secrets(html)
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
    refute_received {:smtp_relay, _event}
  end

  test "an account unverified after mount cannot receive a test message", context do
    use_relay(context.certificates)
    {:ok, view, _html} = open_smtp_settings(context.conn)
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
    {:ok, view, html} = open_smtp_settings(context.conn)
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
    {:ok, view, _html} = open_smtp_settings(context.conn)

    view
    |> form("#user-smtp-form", smtp: Map.put(@attrs, "from_name", "Cancelled replacement"))
    |> render_submit()

    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 5_000
    on_exit(fn -> send(relay, {:ack, reference}) end)
    view |> element("#use-custom-smtp") |> render_click()
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
    {:ok, view, _html} = open_smtp_settings(context.conn)

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{
      "smtp" => Map.put(@attrs, "host", "127.0.0.1")
    })

    refute has_element?(view, "#smtp-enable")
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

    {:ok, view, html} = open_smtp_settings(context.conn)
    assert_state(view, "attention")
    refute_secrets(html)
    refute html =~ "provider-internal-detail"
  end

  test "submission derives port 465 for implicit TLS without prior validation", context do
    use_relay(context.certificates,
      implicit_tls: context.certificates,
      auth_users: credentials()
    )

    {:ok, view, _html} = open_smtp_settings(context.conn)

    # A stale or modified form cannot override the mode's derived port.
    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{
      "smtp" => Map.merge(@attrs, %{"security" => "implicit_tls", "port" => "25"})
    })

    render_async(view, 5_000)
    assert_state(view, "enabled")
    assert has_element?(view, "#smtp-security-value", "Implicit TLS (port 465)")
    refute has_element?(view, "[name='smtp[port]']")
    {:ok, settings} = EmailSending.get_settings(context.user)
    assert settings.port == 465
    assert settings.security == :implicit_tls
    assert_receive {:smtp_relay, {:tls_up, _information}}
  end

  defp saved(user, overrides \\ []), do: saved_smtp_settings(user, @attrs, overrides)

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

  # Input identity controls whether LiveView preserves a browser-owned value
  # during validation or discards it at a submission/settings boundary.
  defp credential_ids(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("input[data-smtp-credential]")
    |> Floki.attribute("id")
  end
end
