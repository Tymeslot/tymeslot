defmodule Tymeslot.Webhooks.InputValidation do
  @moduledoc """
  Webhook input validation and sanitization.

  Validates webhook configuration forms including name, URL, and event selection.
  Uses Ecto embedded schema for structured validation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ecto.Changeset
  alias Tymeslot.DatabaseSchemas.WebhookSchema
  alias Tymeslot.Security.RateLimiter

  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:url, :string)
    field(:events, {:array, :string}, default: [])
  end

  @doc """
  Validates webhook form input.

  ## Parameters
  - `params` - Map containing webhook form parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_webhook_form(map(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def validate_webhook_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case check_rate_limit("webhook_form", metadata) do
      :ok ->
        params
        |> perform_webhook_validation()
        |> handle_webhook_validation_result()

      {:error, :rate_limited} ->
        {:error, %{form: "Too many requests. Please slow down."}}
    end
  end

  @doc """
  Validates a webhook name update.
  """
  @spec validate_name_update(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_name_update(name, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case check_rate_limit("webhook_name", metadata) do
      :ok ->
        %{"name" => name}
        |> perform_name_update_validation()
        |> handle_name_update_result()

      {:error, :rate_limited} ->
        {:error, "Too many requests. Please slow down."}
    end
  end

  @doc """
  Validates a webhook URL update.
  """
  @spec validate_url_update(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_url_update(url, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case check_rate_limit("webhook_url", metadata) do
      :ok ->
        %{"url" => url}
        |> perform_url_update_validation()
        |> handle_url_update_result()

      {:error, :rate_limited} ->
        {:error, "Too many requests. Please slow down."}
    end
  end

  # Private functions

  defp handle_webhook_validation_result({:ok, validated}) do
    {:ok, Map.from_struct(validated)}
  end

  defp handle_webhook_validation_result({:error, changeset}) do
    {:error, translate_errors(changeset)}
  end

  defp perform_webhook_validation(params) do
    %__MODULE__{}
    |> cast(params, [:name, :url, :events])
    |> validate_required([:name], message: "Name cannot be empty")
    |> validate_required([:url])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:url, min: 1, max: 2048)
    |> validate_url_format()
    |> validate_events_list()
    |> apply_action(:validate)
  end

  defp handle_name_update_result({:ok, validated}), do: {:ok, validated.name}

  defp handle_name_update_result({:error, changeset}),
    do: {:error, get_first_error(changeset, :name)}

  defp perform_name_update_validation(params) do
    %__MODULE__{}
    |> cast(params, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> apply_action(:validate)
  end

  defp handle_url_update_result({:ok, validated}), do: {:ok, validated.url}

  defp handle_url_update_result({:error, changeset}),
    do: {:error, get_first_error(changeset, :url)}

  defp perform_url_update_validation(params) do
    %__MODULE__{}
    |> cast(params, [:url])
    |> validate_required([:url])
    |> validate_length(:url, min: 1, max: 2048)
    |> validate_url_format()
    |> apply_action(:validate)
  end

  defp validate_url_format(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case WebhookSchema.validate_url_format(url) do
        :ok -> []
        {:error, msg} -> [{:url, String.capitalize(msg)}]
      end
    end)
  end

  defp validate_events_list(changeset) do
    validate_change(changeset, :events, fn :events, events ->
      case WebhookSchema.validate_events_list(events) do
        :ok -> []
        {:error, msg} -> [{:events, String.capitalize(msg)}]
      end
    end)
  end

  defp check_rate_limit(bucket_key, _metadata) do
    case RateLimiter.check_rate_limit(bucket_key, 60, 60_000) do
      :ok -> :ok
      {:error, _reason} -> {:error, :rate_limited}
    end
  end

  defp translate_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _arg1, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {k, v} -> {k, List.first(v)} end)
    |> Map.new()
  end

  defp get_first_error(changeset, field) do
    case changeset.errors[field] do
      {msg, opts} ->
        Regex.replace(~r/%{(\w+)}/, msg, fn _arg1, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)

      _other ->
        "Invalid input"
    end
  end
end
