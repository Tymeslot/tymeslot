defmodule TymeslotWeb.AccountLive.ErrorFormatter do
  @moduledoc """
  Error formatting utilities for account management.
  Converts various error formats into consistent UI-friendly format.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Formats errors from various sources into consistent format.
  """
  @spec format(
          {:error, :rate_limited, String.t()}
          | :rate_limited
          | {:error, String.t()}
          | String.t()
          | map()
          | any()
        ) :: %{optional(atom()) => [String.t()]}
  def format({:error, :rate_limited, message}) do
    %{base: [message]}
  end

  def format(:rate_limited) do
    %{base: [dgettext("account", "Too many attempts. Please try again later.")]}
  end

  def format({:error, message}) when is_binary(message) do
    format(message)
  end

  def format(message) when is_binary(message) do
    %{field_for(message) => [message]}
  end

  def format(errors) when is_map(errors) do
    format_validation_errors(errors)
  end

  def format(_other), do: %{base: [dgettext("account", "An unexpected error occurred")]}

  defp field_for("Current password is incorrect"), do: :current_password

  defp field_for(msg) do
    cond do
      String.contains?(msg, "email") -> :new_email
      String.contains?(msg, "match") -> :new_password_confirmation
      String.contains?(msg, "8 characters") -> :new_password
      true -> :base
    end
  end

  @doc """
  Formats validation errors from input processor.
  """
  @spec format_validation_errors(map()) :: %{optional(atom()) => [String.t()]}
  def format_validation_errors(errors) when is_map(errors) do
    Enum.into(errors, %{}, fn {field, message} ->
      {field, List.wrap(message)}
    end)
  end
end
