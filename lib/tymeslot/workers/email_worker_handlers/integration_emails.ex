defmodule Tymeslot.Workers.EmailWorkerHandlers.IntegrationEmails do
  @moduledoc """
  Handles integration- and calendar-related email actions: integration health notifications,
  calendar invitations, and event update notifications.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Infrastructure.Config

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.RoomCreationError
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome

  @spec handle_integration_unhealthy_notification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_integration_unhealthy_notification(%{
        "user_id" => user_id,
        "integration_id" => integration_id,
        "integration_type" => integration_type
      }) do
    with {:ok, user} <- UserQueries.get_user(user_id),
         {:ok, integration} <- fetch_integration(integration_type, integration_id) do
      type_atom = safe_integration_type_atom(integration_type)

      case Config.email_service_module().send_integration_unhealthy_notification(
             user,
             integration,
             type_atom
           ) do
        {:ok, _result} ->
          Logger.info("Integration unhealthy notification sent",
            user_id: user_id,
            integration_id: integration_id,
            type: integration_type
          )

          IntegrationHealthStateQueries.update_fields(
            integration_type,
            integration_id,
            notification_sent_at: DateTime.utc_now()
          )

          :ok

        {:error, reason} ->
          Logger.error("Failed to send integration unhealthy notification",
            user_id: user_id,
            integration_id: integration_id,
            error: inspect(reason)
          )

          DeliveryOutcome.from_error(reason, "Failed to send notification")
      end
    else
      {:error, :not_found} ->
        Logger.warning("User or integration not found for unhealthy notification",
          user_id: user_id,
          integration_id: integration_id
        )

        {:discard, "User or integration not found"}
    end
  end

  @spec handle_integration_reauth_notification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_integration_reauth_notification(%{
        "user_id" => user_id,
        "integration_id" => integration_id,
        "integration_type" => integration_type
      }) do
    with {:ok, user} <- UserQueries.get_user(user_id),
         {:ok, integration} <- fetch_integration(integration_type, integration_id) do
      send_reauth_notification(user, integration, integration_type)
    else
      {:error, :not_found} ->
        Logger.warning("User or integration not found for reauth notification",
          user_id: user_id,
          integration_id: integration_id
        )

        {:discard, "User or integration not found"}
    end
  end

  # The integration is re-read at send time rather than trusted from the job
  # args, so a user who reconnected between the flag and the send is not told
  # to reconnect something that already works.
  defp send_reauth_notification(_user, %{needs_reauth: false} = integration, integration_type) do
    Logger.info("Integration no longer needs reauth, discarding notification",
      integration_id: integration.id,
      type: integration_type
    )

    {:discard, "Integration no longer needs reauth"}
  end

  defp send_reauth_notification(user, integration, integration_type) do
    type_atom = safe_integration_type_atom(integration_type)

    case Config.email_service_module().send_integration_reauth_notification(
           user,
           integration,
           type_atom
         ) do
      {:ok, _result} ->
        Logger.info("Integration reauth notification sent",
          user_id: user.id,
          integration_id: integration.id,
          type: integration_type
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to send integration reauth notification",
          user_id: user.id,
          integration_id: integration.id,
          error: inspect(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to send notification")
    end
  end

  @spec handle_integration_paused_notification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_integration_paused_notification(%{
        "user_id" => user_id,
        "integration_id" => integration_id,
        "integration_type" => integration_type,
        "cutoff_days" => cutoff_days
      }) do
    with {:ok, user} <- UserQueries.get_user(user_id),
         {:ok, integration} <- fetch_integration(integration_type, integration_id) do
      type_atom = safe_integration_type_atom(integration_type)

      case Config.email_service_module().send_integration_paused_notification(
             user,
             integration,
             type_atom,
             cutoff_days
           ) do
        {:ok, _result} ->
          Logger.info("Integration paused notification sent",
            user_id: user_id,
            integration_id: integration_id,
            type: integration_type
          )

          :ok

        {:error, reason} ->
          Logger.error("Failed to send integration paused notification",
            user_id: user_id,
            integration_id: integration_id,
            error: inspect(reason)
          )

          DeliveryOutcome.from_error(reason, "Failed to send notification")
      end
    else
      {:error, :not_found} ->
        Logger.warning("User or integration not found for paused notification",
          user_id: user_id,
          integration_id: integration_id
        )

        {:discard, "User or integration not found"}
    end
  end

  @spec handle_video_room_creation_error_notification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_video_room_creation_error_notification(%{
        "user_id" => user_id,
        "integration_id" => integration_id,
        "error_code" => error_code
      }) do
    with {:ok, code} <- RoomCreationError.parse(error_code),
         {:ok, user} <- UserQueries.get_user(user_id),
         {:ok, integration} <- fetch_integration("video", integration_id),
         :ok <- still_worth_sending(integration, code) do
      deliver_room_creation_error_notification(user, integration, code)
    else
      :error ->
        Logger.warning("Unknown video room creation error code, discarding notification",
          integration_id: integration_id,
          code: error_code
        )

        {:discard, "Unknown room creation error code"}

      {:error, :not_found} ->
        Logger.warning("User or integration not found for room creation error notification",
          user_id: user_id,
          integration_id: integration_id
        )

        {:discard, "User or integration not found"}

      {:discard, _reason} = discard ->
        discard
    end
  end

  # The integration is re-read at send time, so an owner whose server was fixed
  # (and whose next booking got its room) between the refusal and the send is
  # not told about something that already works, and an integration switched
  # off or disconnected meanwhile is not told about bookings it no longer
  # takes. Each of these gives the claim on the email back, so the one notice
  # the owner gets is not spent on an email nobody receives.
  defp still_worth_sending(%{room_creation_error: code, is_active: true, deleted_at: nil}, code),
    do: :ok

  defp still_worth_sending(integration, code) do
    RoomCreationError.release(integration.id, code)

    Logger.info("Video room creation refusal no longer worth an email, discarding notification",
      integration_id: integration.id,
      code: code
    )

    {:discard, "Room creation error no longer recorded"}
  end

  defp deliver_room_creation_error_notification(user, integration, code) do
    case Config.email_service_module().send_video_room_creation_error_notification(
           user,
           integration
         ) do
      {:ok, _result} ->
        Logger.info("Video room creation error notification sent",
          user_id: user.id,
          integration_id: integration.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to send video room creation error notification",
          user_id: user.id,
          integration_id: integration.id,
          error: inspect(reason)
        )

        delivery_failure(reason, integration, code)
    end
  end

  # A rejected recipient is the one failure no retry mends, so the claim goes
  # back: the owner was never told, and the next refusal may reach an address
  # that works. Anything else is retried with the claim still held, since the
  # email may yet go out.
  defp delivery_failure({:recipient_rejected, _reason} = rejection, integration, code) do
    RoomCreationError.release(integration.id, code)
    DeliveryOutcome.from_error(rejection, "Failed to send notification")
  end

  defp delivery_failure(reason, _integration, _code),
    do: DeliveryOutcome.from_error(reason, "Failed to send notification")

  @spec handle_calendar_invitation(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_calendar_invitation(%{"user_id" => user_id} = args) do
    with {:ok, user} <- UserQueries.get_user(user_id),
         {:ok, details} <- build_invitation_details(user, args),
         {:ok, _email_result} <-
           Config.email_service_module().send_calendar_invitation(args["attendee_email"], details) do
      Logger.info("Calendar invitation sent",
        attendee_email: args["attendee_email"],
        event_uid: args["event_uid"]
      )

      :ok
    else
      {:error, :not_found} ->
        Logger.warning("User not found for calendar invitation", user_id: user_id)
        {:discard, "User not found"}

      {:error, "Invalid datetime: " <> _rest = reason} ->
        Logger.warning("Invalid datetime in calendar invitation args", reason: reason)
        {:discard, reason}

      {:error, reason} ->
        Logger.error("Failed to send calendar invitation",
          attendee_email: args["attendee_email"],
          error: inspect(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to send calendar invitation")
    end
  end

  @spec handle_event_update_notification(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_event_update_notification(
        %{"event_uid" => event_uid, "integration_id" => integration_id} = args
      ) do
    with {:ok, user} <- UserQueries.get_user(args["user_id"]),
         {:ok, current_event} <-
           CalendarGrid.get_cached_event(integration_id, event_uid),
         {:ok, changes} <- compute_changes(current_event, args),
         false <- changes == [] do
      details = build_update_details(user, current_event, changes, args)

      results =
        Enum.map(args["attendee_emails"], fn email ->
          Config.email_service_module().send_event_update_notification(email, details)
        end)

      errors = Enum.filter(results, &match?({:error, _reason}, &1))

      if errors == [] do
        Logger.info("Event update notifications sent",
          event_uid: event_uid,
          attendee_count: length(args["attendee_emails"])
        )

        :ok
      else
        Logger.error("Some event update notifications failed",
          event_uid: event_uid,
          error_count: length(errors)
        )

        {:discard,
         "Partial delivery failure: #{length(errors)} of #{length(args["attendee_emails"])} failed"}
      end
    else
      {:error, :not_found} ->
        Logger.warning("Event or user not found for update notification",
          event_uid: event_uid
        )

        {:discard, "Event or user not found"}

      true ->
        Logger.info("No effective changes detected, skipping notification",
          event_uid: event_uid
        )

        :ok
    end
  end

  defp build_invitation_details(user, args) do
    with {:ok, start_time} <- parse_datetime(args["event_start_at"]),
         {:ok, end_time} <- parse_datetime(args["event_end_at"]) do
      duration = DateTime.diff(end_time, start_time, :minute)

      {:ok,
       %{
         event_title: args["event_title"],
         event_uid: args["event_uid"],
         start_time: start_time,
         end_time: end_time,
         date: DateTime.to_date(start_time),
         duration: duration,
         location: args["event_location"],
         description: args["event_description"],
         organizer_name: user.name || user.email,
         organizer_email: user.email
       }}
    end
  end

  defp parse_datetime(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> {:error, "Invalid datetime: #{iso_string}"}
    end
  end

  defp fetch_integration("calendar", integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, _integration} = ok ->
        ok

      {:error, :not_found} = not_found ->
        not_found

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
        {:error, :not_found}
    end
  end

  defp fetch_integration("video", integration_id) do
    case VideoIntegrationQueries.get(integration_id) do
      {:ok, _integration} = ok ->
        ok

      {:error, :not_found} = not_found ->
        not_found

      {:error, :requires_reencryption, integration} ->
        Video.handle_reauth_required(integration)
        {:error, :not_found}
    end
  end

  defp fetch_integration(_type, _id), do: {:error, :not_found}

  defp safe_integration_type_atom("calendar"), do: :calendar
  defp safe_integration_type_atom("video"), do: :video

  defp safe_integration_type_atom(type) do
    Logger.warning("Unknown integration type in email worker", type: type)
    :unknown
  end

  defp compute_changes(current_event, args) do
    changes =
      []
      |> maybe_add_change(:title, args["before_title"], current_event.summary)
      |> maybe_add_change(:location, args["before_location"], current_event.location)
      |> maybe_add_change(:description, args["before_description"], current_event.description)
      |> maybe_add_time_change(args, current_event)

    {:ok, changes}
  end

  defp maybe_add_change(changes, field, before_val, current_val) do
    before_normalised = normalise_blank(before_val)
    current_normalised = normalise_blank(current_val)

    if before_normalised != current_normalised do
      [{field, before_val, current_val} | changes]
    else
      changes
    end
  end

  defp maybe_add_time_change(changes, args, current_event) do
    with before_start when is_binary(before_start) <- args["before_start_at"],
         before_end when is_binary(before_end) <- args["before_end_at"],
         {:ok, before_start_dt, _offset} <- DateTime.from_iso8601(before_start),
         {:ok, before_end_dt, _offset} <- DateTime.from_iso8601(before_end) do
      start_changed = DateTime.compare(before_start_dt, current_event.start_at) != :eq
      end_changed = DateTime.compare(before_end_dt, current_event.end_at) != :eq

      if start_changed or end_changed do
        [{:time, before_start_dt, current_event.start_at} | changes]
      else
        changes
      end
    else
      _no_before_times -> changes
    end
  end

  defp parse_method("cancel"), do: :cancel
  defp parse_method("request"), do: :request
  defp parse_method(_other), do: :request

  defp normalise_blank(nil), do: nil
  defp normalise_blank(""), do: nil
  defp normalise_blank(val), do: val

  defp build_update_details(user, current_event, changes, args) do
    duration = DateTime.diff(current_event.end_at, current_event.start_at, :minute)

    %{
      event_title: current_event.summary,
      event_uid: current_event.uid,
      start_time: current_event.start_at,
      end_time: current_event.end_at,
      date: DateTime.to_date(current_event.start_at),
      duration: duration,
      location: current_event.location,
      description: current_event.description,
      organizer_name: user.name || user.email,
      organizer_email: user.email,
      changes: changes,
      method: parse_method(args["method"]),
      sequence: args["sequence"]
    }
  end
end
