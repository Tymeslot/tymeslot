defmodule TymeslotWeb.AccountLive.ErrorFormatter do
  @moduledoc """
  Error formatting utilities for account management.
  Converts various error formats into consistent UI-friendly format.
  """

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
    %{base: ["Too many attempts. Please try again later."]}
  end

  def format({:error, message}) when is_binary(message) do
    format(message)
  end

  def format(message) when is_binary(message) do
    cond do
      message == "Current password is incorrect" ->
        %{current_password: [message]}

      String.contains?(message, "email") ->
        %{new_email: [message]}

      String.contains?(message, "match") ->
        %{new_password_confirmation: [message]}

      String.contains?(message, "8 characters") ->
        %{new_password: [message]}

      true ->
        %{base: [message]}
    end
  end

  def format(errors) when is_map(errors) do
    format_validation_errors(errors)
  end

  def format(_), do: %{base: ["An unexpected error occurred"]}

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
