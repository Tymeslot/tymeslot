defmodule Tymeslot.Bookings.DemoOrchestrator do
  @moduledoc """
  Demo version of the booking orchestrator that simulates booking creation
  without any real side effects.

  This orchestrator:
  - Returns realistic meeting data
  - Doesn't create database records
  - Doesn't send emails
  - Doesn't create calendar events
  - Doesn't create video rooms
  """

  alias Ecto.UUID
  alias Tymeslot.Demo

  require Logger

  @typedoc """
  Minimal meeting map returned by the demo orchestrator.

  This is intentionally untyped because it is a simulated Ecto struct literal
  (`%{__struct__: Tymeslot.Bookings.Meeting, ...}`) whose shape mirrors the real
  schema at runtime rather than being a proper struct type.
  """
  @type meeting :: map()

  @typedoc "Parameters for `submit_booking/2`."
  @type booking_submission_params :: %{
          optional(:form_data) => %{String.t() => term()},
          optional(:meeting_params) => map()
        }

  @doc """
  Simulates booking submission for demo mode.

  Returns a mock meeting struct that looks real but isn't persisted.
  """
  @spec submit_booking(booking_submission_params(), keyword()) ::
          {:ok, meeting()} | {:error, term()}
  def submit_booking(params, opts \\ []) do
    Logger.info("Demo mode: Simulating booking submission")

    rng = Keyword.get(opts, :rng, &:rand.uniform/1)

    with {:ok, normalized_params} <- normalize_params(params),
         {:ok, start_time} <- parse_start_time(normalized_params[:meeting_params]),
         {:ok, mock_meeting} <-
           create_mock_meeting(
             normalized_params,
             normalized_params[:form_data],
             start_time,
             rng,
             opts
           ) do
      Logger.info("Demo mode: Successfully created mock booking")
      {:ok, mock_meeting}
    else
      {:error, _reason} = err -> err
    end
  end

  defp normalize_params(params) do
    meeting_params = params[:meeting_params] || %{}
    organizer_user_id = meeting_params[:organizer_user_id]
    duration = normalize_duration(meeting_params[:duration])

    cond do
      not is_integer(organizer_user_id) ->
        {:error, :invalid_params}

      not (is_integer(duration) and duration > 0 and duration <= 24 * 60) ->
        {:error, :invalid_duration}

      true ->
        normalized = %{
          form_data: params[:form_data] || %{},
          meeting_params: Map.put(meeting_params, :duration, duration),
          organizer_user_id: organizer_user_id
        }

        {:ok, normalized}
    end
  end

  # Normalize supported duration formats to integer minutes.
  # Accepts integers, numeric strings, and strings like "30min"/"30 m"/"30m".
  defp normalize_duration(duration) when is_integer(duration), do: duration

  defp normalize_duration(duration) when is_binary(duration) do
    trimmed = String.trim(duration)

    with {int, rest} <- Integer.parse(trimmed),
         true <- suffix_valid?(String.trim_leading(rest)) do
      int
    else
      _other ->
        case Regex.run(~r/^(\d+)\s*m(in)?$/i, trimmed) do
          [_match, digits | _rest] -> String.to_integer(digits)
          _other -> nil
        end
    end
  end

  defp normalize_duration(_other), do: nil

  defp suffix_valid?(""), do: true
  defp suffix_valid?(suffix), do: String.match?(suffix, ~r/^m(in)?$/i)

  defp parse_start_time(%{date: date, time: time, user_timezone: tz}) do
    with {:ok, d} <- Date.from_iso8601(date),
         {:ok, t} <- Time.from_iso8601(time <> ":00"),
         {:ok, ndt} <- NaiveDateTime.new(d, t),
         {:ok, dt} <- DateTime.from_naive(ndt, tz) do
      {:ok, dt}
    else
      _other -> {:error, :invalid_datetime}
    end
  end

  defp parse_start_time(_other), do: {:error, :invalid_datetime}

  defp create_mock_meeting(params, validated_data, start_time, rng, _opts) do
    %{
      meeting_params: meeting_params,
      organizer_user_id: organizer_user_id
    } = params

    # Compute times
    duration = meeting_params.duration
    end_time = DateTime.add(start_time, duration * 60, :second)

    # Get organizer info with profile via Demo provider to avoid database dependency for demo users
    organizer =
      case Demo.get_user_by_id(organizer_user_id) do
        nil ->
          nil

        user ->
          case Demo.get_profile_by_user_id(user.id) do
            nil -> %{user | profile: nil}
            profile -> %{user | profile: profile}
          end
      end

    if is_nil(organizer) do
      {:error, :organizer_not_found}
    else
      # Build meeting attributes manually for demo
      attrs =
        build_demo_meeting_attributes(
          validated_data,
          meeting_params,
          organizer,
          start_time,
          end_time
        )

      # Create a mock meeting struct that looks real
      mock_meeting = %{
        __struct__: Tymeslot.Bookings.Meeting,
        id: rng.(99_999),
        uid: attrs.uid,
        title: attrs.title,
        summary: attrs.summary,
        start_time: attrs.start_time,
        end_time: attrs.end_time,
        duration: attrs.duration,
        timezone: attrs.timezone,
        organizer_user_id: organizer_user_id,
        organizer_name: attrs.organizer_name,
        organizer_email: attrs.organizer_email,
        attendee_name: attrs.attendee_name,
        attendee_email: attrs.attendee_email,
        attendee_phone: attrs.attendee_phone,
        attendee_company: attrs.attendee_company,
        attendee_message: attrs.attendee_message,
        location: attrs.location,
        meeting_url: generate_demo_meeting_url(rng),
        organizer_meeting_url: generate_demo_meeting_url(rng),
        reschedule_url: attrs.reschedule_url,
        cancel_url: attrs.cancel_url,
        status: "confirmed",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      # Log what would have happened in production
      Logger.info("Demo mode: Would have created meeting", meeting_uid: mock_meeting.uid)

      Logger.info("Demo mode: Would have sent confirmation email",
        attendee_email: mock_meeting.attendee_email
      )

      Logger.info("Demo mode: Would have created calendar event")
      Logger.info("Demo mode: Would have created video room")

      {:ok, mock_meeting}
    end
  end

  defp generate_demo_meeting_url(rng) do
    # Generate a realistic-looking demo meeting URL
    meeting_id = to_string(rng.(999_999_999))
    domain = Application.get_env(:tymeslot, :email)[:domain] || "tymeslot.app"
    "https://demo.#{domain}/meeting/#{meeting_id}"
  end

  defp build_demo_meeting_attributes(
         validated_data,
         meeting_params,
         organizer,
         start_time,
         end_time
       ) do
    # Generate UID
    uid = UUID.generate()

    %{
      uid: uid,
      title: "Meeting with #{validated_data["name"]}",
      summary: "#{meeting_params.duration}-minute meeting scheduled via Tymeslot",
      start_time: start_time,
      end_time: end_time,
      duration: meeting_params.duration,
      timezone: meeting_params.user_timezone,
      organizer_name: get_organizer_name(organizer),
      organizer_email: organizer.email,
      attendee_name: validated_data["name"],
      attendee_email: validated_data["email"],
      attendee_phone: validated_data["phone"],
      attendee_company: validated_data["company"],
      attendee_message: validated_data["message"],
      location: "Online Meeting",
      reschedule_url: build_demo_meeting_url(uid, "/reschedule", organizer),
      cancel_url: build_demo_meeting_url(uid, "/cancel", organizer)
    }
  end

  defp get_organizer_name(user) do
    if user.profile do
      user.profile.full_name || user.email
    else
      user.email
    end
  end

  defp build_demo_meeting_url(uid, path, organizer) do
    username = if organizer.profile, do: organizer.profile.username, else: nil

    if username do
      "/#{username}/meeting/#{uid}#{path}"
    else
      "/meeting/#{uid}#{path}"
    end
  end
end
