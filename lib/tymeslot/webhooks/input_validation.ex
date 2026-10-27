defmodule Tymeslot.Webhooks.InputValidation do
  @moduledoc """
  Webhook input validation and sanitization.

  Validates webhook configuration forms including name, URL, and event selection.
  Uses Ecto embedded schema for structured validation.
  """
  use Ecto.Schema
  use Gettext, backend: TymeslotWeb.Gettext
  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.URL, as: URLValidator
  alias Tymeslot.Security.{RateLimiter, UniversalSanitizer}
  alias Tymeslot.Utils.ChangesetErrors
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Webhooks.{SsrfValidator, WebhookSchema}

  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:url, :string)
    field(:events, {:array, :string}, default: [])
  end

  # Interactive validation (every blur, every event-checkbox toggle) and the
  # actual save used to share this one bucket, so typing could spend the
  # budget the save needed and refuse a save the user never rate-limited
  # themselves on. Interactive callers pass `bucket: :webhook_form_validate`
  # for a separate, looser budget; the save path keeps the default.
  @default_bucket :webhook_form

  @doc """
  Validates webhook form input.

  ## Parameters
  - `params` - Map containing webhook form parameters
  - `opts` - Options including metadata for logging, plus `:bucket`, the
    `Tymeslot.Security.RateLimiter.Limits` entry to charge in place of the
    save path's `:webhook_form`

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_webhook_form(map(), keyword()) ::
          {:ok, map()} | {:error, map() | :rate_limited}
  def validate_webhook_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    bucket = Keyword.get(opts, :bucket, @default_bucket)

    case check_rate_limit(bucket, metadata) do
      :ok ->
        with {:ok, sanitized_params} <- sanitize_text_fields(params, metadata) do
          sanitized_params
          |> perform_webhook_validation(Keyword.get(opts, :stored_name))
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
    {:error, ChangesetErrors.first_per_field(changeset)}
  end

  defp perform_webhook_validation(params, stored_name) do
    name_range = Constraints.integration_name_length_range()

    %__MODULE__{}
    |> cast(params, [:name, :url, :events])
    |> validate_required([:name], message: dgettext_noop("errors", "Name cannot be empty"))
    |> validate_required([:url])
    |> validate_length(:name,
      min: name_range.first,
      max: Constraints.integration_name_max_length(params["name"], stored_name)
    )
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
        {:error, error} -> [events: error]
      end
    end)
  end

  # `Tymeslot.Security.RateLimiter.Integrations` states the rule this used to
  # break: never one instance-wide bucket, the actor is always required.
  # A bare literal key gave every logged-in user of an instance the same 60/min
  # budget, so one of them could refuse webhook edits for all the others.
  defp check_rate_limit(bucket, metadata) do
    case RateLimiter.check(bucket, actor(metadata)) do
      :ok -> :ok
      {:error, :rate_limited, _message} -> {:error, :rate_limited}
    end
  end

  defp actor(%{user_id: nil} = metadata), do: actor(Map.delete(metadata, :user_id))
  defp actor(%{user_id: user_id}), do: "user:#{user_id}"
  defp actor(%{ip: ip}) when is_binary(ip), do: "ip:#{RateLimiter.source_key(ip)}"

  # Still reachable: validate_webhook_form/2's `metadata` opt defaults to
  # %{}, so a caller that omits it (every current one supplies it) shares one
  # bucket with every other such caller rather than crashing.
  defp actor(_metadata), do: "unknown"

  defp sanitize_text_fields(params, metadata) do
    with {:ok, sanitized_name} <- sanitize_field_for_form(params["name"], :name, metadata),
         {:ok, sanitized_url} <- sanitize_field_for_form(params["url"], :url, metadata) do
      {:ok, params |> Map.put("name", sanitized_name) |> Map.put("url", sanitized_url)}
    end
  end

  defp sanitize_field_for_form(value, _field, _metadata) when value in [nil, ""], do: {:ok, value}

  # `UniversalSanitizer`'s moduledoc warns `:plain_text` mode away from
  # values that get interpolated into URLs, because `:strict` mode is the
  # one that would normally guard against that. Here the value IS the URL
  # itself, not something interpolated into one: `:strict` would mangle a
  # legitimate query string or a `--` path segment via its SQL-injection and
  # path-traversal stripping, and `:plain_text` only strips null bytes and
  # trims — every scheme/host/private-IP check still runs afterwards via
  # `validate_url_format/1` -> `UrlValidation.validate_http_url/2`, which is
  # what actually rejects `javascript:`, `data:`, and similar.
  defp sanitize_field_for_form(value, field, metadata) when is_binary(value) do
    case UniversalSanitizer.sanitize_and_validate(value, mode: :plain_text, metadata: metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, reason} -> {:error, %{field => reason}}
    end
  end

  defp sanitize_field_for_form(_value, field, _metadata),
    do: {:error, %{field => "must be a string"}}
end
