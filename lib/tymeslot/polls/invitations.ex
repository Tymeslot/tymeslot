defmodule Tymeslot.Polls.Invitations do
  @moduledoc """
  Inviting people to a poll by email address.

  The host types the addresses, one per line or separated by commas or
  semicolons, each optionally as `Name <address>`. Every invitee becomes a
  participant with their own voting link, emailed to them with the poll's
  candidate times. An invitee is confirmed from the start: the host vouches
  for the address, so unlike someone asking for a link on the voting page
  they count at once, and they get the deadline reminder like everyone else.
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
  """

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{EmailLimits, PollParticipantQueries, PollParticipantSchema, PollSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.FieldValidators.EmailValidator

  @type entry :: %{email: String.t(), name: String.t() | nil}
  @type result :: %{
          invited: [PollParticipantSchema.t()],
          skipped: [String.t()],
          rate_limited: [String.t()]
        }

  @separators ~r/[\n\r,;]+/
  @named ~r/^(.*?)\s*<\s*([^<>\s]+)\s*>$/

  @doc """
  Reads the host's list of addresses into entries, dropping duplicates.

  Returns `{:error, {:invalid_addresses, entries}}` naming each entry that is
  not a valid address, and `{:error, :too_many_invitees}` for more than a poll
  can hold.
  """
  @spec parse(String.t() | nil) ::
          {:ok, [entry()]}
          | {:error, {:invalid_addresses, [String.t()]} | :too_many_invitees}
  def parse(text) when is_binary(text) do
    entries =
      text
      |> String.split(@separators)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parsed = Enum.map(entries, &{&1, parse_entry(&1)})

    case for({raw, entry} <- parsed, not valid?(entry), do: raw) do
      [] -> unique(Enum.map(parsed, &elem(&1, 1)))
      invalid -> {:error, {:invalid_addresses, invalid}}
    end
  end

  def parse(_text), do: {:ok, []}

  @doc """
  Invites `entries` to an open `poll` and emails each new invitee their link.

  All or nothing: returns `{:error, :poll_full}` when the invitees would take
  the poll past its participant cap, and `{:error, {:rate_limited,
  remaining}}` when they are more than its host may invite right now
  (`remaining` is how many they may), and invites nobody.
  """
  @spec invite(PollSchema.t(), [entry()]) ::
          {:ok, result()}
          | {:error,
             :not_open
             | :poll_full
             | {:rate_limited, non_neg_integer()}
             | Ecto.Changeset.t()}
  def invite(%PollSchema{} = poll, entries) do
    if Polls.voting_open?(poll) do
      case Repo.transaction(fn -> insert(poll, entries) end) do
        {:ok, result} ->
          send_invitations(result.invited)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_open}
    end
  end

  @doc """
  Writes the invitees for `poll` inside the caller's transaction, rolling it
  back on failure. The caller sends the invitations with
  `send_invitations/1` once the transaction has committed.
  """
  @spec insert(PollSchema.t(), [entry()]) :: result()
  def insert(_poll, []), do: %{invited: [], skipped: [], rate_limited: []}

  def insert(%PollSchema{} = poll, entries) do
    {skipped, to_confirm, new} = split(entries, existing_participants(poll, entries))
    ensure_room!(poll, length(to_confirm) + length(new))

    %{allowed: allowed, limited: limited} =
      reserve!(poll, Enum.map(to_confirm, &elem(&1, 1).email) ++ Enum.map(new, & &1.email))

    %{
      invited: write_allowed(poll, to_confirm, new, MapSet.new(allowed)),
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
