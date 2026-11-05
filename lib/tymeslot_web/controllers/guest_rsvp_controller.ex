defmodule TymeslotWeb.GuestRsvpController do
  @moduledoc """
  Public, unauthenticated endpoint for a meeting guest to respond to their
  invitation via the tokenised link in their confirmation email.

  Two-step flow to prevent email link-prefetchers from auto-triggering RSVPs:

    * `GET /guest/:token/:response` — looks up the invitation and renders a
      confirmation landing page with a POST form button. No mutation.
    * `POST /guest/:token/:response` — records the RSVP (the domain notifies
      the organiser's dashboard) and renders the success page.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Meetings
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @responses %{"accept" => :accepted, "decline" => :declined}

  # ---------------------------------------------------------------------------
  # GET — confirmation landing page (read-only)
  # ---------------------------------------------------------------------------

  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token, "response" => response})
      when is_map_key(@responses, response) do
    with :ok <- RateLimiter.check(:guest_rsvp, ClientIP.get(conn)),
         {:ok, guest} <- Meetings.get_guest_invitation(token),
         :ok <- check_seat(guest, response) do
      conn
      |> put_layout(html: false)
      |> assign_legal_links(guest.meeting)
      |> render(:confirm,
        meeting: guest.meeting,
        timezone: timezone(guest),
        status: Map.fetch!(@responses, response),
        token: token,
        response: response
      )
    else
      error -> render_error(conn, error)
    end
  end

  def confirm(conn, _params), do: render_error(conn, {:error, :not_found})

  # ---------------------------------------------------------------------------
  # POST — record the RSVP, render success
  # ---------------------------------------------------------------------------

  @spec submit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def submit(conn, %{"token" => token, "response" => response})
      when is_map_key(@responses, response) do
    with :ok <- RateLimiter.check(:guest_rsvp, ClientIP.get(conn)),
         {:ok, guest} <- Meetings.record_guest_rsvp(token, Map.fetch!(@responses, response)) do
      conn
      |> put_layout(html: false)
      |> assign_legal_links(guest.meeting)
      |> render(:confirmation,
        meeting: guest.meeting,
        timezone: timezone(guest),
        status: guest.status,
        token: token
      )
    else
      {:error, :full} -> render_error(conn, full_with_guest(token))
      error -> render_error(conn, error)
    end
  end

  def submit(conn, _params), do: render_error(conn, {:error, :not_found})

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # The zone the guest's times are shown in. A group meeting keeps no
  # attendee timezone of its own, so a guest brought by a participant sees
  # the times as that participant booked them; a guest of a solo booking
  # sees the attendee's. Neither known falls back to UTC in the formatter.
  defp timezone(%{participant: %{timezone: timezone}}) when is_binary(timezone), do: timezone
  defp timezone(%{meeting: meeting}), do: meeting.attendee_timezone

  # A guest of a group booking who declined has given their seat back; the
  # page offering a yes says straight away when none is free any more.
  defp check_seat(guest, "accept"),
    do: if(Meetings.guest_can_accept?(guest), do: :ok, else: {:error, :full, guest})

  defp check_seat(_guest, _response), do: :ok

  # The organiser's legal links, from the meeting the token resolved to.
  defp assign_legal_links(conn, %{organizer_user_id: user_id}),
    do: assign(conn, :legal_links, organiser_legal_links(user_id))

  defp organiser_legal_links(user_id) when is_integer(user_id),
    do: user_id |> Profiles.get_profile() |> Profiles.public_legal_links()

  defp organiser_legal_links(_no_organiser), do: Profiles.public_legal_links(nil)

  # A full meeting has already resolved its guest, so its error page shows the
  # organiser's links. The other errors (unknown token, closed meeting, rate
  # limit) carry no meeting to find the organiser by and show the instance
  # defaults.
  defp render_error(conn, {:error, :full, guest} = error) do
    render_error_page(conn, error, &assign_legal_links(&1, guest.meeting))
  end

  defp render_error(conn, error) do
    render_error_page(conn, error, &assign(&1, :legal_links, Profiles.public_legal_links(nil)))
  end

  defp render_error_page(conn, error, assign_links) do
    {http_status, template} = error_page(error)

    conn
    |> put_status(http_status)
    |> put_layout(html: false)
    |> assign_links.()
    |> render(template)
  end

  # The seat went between the confirm page and the submit: the token still
  # resolves its guest, so the full page can show the organiser's links.
  defp full_with_guest(token) do
    case Meetings.get_guest_invitation(token) do
      {:ok, guest} -> {:error, :full, guest}
      _not_found -> {:error, :full}
    end
  end

  defp error_page({:error, :rate_limited, _message}), do: {:too_many_requests, :too_many_requests}
  defp error_page({:error, :meeting_closed}), do: {:gone, :closed}
  defp error_page({:error, :full}), do: {:conflict, :full}
  defp error_page({:error, :full, _guest}), do: {:conflict, :full}
  defp error_page(_error), do: {:not_found, :invalid}
end
