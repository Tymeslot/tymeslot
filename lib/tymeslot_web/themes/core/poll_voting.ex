defmodule TymeslotWeb.Themes.Core.PollVoting do
  @moduledoc """
  Shared logic for the public poll voting page, mirroring `MeetingManagement`.

  A plain module of functions the scheduling dispatcher calls; it does not
  implement the LiveView behaviour itself. Every function takes and returns a
  socket (or a `{:noreply, socket}` tuple for event/info handlers).

  ## Two kinds of link

  The bare voting link, `/:username/poll/:token`, is the **shareable** one: the
  host sends it to everyone, and anyone opening it can ask for a voting link
  with their name and email, and see the running tallies.

  The personal link adds `?p=<participant_token>` and is the only way to vote.
  It is **emailed**, never shown on the page, so whoever holds it owns the
  address; the first responses saved through it confirm the participant (see
  `Tymeslot.Polls.Voting`). Asking again for the same address sends the same
  link again, which is how a voter who lost it gets back in.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]

  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Security.Honeypot
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Assigns the poll, its tallies, voting-open flag, the resolved participant,
  and whether a link was just requested on this page.

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
      participant: Voting.get_participant(poll, params["p"]),
      link_requested_for: nil
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
    if Honeypot.tripped?(params) do
      # A bot filled the hidden field: fake success and register nothing, exactly
      # as the booking form's honeypot does. Logged like the booking honeypot so
      # the hit is visible, and still counted against the limiter below so a
      # tripped bot cannot hammer the endpoint for free.
      SecurityLogger.log_security_event("poll_register_honeypot_triggered", %{
        ip_address: client_ip(socket),
        poll_id: socket.assigns.poll.id
      })

      with_rate_limit(socket, :poll_register, fn socket ->
        {:noreply, link_sent(socket, params["email"])}
      end)
    else
      register_participant(socket, params)
    end
  end

  def handle_poll_event("cast_votes", %{"votes" => votes_map} = params, socket)
      when is_map(votes_map) do
    with_rate_limit(socket, :poll_vote, fn socket ->
      cast_votes_for(socket, votes_map, params["name"])
    end)
  end

  def handle_poll_event(_event, _params, socket), do: {:noreply, socket}

  defp register_participant(socket, params) do
    with_rate_limit(socket, :poll_register, fn socket ->
      case verify_recaptcha(socket, params) do
        :ok -> do_register(socket, params)
        {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      end
    end)
  end

  # Registration is unauthenticated and writes a row plus an addressable email,
  # so it clears the same reCAPTCHA gate as a booking. A no-op when reCAPTCHA is
  # not configured.
  defp verify_recaptcha(socket, params) do
    metadata = %{
      ip: client_ip(socket),
      user_agent: ClientIP.get_user_agent(socket)
    }

    token = Map.get(params, "g-recaptcha-response", "")

    case RecaptchaHelpers.verify(:booking, token, metadata) do
      :ok -> :ok
      {:error, reason} -> {:error, recaptcha_error_message(reason)}
    end
  end

  defp recaptcha_error_message(:recaptcha_script_blocked) do
    dgettext(
      "booking_polls",
      "Security verification is currently unavailable. This may be caused by JavaScript being disabled, browser privacy extensions (Privacy Badger, uBlock Origin, etc.), or network security policies. Please adjust your settings or contact support if the problem persists."
    )
  end

  defp recaptcha_error_message(_reason),
    do: dgettext("booking_polls", "Security verification failed. Please try again.")

  # The page's locale is the one the voter reads, so their emails use it too.
  defp do_register(socket, params) do
    attrs =
      params
      |> Map.take(["name", "email", "timezone"])
      |> Map.put("locale", socket.assigns[:locale])

    case Voting.request_link(socket.assigns.poll, attrs) do
      :ok -> {:noreply, link_sent(socket, params["email"])}
      {:error, reason} -> {:noreply, put_flash(socket, :error, register_error_message(reason))}
    end
  end

  # The same answer whether the address was new to the poll or already on it.
  defp link_sent(socket, email) do
    assign(socket, link_requested_for: email |> to_string() |> String.trim())
  end

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

  defp with_rate_limit(socket, limit, fun) do
    case RateLimiter.check(limit, client_ip(socket)) do
      :ok ->
        fun.(socket)

      {:error, :rate_limited, _message} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("booking_polls", "Too many attempts. Please wait a moment and try again.")
         )}
    end
  end

  defp client_ip(socket), do: ClientIP.get(socket)

  # --- Vote casting ---

  defp cast_votes_for(%{assigns: %{participant: nil}} = socket, _votes_map, _name) do
    {:noreply,
     put_flash(
       socket,
       :error,
       dgettext("booking_polls", "Please open the personal voting link we emailed you to vote.")
     )}
  end

  defp cast_votes_for(socket, votes_map, name) do
    %{poll: poll, participant: participant} = socket.assigns

    case Voting.cast_votes(poll, participant.token, votes_map, name: name) do
      {:ok, _participant} ->
        {:noreply,
         socket
         |> reload_tallies()
         |> put_flash(:info, saved_message(participant))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, cast_error_message(reason))}
    end
  end

  defp saved_message(%{voted_at: nil}),
    do:
      dgettext(
        "booking_polls",
        "Thanks, your responses count now. We've emailed you a copy with your personal link."
      )

  defp saved_message(_participant),
    do: dgettext("booking_polls", "Your responses have been saved.")

  # --- Reloading ---

  defp reload_tallies(socket) do
    case Polls.get_poll_for_voting(socket.assigns.poll.token) do
      {:ok, poll} ->
        assign(socket,
          poll: poll,
          tallies: Polls.tallies(poll),
          voting_open: Polls.voting_open?(poll),
          participant: reload_participant(poll, socket.assigns[:participant])
        )

      {:error, :not_found} ->
        socket
    end
  end

  defp reload_participant(_poll, nil), do: nil
  defp reload_participant(poll, %{token: token}), do: Voting.get_participant(poll, token)

  # --- Flash messages ---

  defp register_error_message(:voting_closed),
    do: dgettext("booking_polls", "Voting has closed for this poll.")

  defp register_error_message(:poll_full),
    do: dgettext("booking_polls", "This poll has reached its participant limit.")

  defp register_error_message(:too_many_requests),
    do:
      dgettext(
        "booking_polls",
        "This poll is receiving a lot of requests right now. Please try again later."
      )

  defp register_error_message(_changeset),
    do: dgettext("booking_polls", "Please check your name and email, then try again.")

  defp cast_error_message(:voting_closed),
    do: dgettext("booking_polls", "Voting has closed for this poll.")

  defp cast_error_message(%Ecto.Changeset{}),
    do: dgettext("booking_polls", "Please enter your name, then save your responses again.")

  defp cast_error_message(:poll_full),
    do: dgettext("booking_polls", "This poll has reached its participant limit.")

  defp cast_error_message(:unknown_participant),
    do:
      dgettext(
        "booking_polls",
        "This voting link is no longer valid. Please ask for a new one on the poll's page."
      )

  defp cast_error_message(:invalid_slot),
    do:
      dgettext(
        "booking_polls",
        "One of the selected times is no longer available. Please refresh and try again."
      )

  defp cast_error_message(:invalid_response),
    do:
      dgettext(
        "booking_polls",
        "One of your responses wasn't recognised. Please refresh and try again."
      )
end
