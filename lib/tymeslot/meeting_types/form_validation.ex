defmodule Tymeslot.MeetingTypes.FormValidation do
  @moduledoc """
  Preconditions on a form-driven meeting-type write.

  Two different questions, both of which must be answered server-side because
  the form can be forged:

    * **May this host make this change?** Custom questions and paid meeting
      types sit behind feature flags. Core's default checker allows everything,
      so self-hosters are unaffected; the managed overlay narrows them.

    * **Do the referenced records exist, still work, and belong to this host?**
      A video or calendar integration id can be stale by the time it is
      submitted: the integration may have been deleted, deactivated, or had the
      chosen calendar turn read-only since the picker rendered. An availability
      schedule id additionally has to be *owned*, because the referenced
      schedule goes on to drive what the public booking page offers.

  Both gates deliberately restrict only the *permissive* direction. Turning
  payment off, or saving no questions, is always allowed, so a host who has
  downgraded can still edit their way back into compliance rather than being
  locked out of their own meeting types.
  """

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Features
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.UriUtils

  @typedoc "Why a write was refused."
  @type error ::
          :video_integration_required
          | :invalid_video_integration
          | :calendar_integration_required
          | :calendar_integration_invalid
          | :target_calendar_required
          | :target_calendar_invalid
          | :no_writable_calendars
          | :invalid_availability_schedule
          | atom()

  @doc """
  Runs every precondition against the attributes about to be written.
  """
  @spec check(integer(), map()) :: :ok | {:error, error()}
  def check(user_id, attrs) do
    with :ok <- gate_custom_fields(user_id, attrs),
         :ok <- gate_payment(user_id, attrs),
         :ok <- validate_availability_schedule(attrs, user_id),
         :ok <- validate_video_integration(attrs, user_id) do
      validate_calendar_integration(attrs, user_id)
    end
  end

  # The picker only ever lists this profile's own schedules, but the form posts
  # a bare id and can be forged, and a foreign id would otherwise be accepted:
  # the schema's `foreign_key_constraint` proves the row exists, not who owns
  # it. `Schedules.resolve_for_meeting_type/1` looks the id up unscoped at
  # booking time, so an unowned id would silently drive this meeting type's
  # public availability from someone else's hours.
  # Both write paths reach here with the id as a string, so it is normalised
  # rather than matched on shape. A blank one means "follow the profile's
  # default" and needs no check.
  defp validate_availability_schedule(attrs, user_id) do
    case schedule_id(Map.get(attrs, :availability_schedule_id)) do
      :none -> :ok
      :invalid -> {:error, :invalid_availability_schedule}
      id -> schedule_owned?(id, user_id)
    end
  end

  defp schedule_id(nil), do: :none
  defp schedule_id(id) when is_integer(id) and id > 0, do: id

  defp schedule_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> if String.trim(id) == "", do: :none, else: :invalid
    end
  end

  defp schedule_id(_other), do: :invalid

  defp schedule_owned?(id, user_id) do
    with %{id: profile_id} <- Profiles.get_profile(user_id),
         %{} <- Schedules.get_for_profile(id, profile_id) do
      :ok
    else
      _not_owned -> {:error, :invalid_availability_schedule}
    end
  end

  # Only writes that would add or modify a non-empty question list are gated —
  # an absent or empty list (the no-questions path) is always allowed.
  defp gate_custom_fields(user_id, attrs) do
    case Map.get(attrs, :custom_fields) do
      nil -> :ok
      fields when fields == [] or fields == %{} -> :ok
      _non_empty -> Features.check_access(user_id, :custom_questions_allowed)
    end
  end

  # `:stripe_required` is treated as allowed at this layer: the host has the
  # plan but no charges-enabled Connect account yet. The schema changeset
  # (driven by `FormMapper.payment_opts/1`'s `host_charges_enabled`) is the
  # authority on whether a price may actually be persisted without a live
  # account.
  defp gate_payment(user_id, %{payment_required: true}) do
    case Features.check_access(user_id, :meeting_payments) do
      :ok -> :ok
      {:error, :stripe_required} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp gate_payment(_user_id, _attrs), do: :ok

  defp validate_video_integration(%{allow_video: true, video_integration_id: nil}, _user_id) do
    {:error, :video_integration_required}
  end

  defp validate_video_integration(%{allow_video: true, video_integration_id: ""}, _user_id),
    do: {:error, :video_integration_required}

  defp validate_video_integration(%{allow_video: true, video_integration_id: id}, user_id)
       when is_integer(id) do
    case Video.fetch_integration_for_user(id, user_id) do
      {:ok, %{is_active: true}} -> :ok
      {:ok, _integration} -> {:error, :invalid_video_integration}
      {:error, :not_found} -> {:error, :invalid_video_integration}
    end
  end

  defp validate_video_integration(_attrs, _user_id), do: :ok

  defp validate_calendar_integration(
         %{calendar_integration_id: nil, target_calendar_id: nil},
         _user_id
       ),
       do: :ok

  defp validate_calendar_integration(
         %{calendar_integration_id: "", target_calendar_id: nil},
         _user_id
       ),
       do: :ok

  defp validate_calendar_integration(%{calendar_integration_id: nil}, _user_id),
    do: {:error, :calendar_integration_required}

  defp validate_calendar_integration(
         %{calendar_integration_id: "", target_calendar_id: _target},
         _user_id
       ),
       do: {:error, :calendar_integration_required}

  defp validate_calendar_integration(
         %{calendar_integration_id: id, target_calendar_id: target_calendar_id},
         user_id
       )
       when is_integer(id) do
    with {:ok, integration} <- CalendarManagement.fetch_integration_for_user(id, user_id),
         :ok <- validate_target_calendar(target_calendar_id, integration) do
      :ok
    else
      {:error, :not_found} -> {:error, :calendar_integration_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp validate_calendar_integration(%{calendar_integration_id: id}, _user_id)
       when is_binary(id) and id != "" do
    {:error, :calendar_integration_invalid}
  end

  defp validate_calendar_integration(_other_attrs, _user_id), do: :ok

  defp validate_target_calendar(nil, integration), do: target_calendar_missing_error(integration)

  defp validate_target_calendar("", integration), do: target_calendar_missing_error(integration)

  defp validate_target_calendar(target_calendar_id, integration) do
    calendar_list = integration.calendar_list

    if calendar_list == [] do
      :ok
    else
      # Only writable calendars are valid save targets — the same set the
      # picker offers (`Tymeslot.Integrations.Calendar.writable_calendars/1`).
      # A deselected or read-only id must be rejected here even though it is
      # still present in the full `calendar_list`, otherwise a stored
      # `target_calendar_id` that became read-only after a refresh would
      # keep saving successfully while every booking against it fails later.
      found? =
        Enum.any?(Calendar.writable_calendars(calendar_list), fn cal ->
          UriUtils.uri_safe_match?(cal.id, target_calendar_id)
        end)

      if found?, do: :ok, else: {:error, :target_calendar_invalid}
    end
  end

  # No target chosen yet. Distinguishes the ordinary "not selected yet" state
  # from the dead end where every calendar the user selected for this
  # integration is read-only, so the picker has nothing to offer and
  # `:target_calendar_required` would leave the user stuck with no way to
  # comply.
  defp target_calendar_missing_error(integration) do
    if Calendar.all_selected_read_only?(integration.calendar_list) do
      {:error, :no_writable_calendars}
    else
      {:error, :target_calendar_required}
    end
  end
end
