defmodule Tymeslot.Polls.Invitations do
  @moduledoc """
  Inviting people to a poll by email address.

  The host types the addresses, one per line or separated by commas or
  semicolons, each optionally as `Name <address>`. Every invitee becomes a
  participant with their own voting link, emailed to them with the poll's
  candidate times. An invitee is confirmed from the start: the host vouches
  for the address, so unlike someone asking for a link on the voting page
  they count at once, and the poll's deadline reminders are for them:
  inviting the first people schedules those reminders.
  With invitees the poll knows who "everyone" is, so the host is told once all
  of them have voted (see `Tymeslot.Polls.Voting`).
  Someone invited without a name gives it the first time they vote.

  Someone already confirmed on the poll is skipped. Someone who asked for a
  link but has not voted with it yet is confirmed and invited, under the name
  the host typed if they typed one.

  Every address emailed counts against the poll email limits
  (`Tymeslot.Polls.EmailLimits`): a list past the host's allowance invites
  nobody, and an address that has had too many poll emails lately is left out
  and reported, like someone already on the poll.

  The host can send a confirmed participant their link again
  (`resend/2`): an invitee who has not voted gets the invitation, anyone
  else the voting-link email. It shares the voting page's resend window and
  counts against the limits like an invitation.
  """

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Polls.{
    EmailLimits,
    PollParticipantQueries,
    PollParticipantSchema,
    PollSchema,
    Voting
  }

  alias Tymeslot.Repo
  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Security.FieldValidators.NameValidator

  @type entry :: %{email: String.t(), name: String.t() | nil}
  @type result :: %{
          invited: [PollParticipantSchema.t()],
          skipped: [String.t()],
          rate_limited: [String.t()]
        }

  @typedoc "Why `resend/2` sent nothing."
  @type resend_error ::
          :voting_closed
          | :not_found
          | :sent_recently
          | :recipient_rate_limited
          | :host_rate_limited

  @separators ~r/[\n\r,;]+/
  @named ~r/^(.*?)\s*<\s*([^<>\s]+)\s*>$/

  @doc """
  Reads the host's list of addresses into entries, dropping duplicates.

  Returns `{:error, {:invalid_addresses, entries}}` naming each entry that is
  not a valid address, then `{:error, {:invalid_names, names}}` naming each
  name a participant could not be given, and `{:error, :too_many_invitees}`
  for more than a poll can hold.
  """
  @spec parse(String.t() | nil) ::
          {:ok, [entry()]}
          | {:error,
             {:invalid_addresses, [String.t()]}
             | {:invalid_names, [String.t()]}
             | :too_many_invitees}
  def parse(text) when is_binary(text) do
    entries =
      text
      |> String.split(@separators)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parsed = Enum.map(entries, &{&1, parse_entry(&1)})

    with :ok <-
           refuse(:invalid_addresses, for({raw, entry} <- parsed, not valid?(entry), do: raw)),
         :ok <-
           refuse(
             :invalid_names,
             Enum.uniq(for {_raw, entry} <- parsed, not valid_name?(entry), do: entry.name)
           ) do
      unique(Enum.map(parsed, &elem(&1, 1)))
    end
  end

  def parse(_text), do: {:ok, []}

  @doc """
  Writes the invitees for `poll` inside the caller's transaction, rolling it
  back on failure. `Tymeslot.Polls.invite_participants/3` is the entry point:
  it holds the poll's row lock around this and sends the invitations with
  `send_invitations/1` once the transaction has committed.

  All or nothing: rolls the transaction back with `:poll_full` when the
  invitees would take the poll past its participant cap, and with
  `{:rate_limited, remaining}` when they are more than its host may invite
  right now (`remaining` is how many they may).
  """
  @spec insert(PollSchema.t(), [entry()]) :: result()
  def insert(_poll, []), do: %{invited: [], skipped: [], rate_limited: []}

  def insert(%PollSchema{} = poll, entries) do
    {skipped, to_confirm, new} = split(entries, existing_participants(poll, entries))
    ensure_room!(poll, length(to_confirm) + length(new))

    %{allowed: allowed, limited: limited} =
      reserve!(poll, Enum.map(to_confirm, &elem(&1, 1).email) ++ Enum.map(new, & &1.email))

    invited = write_allowed(poll, to_confirm, new, MapSet.new(allowed))

    # Invitees are who the reminders are for. Jobs are unique per deadline
    # and lead time, so a poll that has them already gains none.
    if invited != [], do: :ok = EmailScheduler.schedule_poll_reminders(poll)

    %{
      invited: invited,
      skipped: Enum.map(skipped, & &1.email),
      rate_limited: limited
    }
  end

  defp existing_participants(poll, entries) do
    poll.id
    |> PollParticipantQueries.list_by_poll_and_emails(Enum.map(entries, & &1.email))
    |> Map.new(&{&1.email, &1})
  end

  defp write_allowed(poll, to_confirm, new, allowed) do
    now = DateTime.utc_now()
    defaults = %{poll_id: poll.id, timezone: poll.timezone, locale: host_locale(poll)}

    confirmed =
      for {_participant, e} = pair <- to_confirm,
          e.email in allowed,
          do: write(confirm(pair, now))

    inserted = for e <- new, e.email in allowed, do: write(new_invitee(e, defaults, now))
    confirmed ++ inserted
  end

  # Deliberately counts every address being added, including any the
  # reservation later skips as limited per recipient: the check runs before
  # the charge so a full poll spends none of the host's budget, and counting
  # too many only errs towards refusing.
  defp ensure_room!(%PollSchema{id: poll_id}, adding) do
    if PollParticipantQueries.count_confirmed(poll_id) + adding > PollSchema.max_participants() do
      Repo.rollback(:poll_full)
    end
  end

  @doc """
  The addresses among `entries` that a just-created `poll` (participants
  preloaded) did not invite. A new poll has nobody on it to skip, so these
  are the addresses left out for the poll email limits.
  """
  @spec uninvited(PollSchema.t(), [entry()]) :: [String.t()]
  def uninvited(%PollSchema{participants: participants}, entries) do
    on_poll = MapSet.new(participants, & &1.email)
    for %{email: email} <- entries, not MapSet.member?(on_poll, email), do: email
  end

  @doc "Emails each of `participants` their invitation."
  @spec send_invitations([PollParticipantSchema.t()]) :: :ok
  def send_invitations(participants) do
    Enum.each(participants, &EmailScheduler.schedule_poll_invitation/1)
  end

  @doc """
  Sends confirmed participant `participant_id` of `poll` their personal link
  again, for someone who lost the email: an invitee who has not voted gets
  the invitation, anyone else the voting-link email, both with the link they
  already have.

  Call it inside a transaction holding `poll`'s row lock (as
  `Tymeslot.Polls.resend_invitation/3` does), and roll back on an error: the
  send is claimed before the limits are charged, and only the rollback
  releases the claim when a limit refuses. The job is inserted in the same
  transaction.

  Refuses with `:voting_closed` past the deadline, `:not_found` for anyone
  not confirmed on the poll, `:sent_recently` within
  `Tymeslot.Polls.Voting.resend_interval_seconds/0` of the last email with
  the link (an invitation, a resend or the participant's own request), and
  `:recipient_rate_limited` or `:host_rate_limited` past the poll email
  limits (`Tymeslot.Polls.EmailLimits`).
  """
  @spec resend(PollSchema.t(), Ecto.UUID.t()) :: {:ok, PollSchema.t()} | {:error, resend_error()}
  def resend(%PollSchema{} = poll, participant_id) do
    with :ok <- ensure_voting_open(poll),
         {:ok, participant} <- fetch_confirmed(poll, participant_id),
         :ok <- claim_send(participant),
         :ok <- reserve_resend(poll, participant) do
      :ok = schedule_resend(participant)
      {:ok, poll}
    end
  end

  # --- Resending ---

  defp ensure_voting_open(poll) do
    if PollSchema.voting_open?(poll), do: :ok, else: {:error, :voting_closed}
  end

  defp fetch_confirmed(poll, participant_id) do
    case PollParticipantQueries.get_confirmed_on_poll(poll.id, participant_id) do
      nil -> {:error, :not_found}
      participant -> {:ok, participant}
    end
  end

  # The same claim the voting page takes, so a resend, an invitation and a
  # participant's own request share one window, and two clicks send once.
  defp claim_send(participant) do
    now = DateTime.utc_now()
    resend_before = DateTime.add(now, -Voting.resend_interval_seconds(), :second)

    if PollParticipantQueries.claim_link_send(participant.id, now, resend_before),
      do: :ok,
      else: {:error, :sent_recently}
  end

  # One unit from the address and one from the host, like an invitation, so
  # resending is no way round either limit. Each refusal charges nothing.
  defp reserve_resend(%PollSchema{user_id: user_id}, participant) do
    case EmailLimits.reserve_invitations(user_id, [participant.email]) do
      {:ok, %{allowed: [_email]}} -> :ok
      {:ok, %{limited: [_email]}} -> {:error, :recipient_rate_limited}
      {:error, {:rate_limited, _remaining}} -> {:error, :host_rate_limited}
    end
  end

  defp schedule_resend(participant) do
    if PollParticipantSchema.unanswered_invitee?(participant),
      do: EmailScheduler.schedule_poll_invitation_again(participant),
      else: EmailScheduler.schedule_poll_participant_link(participant)
  end

  # --- Parsing ---

  defp parse_entry(raw) do
    case Regex.run(@named, raw) do
      [_raw, name, email] -> %{email: normalise(email), name: blank_to_nil(name)}
      nil -> %{email: normalise(raw), name: nil}
    end
  end

  defp normalise(email), do: email |> String.trim() |> String.downcase()

  defp blank_to_nil(name) do
    case name |> String.trim() |> String.trim("\"") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp valid?(%{email: email}), do: EmailValidator.validate(email) == :ok

  # The rule the participant's changeset applies, checked here so the host
  # hears which name is wrong instead of the whole invitation failing.
  defp valid_name?(%{name: nil}), do: true
  defp valid_name?(%{name: name}), do: NameValidator.validate(name) == :ok

  defp refuse(_reason, []), do: :ok
  defp refuse(reason, entries), do: {:error, {reason, entries}}

  defp unique(entries) do
    entries = Enum.uniq_by(entries, & &1.email)

    if length(entries) > PollSchema.max_participants() do
      {:error, :too_many_invitees}
    else
      {:ok, entries}
    end
  end

  # --- Writing ---

  defp split(entries, existing) do
    Enum.reduce(Enum.reverse(entries), {[], [], []}, fn entry, {skipped, to_confirm, new} ->
      case Map.get(existing, entry.email) do
        nil -> {skipped, to_confirm, [entry | new]}
        %{confirmed_at: nil} = participant -> {skipped, [{participant, entry} | to_confirm], new}
        _confirmed -> {[entry | skipped], to_confirm, new}
      end
    end)
  end

  # Charged before anything is written, inside the caller's transaction, so a
  # list past the host's allowance rolls back whole. The cap check above runs
  # first, so a full poll spends nothing of the host's budget. A later
  # rollback, or a write that loses a race, keeps the units charged to the
  # recipients as well as the host's, deliberately: it is rare and errs safe.
  defp reserve!(%PollSchema{user_id: user_id}, emails) do
    case EmailLimits.reserve_invitations(user_id, emails) do
      {:ok, reservation} -> reservation
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The host knows who they are inviting: a name they typed wins over the one
  # the person gave when asking for a link.
  defp confirm({participant, entry}, now) do
    participant
    |> PollParticipantSchema.invited_changeset(entry.name, now)
    |> PollParticipantSchema.link_sent_changeset(now)
  end

  defp new_invitee(entry, defaults, now) do
    %PollParticipantSchema{}
    |> PollParticipantSchema.invitation_changeset(Map.merge(defaults, entry), now)
    |> PollParticipantSchema.link_sent_changeset(now)
  end

  defp write(%Ecto.Changeset{data: %{__meta__: %{state: :loaded}}} = changeset),
    do: changeset |> PollParticipantQueries.update() |> unwrap()

  defp write(changeset), do: changeset |> PollParticipantQueries.insert() |> unwrap()

  defp unwrap({:ok, participant}), do: participant
  defp unwrap({:error, changeset}), do: Repo.rollback(changeset)

  # Invitees are written to in the host's language: the host knows them, and
  # nothing else is known about them yet.
  defp host_locale(%PollSchema{user_id: user_id}), do: RecipientLocale.locale_for_user_id(user_id)
end
