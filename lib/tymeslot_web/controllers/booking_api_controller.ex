defmodule TymeslotWeb.BookingApiController do
  @moduledoc """
  `POST /api/v1/bookings` — creates a booking on an organiser's behalf.

  Callers authenticate with the organiser's booking API token, presented as
  `Authorization: Bearer <token>`. A missing, malformed or unknown token is
  answered with 401 and nothing else, so the endpoint never reveals which
  tokens exist. Requests are rate-limited by client IP before the token is
  looked up, and by organiser afterwards, so an unauthenticated flood cannot
  spend a legitimate caller's budget.

  Sending an `Idempotency-Key` header makes a request safe to retry: the repeat
  is answered `200` with the meeting the first attempt created, where a first
  booking is answered `201`.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.BookingApi
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @rate_window_ms 60_000
  @ip_rate_limit 120
  @organiser_rate_limit 60

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    with :ok <- check_ip_rate(conn),
         {:ok, token} <- bearer_token(conn),
         {:ok, profile} <- BookingApi.authenticate(token),
         :ok <- check_organiser_rate(profile.user_id) do
      book(conn, profile)
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  # Private — the booking itself

  defp book(conn, profile) do
    case BookingApi.create_booking(profile, body_params(conn), idempotency_key(conn)) do
      {:ok, :created, meeting} -> render_meeting(conn, 201, meeting)
      {:ok, :replayed, meeting} -> render_meeting(conn, 200, meeting)
      {:error, reason} -> failure(conn, reason)
    end
  end

  # The action's own `params` are the body merged with the path and query
  # string. Reading the body on its own is what keeps a caller from passing
  # attendee details in the URL, where they would reach the access log.
  defp body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_params(%Plug.Conn{body_params: body}) when is_map(body), do: body

  defp render_meeting(conn, status, meeting) do
    conn
    |> put_status(status)
    |> json(%{meeting: meeting_payload(meeting)})
  end

  # `meeting_url` is null when the meeting type provisions a video room: the
  # room is created by a background job, and the link reaches the attendee with
  # their invitation rather than in this response.
  defp meeting_payload(meeting) do
    %{
      uid: meeting.uid,
      status: meeting.status,
      title: meeting.title,
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      duration_minutes: meeting.duration,
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email,
      attendee_timezone: meeting.attendee_timezone,
      attendee_locale: meeting.attendee_locale,
      view_url: meeting.view_url,
      reschedule_url: meeting.reschedule_url,
      cancel_url: meeting.cancel_url,
      meeting_url: meeting.meeting_url
    }
  end

  # Private — authentication and rate limiting

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> present(String.trim(token))
      _other -> {:error, :unauthorized}
    end
  end

  defp present(""), do: {:error, :unauthorized}
  defp present(token), do: {:ok, token}

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] -> nilify(String.trim(key))
      _other -> nil
    end
  end

  defp nilify(""), do: nil
  defp nilify(key), do: key

  defp check_ip_rate(conn) do
    allow("booking_api:ip:#{ClientIP.get(conn)}", @ip_rate_limit)
  end

  # Keyed on the organiser rather than the token, so regenerating a leaked token
  # does not hand its budget back to whoever was spending it.
  defp check_organiser_rate(user_id) do
    allow("booking_api:user:#{user_id}", @organiser_rate_limit)
  end

  defp allow(bucket_key, limit) do
    case RateLimiter.check_rate(bucket_key, @rate_window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, :rate_limited}
    end
  end

  # Private — failures

  defp failure(conn, {:invalid_params, violations}) do
    error(conn, 400, "invalid_params", "The request body was not accepted.", violations)
  end

  defp failure(conn, :unauthorized) do
    error(conn, 401, "unauthorized", "A valid booking API token is required.")
  end

  defp failure(conn, :not_found) do
    error(conn, 401, "unauthorized", "A valid booking API token is required.")
  end

  defp failure(conn, :rate_limited) do
    error(conn, 429, "rate_limited", "Too many requests. Try again shortly.")
  end

  defp failure(conn, :meeting_type_not_found) do
    error(conn, 422, "meeting_type_not_found", "No active meeting type has that slug.")
  end

  defp failure(conn, :meeting_type_requires_payment) do
    error(
      conn,
      422,
      "meeting_type_requires_payment",
      "This meeting type is paid and can only be booked through the payment flow."
    )
  end

  defp failure(conn, :slot_unavailable) do
    error(
      conn,
      409,
      "slot_unavailable",
      "The organiser is not free then. Send force: true to book anyway."
    )
  end

  defp failure(conn, :time_conflict) do
    error(conn, 409, "time_conflict", "The organiser already has a meeting at that time.")
  end

  defp failure(conn, :in_progress) do
    error(
      conn,
      409,
      "in_progress",
      "An earlier request with this idempotency key is still being processed."
    )
  end

  defp failure(conn, reason) when reason in [:insufficient_plan, :pro_required] do
    error(conn, 403, "upgrade_required", "The organiser's plan does not include the booking API.")
  end

  defp failure(conn, reason) when is_atom(reason) do
    error(conn, 403, "forbidden", "The booking API is not available to this organiser.")
  end

  # The domain layer passes validation text through unchanged rather than
  # manufacturing display copy; it is returned here as the violation message.
  defp failure(conn, reason) when is_binary(reason) do
    error(conn, 422, "booking_rejected", reason)
  end

  defp error(conn, status, code, message, violations \\ []) do
    body = %{error: %{code: code, message: message}}
    body = if violations == [], do: body, else: put_in(body, [:error, :violations], violations)

    conn
    |> put_status(status)
    |> json(body)
  end
end
