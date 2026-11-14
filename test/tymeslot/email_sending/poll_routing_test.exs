defmodule Tymeslot.EmailSending.PollRoutingTest do
  @moduledoc "Exercises poll jobs, sender snapshots and retries against a real authenticated TLS relay."

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :integration

  import Swoosh.TestAssertions
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Clock
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Polls.PollQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.FakeSmtpRelay
  alias Tymeslot.Workers.EmailWorker

  defmodule Destination do
    @moduledoc false
    @behaviour Tymeslot.EmailSending.Destination

    @impl Tymeslot.EmailSending.Destination
    def resolve(_host, _port) do
      {:ok,
       %{address: {127, 0, 0, 1}, port: Application.fetch_env!(:tymeslot, :poll_smtp_test_port)}}
    end
  end

  setup_all do
    %{certificates: FakeSmtpRelay.certificates(~c"smtp.example.com")}
  end

  setup :set_swoosh_global

  setup %{certificates: certificates} do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      user_smtp_destination_module: Destination,
      user_smtp_cacertfile: certificates.cacertfile
    )

    owner = insert(:user)
    insert(:profile, user: owner, username: "pollhost#{owner.id}")
    settings = settings(owner)
    poll = insert(:poll, user: owner, notify_on_vote: true)
    slot = insert(:poll_time_slot, poll: poll)
    participant = insert(:poll_participant, poll: poll)

    %{owner: owner, settings: settings, poll: poll, slot: slot, participant: participant}
  end

  test "invitations, personal links and receipts select the host instead of the recipient",
       context do
    recipient_owner = insert(:user, email: context.participant.email)
    settings(recipient_owner, "recipient@other.example.com")
    use_relay(context.certificates)

    for action <- ["send_poll_invitation", "send_poll_participant_link", "send_poll_vote_receipt"] do
      job = job(action, %{"participant_id" => context.participant.id})
      assert :ok = run(job)
      body = message()
      assert_brand(body)
      assert body =~ ~r/^Reply-To:.*#{Regex.escape(context.owner.email)}/m
      assert body =~ context.participant.email
      refute body =~ "recipient@other.example.com"
      refute inspect(Repo.reload!(job).args) =~ "smtp-password"
    end
  end

  test "poll emails preserve the location in both bodies when using custom SMTP", context do
    location = "Garden pavilion"

    context.poll
    |> Changeset.change(location_kind: :custom, location_details: location)
    |> Repo.update!()

    use_relay(context.certificates)

    for {action, args} <- [
          {"send_poll_invitation", %{"participant_id" => context.participant.id}},
          {"send_poll_participant_link", %{"participant_id" => context.participant.id}},
          {"send_poll_deadline_reminders", %{"poll_id" => context.poll.id}}
        ] do
      assert :ok = run(job(action, args))
      body = message()
      assert_brand(body)
      assert body =~ ~r/^Reply-To:.*#{Regex.escape(context.owner.email)}/m

      # The ASCII marker needs no charset conversion (and no optional iconv).
      bodies = body |> :mimemail.decode(encoding: :none) |> text_bodies()

      assert bodies["plain"] =~ "Where: #{location}"
      assert bodies["html"] =~ location
    end
  end

  test "deadline reminders share the host sender and retry only the failed participant",
       context do
    other = insert(:poll_participant, poll: context.poll)

    use_relay(context.certificates,
      rcpt_replies: %{other.email => "451 Temporary mailbox failure"}
    )

    job = job("send_poll_deadline_reminders", %{"poll_id" => context.poll.id})

    assert {:error, _reason} = run(job)
    first = message()
    assert_brand(first)
    assert first =~ context.participant.email
    refute_received {:smtp_relay, {:message, _more}}

    use_relay(context.certificates)
    assert :ok = run(job, 2)
    retried = message()
    assert_brand(retried)
    assert retried =~ other.email
    refute_received {:smtp_relay, {:message, _more}}

    assert :ok = run(job, 3)
    refute_received {:smtp_relay, {:message, _more}}
  end

  test "host nudges use the same custom sender for the host's own copy", context do
    use_relay(context.certificates)
    job = job("send_poll_host_nudge", %{"poll_id" => context.poll.id, "variant" => "all_voted"})

    assert :ok = run(job)
    body = message()
    assert_brand(body)
    assert body =~ context.owner.email
    assert PollQueries.get_with_host(context.poll.id).vote_digest_sent_at
  end

  test "vote digests use the host sender and retain their successful delivery claim", context do
    context.participant
    |> Changeset.change(
      voted_at:
        Clock.utc_now()
        |> DateTime.add(-120, :second)
        |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    use_relay(context.certificates)
    job = job("send_poll_vote_digest", %{"poll_id" => context.poll.id})

    assert :ok = run(job)
    body = message()
    assert_brand(body)
    assert body =~ context.owner.email
    assert :ok = run(job, 2)
    refute_received {:smtp_relay, {:message, _more}}
  end

  test "new-time notices use the host sender for voters", context do
    context.participant
    |> Changeset.change(voted_at: DateTime.truncate(Clock.utc_now(), :second))
    |> Repo.update!()

    use_relay(context.certificates)

    job =
      job("send_poll_new_times", %{"poll_id" => context.poll.id, "slot_ids" => [context.slot.id]})

    assert :ok = run(job)
    assert_brand(message())
  end

  test "cancellation snapshots preserve the owner after the poll is deleted", context do
    job = job("send_poll_cancelled", cancellation_args(context))
    Repo.delete!(context.poll)
    use_relay(context.certificates)

    assert :ok = run(job)
    assert_brand(message())
    assert :ok = run(job, 2)
    refute_received {:smtp_relay, {:message, _more}}
  end

  test "legacy cancellation jobs resolve the owner from the remaining poll", context do
    context.poll |> Changeset.change(status: :cancelled) |> Repo.update!()
    job = job("send_poll_cancelled", %{"poll_id" => context.poll.id})
    use_relay(context.certificates)

    assert :ok = run(job)
    assert_brand(message())

    assert Repo.reload!(job).args == %{
             "action" => "send_poll_cancelled",
             "poll_id" => context.poll.id
           }
  end

  test "a missing snapshot owner discards without falling back, even with the feature off",
       context do
    job = job("send_poll_cancelled", cancellation_args(context))
    Repo.delete!(context.owner)
    with_config(:tymeslot, user_smtp_enabled: false)

    assert {:discard, "poll host not found"} = run(job)
    refute_email_sent()
    refute_received {:smtp_relay, _event}
    refute Repo.get(UserSmtpSettingsSchema, context.settings.id)
  end

  test "cancellation snapshots respect a host's pending account deletion", context do
    job = job("send_poll_cancelled", cancellation_args(context))

    context.owner
    |> Changeset.change(deletion_scheduled_at: DateTime.truncate(Clock.utc_now(), :second))
    |> Repo.update!()

    assert {:discard, "host account pending deletion"} = run(job)
    refute_email_sent()
  end

  test "a custom account authentication failure never falls back to platform delivery", context do
    use_relay(context.certificates, auth: :reject)
    job = job("send_poll_invitation", %{"participant_id" => context.participant.id})

    assert {:error, _reason} = run(job)
    refute_received {:smtp_relay, {:message, _body}}
    refute_email_sent()
    assert Repo.reload!(context.settings).last_error == "authentication_failed"
  end

  test "feature disablement restores the platform sender for queued poll mail", context do
    use_relay(context.certificates)
    job = job("send_poll_invitation", %{"participant_id" => context.participant.id})
    with_config(:tymeslot, user_smtp_enabled: false)

    assert :ok = run(job)
    platform = Application.fetch_env!(:tymeslot, :email)[:from_email]
    assert_email_sent(fn email -> elem(email.from, 1) == platform end)
    refute_received {:smtp_relay, _event}
  end

  test "disabling and reactivating an identity preserves queued recipient claims", context do
    other = insert(:poll_participant, poll: context.poll)
    reference = make_ref()
    use_relay(context.certificates, after_data: {:await, reference})
    job = job("send_poll_deadline_reminders", %{"poll_id" => context.poll.id})

    pending = Tasks.async_nolink(Tymeslot.TaskSupervisor, fn -> run(job) end)
    first = message()
    assert_brand(first)
    assert_receive {:smtp_relay, {:awaiting_ack, relay, ^reference}}, 2_000

    assert {:ok, disabled} =
             EmailSending.disable_settings(
               context.owner,
               {context.settings.id, context.settings.revision}
             )

    send(relay, {:ack, reference})
    assert {:error, _reason} = Task.await(pending, 2_000)
    refute_received {:smtp_relay, {:message, _more}}
    refute_email_sent()

    # The next execution may choose the platform. The copy already accepted
    # by the custom relay remains claimed, so it is never sent again.
    assert :ok = run(job, 2)
    first_recipient = if first =~ context.participant.email, do: context.participant, else: other
    remaining = if first_recipient.id == other.id, do: context.participant, else: other
    assert_email_sent(fn email -> email.to == [{remaining.name, remaining.email}] end)
    refute_email_sent()

    assert {:ok, _enabled} =
             EmailSending.enable_settings(context.owner, {disabled.id, disabled.revision})

    use_relay(context.certificates)
    assert :ok = run(job("send_poll_participant_link", %{"participant_id" => remaining.id}))
    assert_brand(message())
  end

  defp settings(owner, address \\ "polls@brand.example.com") do
    Repo.insert!(%UserSmtpSettingsSchema{
      user_id: owner.id,
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("smtp-login"),
      password_encrypted: Encryption.encrypt("smtp-password"),
      from_address: address,
      from_name: "Poll brand",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: Clock.utc_now()
    })
  end

  defp cancellation_args(context) do
    %{
      "poll_id" => context.poll.id,
      "user_id" => context.owner.id,
      "title" => context.poll.title,
      "recipients" => [
        %{
          "id" => context.participant.id,
          "email" => context.participant.email,
          "name" => context.participant.name,
          "locale" => "en",
          "voted_at" => nil
        }
      ]
    }
  end

  defp job(action, args),
    do: args |> Map.put("action", action) |> EmailWorker.new() |> Oban.insert!()

  defp run(job, attempt \\ 1), do: EmailWorker.perform(%{job | attempt: attempt})

  defp use_relay(certificates, options \\ []) do
    relay = FakeSmtpRelay.start(Keyword.put(options, :starttls, certificates))
    with_config(:tymeslot, poll_smtp_test_port: relay.port)
  end

  defp message do
    assert_receive {:smtp_relay, {:message, body}}, 2_000
    body
  end

  defp assert_brand(body),
    do: assert(body =~ ~r/^From:.*Poll brand.*<polls@brand\.example\.com>/m)

  # Inline logos nest the HTML in multipart/related inside the alternatives.
  @spec text_bodies(:mimemail.mimetuple()) :: %{optional(String.t()) => binary()}
  defp text_bodies({"text", subtype, _headers, _parameters, body}), do: %{subtype => body}

  defp text_bodies({_type, _subtype, _headers, _parameters, parts}) when is_list(parts) do
    Enum.reduce(parts, %{}, fn part, bodies -> Map.merge(bodies, text_bodies(part)) end)
  end

  defp text_bodies(_part), do: %{}
end
