defmodule Tymeslot.Webhooks.InputValidation do
  @moduledoc """
  Webhook input validation and sanitization.

  Validates webhook configuration forms including name, URL, and event selection.
  Uses Ecto embedded schema for structured validation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ecto.Changeset
  alias Tymeslot.ChangesetValidators.URL, as: URLValidator
  alias Tymeslot.Security.{RateLimiter, UniversalSanitizer}
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Webhooks.{SsrfValidator, WebhookSchema}

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
          {:ok, map()} | {:error, map() | :rate_limited}
  def validate_webhook_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case check_rate_limit("webhook_form", metadata) do
      :ok ->
        with {:ok, sanitized_params} <- sanitize_text_fields(params, metadata) do
          sanitized_params
          |> perform_webhook_validation()
          |> handle_webhook_validation_result()
        end

      {:error, :rate_limited} = refusal ->
        # Deliberately not a field error map: a throttled request is not a
        # problem with any field, and the caller keyed it `:form`, which the
        # blur handler looks past (deleting the field's real error) and the
        # modal never renders. The web layer owns the copy.
        refusal
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
    |> validate_length(:name, Constraints.webhook_name_length_opts())
    |> validate_length(:url, min: 1, max: Constraints.url_max_length())
    |> validate_url_format()
    |> validate_events_list()
    |> apply_action(:validate)
  end

  defp validate_url_format(changeset) do
    URLValidator.validate_url(changeset, :url,
      block_private_ips: not SsrfValidator.allow_private?(),
      enforce_https: not SsrfValidator.allow_private?()
    )
  end

  defp validate_events_list(changeset) do
    validate_change(changeset, :events, fn :events, events ->
      case WebhookSchema.validate_events_list(events) do
        :ok -> []
        {:error, msg} -> [{:events, String.capitalize(msg)}]
      end
    end)
  end

  # `Tymeslot.Security.RateLimiter.Integrations` states the rule this used to
  # break: never one instance-wide bucket, the actor is always required.
  # A bare literal key gave every logged-in user of an instance the same 60/min
  # budget, so one of them could refuse webhook edits for all the others.
  defp check_rate_limit(bucket_key, metadata) do
    case RateLimiter.check_rate_limit(actor_bucket(bucket_key, metadata), 60, 60_000) do
      :ok -> :ok
      {:error, _reason} -> {:error, :rate_limited}
    end
  end

  defp actor_bucket(bucket_key, %{user_id: nil} = metadata),
    do: actor_bucket(bucket_key, Map.delete(metadata, :user_id))

  defp actor_bucket(bucket_key, %{user_id: user_id}), do: "#{bucket_key}:user:#{user_id}"

  defp actor_bucket(bucket_key, %{ip: ip}) when is_binary(ip), do: "#{bucket_key}:ip:#{ip}"

  # Still reachable: validate_webhook_form/2's `metadata` opt defaults to
  # %{}, so a caller that omits it (every current one supplies it) falls
  # through to a bare, instance-wide bucket rather than crashing.
  defp actor_bucket(bucket_key, _metadata), do: bucket_key

  defp translate_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _arg1, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {k, v} -> {k, List.first(v)} end)
    |> Map.new()
  end

  defp sanitize_text_fields(params, metadata) do
    with {:ok, sanitized_name} <- sanitize_field_for_form(params["name"], :name, metadata),
         {:ok, sanitized_url} <- sanitize_field_for_form(params["url"], :url, metadata) do
      {:ok, params |> Map.put("name", sanitized_name) |> Map.put("url", sanitized_url)}
    end
  end

  defp sanitize_field_for_form(value, _field, _metadata) when value in [nil, ""], do: {:ok, value}

  defp sanitize_field_for_form(value, field, metadata) when is_binary(value) do
    case UniversalSanitizer.sanitize_and_validate(value, mode: :plain_text, metadata: metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, reason} -> {:error, %{field => reason}}
    end
  end

  defp sanitize_field_for_form(_value, field, _metadata),
    do: {:error, %{field => "must be a string"}}
end
