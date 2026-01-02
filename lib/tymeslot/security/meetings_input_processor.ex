defmodule Tymeslot.Security.MeetingsInputProcessor do
  @moduledoc """
  Input processor for meetings dashboard component.
  Handles validation and sanitization of meeting-related form inputs.
  """
  alias Ecto.UUID
  alias Tymeslot.Security.SecurityLogger
  alias Tymeslot.Security.UniversalSanitizer
  require Logger

  @valid_filters ["upcoming", "past", "cancelled"]

  @doc """
  Validates filter selection input for meeting filtering.

  ## Examples
      
      iex> validate_filter_input(%{"filter" => "upcoming"}, metadata: %{ip: "192.168.1.1"})
      {:ok, %{"filter" => "upcoming"}}
      
      iex> validate_filter_input(%{"filter" => "<script>alert(1)</script>"}, metadata: %{ip: "192.168.1.1"})
      {:error, %{filter: ["Invalid filter option"]}}
  """
  @spec validate_filter_input(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_filter_input(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case Map.get(params, "filter") do
      nil ->
        SecurityLogger.log_validation_failure(:meetings, "missing_filter", metadata)
        {:error, %{filter: ["Filter is required"]}}

      filter_value ->
        with {:ok, sanitized_filter} <-
               UniversalSanitizer.sanitize_and_validate(filter_value,
                 allow_html: false,
                 max_length: 20,
                 metadata: metadata
               ),
             :ok <- ensure_no_sanitization_change(filter_value, sanitized_filter, metadata),
             :ok <- ensure_valid_filter_option(sanitized_filter, metadata) do
          {:ok, %{"filter" => sanitized_filter}}
        else
          {:error, reason} when is_binary(reason) ->
            SecurityLogger.log_validation_failure(
              :meetings,
              "filter_sanitization_failed",
              Map.put(metadata, :reason, reason)
            )

            {:error, %{filter: [reason]}}

          {:error, :sanitization_changed} ->
            {:error, %{filter: ["Invalid characters in filter"]}}

          {:error, :invalid_option} ->
            {:error, %{filter: ["Invalid filter option"]}}
        end
    end
  end

  defp ensure_no_sanitization_change(original, sanitized, metadata) do
    if sanitized == original do
      :ok
    else
      SecurityLogger.log_validation_failure(
        :meetings,
        "filter_sanitization_applied",
        Map.put(metadata, :original_value, original)
      )

      {:error, :sanitization_changed}
    end
  end

  defp ensure_valid_filter_option(sanitized_filter, metadata) do
    if sanitized_filter in @valid_filters do
      :ok
    else
      SecurityLogger.log_validation_failure(
        :meetings,
        "invalid_filter_option",
        Map.put(metadata, :attempted_filter, sanitized_filter)
      )

      {:error, :invalid_option}
    end
  end

  @doc """
  Validates meeting ID input for meeting cancellation/reschedule.

  Accepts UUIDs and performs minimal sanitization without altering valid input.
  """
  @spec validate_meeting_id_input(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_meeting_id_input(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case Map.get(params, "id") do
      nil -> handle_missing_meeting_id(metadata)
      id_value when is_binary(id_value) -> validate_string_meeting_id(id_value, metadata)
      id_value -> handle_invalid_meeting_id_type(id_value, metadata)
    end
  end

  defp handle_missing_meeting_id(metadata) do
    SecurityLogger.log_validation_failure(:meetings, "missing_meeting_id", metadata)
    {:error, %{id: ["Meeting ID is required"]}}
  end

  defp handle_invalid_meeting_id_type(id_value, metadata) do
    SecurityLogger.log_validation_failure(
      :meetings,
      "invalid_meeting_id_type",
      Map.put(metadata, :attempted_id, inspect(id_value))
    )

    {:error, %{id: ["Meeting ID must be a string"]}}
  end

  defp validate_string_meeting_id(id_value, metadata) do
    case sanitize_meeting_id(id_value, metadata) do
      {:ok, sanitized_id} -> validate_sanitized_meeting_id(sanitized_id, id_value, metadata)
      {:error, reason} -> handle_sanitization_failure(reason, metadata)
    end
  end

  defp sanitize_meeting_id(id_value, metadata) do
    # Allow reasonable length for UUIDs and similar identifiers
    UniversalSanitizer.sanitize_and_validate(id_value,
      allow_html: false,
      max_length: 64,
      metadata: metadata
    )
  end

  defp validate_sanitized_meeting_id(sanitized_id, _original_id, metadata) do
    # Do minimal validation: ensure it's a valid UUID. We do NOT treat harmless
    # sanitization (like trimming) as an error.
    case UUID.cast(sanitized_id) do
      {:ok, uuid} ->
        {:ok, %{"id" => uuid}}

      :error ->
        SecurityLogger.log_validation_failure(
          :meetings,
          "invalid_meeting_id_format",
          Map.put(metadata, :attempted_id, sanitized_id)
        )

        {:error, %{id: ["Invalid meeting ID format"]}}
    end
  end

  defp handle_sanitization_failure(reason, metadata) do
    SecurityLogger.log_validation_failure(
      :meetings,
      "meeting_id_sanitization_failed",
      Map.put(metadata, :reason, reason)
    )

    {:error, %{id: [reason]}}
  end
end
