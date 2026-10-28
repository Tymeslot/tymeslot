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
  link again, which is how a voter who lost it gets back in; the page says the
  address was already on the poll.

  On an invite-only poll the bare link asks nobody for an address: it says
  the poll is by invitation and the personal link from the invitation email
  is the only way in. A request sent to it anyway is refused by the domain.

  ## Closing at the deadline

  Voting closes at the poll's deadline without any write, so no broadcast
  says so. A connected page keeps a `PollDeadlineTimer` for the deadline and,
  when it fires, reloads the poll as a broadcast would: the page turns to
  "voting has ended" while the voter still has it open, unless the host has
  moved the deadline meanwhile, in which case the timer is armed again.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1, put_flash: 3]

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Security.Honeypot
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Shared.PollDeadlineTimer
  alias TymeslotWeb.Live.Shared.RateLimit
  alias TymeslotWeb.Themes.Shared.PollVotingComponents

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Assigns the poll, its tallies, voting-open flag, the resolved participant,
  and the outcome of a link request made on this page (`link_request`, nil
  until one is made).

  The participant is resolved from the `"p"` param (a participant token) only
  when that participant belongs to this poll; a token from another poll is
  ignored and the participant is left `nil`, so identity can never leak across
  polls; `invalid_link` then tells the page to say the link did not work.
  Subscribes to poll updates once the socket is connected.

  Also keeps the timezone the visitor's browser reported when the socket
  connected (`voter_timezone`), which a link request stores on the
  participant. The page itself shows times in the poll's timezone. Reads the
  connect params, so it can only be called during `mount/3`.
  """
  @spec assign_poll_state(socket(), Polls.PollSchema.t(), map()) :: socket()
  def assign_poll_state(socket, poll, params) do
    if connected?(socket), do: Polls.subscribe(poll.id)
    participant = Voting.get_participant(poll, params["p"])

    socket
    |> assign(
      poll: poll,
      tallies: Polls.tallies(poll),
      participant: participant,
      invalid_link: params["p"] not in [nil, ""] and is_nil(participant),
      link_request: nil,
      voter_timezone: browser_timezone(socket)
    )
    |> assign_voting_open(poll)
  end

  # One instant decides both what the page shows and when it next wakes.
  # Only a connected page arms the timer: the static render's process ends
  # with the response.
  defp assign_voting_open(socket, poll) do
    now = Clock.utc_now()

    timer =
      if connected?(socket),
        do: PollDeadlineTimer.sync(socket.assigns[:deadline_timer], [poll], now)

    assign(socket, voting_open: Polls.voting_open?(poll, now), deadline_timer: timer)
  end

  # The static render has no connect params; the browser reports its zone
  # only once the socket connects.
  defp browser_timezone(socket) do
    if connected?(socket), do: get_connect_params(socket)["timezone"]
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

      with_poll_limit(socket, :poll_register, fn socket ->
        {:noreply, assign(socket, link_request: :sent)}
      end)
    else
      register_participant(socket, params)
    end
  end

  def handle_poll_event("cast_votes", %{"votes" => votes_map} = params, socket)
      when is_map(votes_map) do
    with_poll_limit(socket, :poll_vote, fn socket ->
      cast_votes_for(socket, votes_map, params["name"])
    end)
  end

  # Nothing ticked: the form sends no `votes` at all, and saving it would
  # otherwise do nothing without a word. A malformed `votes` stays ignored.
  def handle_poll_event("cast_votes", params, socket) when not is_map_key(params, "votes") do
    {:noreply,
     put_flash(
       socket,
       :error,
       dgettext("booking_polls", "Choose an answer for at least one time, then save.")
     )}
  end

  def handle_poll_event(_event, _params, socket), do: {:noreply, socket}

  defp register_participant(socket, params) do
    with_poll_limit(socket, :poll_register, fn socket ->
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
  # The timezone is the one their browser reported; an unknown one is dropped
  # by `Voting`.
  defp do_register(socket, params) do
    attrs =
      params
      |> Map.take(["name", "email"])
      |> Map.merge(%{
        "locale" => socket.assigns[:locale],
        "timezone" => socket.assigns[:voter_timezone]
      })

    case Voting.request_link(socket.assigns.poll, attrs) do
      {:ok, outcome} ->
        {:noreply, assign(socket, link_request: outcome)}

      {:error, reason} ->
        {:noreply, flash_after_reload(socket, reason, &register_error_message/1)}
    end
  end

  @doc """
  Reloads the poll and tallies when a `{:poll_updated, poll_id}` broadcast, or
  the page's own `{:poll_deadline_reached, poll_id}` timer, is for the
  assigned poll; otherwise leaves the socket untouched.
  """
  @spec handle_poll_info(term(), socket()) :: {:noreply, socket()}
  def handle_poll_info({:poll_updated, poll_id}, %{assigns: %{poll: %{id: poll_id}}} = socket) do
    {:noreply, reload_tallies(socket)}
  end

  def handle_poll_info(
        {:poll_deadline_reached, poll_id},
        %{assigns: %{poll: %{id: poll_id}}} = socket
      ) do
    {:noreply, reload_tallies(socket)}
  end

  def handle_poll_info(_message, socket), do: {:noreply, socket}

  # --- Rate limiting ---

  defp with_poll_limit(socket, limit, fun) do
    RateLimit.with_rate_limit(
      RateLimiter.check(limit, client_ip(socket)),
      socket,
      fn -> fun.(socket) end,
      message:
        dgettext("booking_polls", "Too many attempts. Please wait a moment and try again."),
      flash: :socket
    )
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

      # The link died while the page was open (it expired, or the host
      # removed them): the page goes back to what the bare link shows, with
      # the poll and tallies as they now stand, without this voter's votes.
      {:error, :unknown_participant} ->
        socket = socket |> reload_tallies() |> assign(participant: nil)

        {:noreply,
         put_flash(
           socket,
           :error,
           cast_error_message(explain(:unknown_participant, socket.assigns.poll))
         )}

      {:error, reason} ->
        {:noreply, flash_after_reload(socket, reason, &cast_error_message/1)}
    end
  end

  # The poll may have turned invite-only since the page loaded: reloading
  # first switches the view to the notice straight away.
  defp flash_after_reload(socket, :invite_only, message_for) do
    socket |> reload_tallies() |> put_flash(:error, message_for.(:invite_only))
  end

  defp flash_after_reload(socket, reason, message_for),
    do: put_flash(socket, :error, message_for.(reason))

  # A link that stopped working cannot be replaced from an invite-only poll's
  # page, so the voter is pointed at their email instead.
  defp explain(:unknown_participant, %{invite_only: true}), do: :invite_only
  defp explain(reason, _poll), do: reason

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
        socket
        |> assign(
          poll: poll,
          tallies: Polls.tallies(poll),
          participant: reload_participant(poll, socket.assigns[:participant])
        )
        |> assign_voting_open(poll)
        |> reset_link_request(poll)

      {:error, :not_found} ->
        socket
    end
  end

  # An invite-only poll cannot show "link sent": if it opens again later the
  # page asks for a link afresh.
  defp reset_link_request(socket, %{invite_only: true}), do: assign(socket, link_request: nil)
  defp reset_link_request(socket, _poll), do: socket

  defp reload_participant(_poll, nil), do: nil
  defp reload_participant(poll, %{token: token}), do: Voting.get_participant(poll, token)

  # --- Flash messages ---

  defp register_error_message(:voting_closed),
    do: dgettext("booking_polls", "Voting has closed for this poll.")

  defp register_error_message(:invite_only),
    do: PollVotingComponents.invite_only_message()

  defp register_error_message(:poll_full),
    do: dgettext("booking_polls", "This poll has reached its participant limit.")

  defp register_error_message(:too_many_requests),
    do:
      dgettext(
        "booking_polls",
        "This poll is receiving a lot of requests right now. Please try again later."
      )

  defp register_error_message(:recipient_rate_limited),
    do: dgettext("booking_polls", "Too many emails to this address recently; try again later.")

  defp register_error_message(%Ecto.Changeset{} = changeset),
    do: changeset_message(changeset, dgettext("booking_polls", "Please enter your name."))

  defp cast_error_message(:voting_closed),
    do: dgettext("booking_polls", "Voting has closed for this poll.")

  defp cast_error_message(%Ecto.Changeset{} = changeset),
    do:
      changeset_message(
        changeset,
        dgettext("booking_polls", "Please enter your name, then save your responses again.")
      )

  defp cast_error_message(:invite_only),
    do: PollVotingComponents.invite_only_message()

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

  # The name and address rules give translated messages of their own, shown
  # as they are. Ecto's built-in ones (a missing field, a value of the wrong
  # type) are not translated, so a missing name or address gets a sentence
  # written here, and anything else the general one.
  defp changeset_message(%Ecto.Changeset{errors: errors}, blank_name_message) do
    Enum.find_value(
      [:name, :email],
      dgettext("booking_polls", "Please check your name and email, then try again."),
      &field_message(&1, Keyword.get(errors, &1), blank_name_message)
    )
  end

  defp field_message(_field, {message, []}, _blank_name_message), do: message

  defp field_message(:name, {_message, [validation: :required]}, blank_name_message),
    do: blank_name_message

  defp field_message(:email, {_message, [validation: :required]}, _blank_name_message),
    do: dgettext("booking_polls", "Please enter your email address.")

  defp field_message(_field, _error, _blank_name_message), do: nil
end
