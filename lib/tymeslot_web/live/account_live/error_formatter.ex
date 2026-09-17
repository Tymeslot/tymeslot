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
          | {atom(), String.t()}
          | map()
          | any()
        ) :: %{optional(atom()) => [String.t()]}
  def format({:error, :rate_limited, message}) do
    %{base: [message]}
  end

  def format(:rate_limited) do
    %{base: [dgettext("account", "Too many attempts. Please try again later.")]}
  end

  # A bare message carries no field, so it belongs to the form as a whole.
  def format({:error, message}) when is_binary(message) do
    %{base: [message]}
  end

  # Domain errors name the field they belong to, so placement never depends
  # on reading the (translated) message.
  def format({field, message}) when is_atom(field) and is_binary(message) do
    %{field => [message]}
  end

  def format(errors) when is_map(errors) do
    format_validation_errors(errors)
  end

  def format(_other), do: %{base: [dgettext("account", "An unexpected error occurred")]}

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
