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
  link but has not voted with it yet is confirmed and invited.
  """

  alias Tymeslot.Emails.EmailScheduler.PollScheduler
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantQueries, PollParticipantSchema, PollSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.FieldValidators.EmailValidator

  @type entry :: %{email: String.t(), name: String.t() | nil}
  @type result :: %{invited: [PollParticipantSchema.t()], skipped: [String.t()]}

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
  the poll past its participant cap, and invites nobody.
  """
  @spec invite(PollSchema.t(), [entry()]) ::
          {:ok, result()} | {:error, :not_open | :poll_full | Ecto.Changeset.t()}
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
  def insert(_poll, []), do: %{invited: [], skipped: []}

  def insert(%PollSchema{} = poll, entries) do
    existing =
      poll.id
      |> PollParticipantQueries.list_by_poll_and_emails(Enum.map(entries, & &1.email))
      |> Map.new(&{&1.email, &1})

    {skipped, to_confirm, new} = split(entries, existing)

    if PollParticipantQueries.count_confirmed(poll.id) + length(to_confirm) + length(new) >
         PollSchema.max_participants() do
      Repo.rollback(:poll_full)
    end

    now = DateTime.utc_now()
    defaults = %{poll_id: poll.id, timezone: poll.timezone, locale: host_locale(poll)}

    confirmed = Enum.map(to_confirm, &write(confirm(&1, now)))
    inserted = Enum.map(new, &write(new_invitee(&1, defaults, now)))

    %{invited: confirmed ++ inserted, skipped: Enum.map(skipped, & &1.email)}
  end

  @doc "Emails each of `participants` their invitation."
  @spec send_invitations([PollParticipantSchema.t()]) :: :ok
  def send_invitations(participants) do
    Enum.each(participants, &PollScheduler.schedule_invitation/1)
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
        %{confirmed_at: nil} = participant -> {skipped, [participant | to_confirm], new}
        _confirmed -> {[entry | skipped], to_confirm, new}
      end
    end)
  end

  defp confirm(participant, now) do
    participant
    |> PollParticipantSchema.invited_changeset(now)
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
