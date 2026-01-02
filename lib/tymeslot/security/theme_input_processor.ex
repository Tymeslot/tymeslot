defmodule Tymeslot.Security.ThemeInputProcessor do
  @moduledoc """
  Input processor for theme selection component.
  Handles validation and sanitization of theme selection inputs.
  """
  alias Tymeslot.Security.SecurityLogger
  alias Tymeslot.Security.UniversalSanitizer
  alias Tymeslot.Themes.Theme
  require Logger

  @doc """
  Validates theme selection input.

  ## Examples
      
      iex> validate_theme_selection(%{"theme" => "1"}, metadata: %{ip: "192.168.1.1", user_id: 1})
      {:ok, %{"theme" => "1"}}
      
      iex> validate_theme_selection(%{"theme" => "<script>alert(1)</script>"}, metadata: %{ip: "192.168.1.1", user_id: 1})
      {:error, %{theme: ["Invalid theme selection"]}}
  """
  @spec validate_theme_selection(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_theme_selection(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with theme when is_binary(theme) <- Map.get(params, "theme"),
         {:ok, sanitized_theme} <-
           UniversalSanitizer.sanitize_and_validate(theme,
             allow_html: false,
             max_length: 50,
             metadata: metadata
           ) do
      cond do
        sanitized_theme != theme ->
          SecurityLogger.log_validation_failure(
            :theme,
            "theme_sanitization_applied",
            Map.put(metadata, :original_value, theme)
          )

          {:error, %{theme: ["Invalid characters in theme selection"]}}

        not valid_theme_id?(sanitized_theme) ->
          SecurityLogger.log_validation_failure(
            :theme,
            "invalid_theme_id",
            Map.put(metadata, :attempted_theme, sanitized_theme)
          )

          {:error, %{theme: ["Invalid theme selection"]}}

        true ->
          {:ok, %{"theme" => sanitized_theme}}
      end
    else
      nil ->
        SecurityLogger.log_validation_failure(:theme, "missing_theme_id", metadata)
        {:error, %{theme: ["Theme selection is required"]}}

      theme_value when not is_binary(theme_value) ->
        SecurityLogger.log_validation_failure(
          :theme,
          "invalid_theme_type",
          Map.put(metadata, :attempted_theme, inspect(theme_value))
        )

        {:error, %{theme: ["Theme selection must be a string"]}}

      {:error, reason} ->
        SecurityLogger.log_validation_failure(
          :theme,
          "sanitization_failed",
          Map.put(metadata, :reason, reason)
        )

        {:error, %{theme: [reason]}}
    end
  end

  # Private helper functions

  defp valid_theme_id?(theme_id) do
    # Get available theme IDs from the Theme module
    available_theme_ids = Enum.map(Theme.theme_options(), fn {_name, id} -> id end)

    theme_id in available_theme_ids
  end
end
