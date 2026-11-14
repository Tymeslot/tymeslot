defmodule Tymeslot.EmailSending.CalendarRoutingTest do
  @moduledoc "Exercises dashboard calendar sender routing through real TLS/AUTH and persisted jobs."

  use Tymeslot.DataCase, async: false

  import Swoosh.TestAssertions
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.WorkerTestHelpers, only: [persisted_job: 2]

  alias Ecto.Changeset
  alias Tymeslot.Clock
  alias Tymeslot.Emails.BookingDelivery
  alias Tymeslot.Emails.EmailService.CalendarEmails
  alias Tymeslot.Emails.Templates.{CalendarInvitation, EventUpdateNotification}
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Settings
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Notifications.Email.CalendarEventDetails
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.FakeSmtpRelay
  alias Tymeslot.Workers.EmailWorker

  @moduletag :emails
  @moduletag :integration

  defmodule Destination do
    @moduledoc false
    @behaviour Tymeslot.EmailSending.Destination

    @impl Tymeslot.EmailSending.Destination
    def resolve(_host, _port) do
      {:ok,
       %{
         address: {127, 0, 0, 1},
         port: Application.fetch_env!(:tymeslot, :calendar_smtp_test_port)
       }}
    end
  end

  setup_all do
    %{certificates: FakeSmtpRelay.certificates(~c"smtp.example.com")}
  end

  setup %{certificates: certificates} do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      user_smtp_destination_module: Destination,
      user_smtp_cacertfile: certificates.cacertfile,
      email_service_module: Tymeslot.Emails.EmailService
    )

    with_config(:swoosh, shared_test_process: self())
    owner = insert(:user, name: "Actual organizer")
    integration = insert(:calendar_integration, user: owner)
    settings = settings(owner, "calendar@owner.example.com")
    %{owner: owner, integration: integration, settings: settings}
  end

  test "legacy invitation jobs select the organizer rather than the recipient's SMTP account",
       context do
    recipient = insert(:user)
    settings(recipient, "calendar@recipient.example.com")
    use_relay(context.certificates)

    job = persisted_job(EmailWorker, invitation(context.owner, recipient.email))
    original_args = job.args
    assert :ok = EmailWorker.perform(job)
    assert_from(message(), "calendar@owner.example.com")
    assert Repo.reload!(job).args == original_args
    refute_email_sent()
  end

  test "calendar templates retain the actual organizer and calendar identity with custom From",
       context do
    args = invitation(context.owner)
    assert {:ok, details} = CalendarEventDetails.invitation_details(context.owner, args)
    assert {:ok, prepared, sender} = BookingDelivery.prepare(details)
    invitation = CalendarInvitation.render(args["attendee_email"], prepared)

    assert invitation.from == {sender.from_name, sender.from_address}
    assert invitation.reply_to == {context.owner.name, context.owner.email}
    ics = calendar_body(invitation)
    assert ics =~ "UID:original-calendar-uid"
    assert ics =~ "SEQUENCE:4"
    assert ics =~ "mailto:#{context.owner.email}"
    refute ics =~ sender.from_address

    event = update(context)["event"]
    assert {:ok, current} = CalendarEventDetails.snapshot_event(event)

    assert {:ok, details} =
             CalendarEventDetails.update_details(
               context.owner,
               current,
               [{:title, "Old title", current.summary}],
               update(context)
             )

    assert {:ok, prepared, ^sender} = BookingDelivery.prepare(details)
    update = EventUpdateNotification.render("guest@example.com", prepared)
    assert update.from == invitation.from
    assert update.reply_to == invitation.reply_to
    ics = calendar_body(update)
    assert ics =~ "UID:original-calendar-uid"
    assert ics =~ "SEQUENCE:5"
    assert ics =~ "mailto:#{context.owner.email}"
    refute ics =~ sender.from_address
  end

  test "a cancellation snapshot survives removal of the cached event and its integration",
       context do
    args = Map.put(invitation(context.owner), "method", "cancel")
    job = persisted_job(EmailWorker, args)
    Repo.delete!(context.integration)
    use_relay(context.certificates)

    assert :ok = EmailWorker.perform(job)
    body = message()
    assert_from(body, "calendar@owner.example.com")
    assert body =~ "Cancelled"
  end

  test "an update snapshot survives event/integration removal and keeps successful recipient claims",
       context do
    job = persisted_job(EmailWorker, update(context))
    Repo.delete!(context.integration)
    use_relay(context.certificates)
    assert :ok = EmailWorker.perform(job)
    assert_from(message(), "calendar@owner.example.com")
    assert_from(message(), "calendar@owner.example.com")

    assert :ok = EmailWorker.perform(%{job | attempt: 2})
    refute_received {:smtp_relay, {:message, _duplicate}}
  end

  test "partial updates retry only missed recipients with current settings and unchanged job args",
       context do
    job = persisted_job(EmailWorker, update(context))

    use_relay(context.certificates,
      rcpt_replies: %{"second@example.com" => "451 4.3.0 Temporary mailbox failure"}
    )

    assert {:error, _reason} = EmailWorker.perform(job)
    assert_from(message(), "calendar@owner.example.com")
    refute_received {:smtp_relay, {:message, _more}}

    replacement =
      context.settings
      |> Changeset.change(
        revision: 2,
        tested_revision: 2,
        from_address: "updated@owner.example.com"
      )
      |> Repo.update!()

    use_relay(context.certificates)
    assert :ok = EmailWorker.perform(%{job | attempt: 2})
    assert_from(message(), replacement.from_address)
    refute_received {:smtp_relay, {:message, _duplicate}}
    assert Repo.reload!(job).args == job.args
  end

  test "a mid-batch edit cannot redirect remaining recipients and a retry preserves the accepted copy",
       context do
    reference = make_ref()
    use_relay(context.certificates, after_data: {:await, reference})
    job = persisted_job(EmailWorker, update(context))

    pending =
      Tasks.async_nolink(Tymeslot.TaskSupervisor, fn -> EmailWorker.perform(job) end)

    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 2_000

    context.settings
    |> Changeset.change(
      revision: 2,
      tested_revision: 2,
      from_address: "updated@owner.example.com"
    )
    |> Repo.update!()

    send(relay, {:ack, reference})
    assert {:error, _reason} = Task.await(pending, 2_000)
    assert_from(message(), "calendar@owner.example.com")
    refute_received {:smtp_relay, {:message, _redirected}}
    refute_email_sent()

    use_relay(context.certificates)
    assert :ok = EmailWorker.perform(%{job | attempt: 2})
    assert_from(message(), "updated@owner.example.com")
    refute_received {:smtp_relay, {:message, _duplicate}}
  end

  test "feature disablement resumes only missed copies and reactivation restores custom routing",
       context do
    job = persisted_job(EmailWorker, update(context))

    use_relay(context.certificates,
      rcpt_replies: %{"second@example.com" => "451 4.3.0 Temporary mailbox failure"}
    )

    assert {:error, _reason} = EmailWorker.perform(job)
    message()
    with_config(:tymeslot, user_smtp_enabled: false)
    assert :ok = EmailWorker.perform(%{job | attempt: 2})

    assert_email_sent(fn email ->
      assert email.to == [{"", "second@example.com"}]
      assert elem(email.from, 1) != context.settings.from_address
    end)

    refute_received {:smtp_relay, {:message, _more}}
    with_config(:tymeslot, user_smtp_enabled: true)
    use_relay(context.certificates)
    next_job = persisted_job(EmailWorker, invitation(context.owner))
    assert :ok = EmailWorker.perform(next_job)
    assert_from(message(), context.settings.from_address)
  end

  test "disabled identities use the platform sender for both calendar job types", context do
    assert {:ok, _disabled} =
             EmailSending.disable_settings(
               context.owner,
               context.settings |> Settings.from_schema() |> Settings.version()
             )

    for args <- [invitation(context.owner), update(context)] do
      job = persisted_job(EmailWorker, args)
      assert :ok = EmailWorker.perform(job)
    end

    assert_email_sent(fn email -> assert elem(email.from, 1) != context.settings.from_address end)
    refute_received {:smtp_relay, {:message, _custom}}
  end

  test "custom authentication failure never falls back to the platform", context do
    use_relay(context.certificates, auth: :reject)
    job = persisted_job(EmailWorker, invitation(context.owner))
    assert {:error, _reason} = EmailWorker.perform(job)
    refute_received {:smtp_relay, {:message, _message}}
    refute_email_sent()
  end

  test "direct calendar service calls require an authoritative owner while custom routing is enabled" do
    assert {:error, :owner_not_found} =
             CalendarEmails.send_calendar_invitation("guest@example.com", %{})

    assert {:error, :owner_not_found} =
             CalendarEmails.send_event_update_notification("guest@example.com", %{})

    refute_email_sent()
  end

  test "snapshots never send after their organizer is deleted, even with the feature disabled",
       context do
    invitation = persisted_job(EmailWorker, invitation(context.owner))
    update = persisted_job(EmailWorker, update(context))
    Repo.delete!(context.owner)
    with_config(:tymeslot, user_smtp_enabled: false)

    assert {:discard, "User not found"} = EmailWorker.perform(invitation)
    assert {:discard, "Event or user not found"} = EmailWorker.perform(update)
    assert Repo.get(UserSmtpSettingsSchema, context.settings.id) == nil
    refute_email_sent()
  end

  test "organizers awaiting deletion cannot send calendar snapshots", context do
    context.owner
    |> Changeset.change(deletion_scheduled_at: DateTime.utc_now(:second))
    |> Repo.update!()

    for args <- [invitation(context.owner), update(context)] do
      job = persisted_job(EmailWorker, args)
      assert {:discard, "Account pending deletion"} = EmailWorker.perform(job)
    end

    refute_email_sent()
  end

  test "external calendar alerts retain platform delivery while custom SMTP is broken", context do
    use_relay(context.certificates, auth: :reject)

    meeting =
      insert(:meeting,
        organizer_user_id: context.owner.id,
        organizer_email: context.owner.email,
        calendar_integration_id: context.integration.id
      )

    assert {:ok, _result} =
             CalendarEmails.send_external_booking_change(meeting, context.owner.email, :deleted)

    assert_email_sent(fn email ->
      assert elem(email.from, 1) != context.settings.from_address
      assert elem(hd(email.to), 1) == context.owner.email
    end)

    refute_received {:smtp_relay, {:message, _custom}}
  end

  defp settings(owner, from_address) do
    Repo.insert!(%UserSmtpSettingsSchema{
      user_id: owner.id,
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("calendar-account"),
      password_encrypted: Encryption.encrypt("calendar-secret"),
      from_address: from_address,
      from_name: "Calendar brand",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: Clock.utc_now()
    })
  end

  defp invitation(owner, attendee_email \\ "guest@example.com") do
    %{
      "action" => "send_calendar_invitation",
      "user_id" => owner.id,
      "attendee_email" => attendee_email,
      "event_title" => "Team sync",
      "event_uid" => "calendar-event-uid",
      "ical_uid" => "original-calendar-uid",
      "event_start_at" => "2026-11-12T10:00:00Z",
      "event_end_at" => "2026-11-12T11:00:00Z",
      "event_location" => "Office",
      "event_description" => "Agenda",
      "sequence" => 4
    }
  end

  defp update(context) do
    %{
      "action" => "send_event_update_notification",
      "user_id" => context.owner.id,
      "integration_id" => context.integration.id,
      "event_uid" => "calendar-event-uid",
      "ical_uid" => "original-calendar-uid",
      "attendee_emails" => ["first@example.com", "second@example.com"],
      "before_title" => "Old title",
      "before_location" => "Office",
      "before_description" => "Agenda",
      "before_start_at" => "2026-11-12T10:00:00Z",
      "before_end_at" => "2026-11-12T11:00:00Z",
      "sequence" => 5,
      "event" => %{
        "uid" => "calendar-event-uid",
        "summary" => "New title",
        "location" => "Office",
        "description" => "Agenda",
        "start_at" => "2026-11-12T10:00:00Z",
        "end_at" => "2026-11-12T11:00:00Z"
      }
    }
  end

  defp use_relay(certificates, options \\ []) do
    options = Keyword.merge([auth_users: %{"calendar-account" => "calendar-secret"}], options)
    relay = FakeSmtpRelay.start(Keyword.put(options, :starttls, certificates))
    with_config(:tymeslot, calendar_smtp_test_port: relay.port)
  end

  defp message do
    assert_receive {:smtp_relay, {:message, body}}, 2_000
    body
  end

  defp calendar_body(email) do
    [ics] = Enum.filter(email.attachments, &(&1.content_type == "text/calendar"))
    ics.data |> LineFolder.unfold_lines() |> Enum.join("\n")
  end

  defp assert_from(body, address), do: assert(body =~ ~r/^From:.*#{Regex.escape(address)}/m)
end
