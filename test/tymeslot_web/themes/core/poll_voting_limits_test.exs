defmodule TymeslotWeb.Themes.Core.PollVotingLimitsTest do
  @moduledoc """
  The voting page's answer when the poll email limits turn a link request
  away.
  """

  # async: false: these tests fill shared rate-limit buckets, which another
  # module's setup would otherwise clear mid-test.
  use Tymeslot.DataCase, async: false

  @moduletag :unit
  @moduletag :polls

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Themes.Core.PollVoting

  # A minimal disconnected socket, as in PollVotingTest, with a client
  # address of its own so the per-client bucket never interferes.
  defp socket(assigns) do
    base = %{
      __changed__: %{},
      flash: %{},
      client_ip: "poll-limits-#{System.unique_integer([:positive])}"
    }

    %Phoenix.LiveView.Socket{transport_pid: nil, assigns: Map.merge(base, assigns)}
  end

  defp fill(name, key),
    do: :ok = RateLimiter.consume(name, key, RateLimiter.remaining(name, key))

  defp register(poll, email) do
    {:noreply, socket} =
      PollVoting.handle_poll_event(
        "register_participant",
        %{"name" => "Ada", "email" => email},
        socket(%{poll: poll, participant: nil})
      )

    socket
  end

  setup do
    poll = insert(:poll)
    {:ok, poll} = Polls.get_poll_for_voting(poll.token)
    %{poll: poll, email: "ada-#{System.unique_integer([:positive])}@example.com"}
  end

  test "an address that has had too many emails is told so, and nothing is sent", %{
    poll: poll,
    email: email
  } do
    fill(:poll_recipient_email, email)

    socket = register(poll, email)

    assert socket.assigns.flash["error"] ==
             "Too many emails to this address recently; try again later."

    refute Map.has_key?(socket.assigns, :link_requested_for)
    assert PollParticipantQueries.get_by_poll_and_email(poll.id, email) == nil
  end

  test "a poll that has taken its share of requests asks the visitor to come back", %{
    poll: poll,
    email: email
  } do
    fill(:poll_link_request, poll.id)

    socket = register(poll, email)

    assert socket.assigns.flash["error"] ==
             "This poll is receiving a lot of requests right now. Please try again later."

    assert PollParticipantQueries.get_by_poll_and_email(poll.id, email) == nil
  end
end
