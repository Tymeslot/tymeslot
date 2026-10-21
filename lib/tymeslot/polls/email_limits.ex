defmodule Tymeslot.Polls.EmailLimits do
  @moduledoc """
  The limits on poll emails, counted per address emailed.

  Anyone can type any address into a poll, the host into an invitation list
  and a visitor into the voting page, so polls must not become a way to flood
  someone's inbox:

  - a host invites so many addresses an hour and a day, across all their
    polls (`:poll_host_invitations`);
  - an address is sent so many poll emails an hour and a day, invitations and
    voting links alike, across every poll (`:poll_recipient_email`);
  - a poll takes so many voting-link requests an hour (`:poll_link_request`),
    on top of the per-client limit on the voting page.

  The numbers are `config :tymeslot, :poll_email_limits`, which a deployment
  overrides key by key. `Tymeslot.Polls.Invitations` and
  `Tymeslot.Polls.Voting` call this before they write or send anything, so
  every way of inviting or asking for a link is counted.
  """

  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Security.RateLimiter

  @typedoc "The addresses that may be emailed, and those over their own limit."
  @type reservation :: %{allowed: [String.t()], limited: [String.t()]}

  @doc """
  Charges a voting-link request to `poll`'s budget. Refused requests count
  too, like every per-client limit. Answers `{:error, :too_many_requests}`,
  the voting page's "receiving a lot of requests" refusal, once it is spent.
  """
  @spec charge_link_request(PollSchema.t()) :: :ok | {:error, :too_many_requests}
  def charge_link_request(%PollSchema{id: poll_id}) do
    case RateLimiter.check(:poll_link_request, poll_id) do
      :ok -> :ok
      {:error, :rate_limited, _message} -> {:error, :too_many_requests}
    end
  end

  @doc """
  Charges one poll email to `email`'s budget, just before it is sent.
  A refusal charges nothing.
  """
  @spec charge_recipient(String.t()) :: :ok | {:error, :recipient_rate_limited}
  def charge_recipient(email) when is_binary(email) do
    case RateLimiter.consume(:poll_recipient_email, email, 1) do
      :ok -> :ok
      {:error, {:rate_limited, _remaining}} -> {:error, :recipient_rate_limited}
    end
  end

  @doc """
  Reserves an invitation for each of `emails` (already normalised and
  distinct) against host `host_id`'s budget and each address's own.

  An address over its own limit is left out as `:limited` and costs the host
  nothing: the host cannot know who else has been emailing it. The rest are
  charged to the host whole: when they do not all fit, nothing is charged and
  the answer is `{:error, {:rate_limited, remaining}}`, how many more the host
  may invite right now.
  """
  @spec reserve_invitations(pos_integer(), [String.t()]) ::
          {:ok, reservation()}
          | {:error, {:rate_limited, non_neg_integer()} | :invalid_user_id}
  def reserve_invitations(host_id, emails) do
    {sendable, limited} =
      Enum.split_with(emails, &(RateLimiter.remaining(:poll_recipient_email, &1) > 0))

    with :ok <- RateLimiter.consume(:poll_host_invitations, host_id, length(sendable)) do
      # An address another request filled since the read above is left out
      # too; the host keeps that one unit spent, which errs on the safe side.
      {allowed, raced} = Enum.split_with(sendable, &(charge_recipient(&1) == :ok))
      {:ok, %{allowed: allowed, limited: limited ++ raced}}
    end
  end
end
