defmodule TymeslotWeb.Themes.Core.PollVoting do
  @moduledoc """
  Shared logic for the public poll voting page, mirroring `MeetingManagement`.

  A plain module of functions the scheduling dispatcher calls; it does not
  implement the LiveView behaviour itself. Every function takes and returns a
  socket (or a `{:noreply, socket}` tuple for event/info handlers).

  ## Two kinds of link

  The bare voting link, `/:username/poll/:token`, is the **shareable** one: the
  host sends it to everyone, and anyone opening it can register and vote.

  Once a person registers, their identity travels in the URL as a query param,
  `?p=<participant_token>`. That `?p=` link is **per person** — it resumes their
  registration and their previous responses on a refresh or bookmark, so it must
  not be shared. Registration `push_patch`es to add `?p=` precisely so the
  identity survives a reload.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2, put_flash: 3]

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  # Public write actions are rate-limited per client IP over a one-minute window,
  # sized to a handful of legitimate submissions like the booking limiter.
  @register_limit 5
  @vote_limit 10
  @rate_window_ms 60_000

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Assigns the poll, its tallies, voting-open flag, and the resolved participant.

  The participant is resolved from the `"p"` param (a participant token) only
  when that participant belongs to this poll; a token from another poll is
  ignored and the participant is left `nil`, so identity can never leak across
  polls. Subscribes to poll updates once the socket is connected.
  """
  @spec assign_poll_state(socket(), Polls.PollSchema.t(), map()) :: socket()
  def assign_poll_state(socket, poll, params) do
    if connected?(socket), do: Polls.subscribe(poll.id)

    assign(socket,
      poll: poll,
      tallies: Polls.tallies(poll),
      voting_open: Polls.voting_open?(poll),
      participant: resolve_participant(poll, params["p"])
    )
  end

  @doc """
  Handles the voting page's `register_participant` and `cast_votes` events.

  Unknown events are ignored. Both write actions are rate-limited per client IP.
  """
  @spec handle_poll_event(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle_poll_event(
        "register_participant",
        %{"name" => _name, "email" => _email} = params,
        socket
      ) do
    with_rate_limit(socket, "poll_register:", @register_limit, fn socket ->
      attrs = Map.take(params, ["name", "email", "timezone", "locale"])

      case Voting.register_participant(socket.assigns.poll, attrs) do
        {:ok, participant} ->
          {:noreply,
           socket
           |> assign(participant: participant)
           |> put_flash(
             :info,
             dgettext("booking", "You're registered. Your responses are saved as you vote.")
           )
           |> push_patch(to: put_participant_in_url(socket, participant))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, register_error_message(reason))}
      end
    end)
  end

  def handle_poll_event("cast_votes", %{"votes" => votes_map}, socket) do
    with_rate_limit(socket, "poll_vote:", @vote_limit, fn socket ->
      cast_votes_for(socket, votes_map)
    end)
  end

  def handle_poll_event(_event, _params, socket), do: {:noreply, socket}

  @doc """
  Reloads the poll and tallies when a `{:poll_updated, poll_id}` broadcast is for
  the assigned poll; otherwise leaves the socket untouched.
  """
  @spec handle_poll_info(term(), socket()) :: {:noreply, socket()}
  def handle_poll_info({:poll_updated, poll_id}, %{assigns: %{poll: %{id: poll_id}}} = socket) do
    {:noreply, reload_tallies(socket)}
  end

  def handle_poll_info(_message, socket), do: {:noreply, socket}

  # --- Rate limiting ---

  defp with_rate_limit(socket, prefix, limit, fun) do
    bucket = prefix <> client_ip(socket)

    case RateLimiter.check_rate_limit(bucket, limit, @rate_window_ms) do
      :ok ->
        fun.(socket)

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("booking", "Too many attempts. Please wait a moment and try again.")
         )}
    end
  end

  defp client_ip(socket), do: ClientIP.get(socket)

  # --- Vote casting ---

  defp cast_votes_for(%{assigns: %{participant: nil}} = socket, _votes_map) do
    {:noreply, put_flash(socket, :error, dgettext("booking", "Please register before voting."))}
  end

  defp cast_votes_for(socket, votes_map) do
    %{poll: poll, participant: participant} = socket.assigns

    case Voting.cast_votes(poll, participant.token, votes_map) do
      {:ok, _participant} ->
        {:noreply,
         socket
         |> reload_tallies()
         |> put_flash(:info, dgettext("booking", "Your responses have been saved."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, cast_error_message(reason))}
    end
  end

  # --- Participant resolution ---

  defp resolve_participant(_poll, token) when not is_binary(token), do: nil

  defp resolve_participant(poll, token) do
    case PollParticipantQueries.get_by_token(token) do
      nil -> nil
      participant -> if participant.poll_id == poll.id, do: participant, else: nil
    end
  end

  # --- Reloading ---

  defp reload_tallies(socket) do
    case Polls.get_poll_for_voting(socket.assigns.poll.token) do
      {:ok, poll} ->
        assign(socket,
          poll: poll,
          tallies: Polls.tallies(poll),
          voting_open: Polls.voting_open?(poll),
          participant: reload_participant(socket.assigns[:participant])
        )

      {:error, :not_found} ->
        socket
    end
  end

  defp reload_participant(nil), do: nil
  defp reload_participant(%{token: token}), do: PollParticipantQueries.get_by_token(token)

  # --- URL building ---

  defp put_participant_in_url(socket, participant) do
    "#{poll_path(socket)}?p=#{participant.token}"
  end

  defp poll_path(socket) do
    poll = socket.assigns.poll

    case socket.assigns[:organizer_profile] do
      %{username: username} when is_binary(username) and byte_size(username) > 0 ->
        "/#{username}/poll/#{poll.token}"

      _no_username ->
        "/poll/#{poll.token}"
    end
  end

  # --- Flash messages ---

  defp register_error_message(:voting_closed),
    do: dgettext("booking", "Voting has closed for this poll.")

  defp register_error_message(:poll_full),
    do: dgettext("booking", "This poll has reached its participant limit.")

  defp register_error_message(_changeset),
    do: dgettext("booking", "Please check your name and email, then try again.")

  defp cast_error_message(:voting_closed),
    do: dgettext("booking", "Voting has closed for this poll.")

  defp cast_error_message(:unknown_participant),
    do: dgettext("booking", "We couldn't find your registration. Please register again.")

  defp cast_error_message(:invalid_slot),
    do:
      dgettext(
        "booking",
        "One of the selected times is no longer available. Please refresh and try again."
      )

  defp cast_error_message(:invalid_response),
    do:
      dgettext(
        "booking",
        "One of your responses wasn't recognised. Please refresh and try again."
      )
end
