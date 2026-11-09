defmodule Tymeslot.EmailSending.BookingRoutingTest do
  @moduledoc """
  Exercises unchanged queued booking jobs against authenticated SMTP accounts.

  Only DNS endpoints and CA trust are replaced. The real worker, ownership
  lookup, templates, delivery claims, TLS and AUTH run across the full boundary.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Clock
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.{Breakers, UserSmtpSettingsSchema}
  alias Tymeslot.Infrastructure.CircuitBreaker
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
         port: Application.fetch_env!(:tymeslot, :booking_smtp_test_port)
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

    owner = insert(:user)
    settings = settings(owner, "owner-account", "owner-secret", "bookings@owner.example.com")
    %{owner: owner, settings: settings}
  end

  test "one relay authenticates distinct owners and ignores the recipient's identity", context do
    other = insert(:user)
    settings(other, "other-account", "other-secret", "bookings@other.example.com")

    use_relay(context.certificates,
      auth_users: %{"owner-account" => "owner-secret", "other-account" => "other-secret"}
    )

    first = meeting(context.owner, attendee_email: other.email)
    second = meeting(other, attendee_email: context.owner.email)

    assert :ok = run(job(first))
    assert_from(message(), "bookings@owner.example.com")
    assert_from(message(), "bookings@owner.example.com")
    assert :ok = run(job(second))
    assert_from(message(), "bookings@other.example.com")
    assert_from(message(), "bookings@other.example.com")
  end

  test "a queued legacy job uses settings tested after it was queued", context do
    meeting = meeting(context.owner)
    job = job(meeting)

    use_relay(context.certificates,
      auth_users: %{"replacement-account" => "replacement-secret"}
    )

    assert {:ok, replacement} =
             EmailSending.test_and_save_settings(
               context.owner,
               %{
                 username: "replacement-account",
                 password: "replacement-secret",
                 from_name: "Replacement brand",
                 from_address: "new@owner.example.com"
               },
               {context.settings.id, context.settings.revision}
             )

    assert replacement.enabled
    assert_from(message(), "new@owner.example.com")
    assert :ok = run(job)
    assert_from(message(), "new@owner.example.com")
    assert_from(message(), "new@owner.example.com")

    assert Repo.get!(Oban.Job, job.id).args == %{
             "action" => "send_cancellation_emails",
             "meeting_id" => meeting.id
           }
  end

  test "partial success retries only the missed recipient with the same queued arguments",
       context do
    meeting = meeting(context.owner)
    job = job(meeting)

    use_relay(context.certificates,
      auth_users: %{"owner-account" => "owner-secret"},
      rcpt_replies: %{meeting.attendee_email => "451 4.3.0 Temporary mailbox failure"}
    )

    assert {:error, _reason} = run(job)
    first = message()
    assert first =~ meeting.organizer_email
    assert_from(first, "bookings@owner.example.com")
    refute_received {:smtp_relay, {:message, _more}}

    use_relay(context.certificates, auth_users: %{"owner-account" => "owner-secret"})
    assert :ok = run(job, 2)
    second = message()
    assert second =~ meeting.attendee_email
    assert_from(second, "bookings@owner.example.com")
    refute_received {:smtp_relay, {:message, _more}}

    assert :ok = run(job, 3)
    refute_received {:smtp_relay, {:message, _more}}
  end

  test "post-DATA timeouts spend the worker's one retry and retain completed claims", context do
    meeting = meeting(context.owner)
    job = job(meeting)
    use_relay(context.certificates, after_data: :silent)
    with_config(:tymeslot, email_send_deadline_ms: 1_000)

    assert {:error, _reason} = run(job)
    message()
    message()

    # Attempts represent retries after recovery; timeout failures still count
    # against the selected account's breaker in production.
    {:ok, sender} = EmailSending.resolve_booking_sender(meeting)
    CircuitBreaker.reset(Breakers.name(sender))

    assert :ok = run(job, 2)
    message()
    message()
    assert :ok = run(job, 3)
    refute_received {:smtp_relay, {:message, _more}}
  end

  defp settings(owner, username, password, address) do
    settings = %UserSmtpSettingsSchema{
      user_id: owner.id,
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt(username),
      password_encrypted: Encryption.encrypt(password),
      from_address: address,
      from_name: "Booking brand",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: Clock.utc_now()
    }

    Repo.insert!(settings)
  end

  defp meeting(owner, attributes \\ []) do
    insert(
      :meeting,
      Keyword.merge(
        [organizer_user_id: owner.id, organizer_email: owner.email, status: :cancelled],
        attributes
      )
    )
  end

  defp job(meeting) do
    %{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}
    |> EmailWorker.new()
    |> Oban.insert!()
  end

  defp run(job, attempt \\ 1), do: EmailWorker.perform(%{job | attempt: attempt})

  defp use_relay(certificates, options) do
    relay = FakeSmtpRelay.start(Keyword.put(options, :starttls, certificates))
    with_config(:tymeslot, booking_smtp_test_port: relay.port)
  end

  defp message do
    assert_receive {:smtp_relay, {:message, body}}, 2_000
    body
  end

  defp assert_from(body, address), do: assert(body =~ ~r/^From:.*#{Regex.escape(address)}/m)
end
