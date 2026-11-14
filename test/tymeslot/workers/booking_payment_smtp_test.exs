defmodule Tymeslot.Workers.BookingPaymentSmtpTest do
  @moduledoc "Exercises refund worker ownership, SMTP transport and platform financial routing."

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :payments
  @moduletag :integration

  import Swoosh.TestAssertions
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.WorkerTestHelpers, only: [persisted_job: 2]

  alias Ecto.Changeset
  alias Tymeslot.Clock
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.{Breakers, Sender, Settings, UserSmtpSettingsSchema}
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.FakeSmtpRelay
  alias Tymeslot.Workers.SendBookingPaymentRefunded
  alias Tymeslot.Workers.SendChargeDisputeOpened
  alias Tymeslot.Workers.SendConnectAccountRestricted

  defmodule Destination do
    @moduledoc false
    @behaviour Tymeslot.EmailSending.Destination

    @impl Tymeslot.EmailSending.Destination
    def resolve(_host, _port) do
      {:ok,
       %{address: {127, 0, 0, 1}, port: Application.fetch_env!(:tymeslot, :refund_smtp_test_port)}}
    end
  end

  setup_all do
    %{certificates: FakeSmtpRelay.certificates(~c"smtp.example.com")}
  end

  setup %{certificates: certificates} do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      user_smtp_destination_module: Destination,
      user_smtp_cacertfile: certificates.cacertfile
    )

    with_config(:swoosh, :shared_test_process, self())
    owner = insert(:user)
    settings = settings(owner)
    %{owner: owner, settings: settings}
  end

  test "a legacy refund job uses its retained owner after meeting deletion and sends once",
       context do
    attendee = insert(:user)
    settings(attendee)
    meeting = insert(:meeting, organizer_user_id: context.owner.id)
    payment = payment(context.owner, meeting_id: meeting.id, attendee_email: attendee.email)
    job = job(payment)
    Repo.delete!(meeting)
    assert Repo.reload!(payment).meeting_id == nil
    use_relay(context.certificates, auth_users: %{"refund-login" => "refund-secret"})

    assert :ok = SendBookingPaymentRefunded.perform(job)
    body = message()
    assert body =~ ~r/^From:.*refunds@brand.example.com/m
    assert body =~ ~r/^Reply-To:.*#{Regex.escape(context.owner.email)}/m
    assert body =~ attendee.email
    assert :ok = SendBookingPaymentRefunded.perform(%{job | attempt: 2})
    refute_received {:smtp_relay, {:message, _duplicate}}
    refute_email_sent()
    assert Repo.reload!(job).args == %{"booking_payment_id" => payment.id}
  end

  for disabled <- [:deployment, :identity] do
    test "a queued refund uses the platform when #{disabled} is disabled", context do
      payment = payment(context.owner)
      job = job(payment)

      case unquote(disabled) do
        :deployment -> with_config(:tymeslot, :user_smtp_enabled, false)
        :identity -> Repo.update!(Changeset.change(context.settings, enabled: false))
      end

      assert :ok = SendBookingPaymentRefunded.perform(job)

      assert_email_sent(fn email ->
        assert elem(email.from, 1) == platform_address()
        assert email.reply_to == {"Refund host", context.owner.email}
      end)

      refute_received {:smtp_relay, _event}
    end
  end

  test "a queued refund resolves the current tested revision and ignores forged sender arguments",
       context do
    payment = payment(context.owner)
    original = job(payment)

    use_relay(context.certificates,
      auth_users: %{"replacement-login" => "replacement-secret"}
    )

    assert {:ok, _updated} =
             EmailSending.test_and_save_settings(
               context.owner,
               %{
                 username: "replacement-login",
                 password: "replacement-secret",
                 from_name: "New refund brand",
                 from_address: "new-refunds@brand.example.com"
               },
               context.settings |> Settings.from_schema() |> Settings.version()
             )

    message()
    foreign = insert(:user)
    forged = %{original | args: Map.put(original.args, "organizer_user_id", foreign.id)}
    assert :ok = SendBookingPaymentRefunded.perform(forged)
    assert message() =~ ~r/^From:.*new-refunds@brand.example.com/m
    refute_email_sent()
  end

  for enabled? <- [true, false] do
    test "a deleted host is discarded even with feature enabled #{enabled?}", context do
      payment = payment(context.owner)
      job = job(payment)
      Repo.delete!(context.owner)
      replacement = insert(:user, email: context.owner.email)
      settings(replacement)
      with_config(:tymeslot, :user_smtp_enabled, unquote(enabled?))

      assert {:discard, reason} = SendBookingPaymentRefunded.perform(job)
      assert reason == "booking payment host not found"
      assert SendBookingPaymentRefunded.expected_outcome?(reason)
      refute_received {:smtp_relay, _event}
      refute_email_sent()
    end
  end

  test "a retained payment explicitly marked host-deleted is never sent", context do
    payment = payment(context.owner, host_deleted_at: DateTime.truncate(Clock.utc_now(), :second))

    assert {:discard, "booking payment host not found"} =
             SendBookingPaymentRefunded.perform(job(payment))

    refute_received {:smtp_relay, _event}
    refute_email_sent()
  end

  test "an invalid retained host never selects the recipient's custom identity", context do
    payment = payment(context.owner, host_user_id: 0, attendee_email: context.owner.email)

    assert {:discard, "booking payment host not found"} =
             SendBookingPaymentRefunded.perform(job(payment))

    refute_received {:smtp_relay, _event}
    refute_email_sent()
  end

  test "failed custom SMTP never falls back and a repaired revision retries the unclaimed refund",
       context do
    payment = payment(context.owner)
    job = job(payment)
    use_relay(context.certificates, auth: :reject)

    assert {:error, :authentication_failed} = SendBookingPaymentRefunded.perform(job)
    refute_received {:smtp_relay, {:message, _failed}}
    refute_email_sent()

    Repo.update!(Changeset.change(context.settings, revision: 2, tested_revision: 2))
    use_relay(context.certificates, auth_users: %{"refund-login" => "refund-secret"})

    assert :ok = SendBookingPaymentRefunded.perform(%{job | attempt: 2})
    assert message() =~ ~r/^From:.*refunds@brand.example.com/m
    assert :ok = SendBookingPaymentRefunded.perform(%{job | attempt: 3})
    refute_received {:smtp_relay, {:message, _duplicate}}
  end

  test "custom account circuit snoozes are bounded for the direct refund worker", context do
    payment = payment(context.owner)
    job = job(payment)
    use_relay(context.certificates, auth: :reject)
    sender = Sender.from_settings(context.settings)
    assert {:error, :authentication_failed} = SendBookingPaymentRefunded.perform(job)
    breaker = Breakers.name(sender)
    threshold = CircuitBreaker.status(breaker).config.failure_threshold

    for attempt <- 2..threshold do
      assert {:error, :authentication_failed} =
               SendBookingPaymentRefunded.perform(%{job | attempt: attempt})
    end

    assert CircuitBreaker.status(breaker).status == :open
    assert {:snooze, seconds} = SendBookingPaymentRefunded.perform(job)
    assert seconds >= 300

    assert {:error, reason} =
             SendBookingPaymentRefunded.perform(%{job | meta: %{"snoozed" => 12}})

    assert reason =~ "maximum wait"
    refute_email_sent()
  end

  test "permanent recipient rejection remains a discard through custom SMTP", context do
    use_relay(context.certificates, rcpt_reply: "550 5.1.1 Unknown recipient")

    assert {:discard, "Recipient permanently undeliverable"} =
             context.owner |> payment() |> job() |> SendBookingPaymentRefunded.perform()

    refute_received {:smtp_relay, {:message, _body}}
    refute_email_sent()
  end

  test "financial dispute and payout restriction notices retain the platform despite broken SMTP",
       context do
    use_relay(context.certificates, auth: :reject)
    payment = payment(context.owner, status: :disputed, stripe_charge_id: "ch_platform_notice")
    dispute = persisted_job(SendChargeDisputeOpened, %{"booking_payment_id" => payment.id})
    assert :ok = SendChargeDisputeOpened.perform(dispute)

    assert_email_sent(fn email ->
      assert elem(email.from, 1) == platform_address()
      assert email.to == [{"Refund host", context.owner.email}]
    end)

    account =
      insert(:connect_account, user: context.owner, disabled_reason: "requirements.past_due")

    restriction =
      persisted_job(SendConnectAccountRestricted, %{"connect_account_id" => account.id})

    assert :ok = SendConnectAccountRestricted.perform(restriction)
    assert_email_sent(fn email -> assert elem(email.from, 1) == platform_address() end)
    refute_received {:smtp_relay, _event}
  end

  defp payment(owner, attributes \\ []) do
    insert(
      :booking_payment,
      Keyword.merge(
        [
          host_user_id: owner.id,
          host_email: owner.email,
          host_name: "Refund host",
          attendee_email: "customer@example.com",
          attendee_name: "Customer",
          status: :refunded,
          amount_cents: 5_000,
          refunded_amount_cents: 5_000
        ],
        attributes
      )
    )
  end

  defp job(payment),
    do: persisted_job(SendBookingPaymentRefunded, %{"booking_payment_id" => payment.id})

  defp settings(owner) do
    Repo.insert!(%UserSmtpSettingsSchema{
      user_id: owner.id,
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("refund-login"),
      password_encrypted: Encryption.encrypt("refund-secret"),
      from_address: "refunds@brand.example.com",
      from_name: "Refund brand",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: Clock.utc_now()
    })
  end

  defp use_relay(certificates, options) do
    relay = FakeSmtpRelay.start(Keyword.put(options, :starttls, certificates))
    with_config(:tymeslot, refund_smtp_test_port: relay.port)
  end

  defp message do
    assert_receive {:smtp_relay, {:message, body}}, 2_000
    body
  end

  defp platform_address, do: Application.fetch_env!(:tymeslot, :email)[:from_email]
end
