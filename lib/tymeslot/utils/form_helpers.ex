defmodule Tymeslot.Utils.FormHelpers do
  @moduledoc """
  Utilities for handling form data and errors.
  """

  alias Ecto.Changeset

  @doc """
  Formats changeset errors into a map of field -> list of error messages.
  """
  @spec format_changeset_errors(Changeset.t()) :: map()
  def format_changeset_errors(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _full_match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Converts context error atoms to user-friendly error messages.
  """
  @spec format_context_error(atom() | any()) :: map()
  def format_context_error(:video_integration_required) do
    %{video_integration: ["Please select a video provider for video meetings"]}
  end

  def format_context_error(:invalid_video_integration) do
    %{video_integration: ["Selected video provider is invalid or inactive"]}
  end

  def format_context_error(:invalid_duration) do
    %{duration: ["Duration must be a valid number"]}
  end

  def format_context_error(:calendar_integration_required) do
    %{calendar_integration: ["Please select a calendar account"]}
  end

  def format_context_error(:calendar_integration_invalid) do
    %{calendar_integration: ["Selected calendar account is invalid"]}
  end

  def format_context_error(:target_calendar_required) do
    %{target_calendar: ["Please select a target calendar"]}
  end

  def format_context_error(:target_calendar_invalid) do
    %{target_calendar: ["Selected calendar is not available for this account"]}
  end

  def format_context_error(:invalid_price) do
    %{price_cents: ["Enter a valid price"]}
  end

  def format_context_error(error) when is_atom(error) do
    %{base: [format_generic_error(error)]}
  end

  def format_context_error(error) do
    %{base: [to_string(error)]}
  end

  defp format_generic_error(error) when is_atom(error) do
    error
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
